-- EbonClearance_RealmComms.lua
-- Realm-wide addon comms over a hidden, private chat channel.
--
-- Why a chat channel: on WoW 3.3.5a SendAddonMessage only reaches GUILD /
-- PARTY / RAID / BATTLEGROUND / WHISPER - there is no realm-wide addon
-- channel. Realm-wide features (the Server Stats odometer, realm-wide update
-- checks) therefore ride a private named chat channel: join it, hide it from
-- the chat UI, send with SendChatMessage(..., "CHANNEL", ...), receive via
-- CHAT_MSG_CHANNEL. This is the same proven 3.3.5a technique a sibling addon
-- on this server uses for peer sync (neutral framing per repo rule).
--
-- SIBLING of NS.Comms, not a replacement: NS.Comms stays the guild/group
-- SendAddonMessage transport. NS.RealmComms mirrors its RegisterHandler / Send
-- shape so consumers feel identical, minus channel/target (there is only one
-- destination: the realm channel).
--
-- 3.3.5a constraints baked in:
--   * No RegisterAddonMessagePrefix (this isn't an addon message).
--   * Payloads are SINGLE messages - NO chunking. Consumers cap their own
--     payloads well under the ~255-char SendChatMessage limit.
--   * Delimiter is "|" escaped as "||" (NOT a tab: SendChatMessage can mangle
--     control chars). Safe because GuildShare.zoneNameSafe forbids "|" in every
--     payload field, so the only "|" are the structural section delimiters. On
--     receive we unescape, strip any server-injected colour / tier prefix
--     (e.g. "[HCIV]"), then split - mirroring the sibling addon's hardening.
--   * No C_Timer: an OnUpdate queue paces sends at ~6.7 msg/s (under the
--     ~10 msg/s anti-spam ceiling).
local NS = select(2, ...)
local L = NS.L

local RealmComms = {}
NS.RealmComms = RealmComms

local CHANNEL_NAME = "ebonclearance" -- private; must not collide with other addons' channels
local SEND_DELAY = 0.15 -- ~6.7 msg/s; under the ~10 msg/s 3.3.5a ceiling
local MAX_QUEUE = 100 -- safety cap; our traffic is tiny (one line per request/reply)
local MAX_WIRE = 250 -- SendChatMessage hard limit is ~255; consumers cap payloads at 200

local handlers = {} -- msgType -> fn(payload, sender)
local sendQueue = {}
local nextSendTime = 0
local channelIndex = nil
local joined = false

local function isOurChannel(name)
    return type(name) == "string" and name:lower():find(CHANNEL_NAME, 1, true) ~= nil
end

-- GetChannelList() returns joined channels as (id, name) pairs.
local function findChannel()
    if not GetChannelList then
        return nil
    end
    local all = { GetChannelList() }
    for i = 1, #all, 2 do
        local idx = tonumber(all[i])
        local nm = all[i + 1]
        if idx and idx > 0 and isOurChannel(nm) then
            return idx
        end
    end
    return nil
end

local function hideChannelFromChat()
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local f = _G["ChatFrame" .. i]
        if f and ChatFrame_RemoveChannel then
            ChatFrame_RemoveChannel(f, CHANNEL_NAME)
        end
    end
end

-- Server cores can prepend colour escapes / bracket tier tags (e.g.
-- "|cffff0000[HCIV]|r") to chat text. Strip colour escapes, then a leading
-- bracket-enclosed prefix, before parsing our payload.
local function stripPrefix(msg)
    local s = msg:gsub("|c%x+", ""):gsub("|r", "")
    s = s:gsub("^%s*%[[^%]]+%]%s*", "")
    return s
end

function RealmComms.RegisterHandler(msgType, fn)
    handlers[msgType] = fn
end

function RealmComms.IsJoined()
    return joined and channelIndex ~= nil
end

-- Join + hide the private channel. Gated by the caller (only invoked when a
-- realm feature is opted in), so joining a channel slot is never unsolicited.
function RealmComms.Join()
    if joined then
        return
    end
    joined = true -- set first so a failed join doesn't retry every call
    channelIndex = findChannel() or JoinChannelByName(CHANNEL_NAME)
    if channelIndex and channelIndex > 0 then
        hideChannelFromChat()
    end
    -- JoinChannelByName may settle a moment later and GetChannelList only then
    -- reflects the real index; re-find + re-hide shortly after. (The index is
    -- also learned from the first message we receive on the channel.)
    if NS.Delay then
        NS.Delay(1, function()
            local idx = findChannel()
            if idx and idx > 0 then
                channelIndex = idx
            end
            hideChannelFromChat()
        end)
    end
end

function RealmComms.Send(msgType, payload)
    if not joined then
        RealmComms.Join()
    end
    -- Escape every "|" so the server's colour-escape parser and our delimiter
    -- can't collide; the receiver reverses this before splitting.
    local wire = (tostring(msgType) .. "|" .. tostring(payload)):gsub("|", "||")
    if #wire > MAX_WIRE then
        return -- single-message transport; the consumer must cap its payload
    end
    if #sendQueue >= MAX_QUEUE then
        table.remove(sendQueue, 1)
    end
    sendQueue[#sendQueue + 1] = wire
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("CHAT_MSG_CHANNEL")
-- CHAT_MSG_CHANNEL args: text(1), author(2), lang(3), channelName(4), _(5),
-- _(6), _(7), channelNumber(8). We key off channelNumber (arg8), matching the
-- sibling addon's proven arg layout on this server.
frame:SetScript("OnEvent", function(self, event, text, sender, _, chanString, _, _, _, chanNum)
    -- Once our index is known, a different channel number is a cheap skip that
    -- filters out all General/Trade/etc. traffic before any string work. But
    -- channel indices RENUMBER when a lower-numbered channel is left, so a
    -- number mismatch alone must not make us deaf: if the channel-name string
    -- (arg4) is ours, fall through and re-learn the new index below.
    if channelIndex and chanNum and chanNum ~= channelIndex and not isOurChannel(chanString) then
        return
    end
    if type(text) ~= "string" then
        return
    end
    local decoded = stripPrefix(text:gsub("||", "|"))
    local parts = { strsplit("|", decoded) }
    local msgType = parts[1]
    if not msgType or not handlers[msgType] then
        return -- not one of ours (the msgType token is the discriminator)
    end
    -- Learn / refresh our channel index from a message that matched a handler.
    -- On a renumber, re-hide too (the channel can resurface in chat tabs
    -- under its new number).
    if type(chanNum) == "number" and chanNum > 0 then
        if channelIndex and channelIndex ~= chanNum then
            hideChannelFromChat()
        end
        channelIndex = chanNum
    end
    -- Rejoin the payload's own "|" section delimiters (parts 2..n).
    local payload = table.concat(parts, "|", 2)
    pcall(handlers[msgType], payload, sender)
end)

frame:SetScript("OnUpdate", function()
    if #sendQueue == 0 then
        return
    end
    local now = GetTime()
    if now < nextSendTime then
        return
    end
    -- Re-validate the cached index right before sending. Channel indices
    -- renumber when a lower-numbered channel is left; pcall only catches an
    -- INVALID index, not a successful send to whatever channel now owns the
    -- old slot - which would post the raw payload into General/Trade for
    -- everyone. One GetChannelName per queued send is cheap insurance.
    if channelIndex and channelIndex > 0 and GetChannelName then
        local _, liveName = GetChannelName(channelIndex)
        if not isOurChannel(liveName) then
            channelIndex = findChannel()
            if channelIndex then
                hideChannelFromChat()
            end
        end
    end
    local wire = table.remove(sendQueue, 1)
    -- Index fast-path, name fallback; both guarded (a stale index errors).
    local sent = false
    if channelIndex and channelIndex > 0 then
        sent = pcall(SendChatMessage, wire, "CHANNEL", nil, channelIndex)
    end
    if not sent then
        pcall(SendChatMessage, wire, "CHANNEL", nil, CHANNEL_NAME)
    end
    nextSendTime = now + SEND_DELAY
end)

-- ---- self-test diagnostic (/ec realmtest) -------------------------------
-- A solo player can verify the whole transport with no second client: chat
-- channels echo your own messages back, so a ping we send returns to us.
local selfTestToken = nil
local selfTestEchoed = false

RealmComms.RegisterHandler("RPNG", function(payload, sender)
    if selfTestToken and payload == selfTestToken then
        selfTestEchoed = true
        NS.PrintNicef(L["Realm channel OK: message echoed back (from %s)."], tostring(sender))
    end
end)

function RealmComms.RunSelfTest()
    RealmComms.Join()
    NS.PrintNicef(
        L["Realm channel self-test. Joined: %s, channel index: %s."],
        RealmComms.IsJoined() and L["yes"] or L["no"],
        tostring(channelIndex)
    )
    selfTestToken = tostring(GetTime())
    selfTestEchoed = false
    RealmComms.Send("RPNG", selfTestToken)
    NS.PrintNicef(L["Sent a channel ping; waiting for it to echo back..."])
    if NS.Delay then
        NS.Delay(3, function()
            if not selfTestEchoed then
                NS.PrintNicef(
                    L["Realm channel test inconclusive: no echo in 3s. Try /reload, or you may be in too many chat channels (10 max)."]
                )
            end
        end)
    end
end
