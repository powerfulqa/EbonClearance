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
--                                       EnsureDB in EbonClearance.lua)
--   * NS.PET_NAME_LC                  live lowercase pet name (refreshed
--                                       by EnsureDB + refreshNames)
--
-- All three are mirrored onto NS at the binding sites in EbonClearance.lua.
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

local function EC_TrackGreedySpeech(msg)
    msg = EC_StripCodes(msg)
    if not msg or msg == "" then
        return
    end
    msg = msg:lower()
    -- Store the time of speech rather than a boolean; the bubble OnUpdate
    -- prunes entries older than 8 s each tick (chat bubbles in 3.3.5 are
    -- visible for ~5-7 s, so an 8 s TTL covers a bubble's lifetime). The
    -- truthy value still satisfies the existing
    -- `if EC_greedyMessages[clean] then` match in the bubble walker.
    EC_greedyMessages[msg] = GetTime()
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

local function EC_InstallGreedyMuteOnce()
    if EC_greedyFiltersInstalled then
        return
    end
    EC_greedyFiltersInstalled = true

    ChatFrame_AddMessageEventFilter("CHAT_MSG_MONSTER_SAY", EC_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_MONSTER_YELL", EC_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_MONSTER_WHISPER", EC_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_MONSTER_EMOTE", EC_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_MONSTER_PARTY", EC_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_SAY", EC_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_YELL", EC_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_TEXT_EMOTE", EC_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_EMOTE", EC_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", EC_GreedyEventFilter)
end
NS.InstallGreedyMuteOnce = EC_InstallGreedyMuteOnce

local EC_bubbleFrame = CreateFrame("Frame")
local EC_killedBubbles = setmetatable({}, { __mode = "k" })

local function EC_KillBubbleFrame(frame)
    if not frame or frame.__EC_killed then
        return
    end
    frame.__EC_killed = true
    EC_killedBubbles[frame] = true

    frame:SetAlpha(0)
    frame:EnableMouse(false)
    frame:Hide()

    if frame.HookScript then
        frame:HookScript("OnShow", function(self)
            self:SetAlpha(0)
            self:Hide()
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
    local now = GetTime()
    local hasLive = false
    for k, t in pairs(EC_greedyMessages) do
        if (now - t) > 8 then
            EC_greedyMessages[k] = nil
        else
            hasLive = true
        end
    end

    -- Nothing tracked: no killed frames to re-hide and no live Greedy speech
    -- to match against. Becomes a constant-time no-op until either set fills.
    if not next(EC_killedBubbles) and not hasLive then
        return
    end

    for bubble in pairs(EC_killedBubbles) do
        if bubble and bubble.IsShown and bubble:IsShown() then
            bubble:SetAlpha(0)
            bubble:Hide()
        end
    end

    if not hasLive then
        return
    end

    local numChildren = WorldFrame and WorldFrame.GetNumChildren and WorldFrame:GetNumChildren() or 0
    for i = 1, numChildren do
        local child = select(i, WorldFrame:GetChildren())
        if child and child.GetObjectType and child:GetObjectType() == "Frame" and child:IsVisible() then
            local numRegions = child.GetNumRegions and child:GetNumRegions() or 0
            for j = 1, numRegions do
                local region = select(j, child:GetRegions())
                if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                    local text = region:GetText()
                    if text then
                        local clean = EC_StripCodes(text):lower()
                        if EC_greedyMessages[clean] then
                            EC_KillBubbleFrame(child)
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
