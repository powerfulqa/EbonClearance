#!/usr/bin/env lua
-- Unit + static tests for proc-share encode/decode/merge (v2.53.0).
-- Run: lua tests/test_procshare.lua
-- Loads the chunk in isolation with a stub NS.Comms.

local handlers = {}
local sent = {}
local function clearSent()
    for i = #sent, 1, -1 do
        sent[i] = nil
    end
end

-- ADB stub. ProcShare merges into ADB.chanceProcConfirmedItems; the merge
-- policy is local-wins so pre-existing entries are preserved.
local adbConfirmed = {}
local NS = {
    Comms = {
        RegisterHandler = function(t, fn) handlers[t] = fn end,
        Send = function(t, payload, channel, target)
            sent[#sent + 1] = { t = t, payload = payload, channel = channel, target = target }
        end,
    },
    ADB = { chanceProcConfirmedItems = adbConfirmed },
    Delay = function() end,
    compCache = {},
}
_G.UnitName = function() return "Self" end
_G.GetTime = function() return 1234.5 end
_G.date = function() return "12:00:00" end

local chunk = assert(loadfile("EbonClearance_ProcShare.lua"))
chunk("EbonClearance", NS)
local ps = NS.ProcShare

local fails = 0
local function ok(name, cond)
    if cond then
        print("PASS  " .. name)
    else
        print("FAIL  " .. name)
        fails = fails + 1
    end
end
local function eq(name, a, b) ok(name .. " (" .. tostring(a) .. ")", a == b) end

-- ---- encode/decode roundtrip ----
local payload = ps.encodePayload({
    [12345] = { spellID = 700123, family = "Vulnerability", item = "Test Blade", learnedAt = 100 },
    [67890] = { spellID = 700456, family = "Iron Will", item = "Test Axe", learnedAt = 200 },
})
ok("payload has pairs section", payload:find("pairs:", 1, true) ~= nil)
ok("payload has itemID 12345", payload:find("12345~700123", 1, true) ~= nil)
ok("payload under 255 bytes", #payload < 255)

local dec = ps.decodePayload(payload)
eq("decode has pair 12345", dec.pairs[12345] and dec.pairs[12345].spellID, 700123)
eq("decode family", dec.pairs[12345] and dec.pairs[12345].family, "Vulnerability")
eq("decode item", dec.pairs[12345] and dec.pairs[12345].item, "Test Blade")
eq("decode has pair 67890", dec.pairs[67890] and dec.pairs[67890].spellID, 700456)

-- ---- cap enforcement: 240-byte limit trims oldest (lowest learnedAt) first ----
local many = {}
for i = 1, 30 do
    many[10000 + i] = { spellID = 700000 + i, family = "Family" .. i, item = "Item" .. i, learnedAt = i }
end
local capped = ps.encodePayload(many)
ok("capped payload under MAX_PAYLOAD", #capped <= 240)
local dCapped = ps.decodePayload(capped)
-- Highest learnedAt (i=30) must survive; lowest (i=1) must be trimmed.
ok("newest pair survives cap", dCapped.pairs[10030] ~= nil)
ok("oldest pair trimmed by cap", dCapped.pairs[10001] == nil)

-- ---- delimiter-unsafe fields are skipped/blanked ----
local bad = ps.encodePayload({
    [999] = { spellID = 700999, family = "Bad~Family", item = "Bad;Item", learnedAt = 1 },
})
ok("unsafe family blanked", not bad:find("Bad~Family", 1, true))
ok("unsafe item blanked", not bad:find("Bad;Item", 1, true))

-- ---- mergeReply: local-wins policy ----
for k in pairs(adbConfirmed) do adbConfirmed[k] = nil end -- reset
adbConfirmed[11111] = { spellID = 700111, family = "PreExisting", item = "PreExistingItem", learnedAt = 50 }
local decoded = ps.decodePayload(ps.encodePayload({
    [11111] = { spellID = 700999, family = "Attacker", item = "AttackerItem", learnedAt = 999 }, -- attempt to overwrite
    [22222] = { spellID = 700222, family = "New", item = "NewItem", learnedAt = 100 },
}))
local n = ps.mergeReply(decoded)
eq("merge only wrote 1 new (local-wins for 11111)", n, 1)
eq("local-wins: 11111 unchanged", adbConfirmed[11111].family, "PreExisting")
eq("11111 spellID preserved", adbConfirmed[11111].spellID, 700111)
eq("22222 merged in", adbConfirmed[22222] and adbConfirmed[22222].family, "New")

-- ---- ring buffer records the merge ----
ok("ring buffer populated by merge", #NS.recentProcShareMerges >= 1)
ok("ring buffer entry has direction", NS.recentProcShareMerges[1] and NS.recentProcShareMerges[1].direction == "in")

-- ---- transport handler behavior (privacy-critical paths) ----
EbonClearanceDB = {}

-- opt-in OFF: a PREQ from someone else produces no reply
EbonClearanceDB.shareChanceProcs = false
clearSent()
handlers.PREQ("", "Other", "GUILD")
ok("no reply when opted out", #sent == 0)

-- opt-in ON: a PREQ from someone else produces exactly one PDAT whisper
EbonClearanceDB.shareChanceProcs = true
clearSent()
handlers.PREQ("", "Other", "GUILD")
ok("one reply when opted in", #sent == 1)
ok("reply is PDAT", sent[1] and sent[1].t == "PDAT")
ok("reply is whisper to requester", sent[1] and sent[1].channel == "WHISPER" and sent[1].target == "Other")

-- PREQ from ourselves produces no reply (self-skip)
clearSent()
handlers.PREQ("", "Self", "GUILD")
ok("no self-reply", #sent == 0)

-- PDAT merges into ADB but sender name is never stored
for k in pairs(adbConfirmed) do adbConfirmed[k] = nil end
for i = #NS.recentProcShareMerges, 1, -1 do NS.recentProcShareMerges[i] = nil end
local pdatPayload = ps.encodePayload({
    [33333] = { spellID = 700333, family = "Merged", item = "MergedItem", learnedAt = 1 },
})
handlers.PDAT(pdatPayload, "SecretSenderName", "WHISPER")
ok("PDAT merged into ADB", adbConfirmed[33333] ~= nil)
local flat = {}
local function flatten(t)
    if type(t) ~= "table" then
        flat[#flat + 1] = tostring(t)
        return
    end
    for k, v in pairs(t) do
        flat[#flat + 1] = tostring(k)
        flatten(v)
    end
end
flatten(adbConfirmed)
flatten(NS.recentProcShareMerges)
ok("sender name not stored in ADB / ring", table.concat(flat, "|"):find("SecretSenderName", 1, true) == nil)

-- ---- static-pattern invariants (scan live code, not comments) ----
local function readCode(p)
    local fh = assert(io.open(p, "r"))
    local s = fh:read("*a")
    fh:close()
    local out = {}
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
        local t = line:match("^%s*(.-)%s*$") or ""
        if t:sub(1, 2) ~= "--" then out[#out + 1] = line end
    end
    return table.concat(out, "\n")
end
local share = readCode("EbonClearance_ProcShare.lua")
ok("exposes NS.ProcShare", share:find("NS.ProcShare", 1, true) ~= nil)
ok("exposes InjectTestPeers diagnostic", share:find("function ProcShare.InjectTestPeers", 1, true) ~= nil)
ok("uses NS.Comms transport", share:find("NS.Comms", 1, true) ~= nil)
ok("reply gated on shareChanceProcs", share:find("shareChanceProcs", 1, true) ~= nil)
ok("registers PREQ", share:find('"PREQ"', 1, true) ~= nil)
ok("registers PDAT", share:find('"PDAT"', 1, true) ~= nil)
ok("no 4.0 group event", not share:find("GROUP_ROSTER_UPDATE", 1, true))
ok("no RegisterAddonMessagePrefix", not share:find("RegisterAddonMessagePrefix", 1, true))

local panel = readCode("EbonClearance_GuildPanel.lua")
ok("panel opt-in writes shareChanceProcs", panel:find("shareChanceProcs", 1, true) ~= nil)
ok("panel binds Refresh button to RequestNow", panel:find("ProcShare.RequestNow", 1, true) ~= nil)

local events = readCode("EbonClearance_Events.lua")
ok("Events.lua seeds shareChanceProcs default", events:find("shareChanceProcs", 1, true) ~= nil)
ok("Events.lua fires ProcShare.RequestNow post-login", events:find("ProcShare.RequestNow", 1, true) ~= nil)
ok("Events.lua watch-list includes shareChanceProcs", events:find('"shareChanceProcs"', 1, true) ~= nil)

local br = readCode("EbonClearance_BugReport.lua")
ok("BugReport dumps ProcShare merges section", br:find("Proc Pairings Shared This Session", 1, true) ~= nil)
ok("BugReport reads NS.recentProcShareMerges", br:find("NS.recentProcShareMerges", 1, true) ~= nil)

print()
if fails > 0 then io.stderr:write("RESULT: " .. fails .. " test(s) failed\n"); os.exit(1) end
print("RESULT: all tests passed")
