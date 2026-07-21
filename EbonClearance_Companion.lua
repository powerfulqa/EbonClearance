-- EbonClearance_Companion - Greedy Scavenger chat / bubble filtering.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 3 of the multi-stage file split tracked in docs/CODE_REVIEW.md
-- item 4. This file owns the contiguous chat-filter / speech-bubble
-- cluster that previously lived in EbonClearance.lua at lines ~164-446:
--
--   * EC_GreedyEventFilter      (per-chat-event mute + speech tracker)
--   * EC_InstallGreedyMuteOnce  (one-shot install on 10 chat events;
--                                exposed as NS.InstallGreedyMuteOnce)
--   * EC_bubbleFrame OnUpdate   (200 ms WorldFrame walker, 8 s TTL
--                                speech window, weak-table kill set)
--   * ApplyGreedyChatFilter     (secondary CHAT_MSG_SAY/YELL/EMOTE
--                                filter, settings-driven add/remove;
--                                exposed as NS.ApplyGreedyChatFilter)
--
-- Cross-file API surface this file relies on:
--   * NS.compCache.lastScavSpokeAt    written by EC_GreedyEventFilter
--   * NS.compCache.scavSpeechEverHeard  written by EC_GreedyEventFilter
--   * NS.DB                           live DB binding (refreshed by
--                                       EnsureDB in EbonClearance_Events.lua)
--   * NS.PET_NAME_LC                  live lowercase pet name (refreshed
--                                       by EnsureDB + refreshNames)
--
-- All three are mirrored onto NS at the binding sites in EbonClearance_Events.lua.
-- This file reads them inline at call time so it always sees the latest
-- value (no stale upvalues even if EnsureDB rebinds mid-session).

local NS = select(2, ...)
local EC_compCache = NS.compCache

-- Cached API upvalue. Refreshed here at file load so the chat-filter and
-- bubble walker hot paths resolve via local rather than _G index lookup.
local GetTime = GetTime

-- Per-session state local to this module:
--   * EC_greedyMessages[lowercased-cleaned-msg] = GetTime() entry, pruned
--     by the bubble OnUpdate at 8 s TTL.
--   * EC_greedyFiltersInstalled gates EC_InstallGreedyMuteOnce so the
--     ChatFrame_AddMessageEventFilter calls fire exactly once per session.
local EC_greedyMessages = {}
local EC_greedyFiltersInstalled = false

-- /ec bubbles diagnostic rings (session-only, never persisted). One records
-- what the chat filter tracked for bubble-matching; the other records the
-- sentence-length texts the bubble walker actually read off screen and
-- whether each matched. When a bubble escapes the mute, diffing the two
-- shows exactly why (line never tracked vs text divergence) instead of
-- guessing at chat formatting. Declared here, above EC_TrackGreedySpeech,
-- so the push helper is a resolved upvalue at its call sites.
NS.recentGreedyTracked = {}
NS.recentBubbleSeen = {}
local EC_BUBBLE_RING_MAX = 15
local function EC_PushBubbleRing(ring, key, matched)
    local top = ring[1]
    if top and top.key == key and top.matched == matched then
        top.at = GetTime() -- refresh the repeat instead of flooding the ring
        return
    end
    table.insert(ring, 1, { key = key, matched = matched, at = GetTime() })
    if #ring > EC_BUBBLE_RING_MAX then
        table.remove(ring)
    end
end

local function EC_StripCodes(s)
    if type(s) ~= "string" then
        return nil
    end
    return s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h", ""):gsub("|h", "")
end

local function EC_IsGreedyAuthor(author)
    if type(author) ~= "string" then
        return false
    end
    author = EC_StripCodes(author)
    if not author or author == "" then
        return false
    end
    return author:lower() == NS.PET_NAME_LC
end

