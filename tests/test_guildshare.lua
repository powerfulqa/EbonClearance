#!/usr/bin/env lua
-- Unit + static tests for guild-share encode/decode/merge.
-- Run: lua tests/test_guildshare.lua
-- Loads the chunk in isolation with a stub NS.Comms (it registers handlers at load).

local NS = {
    Comms = { RegisterHandler = function() end, Send = function() end },
    Delay = function() end,
}
local chunk = assert(loadfile("EbonClearance_GuildShare.lua"))
chunk("EbonClearance", NS)
local gs = NS.GuildShare

local fails = 0
local function ok(name, cond)
    if cond then print("PASS  " .. name) else print("FAIL  " .. name); fails = fails + 1 end
end
local function eq(name, a, b) ok(name .. " (" .. tostring(a) .. ")", a == b) end

-- topZones: sort desc, cap to n
local top = gs.topZones({ ["Durotar"] = 50, ["Barrens"] = 200, ["Mulgore"] = 10 }, 2)
eq("topZones count", #top, 2)
eq("topZones[1] name", top[1].name, "Barrens")
eq("topZones[1] copper", top[1].copper, 200)

-- encode/decode round-trip
local payload = gs.encodePayload({ { name = "Barrens", copper = 200 } }, { totalCopper = 999, itemsSold = 12, bestGPH = 3456 })
ok("payload has stats", payload:find("stats:", 1, true) ~= nil)
ok("payload has zones", payload:find("zones:", 1, true) ~= nil)
local dec = gs.decodePayload(payload)
eq("decode totalCopper", dec.stats.totalCopper, 999)
eq("decode itemsSold", dec.stats.itemsSold, 12)
eq("decode bestGPH", dec.stats.bestGPH, 3456)
eq("decode zone name", dec.zones[1].name, "Barrens")
eq("decode zone copper", dec.zones[1].copper, 200)

-- cap to 5 zones + skip delimiter-bad names
local many = {}
for i = 1, 9 do many[i] = { name = "Zone" .. i, copper = i * 10 } end
many[10] = { name = "Bad=Zone", copper = 5 }
local capped = gs.encodePayload(many, { totalCopper = 0, itemsSold = 0, bestGPH = 0 })
local dc = gs.decodePayload(capped)
ok("capped to <= 5 zones", #dc.zones <= 5)
ok("delimiter zone skipped", capped:find("Bad=Zone", 1, true) == nil)
ok("payload under 255 bytes", #capped < 255)

-- merge: pool two replies
local agg = gs.newAggregate()
gs.mergeReply(agg, gs.decodePayload(gs.encodePayload({ { name = "Barrens", copper = 100 } }, { totalCopper = 100, itemsSold = 5, bestGPH = 1000 })))
gs.mergeReply(agg, gs.decodePayload(gs.encodePayload({ { name = "Barrens", copper = 50 } }, { totalCopper = 200, itemsSold = 3, bestGPH = 2000 })))
eq("merge memberCount", agg.memberCount, 2)
eq("merge Barrens copper", agg.zones["Barrens"].copper, 150)
eq("merge Barrens contributors", agg.zones["Barrens"].contributors, 2)
eq("merge totalCopper", agg.totalCopper, 300)
eq("merge totalItems", agg.totalItems, 8)
eq("merge bestGPH (max)", agg.bestGPH, 2000)

print()
if fails > 0 then io.stderr:write("RESULT: " .. fails .. " test(s) failed\n"); os.exit(1) end
print("RESULT: all tests passed")
os.exit(0)
