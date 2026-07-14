-- EbonClearance_ProcShare.lua
-- v2.53.0: guild/group-scoped anonymous sharing of confirmed chance-on-hit
-- proc-pairing knowledge. Rides on NS.Comms (PREQ request / PDAT reply).
-- Anonymous = the PDAT sender is ignored and never stored or shown; only the
-- pairing records are merged. Unlike EbonClearance_GuildShare, ProcShare has
-- no optional "name" section - pairing knowledge is a fact, not an
-- achievement, so attribution has no value.
--
-- The knowledge base lives at ADB.chanceProcConfirmedItems (account-wide),
-- populated locally by EC_TryAutolearnFromLearnedSpell in v2.49.1. This
-- consumer lets a guildmate's autolearned pairings propagate opt-in.
--
-- Merge policy: local-wins. A received pair is written only if the local
-- ADB.chanceProcConfirmedItems[itemID] is nil, so a corrupt sender cannot
-- overwrite a good local record.
local NS = select(2, ...)

local ProcShare = {}
NS.ProcShare = ProcShare

local MAX_PAYLOAD = 240 -- stay safely under the ~255-byte addon-message limit
local RECENT_MERGE_MAX = 20

-- Delimiter-safe check for strings that ride inside pair records.
-- Pair delimiter is `~`, inter-pair is `;`, section delimiter is `|` (unused
-- here since ProcShare only has one section but reserved to match GuildShare's
-- envelope). Tab is also reserved by the transport (NS.Comms uses it as the
-- msgType-payload separator).
local function pairFieldSafe(s)
    return type(s) == "string" and s ~= "" and not s:find("[~;|\t]")
end

