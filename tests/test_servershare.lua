#!/usr/bin/env lua
-- Unit + static tests for the realm-wide "Stats - Server" odometer.
-- Run: lua tests/test_servershare.lua
-- Loads EbonClearance_ServerShare.lua in isolation with a stub NS.RealmComms
-- (it registers SREQ/SDAT handlers at load) + stubs for the helpers it uses.

local rhandlers = {}
local sent = {}
local noted = {} -- NS.Comms.NotePeerVersion calls
local fakeNow = 1000
local function clearSent() for i = #sent, 1, -1 do sent[i] = nil end end

_G.GetTime = function() return fakeNow end
_G.UnitName = function() return "Self" end
_G.GetItemInfo = function(id) return "Item" .. tostring(id) end

local NS = {
    RealmComms = {
        RegisterHandler = function(t, fn) rhandlers[t] = fn end,
        -- NOTE: realm sends take (msgType, payload) ONLY - no channel/target.
        -- The absence of a target is what proves replies go channel-wide, not
        -- as a whisper storm aimed at one player.
        Send = function(t, payload) sent[#sent + 1] = { t = t, payload = payload } end,
        Join = function() end,
    },
    Comms = {
        NotePeerVersion = function(v, s) noted[#noted + 1] = { v = v, s = s } end,
    },
    GuildShare = {
        topZones = function(map, n)
            local arr = {}
            for name, c in pairs(map or {}) do arr[#arr + 1] = { name = name, copper = c } end
            table.sort(arr, function(a, b) return a.copper > b.copper end)
            while #arr > (n or 5) do arr[#arr] = nil end
            return arr
        end,
    },
    Delay = function(_, fn) if fn then fn() end end, -- fire scheduled replies synchronously
    GetVersion = function() return "v2.58.0" end,
    compCache = {},
}
local chunk = assert(loadfile("EbonClearance_ServerShare.lua"))
chunk("EbonClearance", NS)
local ss = NS.ServerShare

local fails = 0
local function ok(name, cond)
    if cond then print("PASS  " .. name) else print("FAIL  " .. name); fails = fails + 1 end
end
local function eq(name, a, b) ok(name .. " (" .. tostring(a) .. ")", a == b) end

-- ---- codec round-trip ----
local p = ss.encodePayload(
    { cop = 999, sold = 12, del = 5, proc = 3 },
    { { name = "Barrens", copper = 200 } },
    { { id = 4306, name = "Silk Cloth", count = 7 } },
    "v2.58.0"
)
ok("payload has totals", p:find("t:", 1, true) ~= nil)
ok("payload has ver", p:find("ver:v2.58.0", 1, true) ~= nil)
ok("payload has zones", p:find("z:", 1, true) ~= nil)
ok("payload has items", p:find("i:", 1, true) ~= nil)
ok("payload under 255", #p < 255)
local d = ss.decodePayload(p)
eq("decode cop", d.cop, 999)
eq("decode sold", d.sold, 12)
eq("decode del", d.del, 5)
eq("decode proc", d.proc, 3)
eq("decode ver", d.ver, "v2.58.0")
eq("decode zone name", d.zones[1].name, "Barrens")
eq("decode zone copper", d.zones[1].copper, 200)
eq("decode item id", d.items[1].id, 4306)
eq("decode item name", d.items[1].name, "Silk Cloth")
eq("decode item count", d.items[1].count, 7)

-- ---- keyed aggregate via the SDAT handler ----
EbonClearanceDB = {
    totalCopper = 100, totalItemsSold = 10, totalItemsDeleted = 2,
    processCastCounts = { Disenchant = 3 }, soldItemCounts = { [4306] = 5 },
    copperByZone = { Barrens = 100 },
}
NS.compCache.serverPeers = nil
fakeNow = 5000
rhandlers.SDAT(ss.encodePayload({ cop = 1000, sold = 20, del = 4, proc = 1 },
    { { name = "Barrens", copper = 500 } }, { { id = 4306, name = "Silk Cloth", count = 8 } }, "v2.58.0"), "Alaric")
rhandlers.SDAT(ss.encodePayload({ cop = 2000, sold = 30, del = 6, proc = 2 },
    { { name = "Durotar", copper = 300 } }, {}, "v2.58.0"), "Brynn")
local agg = ss.GetAggregate()
eq("agg userCount", agg.userCount, 2)
eq("agg sum cop", agg.totalCopper, 3000)
eq("agg sum sold", agg.itemsSold, 50)
eq("agg sum del", agg.itemsDeleted, 10)
eq("agg sum proc", agg.itemsProcessed, 3)
eq("agg top zone name", agg.zones[1].name, "Barrens")
eq("agg top zone copper", agg.zones[1].copper, 500)
eq("agg top item count", agg.items[1].count, 8)

-- re-send from the SAME sender must NOT double-count (latest-wins keyed store)
rhandlers.SDAT(ss.encodePayload({ cop = 1000, sold = 20, del = 4, proc = 1 }, {}, {}, nil), "Alaric")
local agg2 = ss.GetAggregate()
eq("userCount after re-send (no dupe)", agg2.userCount, 2)
eq("sum cop after re-send (no dupe)", agg2.totalCopper, 3000)

-- spoof containment: an absurd contributor is dropped by the sanity cap
rhandlers.SDAT(ss.encodePayload({ cop = 9e14, sold = 0, del = 0, proc = 0 }, {}, {}, nil), "Spoofer")
eq("spoofed contributor rejected", ss.GetAggregate().userCount, 2)

-- ---- SREQ responder behaviour (privacy + anti-storm) ----
-- opt-in OFF: no reply
EbonClearanceDB.shareServerData = false
clearSent()
fakeNow = fakeNow + 100
rhandlers.SREQ("v2.58.0", "Other")
ok("no reply when opted out", #sent == 0)

-- opt-in ON: exactly one SDAT, sent channel-wide (no target field)
EbonClearanceDB.shareServerData = true
clearSent()
fakeNow = fakeNow + 100
rhandlers.SREQ("v2.58.0", "Other")
ok("one reply when opted in", #sent == 1)
ok("reply is SDAT", sent[1] and sent[1].t == "SDAT")
ok("reply is channel-wide (no whisper target)", sent[1] and sent[1].target == nil)

-- self-skip: no reply to our own request
clearSent()
fakeNow = fakeNow + 100
rhandlers.SREQ("v2.58.0", "Self")
ok("no self-reply", #sent == 0)

-- responder floor: a burst of requests yields at most one reply
clearSent()
fakeNow = fakeNow + 100
rhandlers.SREQ("v2.58.0", "Other")
rhandlers.SREQ("v2.58.0", "Other2") -- same instant, within REPLY_FLOOR
ok("responder floor bounds bursts to one reply", #sent == 1)

-- ---- version piggyback ----
for i = #noted, 1, -1 do noted[i] = nil end
fakeNow = fakeNow + 100
rhandlers.SREQ("v2.99.0", "PeerX")
local sreqVer = false
for _, e in ipairs(noted) do if e.v == "v2.99.0" then sreqVer = true end end
ok("SREQ version feeds NotePeerVersion", sreqVer)
for i = #noted, 1, -1 do noted[i] = nil end
rhandlers.SDAT(ss.encodePayload({ cop = 1, sold = 0, del = 0, proc = 0 }, {}, {}, "v3.00.0"), "PeerY")
local sdatVer = false
for _, e in ipairs(noted) do if e.v == "v3.00.0" then sdatVer = true end end
ok("SDAT version feeds NotePeerVersion", sdatVer)

-- ---- anonymity: sender never appears in the displayed aggregate ----
NS.compCache.serverPeers = nil
fakeNow = fakeNow + 100
rhandlers.SDAT(ss.encodePayload({ cop = 100, sold = 1, del = 0, proc = 0 },
    { { name = "Barrens", copper = 100 } }, {}, nil), "SecretSenderName")
local flat = {}
local function flatten(t)
    for k, v in pairs(t) do
        flat[#flat + 1] = tostring(k)
        if type(v) == "table" then flatten(v) else flat[#flat + 1] = tostring(v) end
    end
end
flatten(ss.GetAggregate())
ok("sender name not in displayed aggregate", table.concat(flat, "|"):find("SecretSenderName", 1, true) == nil)

-- ---- TTL: stale sharers drop out of the count ----
NS.compCache.serverPeers = nil
fakeNow = 20000
rhandlers.SDAT(ss.encodePayload({ cop = 100, sold = 0, del = 0, proc = 0 }, {}, {}, nil), "Fresh")
eq("stored while fresh", ss.GetAggregate().userCount, 1)
fakeNow = 20000 + 1300 -- past the 1200s TTL
eq("expired after TTL", ss.GetAggregate().userCount, 0)

-- ---- static-pattern invariants (scan live code, not comments) ----
local function readCode(path)
    local fh = assert(io.open(path, "r"))
    local s = fh:read("*a")
    fh:close()
    local out = {}
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
        local t = line:match("^%s*(.-)%s*$") or ""
        if t:sub(1, 2) ~= "--" then out[#out + 1] = line end
    end
    return table.concat(out, "\n")
end

local share = readCode("EbonClearance_ServerShare.lua")
ok("exposes NS.ServerShare", share:find("NS.ServerShare", 1, true) ~= nil)
ok("uses NS.RealmComms transport", share:find("NS.RealmComms", 1, true) ~= nil)
ok("registers SREQ", share:find('"SREQ"', 1, true) ~= nil)
ok("registers SDAT", share:find('"SDAT"', 1, true) ~= nil)
ok("reply gated on shareServerData", share:find("shareServerData", 1, true) ~= nil)
ok("exposes InjectTestPeers diagnostic", share:find("function ServerShare.InjectTestPeers", 1, true) ~= nil)
ok("per-contributor sanity cap present", share:find("COPPER_CAP", 1, true) ~= nil)
ok("no 4.0 group event", not share:find("GROUP_ROSTER_UPDATE", 1, true))
ok("share: no RegisterAddonMessagePrefix", not share:find("RegisterAddonMessagePrefix", 1, true))

local rc = readCode("EbonClearance_RealmComms.lua")
ok("RealmComms pipe-escapes on send", rc:find('gsub("|", "||")', 1, true) ~= nil)
ok("RealmComms unescapes on receive", rc:find('gsub("||", "|")', 1, true) ~= nil)
ok("RealmComms strips server prefix", rc:find("stripPrefix", 1, true) ~= nil)
ok("RealmComms has RunSelfTest", rc:find("function RealmComms.RunSelfTest", 1, true) ~= nil)
ok("RealmComms: no chunking", not rc:find("MAX_CHUNK", 1, true))
ok("RealmComms: no RegisterAddonMessagePrefix", not rc:find("RegisterAddonMessagePrefix", 1, true))

local panel = readCode("EbonClearance_ServerStatsPanel.lua")
ok("panel reads aggregate", panel:find("GetAggregate", 1, true) ~= nil)
ok("panel opt-in writes shareServerData", panel:find("shareServerData", 1, true) ~= nil)
ok("panel does not self-register", panel:find("InterfaceOptions_AddCategory", 1, true) == nil)

local events = readCode("EbonClearance_Events.lua")
ok("Events registers server panel centrally",
    events:find('InterfaceOptions_AddCategory(_G["EbonClearanceOptionsServer"])', 1, true) ~= nil)
ok("Events seeds shareServerData default", events:find("EbonClearanceDB.shareServerData == nil", 1, true) ~= nil)

print()
if fails > 0 then io.stderr:write("RESULT: " .. fails .. " test(s) failed\n"); os.exit(1) end
print("RESULT: all tests passed")
os.exit(0)
