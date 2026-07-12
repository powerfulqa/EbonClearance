-- EbonClearance_ServerShare.lua
-- Realm-wide "collective odometer": anonymous combined totals from EC users
-- sharing right now (gold vendored, items sold/deleted/processed) + pooled top
-- zones/items + a live sharer count. Rides NS.RealmComms (the hidden-channel
-- bus), NOT NS.Comms - the realm has no addon-message channel.
--
-- Deliberately NOT a leaderboard and NOT all-time: it's whoever is online,
-- opted in, and heard in the rolling window. All anonymous - no names are ever
-- shown or stored (senders are used only as a transient de-dupe key + headcount).
--
-- Anti-flood model (on-demand + self-suppression, maintainer-chosen):
--   * Nothing is sent unless someone opens the Server Stats panel.
--   * Opening first LISTENS: if any SREQ/SDAT was heard in the last 90s, send
--     nothing and just show the overheard aggregate.
--   * A request is throttled (60s) and replies go ON THE CHANNEL (everyone
--     aggregates), jittered, one per responder per 30s - so it scales DOWN
--     with population instead of storming one player.
local NS = select(2, ...)

local ServerShare = {}
NS.ServerShare = ServerShare

local MAX_ZONES = 5
local MAX_ITEMS = 5
local MAX_PAYLOAD = 200 -- channel headroom (SendChatMessage ~255, minus escaping)
local TTL = 1200 -- 20 min: drop a sharer we haven't heard from
local SREQ_COOLDOWN = 60 -- min seconds between our own requests
local SUPPRESS_WINDOW = 90 -- recent channel activity cancels our own request
local REPLY_FLOOR = 30 -- min seconds between our own replies (bounds bursts)
local JITTER = 8 -- reply after random(0, JITTER)s so replies spread out
-- Spoof containment: reject an obviously-garbage contributor (a public channel
-- lets anyone inject fake numbers). Ceilings are far above any real lifetime.
local COPPER_CAP = 1e12 -- ~100,000,000 gold
local COUNT_CAP = 1e8

local function playerName()
    return UnitName("player")
end

-- A field is unsafe if it contains a payload delimiter.
local function fieldSafe(s)
    return type(s) == "string" and s ~= "" and not s:find("[=;|,~\t]")
end