-- Build the wire payload from ADB.chanceProcConfirmedItems. Trims oldest
-- `learnedAt` first if the whole thing exceeds MAX_PAYLOAD - most recent
-- learnings are more likely to be valuable / accurate.
function ProcShare.encodePayload(pairs_)
    if type(pairs_) ~= "table" then
        return ""
    end
    -- Sort by learnedAt DESC so the newest ride first; trim from the tail if oversized.
    local arr = {}
    for id, rec in pairs(pairs_) do
        if type(id) == "number" and type(rec) == "table"
            and type(rec.spellID) == "number"
        then
            arr[#arr + 1] = {
                id = id,
                spellID = rec.spellID,
                family = rec.family,
                item = rec.item,
                learnedAt = tonumber(rec.learnedAt) or 0,
            }
        end
    end
    table.sort(arr, function(a, b) return a.learnedAt > b.learnedAt end)

    local parts = {}
    for _, e in ipairs(arr) do
        local family = pairFieldSafe(e.family) and e.family or ""
        local item = pairFieldSafe(e.item) and e.item or ""
        parts[#parts + 1] = string.format("%d~%d~%s~%s", e.id, e.spellID, family, item)
    end
    local payload = "pairs:" .. table.concat(parts, ";")

    -- Trim from the tail (oldest) until payload fits the cap.
    while #payload > MAX_PAYLOAD and #parts > 0 do
        parts[#parts] = nil
        payload = "pairs:" .. table.concat(parts, ";")
    end

    return payload
end

-- Reverse of encodePayload. Returns { pairs = { [itemID] = { spellID, family, item }, ... } }.
-- Silently skips malformed rows.
function ProcShare.decodePayload(payload)
    local out = { pairs = {} }
    if type(payload) ~= "string" or payload == "" then
        return out
    end
    -- Order-independent section dispatch (matches GuildShare's envelope
    -- so a future added section slots in cleanly).
    for section in payload:gmatch("([^|]+)") do
        local prefix, body = section:match("^(%a+):(.*)$")
        if prefix == "pairs" and body and body ~= "" then
            for row in body:gmatch("([^;]+)") do
                local id, spellID, family, item = row:match("^(%-?%d+)~(%-?%d+)~([^~]*)~(.*)$")
                id = tonumber(id)
                spellID = tonumber(spellID)
                if id and spellID and id > 0 and spellID > 0 then
                    out.pairs[id] = {
                        spellID = spellID,
                        family = (family ~= "" and family) or nil,
                        item = (item ~= "" and item) or nil,
                    }
                end
            end
        end
    end
    return out
end

-- Session-local ring buffer of merges (both incoming and outgoing). Session
-- only; wiped on /reload. Consumed by /ec bugreport.
local recentMerges = {}
NS.recentProcShareMerges = recentMerges
NS.recentProcShareMergesMax = RECENT_MERGE_MAX

local function logMerge(itemID, spellID, family, item, direction)
    if #recentMerges >= RECENT_MERGE_MAX then
        table.remove(recentMerges, 1)
    end
    recentMerges[#recentMerges + 1] = {
        itemID = itemID,
        spellID = spellID,
        family = family or "?",
        item = item or ("item:" .. tostring(itemID)),
        direction = direction or "?",
        loggedAt = date("%H:%M:%S"),
    }
end

-- Apply a decoded payload to ADB.chanceProcConfirmedItems. Local-wins: skip
-- itemIDs the local player already has. Returns the count merged.
function ProcShare.mergeReply(decoded)
    local ADB = NS.ADB
    if not (ADB and ADB.chanceProcConfirmedItems) then
        return 0
    end
    local n = 0
    for id, rec in pairs(decoded.pairs or {}) do
        if not ADB.chanceProcConfirmedItems[id] then
            ADB.chanceProcConfirmedItems[id] = {
                spellID = rec.spellID,
                family = rec.family,
                item = rec.item,
                learnedAt = GetTime(),
            }
            n = n + 1
            logMerge(id, rec.spellID, rec.family, rec.item, "in")
        end
    end
    return n
end

-- ---- transport consumer + on-demand request ----------------------------
-- Match the Comms per-channel send throttle (30s). RequestNow does NOT
-- clear ADB (unlike GuildShare's session-only aggregate reset) because
-- pairings are persistent knowledge - a Refresh keeps prior merges.
local PREQ_THROTTLE_S = 30
local lastReqAt = 0

function ProcShare.RequestNow()
    local now = GetTime()
    if (now - lastReqAt) < PREQ_THROTTLE_S then
        return
    end
    lastReqAt = now
    if GetGuildInfo("player") then
        NS.Comms.Send("PREQ", "", "GUILD")
    end
    if GetNumRaidMembers() > 0 then
        NS.Comms.Send("PREQ", "", "RAID")
    elseif GetNumPartyMembers() > 0 then
        NS.Comms.Send("PREQ", "", "PARTY")
    end
end

local function playerName()
    return UnitName("player")
end

-- Diagnostic (/ec procsharetest): simulate guildmates replying so the merge
-- pipeline can be exercised on one account. Merges a few fake pairs through
-- the real merge path. Touches ADB.chanceProcConfirmedItems (persistent) so
-- the fake IDs used are high-range to avoid clashing with real 3.3.5a items.
function ProcShare.InjectTestPeers()
    local fakes = {
        pairs = {
            [999901] = { spellID = 700901, family = "Test Family A", item = "Test Item Alpha" },
            [999902] = { spellID = 700902, family = "Test Family B", item = "Test Item Bravo" },
            [999903] = { spellID = 700903, family = "Test Family C", item = "Test Item Charlie" },
        },
    }
    local n = ProcShare.mergeReply(fakes)
    if NS.PrintNicef then
        NS.PrintNicef("|cff66ccff[EC ProcShare]|r injected %d fake pairing(s) into ADB.chanceProcConfirmedItems", n)
    end
    return n
end

-- A peer asked for our pairings: reply by whisper IF we opted in. The sender
-- is used only as the whisper target; it is never stored or displayed.
NS.Comms.RegisterHandler("PREQ", function(_, sender, _)
    if not (EbonClearanceDB and EbonClearanceDB.shareChanceProcs) then
        return
    end
    if sender and sender ~= playerName() then
        local ADB = NS.ADB or {}
        local payload = ProcShare.encodePayload(ADB.chanceProcConfirmedItems or {})
        if payload and payload ~= "pairs:" then
            NS.Comms.Send("PDAT", payload, "WHISPER", sender)
            -- Log the outgoing send with a synthetic entry (no per-pair detail).
            -- The requester's name is kept HERE on purpose: /ec bugreport prints
            -- the merge ring and the maintainer wants to see WHO asked for data
            -- when debugging share issues. The anonymity contract covers the
            -- INCOMING path (data contributors are never named in ADB or the
            -- ring); the outgoing requester is diagnostic metadata, not shared
            -- data.
            logMerge(0, 0, "outgoing", "PDAT sent to " .. tostring(sender), "out")
        end
    end
end)

-- A reply arrived: merge anonymously (sender ignored entirely).
NS.Comms.RegisterHandler("PDAT", function(payload, _, _)
    ProcShare.mergeReply(ProcShare.decodePayload(payload))
    if NS.RefreshGuildPanel then
        NS.RefreshGuildPanel()
    end
end)