-- Canonical matching key: codes stripped, lowercased, punctuation dropped,
-- whitespace collapsed. The CHAT text and the BUBBLE text for the same line
-- can differ in embedded formatting (coloured player names, link wrappers,
-- brackets - the client renders bubbles differently from chat lines), so
-- exact string equality misses those lines. Reducing both sides to plain
-- letters, digits, and single spaces makes the match format-blind. Root
-- cause of the resummon "Beep. Configuration loaded from <name>'s
-- preferences..." bubble escaping the mute while its chat line was hidden.
local function EC_GreedyKey(s)
    s = EC_StripCodes(s)
    if not s or s == "" then
        return nil
    end
    s = s:lower()
    s = s:gsub("[^%w%s]", "")
    s = s:gsub("%s+", " ")
    if s == "" then
        return nil
    end
    return s
end

local function EC_TrackGreedySpeech(msg)
    local key = EC_GreedyKey(msg)
    if not key then
        return
    end
    EC_PushBubbleRing(NS.recentGreedyTracked, key)
    -- Store the time of speech rather than a boolean; the bubble OnUpdate
    -- prunes entries older than 8 s each tick (chat bubbles in 3.3.5 are
    -- visible for ~5-7 s, so an 8 s TTL covers a bubble's lifetime). The
    -- truthy value still satisfies the existing table-membership match in
    -- the bubble walker.
    EC_greedyMessages[key] = GetTime()
end

local function EC_GreedyEventFilter(self, _event, msg, author)
    local DB = NS.DB
    local hideChat = true
    local hideBubbles = true
    if DB then
        hideChat = (DB.muteGreedy == true) or (DB.hideGreedyChat == true)
        hideBubbles = (DB.muteGreedy == true) or (DB.hideGreedyBubbles == true)
    end

    -- Record the Scavenger's speech timestamp BEFORE the mute-disabled
    -- early-return below, so the loot-silence stuck signal works even when
    -- the user has both chat and bubble mute off. Gated on DB.autoLootCycle
    -- so users not running the cycle don't pay the author-check on every
    -- chat line.
    --
    -- v2.8.0: substring match on author OR body. Strict equality on
    -- "greedy scavenger" missed Project Ebonhold's customised pet names
    -- (e.g. "Serv's Scavenger") and emote-style messages whose body
    -- contains the species name but no "says/yells/whispers" pattern
    -- ("Greedy Scavenger gnaws on the corpse"). Either source naming the
    -- pet is enough to refresh the speech baseline. Without this, normal
    -- farming triggered false positives every time the player looted
    -- 2 items in 60 s.
    if DB and DB.autoLootCycle then
        local lcAuthor = type(author) == "string" and author:lower() or ""
        if lcAuthor:find("scavenger", 1, true) then
            EC_compCache.lastScavSpokeAt = GetTime()
            -- v2.10.0: arm the silent-realm guard. Set ONLY by real chat
            -- matches; the on-summon synthetic refresh further down does
            -- not touch this flag. Once true, the loot-silence stuck
            -- signal is allowed to fire for the rest of the session.
            EC_compCache.scavSpeechEverHeard = true
        elseif type(msg) == "string" then
            local lcMsg = EC_StripCodes(msg):lower()
            if lcMsg:find("scavenger", 1, true) then
                EC_compCache.lastScavSpokeAt = GetTime()
                EC_compCache.scavSpeechEverHeard = true
            end
        end
    end

    -- Both feature flags off -> filter has no effect; skip the string-op tail.
    -- Fires on 10 chat events for every line of chat received.
    if not hideChat and not hideBubbles then
        return false
    end

    if EC_IsGreedyAuthor(author) then
        if hideBubbles and type(msg) == "string" then
            EC_TrackGreedySpeech(msg)
        end
        if hideChat then
            return true
        end
    end

    if type(msg) == "string" then
        local clean = EC_StripCodes(msg):lower()
        if
            clean:find("greedy scavenger", 1, true)
            and (clean:find(" says", 1, true) or clean:find(" yells", 1, true) or clean:find(" whispers", 1, true))
        then
            -- Textual-fallback path. Refresh the speech timestamp here too so
            -- the loot-silence signal stays accurate when the chat line
            -- arrives via an event that doesn't set the author field.
            -- v2.10.0: also arm the silent-realm guard here, on the same
            -- "real-speech-observed" rule as the author/body matches above.
            if DB and DB.autoLootCycle then
                EC_compCache.lastScavSpokeAt = GetTime()
                EC_compCache.scavSpeechEverHeard = true
            end
            if hideBubbles then
                local said = clean:match("greedy scavenger%s*says[:%s]*(.*)")
                    or clean:match("greedy scavenger%s*yells[:%s]*(.*)")
                    or clean:match("greedy scavenger%s*whispers[:%s]*(.*)")
                if said then
                    EC_TrackGreedySpeech(said)
                end
            end
            if hideChat then
                return true
            end
        end
    end

    return false
end

-- EC-TRAP: two chat-filter systems coexist on purpose. This one
-- (EC_GreedyEventFilter) also drives loot-silence stuck detection via the
-- speech timestamps. Do NOT merge it with, or delete, the other system
-- (ApplyGreedyChatFilter below) without the side-by-side test. See
-- docs/CODE_REVIEW.md item 1.
local function EC_InstallGreedyMuteOnce()
    if EC_greedyFiltersInstalled then
        return
    end
    EC_greedyFiltersInstalled = true

    -- CHAT_MSG_SYSTEM dropped (post-audit): system messages never have the
    -- pet as their author, so the filter would always fall through to the
    -- substring-match tail and never produce a useful hide. The dispatch
    -- still cost a gsub-laden EC_StripCodes + find on every system line.
    ChatFrame_AddMessageEventFilter("CHAT_MSG_MONSTER_SAY", EC_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_MONSTER_YELL", EC_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_MONSTER_WHISPER", EC_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_MONSTER_EMOTE", EC_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_MONSTER_PARTY", EC_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_SAY", EC_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_YELL", EC_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_TEXT_EMOTE", EC_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_EMOTE", EC_GreedyEventFilter)
end
NS.InstallGreedyMuteOnce = EC_InstallGreedyMuteOnce

local EC_bubbleFrame = CreateFrame("Frame")
local EC_killedBubbles = setmetatable({}, { __mode = "k" })

-- Decide whether a previously-killed bubble frame must STAY hidden. Two
-- reasons to stay hidden: (a) the frame still shows the exact text it was
-- killed for (frame.__EC_killedKey) - the client keeps a bubble's text for
-- its whole life, which on this server outlives the 8 s tracking TTL, so
-- the TTL alone must never un-hide a killed bubble mid-life; (b) the frame
-- now shows a DIFFERENT tracked live Greedy line (recycled for the pet's
-- next sentence) - re-key and keep hiding. Only a text change to something
-- untracked means the frame was recycled for another speaker and has to
-- come back, or bubble-mute users slowly lose everyone's bubbles.
local function EC_BubbleShouldStayHidden(frame)
    if not (frame and frame.GetNumRegions) then
        return false
    end
    local now = GetTime()
    local numRegions = frame:GetNumRegions() or 0
    local regions = numRegions > 0 and { frame:GetRegions() } or nil
    for j = 1, numRegions do
        local region = regions[j]
        if region and region.GetObjectType and region:GetObjectType() == "FontString" then
            local key = EC_GreedyKey(region:GetText())
            if key then
                if frame.__EC_killedKey and key == frame.__EC_killedKey then
                    return true
                end
                local t = EC_greedyMessages[key]
                if t and (now - t) <= 8 then
                    frame.__EC_killedKey = key
                    return true
                end
            end
        end
    end
    return false
end

local function EC_RestoreBubbleFrame(frame)
    EC_killedBubbles[frame] = nil
    frame.__EC_killedKey = nil
    frame:SetAlpha(1)
    frame:EnableMouse(frame.__EC_prevMouse == true)
    -- Clear the captured mouse state so a later re-kill of this recycled
    -- frame re-captures the live value instead of reusing a stale one.
    frame.__EC_prevMouse = nil
end

local function EC_KillBubbleFrame(frame, key)
    if not frame then
        return
    end
    EC_killedBubbles[frame] = true
    if key then
        frame.__EC_killedKey = key
    end
    if frame.__EC_prevMouse == nil then
        frame.__EC_prevMouse = (frame.IsMouseEnabled and frame:IsMouseEnabled()) == true
    end
    frame:SetAlpha(0)
    frame:EnableMouse(false)
    frame:Hide()

    -- Install the OnShow guard once per frame. __EC_killed marks "hook
    -- installed", NOT "suppressed" (HookScript cannot be removed); the
    -- suppression decision is re-derived from the current text every show,
    -- so a recycled frame carrying a different bubble restores itself.
    if frame.__EC_killed then
        return
    end
    frame.__EC_killed = true
    if frame.HookScript then
        frame:HookScript("OnShow", function(self)
            if not EC_killedBubbles[self] then
                return
            end
            if EC_BubbleShouldStayHidden(self) then
                self:SetAlpha(0)
                self:Hide()
            else
                EC_RestoreBubbleFrame(self)
            end
        end)
    end
end
EC_bubbleFrame.elapsed = 0
EC_bubbleFrame:SetScript("OnUpdate", function(self, elapsed)
    local DB = NS.DB
    local hideBubbles = true
    if DB then
        hideBubbles = (DB.muteGreedy == true) or (DB.hideGreedyBubbles == true)
    end
    if not hideBubbles then
        return
    end

    -- Tick gate. 200 ms is short enough that a fresh bubble dies in 1-2
    -- ticks of its visibility window (bubbles last ~5-7 s) and long enough
    -- that the WorldFrame-children walk does not run more than five times
    -- per second in raids, where the child count is highest. Capping the
    -- gated work this way is the cheapest defence against a busy world.
    self.elapsed = (self.elapsed or 0) + elapsed
    if self.elapsed < 0.20 then
        return
    end
    self.elapsed = 0

    -- Prune expired greedy-speech timestamps (8 s TTL). Without this the
    -- set never empties on its own and the OnUpdate body keeps walking
    -- WorldFrame children long after the Scavenger has gone quiet.
    -- v2.62.1: also track the SHORTEST live key length. Normalisation only
    -- ever shortens a string, so any on-screen text shorter than the
    -- shortest tracked key can be skipped below without the ~6-gsub
    -- EC_GreedyKey pass - which used to run for every nameplate name and
    -- combat-text FontString in view during a speech window.
    local now = GetTime()
    local hasLive = false
    local minLiveKeyLen = math.huge
    for k, t in pairs(EC_greedyMessages) do
        if (now - t) > 8 then
            EC_greedyMessages[k] = nil
        else
            hasLive = true
            if #k < minLiveKeyLen then
                minLiveKeyLen = #k
            end
        end
    end

    -- Nothing tracked: no killed frames to re-hide and no live Greedy speech
    -- to match against. Becomes a constant-time no-op until either set fills.
    if not next(EC_killedBubbles) and not hasLive then
        return
    end

    for bubble in pairs(EC_killedBubbles) do
        if bubble and bubble.IsShown and bubble:IsShown() then
            if EC_BubbleShouldStayHidden(bubble) then
                bubble:SetAlpha(0)
                bubble:Hide()
            else
                -- Recycled frame now showing a DIFFERENT, untracked text
                -- (someone else's bubble): give it back.
                EC_RestoreBubbleFrame(bubble)
            end
        end
    end

    if not hasLive then
        return
    end

    -- Materialise the WorldFrame children + each child's regions into local
    -- tables before iterating. The original `select(i, frame:GetChildren())`
    -- inside a loop is O(numChildren) per iteration (varargs unpack is
    -- linear), making the nested walk O(children^2 * regions^2) per tick.
    -- In a busy raid (numChildren ~80 with floating combat text) that's
    -- tens of thousands of select operations every 200 ms.
    local numChildren = WorldFrame and WorldFrame.GetNumChildren and WorldFrame:GetNumChildren() or 0
    local children = numChildren > 0 and { WorldFrame:GetChildren() } or nil
    for i = 1, numChildren do
        local child = children[i]
        if child and child.GetObjectType and child:GetObjectType() == "Frame" and child:IsVisible() then
            local numRegions = child.GetNumRegions and child:GetNumRegions() or 0
            local regions = numRegions > 0 and { child:GetRegions() } or nil
            for j = 1, numRegions do
                local region = regions[j]
                if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                    local text = region:GetText()
                    -- Raw-length pre-filter (see the prune loop above): a
                    -- text shorter than the shortest live key can never
                    -- normalise into a match, so skip the string work.
                    if text and #text >= minLiveKeyLen then
                        local key = EC_GreedyKey(text)
                        local matched = key and EC_greedyMessages[key] ~= nil
                        -- Ring only sentence-length texts: the walk also sees
                        -- nameplate names and other short world FontStrings,
                        -- which would flood the diagnostic with noise.
                        if key and #key >= 25 then
                            EC_PushBubbleRing(NS.recentBubbleSeen, key, matched == true)
                        end
                        if matched then
                            EC_KillBubbleFrame(child, key)
                            break
                        end
                    end
                end
            end
        end
    end
end)

local CHAT_FILTER_EVENTS = {
    "CHAT_MSG_SAY",
    "CHAT_MSG_YELL",
    "CHAT_MSG_EMOTE",
    "CHAT_MSG_TEXT_EMOTE",
}

local function GreedyScavengerChatFilter(self, _event, _msg, author)
    if EC_IsGreedyAuthor(author) then
        return true
    end
    return false
end

-- Copyable diagnostic for the Greedy bubble mute (backs /ec bubbles).
-- Session-only. Shows the mute flags, what the chat filter tracked, and the
-- sentence-length bubble texts the walker examined with match verdicts,
-- newest first. A MISS row whose text differs from a tracked row is a
-- formatting divergence; an escaped bubble with NO tracked row at all means
-- the chat filter never saw (or never matched) the line.
function NS.ShowBubbleDiag()
    local DB = NS.DB
    local now = GetTime()
    local liveCount = 0
    for _ in pairs(EC_greedyMessages) do
        liveCount = liveCount + 1
    end
    local lines = {}
    lines[#lines + 1] = string.format(
        "Bubble mute diagnostic (matcher: normalized keys). muteGreedy=%s hideGreedyBubbles=%s live-tracked=%d",
        tostring(DB and DB.muteGreedy == true),
        tostring(DB and DB.hideGreedyBubbles == true),
        liveCount
    )
    lines[#lines + 1] = "-- Tracked by chat filter (newest first) --"
    if #NS.recentGreedyTracked == 0 then
        lines[#lines + 1] = "  (nothing tracked this session)"
    end
    for i = 1, #NS.recentGreedyTracked do
        local e = NS.recentGreedyTracked[i]
        lines[#lines + 1] = string.format("  %.0fs ago: %s", now - (e.at or now), tostring(e.key))
    end
    lines[#lines + 1] = "-- Bubble texts examined on screen (newest first) --"
    if #NS.recentBubbleSeen == 0 then
        lines[#lines + 1] = "  (none examined - no live tracked speech while bubbles were up)"
    end
    for i = 1, #NS.recentBubbleSeen do
        local e = NS.recentBubbleSeen[i]
        lines[#lines + 1] =
            string.format("  [%s] %.0fs ago: %s", e.matched and "HIDDEN" or "MISS", now - (e.at or now), tostring(e.key))
    end
    local body = table.concat(lines, "\n")
    if NS.ShowCopyFrame then
        NS.ShowCopyFrame("EbonClearance: Bubble Mute Diagnostic", body)
    elseif NS.PrintNice then
        NS.PrintNice(body)
    end
end

-- EC-TRAP: second of two intentional chat-filter systems (see
-- EC_InstallGreedyMuteOnce above). Do NOT assume this is redundant and
-- delete it. See docs/CODE_REVIEW.md item 1.
local function ApplyGreedyChatFilter()
    local DB = NS.DB
    for i = 1, #CHAT_FILTER_EVENTS do
        local ev = CHAT_FILTER_EVENTS[i]
        if ChatFrame_RemoveMessageEventFilter then
            ChatFrame_RemoveMessageEventFilter(ev, GreedyScavengerChatFilter)
        end
        if DB and ((DB.muteGreedy == true) or (DB.hideGreedyChat == true)) and ChatFrame_AddMessageEventFilter then
            ChatFrame_AddMessageEventFilter(ev, GreedyScavengerChatFilter)
        end
    end
end
NS.ApplyGreedyChatFilter = ApplyGreedyChatFilter