-- ---- wire codec (compact; own format, 200-byte capped) ------------------
-- t:cop,sold,del,proc | ver:<version> | i:id~name=count;... | z:name=copper;...
function ServerShare.encodePayload(totals, zones, items, ver)
    local t = totals or {}
    local totalsPart = string.format(
        "t:%d,%d,%d,%d",
        math.floor(tonumber(t.cop) or 0),
        math.floor(tonumber(t.sold) or 0),
        math.floor(tonumber(t.del) or 0),
        math.floor(tonumber(t.proc) or 0)
    )
    local verPart = (type(ver) == "string" and fieldSafe(ver)) and ("ver:" .. ver) or nil
    local pickedItems = {}
    for _, it in ipairs(items or {}) do
        if #pickedItems >= MAX_ITEMS then
            break
        end
        local id = math.floor(tonumber(it.id) or 0)
        local n = math.floor(tonumber(it.count) or 0)
        if id > 0 and n > 0 and fieldSafe(it.name) then
            pickedItems[#pickedItems + 1] = id .. "~" .. it.name .. "=" .. n
        end
    end
    local pickedZones = {}
    for _, z in ipairs(zones or {}) do
        if #pickedZones >= MAX_ZONES then
            break
        end
        if fieldSafe(z.name) then
            pickedZones[#pickedZones + 1] = z
        end
    end
    local function assemble(zlist, ilist)
        local out = totalsPart
        if verPart then
            out = out .. "|" .. verPart
        end
        if #ilist > 0 then
            out = out .. "|i:" .. table.concat(ilist, ";")
        end
        local zparts = {}
        for _, z in ipairs(zlist) do
            zparts[#zparts + 1] = z.name .. "=" .. tostring(math.floor(tonumber(z.copper) or 0))
        end
        if #zparts > 0 then
            out = out .. "|z:" .. table.concat(zparts, ";")
        end
        return out
    end
    -- Trim zones first, then items, until it fits (totals+ver always kept).
    local payload = assemble(pickedZones, pickedItems)
    while #payload > MAX_PAYLOAD and #pickedZones > 0 do
        pickedZones[#pickedZones] = nil
        payload = assemble(pickedZones, pickedItems)
    end
    while #payload > MAX_PAYLOAD and #pickedItems > 0 do
        pickedItems[#pickedItems] = nil
        payload = assemble(pickedZones, pickedItems)
    end
    return payload
end

function ServerShare.decodePayload(str)
    local out = { cop = 0, sold = 0, del = 0, proc = 0, ver = nil, zones = {}, items = {} }
    if type(str) ~= "string" then
        return out
    end
    for section in str:gmatch("[^|]+") do
        local prefix, body = section:match("^(%w+):(.*)$")
        if prefix == "t" then
            local c, s, d, p = body:match("^(%d+),(%d+),(%d+),(%d+)")
            if c then
                out.cop = tonumber(c) or 0
                out.sold = tonumber(s) or 0
                out.del = tonumber(d) or 0
                out.proc = tonumber(p) or 0
            end
        elseif prefix == "ver" then
            if body ~= "" then
                out.ver = body
            end
        elseif prefix == "i" then
            for entry in body:gmatch("[^;]+") do
                local id, name, cnt = entry:match("^(%d+)~(.-)=(%d+)$")
                if id and name and name ~= "" then
                    out.items[#out.items + 1] = { id = tonumber(id), name = name, count = tonumber(cnt) or 0 }
                end
            end
        elseif prefix == "z" then
            for entry in body:gmatch("[^;]+") do
                local name, copper = entry:match("^(.-)=(%d+)$")
                if name and name ~= "" then
                    out.zones[#out.zones + 1] = { name = name, copper = tonumber(copper) or 0 }
                end
            end
        end
    end
    return out
end

-- ---- per-sender keyed store (session-only, rolling) ---------------------
-- serverPeers[sender] = { d = decoded, t = GetTime() }. Latest-wins per sender
-- (so a re-broadcast never double-counts); distinct live keys = the headcount.
local function peers()
    if not NS.compCache.serverPeers then
        NS.compCache.serverPeers = {}
    end
    return NS.compCache.serverPeers
end

local function saneDecoded(d)
    if not d then
        return false
    end
    if (d.cop or 0) < 0 or (d.cop or 0) > COPPER_CAP then
        return false
    end
    for _, v in ipairs({ d.sold or 0, d.del or 0, d.proc or 0 }) do
        if v < 0 or v > COUNT_CAP then
            return false
        end
    end
    return true
end

local function storePeer(sender, decoded)
    if type(sender) ~= "string" or sender == "" then
        return
    end
    if not saneDecoded(decoded) then
        return -- spoof containment: drop obviously-garbage totals
    end
    peers()[sender] = { d = decoded, t = GetTime() }
end

-- Compute the odometer from live (non-expired) peers.
function ServerShare.GetAggregate()
    local now = GetTime()
    local agg = {
        userCount = 0,
        totalCopper = 0,
        itemsSold = 0,
        itemsDeleted = 0,
        itemsProcessed = 0,
        zones = {},
        items = {},
    }
    local zoneCopper, itemAcc = {}, {}
    local store = peers()
    for sender, rec in pairs(store) do
        if (now - (rec.t or 0)) > TTL then
            store[sender] = nil
        else
            local d = rec.d
            agg.userCount = agg.userCount + 1
            agg.totalCopper = agg.totalCopper + (d.cop or 0)
            agg.itemsSold = agg.itemsSold + (d.sold or 0)
            agg.itemsDeleted = agg.itemsDeleted + (d.del or 0)
            agg.itemsProcessed = agg.itemsProcessed + (d.proc or 0)
            for _, z in ipairs(d.zones or {}) do
                zoneCopper[z.name] = (zoneCopper[z.name] or 0) + (z.copper or 0)
            end
            for _, it in ipairs(d.items or {}) do
                local e = itemAcc[it.id]
                if not e then
                    e = { id = it.id, name = it.name, count = 0 }
                    itemAcc[it.id] = e
                end
                e.name = e.name or it.name
                e.count = e.count + (it.count or 0)
            end
        end
    end
    for name, copper in pairs(zoneCopper) do
        agg.zones[#agg.zones + 1] = { name = name, copper = copper }
    end
    table.sort(agg.zones, function(a, b) return a.copper > b.copper end)
    while #agg.zones > MAX_ZONES do
        agg.zones[#agg.zones] = nil
    end
    for _, e in pairs(itemAcc) do
        agg.items[#agg.items + 1] = e
    end
    table.sort(agg.items, function(a, b) return a.count > b.count end)
    while #agg.items > MAX_ITEMS do
        agg.items[#agg.items] = nil
    end
    return agg
end

-- ---- local share --------------------------------------------------------
local function myVersion()
    return NS.GetVersion and NS.GetVersion() or nil
end

local function localPayload()
    local DB = EbonClearanceDB or {}
    local proc = 0
    for _, n in pairs(DB.processCastCounts or {}) do
        proc = proc + (tonumber(n) or 0)
    end
    local totals = {
        cop = DB.totalCopper or 0,
        sold = DB.totalItemsSold or 0,
        del = DB.totalItemsDeleted or 0,
        proc = proc,
    }
    local itemsTop = {}
    do
        local arr = {}
        for id, n in pairs(DB.soldItemCounts or {}) do
            arr[#arr + 1] = { id = id, count = tonumber(n) or 0 }
        end
        table.sort(arr, function(a, b) return a.count > b.count end)
        for _, e in ipairs(arr) do
            if #itemsTop >= MAX_ITEMS then
                break
            end
            local name = GetItemInfo and GetItemInfo(e.id)
            if name and fieldSafe(name) then
                itemsTop[#itemsTop + 1] = { id = math.floor(tonumber(e.id) or 0), name = name, count = e.count }
            end
        end
    end
    local zones = NS.GuildShare and NS.GuildShare.topZones(DB.copperByZone, MAX_ZONES) or {}
    return ServerShare.encodePayload(totals, zones, itemsTop, myVersion())
end

-- ---- update-check piggyback ---------------------------------------------
local function noteVersion(ver, sender)
    if ver and NS.Comms and NS.Comms.NotePeerVersion then
        NS.Comms.NotePeerVersion(ver, sender)
    end
end

-- ---- on-demand request + self-suppression -------------------------------
local lastReqAt = 0
local lastActivityAt = 0 -- any SREQ/SDAT heard (overhearing suppression)
local lastReplyAt = 0 -- our own last reply (responder floor)

-- Called when the panel opens / Refresh is clicked. Sends AT MOST one request,
-- and only if the channel has been quiet - otherwise the overheard aggregate is
-- already fresh. Never resets the store (it's rolling).
function ServerShare.RequestNow()
    -- Always include ourselves when sharing, so the panel shows our own totals
    -- even if nobody else is around.
    if EbonClearanceDB and EbonClearanceDB.shareServerData then
        storePeer(playerName(), ServerShare.decodePayload(localPayload()))
    end
    local now = GetTime()
    if (now - lastActivityAt) < SUPPRESS_WINDOW then
        return -- someone requested/replied recently; rely on overheard data
    end
    if (now - lastReqAt) < SREQ_COOLDOWN then
        return
    end
    lastReqAt = now
    NS.RealmComms.Send("SREQ", myVersion() or "")
end

-- ---- channel handlers ---------------------------------------------------
-- A peer is asking for data (payload = their version). Learn their version,
-- then reply on the channel IF we opted in - jittered, and no more than once
-- per REPLY_FLOOR regardless of how many requests arrive.
NS.RealmComms.RegisterHandler("SREQ", function(payload, sender)
    lastActivityAt = GetTime()
    noteVersion(payload, sender)
    if not (EbonClearanceDB and EbonClearanceDB.shareServerData) then
        return
    end
    if not sender or sender == playerName() then
        return -- don't answer our own request
    end
    local now = GetTime()
    if (now - lastReplyAt) < REPLY_FLOOR then
        return -- responder floor: bounds a burst of requests to one reply
    end
    lastReplyAt = now -- reserve the slot now so concurrent requests don't stack
    if NS.Delay then
        -- random jitter so N responders don't all fire at once. Vary by a cheap
        -- per-call value (GetTime fractional) since math.random is fine here.
        NS.Delay(math.random() * JITTER, function()
            NS.RealmComms.Send("SDAT", localPayload())
        end)
    else
        NS.RealmComms.Send("SDAT", localPayload())
    end
end)

-- A data line arrived (including our own echo when we share). Store it keyed by
-- sender (latest-wins), learn the embedded version, repaint.
NS.RealmComms.RegisterHandler("SDAT", function(payload, sender)
    lastActivityAt = GetTime()
    local d = ServerShare.decodePayload(payload)
    noteVersion(d.ver, sender)
    storePeer(sender, d)
    if NS.RefreshServerStatsPanel then
        NS.RefreshServerStatsPanel()
    end
end)

-- ---- diagnostic (/ec servertest) ----------------------------------------
-- Populate the odometer with fake sharers so the panel + user-count can be
-- exercised on ONE account, no channel traffic. Session-only; saves nothing.
function ServerShare.InjectTestPeers()
    local fakes = {
        { name = "Alaric", d = { cop = 5000000, sold = 1200, del = 300, proc = 80, zones = { { name = "The Barrens", copper = 3000000 }, { name = "Durotar", copper = 800000 } }, items = { { id = 2589, name = "Linen Cloth", count = 50 } } } },
        { name = "Brynn", d = { cop = 3200000, sold = 800, del = 150, proc = 40, zones = { { name = "The Barrens", copper = 1500000 }, { name = "Elwynn Forest", copper = 2200000 } }, items = { { id = 2589, name = "Linen Cloth", count = 40 }, { id = 774, name = "Malachite", count = 20 } } } },
        { name = "Cael", d = { cop = 900000, sold = 400, del = 90, proc = 12, zones = { { name = "Westfall", copper = 700000 } }, items = { { id = 4306, name = "Silk Cloth", count = 15 } } } },
        -- An obviously-spoofed contributor: the sanity cap must drop it entirely.
        { name = "Spoofer", d = { cop = 9e14, sold = 9e9, del = 0, proc = 0, zones = {}, items = {} } },
    }
    for _, f in ipairs(fakes) do
        storePeer(f.name, f.d)
    end
    if EbonClearanceDB and EbonClearanceDB.shareServerData then
        storePeer(playerName(), ServerShare.decodePayload(localPayload()))
    end
    if NS.RefreshServerStatsPanel then
        NS.RefreshServerStatsPanel()
    end
    return #fakes
end
