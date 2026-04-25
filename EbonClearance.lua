-- EbonClearance - auto-vendoring + clearance addon for Project Ebonhold (3.3.5a)
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.

local ADDON_NAME = "EbonClearance"
-- TARGET_NAME / PET_NAME are the enUS display names of the two Project Ebonhold
-- companion NPCs the addon drives. These strings are compared directly against
-- creatureName in FindGoblinMerchantIndex / SummonGreedyScavenger, so a realm
-- with localised names would break those lookups. FindGoblinMerchantIndex
-- already has a spellID == 600126 fallback for the Goblin Merchant; adding a
-- matching fallback for the Scavenger is the L10n escape hatch if we ever need
-- one. See docs/ADDON_GUIDE.md "Gotchas" for the full localisation notes.
local TARGET_NAME = "Goblin Merchant"
local PET_NAME = "Greedy scavenger"

-- Provenance. Mirrored into globals so the origin/author are visible to any
-- /run introspection, addon-management tool, or crash trace. LICENSE requires
-- these to be preserved in derivatives.
local ADDON_DISPLAY = "EbonClearance"
local ADDON_AUTHOR = "Serv"
local ADDON_URL = "https://github.com/powerfulqa/EbonClearance"
_G["EBONCLEARANCE_IDENT"] = ADDON_DISPLAY
_G["EBONCLEARANCE_AUTHOR"] = ADDON_AUTHOR
_G["EBONCLEARANCE_ORIGIN"] = ADDON_URL
_G["__EbonClearance_origin"] = ADDON_URL
_G["__EbonClearance_author"] = ADDON_AUTHOR

local EC_GetPlayerName
local EC_IsAddonEnabledForChar

-- Cached WoW 3.3.5a API upvalues. Local lookups beat _G hash on hot paths
-- (bag scans, vendor loop, pet-check OnUpdate). See docs/ADDON_GUIDE.md.
local GetItemInfo = GetItemInfo
local GetContainerItemID = GetContainerItemID
local GetContainerItemInfo = GetContainerItemInfo
local GetContainerNumSlots = GetContainerNumSlots
local UseContainerItem = UseContainerItem
local PickupContainerItem = PickupContainerItem
local DeleteCursorItem = DeleteCursorItem
local GetMerchantNumItems = GetMerchantNumItems
local GetMerchantItemInfo = GetMerchantItemInfo
local GetMerchantItemLink = GetMerchantItemLink
local GetNumCompanions = GetNumCompanions
local GetCompanionInfo = GetCompanionInfo
local CallCompanion = CallCompanion
local IsMounted = IsMounted
local IsEquippedItem = IsEquippedItem

-- Forward declarations. These must exist as upvalues before any function
-- that references them is compiled, or references inside those closures
-- resolve to _G.<name> instead of the intended local. See docs/CODE_REVIEW.md.
local STATE = {
    IDLE = "idle",
    LOOTING = "looting",
    WAITING_MERCHANT = "waiting_merchant",
    SELLING = "selling",
}
local EC_lootCycleState = STATE.IDLE
local EC_addonDismissed = false
local running = false

local EC_greedyMessages = {}
local EC_greedyFiltersInstalled = false

local function EC_StripCodes(s)
    if type(s) ~= "string" then
        return nil
    end
    return s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h", ""):gsub("|h", "")
end

local PET_NAME_LC = PET_NAME:lower()
local function EC_IsGreedyAuthor(author)
    if type(author) ~= "string" then
        return false
    end
    author = EC_StripCodes(author)
    if not author or author == "" then
        return false
    end
    return author:lower() == PET_NAME_LC
end

local function EC_TrackGreedySpeech(msg)
    msg = EC_StripCodes(msg)
    if not msg or msg == "" then
        return
    end
    msg = msg:lower()
    EC_greedyMessages[msg] = true
end

local function EC_GreedyEventFilter(self, event, msg, author, ...)
    local hideChat = true
    local hideBubbles = true
    if DB then
        hideChat = (DB.muteGreedy == true) or (DB.hideGreedyChat == true)
        hideBubbles = (DB.muteGreedy == true) or (DB.hideGreedyBubbles == true)
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
    local hideBubbles = true
    if DB then
        hideBubbles = (DB.muteGreedy == true) or (DB.hideGreedyBubbles == true)
    end
    if not hideBubbles then
        return
    end

    for bubble in pairs(EC_killedBubbles) do
        if bubble and bubble.IsShown and bubble:IsShown() then
            bubble:SetAlpha(0)
            bubble:Hide()
        end
    end

    if not next(EC_greedyMessages) then
        return
    end

    self.elapsed = (self.elapsed or 0) + elapsed
    if self.elapsed < 0.05 then
        return
    end
    self.elapsed = 0

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

local PET_CHAT_PREFIX = PET_NAME .. " says:"

local CHAT_FILTER_EVENTS = {
    "CHAT_MSG_SAY",
    "CHAT_MSG_YELL",
    "CHAT_MSG_EMOTE",
    "CHAT_MSG_TEXT_EMOTE",
}

local function GreedyScavengerChatFilter(self, event, msg, author, ...)
    if EC_IsGreedyAuthor(author) then
        return true
    end
    return false
end

local function ApplyGreedyChatFilter()
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

local DB
-- Account-wide SavedVariable. Holds a single `whitelist` table that unions with
-- the per-character whitelist at sell time. Bootstrapped by EnsureAccountDB().
local ADB

-- Resolves list names (used by CreateListUI) to the underlying table. Extra
-- scopes (e.g. account whitelist) register themselves here so CreateListUI can
-- render them without knowing about the scope.
local EC_ExtraListTables = {}

local function EC_GetListTable(name)
    local extra = EC_ExtraListTables[name]
    if extra ~= nil then
        return extra
    end
    return DB and DB[name]
end

local function EnsureAccountDB()
    if EbonClearanceAccountDB == nil then
        EbonClearanceAccountDB = {}
    end
    ADB = EbonClearanceAccountDB
    if type(ADB.whitelist) ~= "table" then
        ADB.whitelist = {}
    end
    EC_ExtraListTables["accountWhitelist"] = ADB.whitelist
end

local function EnsureDB()
    -- Legacy-rename migration. MUST run before field defaults below, because
    -- the profile-migration block (further down) reads existing DB.whitelist
    -- to decide whether to snapshot it into an "Imported" profile. If field
    -- defaults ran first, DB.whitelist would be {}, and any data the user
    -- had under the old EbonholdStuffDB name would be lost. Order-dependent.
    if EbonholdStuffDB and not EbonClearanceDB then
        EbonClearanceDB = EbonholdStuffDB
        EbonholdStuffDB = nil
    end
    if EbonClearanceDB == nil then
        EbonClearanceDB = {}
    end
    DB = EbonClearanceDB
    EnsureAccountDB()

    if type(DB.deleteList) ~= "table" then
        DB.deleteList = {}
    end
    if type(DB.allowedChars) ~= "table" then
        DB.allowedChars = {}
    end

    if type(DB.totalCopper) ~= "number" then
        DB.totalCopper = 0
    end

    if type(DB.totalItemsSold) ~= "number" then
        DB.totalItemsSold = 0
    end
    if type(DB.totalItemsDeleted) ~= "number" then
        DB.totalItemsDeleted = 0
    end
    if type(DB.totalRepairs) ~= "number" then
        DB.totalRepairs = 0
    end
    if type(DB.totalRepairCopper) ~= "number" then
        DB.totalRepairCopper = 0
    end

    if type(DB.soldItemCounts) ~= "table" then
        DB.soldItemCounts = {}
    end
    if type(DB.deletedItemCounts) ~= "table" then
        DB.deletedItemCounts = {}
    end

    if type(DB.repairGear) ~= "boolean" then
        DB.repairGear = true
    end

    if type(DB.enableDeletion) ~= "boolean" then
        DB.enableDeletion = true
    end
    if type(DB.summonGreedy) ~= "boolean" then
        DB.summonGreedy = true
    end
    if type(DB.summonDelay) ~= "number" then
        DB.summonDelay = 1.6
    end

    if type(DB.vendorInterval) ~= "number" then
        DB.vendorInterval = 0.1
    end
    if DB.vendorInterval < 0.05 then
        DB.vendorInterval = 0.1
    end
    if type(DB.maxItemsPerRun) ~= "number" then
        DB.maxItemsPerRun = 80
    end
    if type(DB.fastMode) ~= "boolean" then
        DB.fastMode = false
    end
    if type(DB.autoLootCycle) ~= "boolean" then
        DB.autoLootCycle = false
    end
    if type(DB.bagFullThreshold) ~= "number" then
        DB.bagFullThreshold = 2
    end
    if type(DB.autoOpenContainers) ~= "boolean" then
        DB.autoOpenContainers = false
    end
    if DB.merchantMode ~= "goblin" and DB.merchantMode ~= "any" and DB.merchantMode ~= "both" then
        DB.merchantMode = "goblin"
    end

    if type(DB.muteGreedy) ~= "boolean" then
        DB.muteGreedy = true
    end
    if type(DB.hideGreedyChat) ~= "boolean" then
        DB.hideGreedyChat = DB.muteGreedy
    end
    if type(DB.hideGreedyBubbles) ~= "boolean" then
        DB.hideGreedyBubbles = DB.muteGreedy
    end

    if type(DB.enabled) ~= "boolean" then
        DB.enabled = true
    end
    if type(DB.enableOnlyListedChars) ~= "boolean" then
        DB.enableOnlyListedChars = false
    end

    if type(DB.inventoryWorthTotal) ~= "number" then
        DB.inventoryWorthTotal = 0
    end
    if type(DB.inventoryWorthCount) ~= "number" then
        DB.inventoryWorthCount = 0
    end
    if type(DB.whitelist) ~= "table" then
        DB.whitelist = {}
    end
    if type(DB.whitelistMinQuality) ~= "number" then
        DB.whitelistMinQuality = 1
    end
    if DB.whitelistMinQuality > 3 then
        DB.whitelistMinQuality = 3
    end
    if type(DB.whitelistQualityEnabled) ~= "boolean" then
        DB.whitelistQualityEnabled = false
    end
    if type(DB.minimapButtonAngle) ~= "number" then
        DB.minimapButtonAngle = 220
    end
    if type(DB.keepBagsOpen) ~= "boolean" then
        DB.keepBagsOpen = true
    end
    if type(DB.vendorBtnShown) ~= "boolean" then
        DB.vendorBtnShown = false
    end
    if type(DB.blacklist) ~= "table" then
        DB.blacklist = {}
    end

    -- Whitelist profiles migration. First-run of the profile-aware schema:
    -- if the user already has items in the flat DB.whitelist (from pre-profile
    -- builds, or from the EbonholdStuffDB rename above), snapshot them into
    -- an "Imported" profile and auto-activate it so nothing is lost. Fresh
    -- installs get an empty Default profile as the active one. Depends on
    -- DB.whitelist having been initialised upstream -- do not reorder.
    if type(DB.whitelistProfiles) ~= "table" then
        DB.whitelistProfiles = {}
        DB.whitelistProfiles["Default"] = {}
        local hasItems = next(DB.whitelist) ~= nil
        if hasItems then
            local snapshot = {}
            for k, v in pairs(DB.whitelist) do
                snapshot[k] = v
            end
            DB.whitelistProfiles["Imported"] = snapshot
            DB.activeProfileName = "Imported"
        else
            DB.activeProfileName = "Default"
        end
    end
    if type(DB.activeProfileName) ~= "string" then
        DB.activeProfileName = "Default"
    end
    DB.whitelistProfiles["Default"] = {}
    if type(DB.blacklistProfiles) ~= "table" then
        DB.blacklistProfiles = {}
    end

    -- _seededLists is kept as a one-shot guard so future first-install seeds
    -- can be added without re-seeding existing users. Earlier builds seeded
    -- two legacy item IDs (300581, 300574) that returned nil from GetItemInfo
    -- and were removed in the v2.0.13 quality pass. New installs now start
    -- with an empty delete list; users add IDs via the Deletion panel.
    if not DB._seededLists then
        DB._seededLists = true
    end
end

-- Session stats (in-memory only; reset on /reload or by user button).
local EC_session = {
    copper = 0,
    sold = 0,
    deleted = 0,
    repairs = 0,
    repairCopper = 0,
}

local function EC_ResetSession()
    EC_session.copper = 0
    EC_session.sold = 0
    EC_session.deleted = 0
    EC_session.repairs = 0
    EC_session.repairCopper = 0
end

-- Keep bags open when merchant closes
local EC_keepBagsFlag = false

local function EC_OpenAllBags()
    if OpenAllBags then
        OpenAllBags()
    elseif OpenBackpack then
        OpenBackpack()
        for i = 1, 4 do
            if OpenBag then
                OpenBag(i)
            end
        end
    end
end

EC_GetPlayerName = function()
    local n = UnitName("player")
    if not n or n == "" then
        return ""
    end
    return n
end

local function EC_IsCharacterAllowed()
    if not DB or not DB.enableOnlyListedChars then
        return true
    end
    local name = EC_GetPlayerName()
    return DB.allowedChars and DB.allowedChars[name] == true
end

EC_IsAddonEnabledForChar = function()
    if DB and DB.enabled == false then
        return false
    end
    return EC_IsCharacterAllowed()
end

local function IsInSet(setTable, itemID)
    if not itemID or not setTable then
        return false
    end
    local v = setTable[itemID]
    return (v == true) or (v == 1)
end

-- Whitelist profile functions
local function EC_ValidateProfileName(name)
    if type(name) ~= "string" then
        return false, "Invalid name."
    end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then
        return false, "Profile name cannot be empty."
    end
    if name:find("[:|]") then
        return false, "Profile name cannot contain : or | characters."
    end
    return true, name
end

local function EC_CountItems(tbl)
    local n = 0
    for k, v in pairs(tbl) do
        if type(k) == "number" and (v == true or v == 1) then
            n = n + 1
        end
    end
    return n
end

local function EC_SaveProfile(name)
    local ok, cleaned = EC_ValidateProfileName(name)
    if not ok then
        return false, cleaned
    end
    name = cleaned
    if name == "Default" then
        return false, "The Default profile is locked to empty and cannot be overwritten."
    end
    local snapshot = {}
    for k, v in pairs(DB.whitelist) do
        snapshot[k] = v
    end
    DB.whitelistProfiles[name] = snapshot
    local blSnapshot = {}
    for k, v in pairs(DB.blacklist) do
        blSnapshot[k] = v
    end
    DB.blacklistProfiles[name] = blSnapshot
    DB.activeProfileName = name
    local wlCount = EC_CountItems(snapshot)
    local blCount = EC_CountItems(blSnapshot)
    return true, string.format('Saved profile "|cffffff00%s|r" (%d whitelist, %d blacklist).', name, wlCount, blCount)
end

local function EC_LoadProfile(name)
    if type(name) ~= "string" or not DB.whitelistProfiles[name] then
        return false, string.format('Profile "%s" not found.', tostring(name))
    end
    wipe(DB.whitelist)
    for k, v in pairs(DB.whitelistProfiles[name]) do
        DB.whitelist[k] = v
    end
    wipe(DB.blacklist)
    if DB.blacklistProfiles[name] then
        for k, v in pairs(DB.blacklistProfiles[name]) do
            DB.blacklist[k] = v
        end
    end
    DB.activeProfileName = name
    local wlCount = EC_CountItems(DB.whitelist)
    local blCount = EC_CountItems(DB.blacklist)
    -- Refresh panels if they exist
    local wp = _G["EbonClearanceOptionsWhitelist"]
    if wp and wp.listUI then
        wp.listUI:Refresh()
    end
    local bp = _G["EbonClearanceOptionsBlacklist"]
    if bp and bp.listUI then
        bp.listUI:Refresh()
    end
    return true, string.format('Loaded profile "|cffffff00%s|r" (%d whitelist, %d blacklist).', name, wlCount, blCount)
end

local function EC_DeleteProfile(name)
    if type(name) ~= "string" or not DB.whitelistProfiles[name] then
        return false, string.format('Profile "%s" not found.', tostring(name))
    end
    if name == "Default" then
        return false, "The Default profile cannot be deleted."
    end
    -- Count remaining profiles
    local count = 0
    for _ in pairs(DB.whitelistProfiles) do
        count = count + 1
    end
    if count <= 1 then
        return false, "Cannot delete the only remaining profile."
    end
    DB.whitelistProfiles[name] = nil
    DB.blacklistProfiles[name] = nil
    if DB.activeProfileName == name then
        DB.activeProfileName = next(DB.whitelistProfiles) or "Default"
    end
    return true, string.format('Deleted profile "|cffffff00%s|r".', name)
end

local function EC_RenameProfile(oldName, newName)
    if type(oldName) ~= "string" or not DB.whitelistProfiles[oldName] then
        return false, string.format('Profile "%s" not found.', tostring(oldName))
    end
    if oldName == "Default" then
        return false, "The Default profile cannot be renamed."
    end
    local ok, cleaned = EC_ValidateProfileName(newName)
    if not ok then
        return false, cleaned
    end
    newName = cleaned
    if newName == "Default" then
        return false, 'Cannot rename a profile to "Default".'
    end
    if newName == oldName then
        return true, "Name unchanged."
    end
    if DB.whitelistProfiles[newName] then
        return false, string.format('A profile named "%s" already exists.', newName)
    end
    DB.whitelistProfiles[newName] = DB.whitelistProfiles[oldName]
    DB.whitelistProfiles[oldName] = nil
    if DB.blacklistProfiles[oldName] then
        DB.blacklistProfiles[newName] = DB.blacklistProfiles[oldName]
        DB.blacklistProfiles[oldName] = nil
    end
    if DB.activeProfileName == oldName then
        DB.activeProfileName = newName
    end
    return true, string.format('Renamed "|cffffff00%s|r" to "|cffffff00%s|r".', oldName, newName)
end

local function CopperToColoredText(copper)
    if not copper or copper < 0 then
        copper = 0
    end
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local cop = copper % 100

    local g = string.format("|cffF8D943%dg|r", gold)
    local s = string.format("|cffC0C0C0%ds|r", silver)
    local c = string.format("|cffB87333%dc|r", cop)
    return string.format("%s %s %s", g, s, c)
end

local function PrintNice(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff7fbfff[EbonClearance]|r " .. msg)
end

-- Format + print convenience. Use instead of PrintNice(string.format(fmt, ...)).
local function PrintNicef(fmt, ...)
    PrintNice(string.format(fmt, ...))
end

-- Price provider seam. Vendor price is the only source today; probes for
-- Auctionator-WotLK / Auctioneer can be dropped in here without touching
-- callers. The _-prefixed args are reserved for those probes -- rename them
-- when activating a probe.
local function EC_GetItemPrice(_itemLink, _itemID, sellPrice, count)
    -- if _G.Auctionator_GetPrice then
    --     local v = _G.Auctionator_GetPrice(_itemLink)
    --     if v and v > 0 then return v * (count or 1) end
    -- end
    -- if _G.AucAdvanced and _G.AucAdvanced.API and _G.AucAdvanced.API.GetMarketValue then
    --     local v = _G.AucAdvanced.API.GetMarketValue(_itemLink)
    --     if v and v > 0 then return v * (count or 1) end
    -- end
    return (sellPrice or 0) * (count or 1)
end

local function EC_CalcInventoryWorthCopper()
    local total = 0
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag)
        for slot = 1, slots do
            local itemID = GetContainerItemID(bag, slot)
            if itemID then
                local texture, itemCount, locked = GetContainerItemInfo(bag, slot)
                if itemCount and itemCount > 0 then
                    local name, link, quality, level, minLevel, itemType, subType, stackCount, equipLoc, icon, sellPrice =
                        GetItemInfo(itemID)
                    if sellPrice and sellPrice > 0 then
                        total = total + (sellPrice * itemCount)
                    end
                end
            end
        end
    end
    return total
end

local function EC_RecordInventoryWorthSample()
    if not DB then
        return
    end
    local worth = EC_CalcInventoryWorthCopper()
    DB.inventoryWorthTotal = (DB.inventoryWorthTotal or 0) + worth
    DB.inventoryWorthCount = (DB.inventoryWorthCount or 0) + 1
end

local EC_activeIDBox = nil
local EC_Original_ChatEdit_InsertLink = ChatEdit_InsertLink

local function EC_ExtractItemID(link)
    if type(link) ~= "string" then
        return nil
    end
    local id = link:match("item:(%d+)")
    if id then
        return tonumber(id)
    end
    return nil
end

ChatEdit_InsertLink = function(link)
    if EC_activeIDBox and EC_activeIDBox:IsShown() then
        local id = EC_ExtractItemID(link)
        if id then
            EC_activeIDBox:SetText(tostring(id))
            EC_activeIDBox:HighlightText()
            return true
        end
    end
    return EC_Original_ChatEdit_InsertLink(link)
end

local function SummonGreedyScavenger()
    -- Don't summon while mounted (delayed calls from dismount can race with remounting)
    if IsMounted and IsMounted() then
        return
    end

    local num = GetNumCompanions("CRITTER")
    if not num or num <= 0 then
        return
    end

    for i = 1, num do
        local creatureID, creatureName, spellID, icon, isSummoned = GetCompanionInfo("CRITTER", i)
        if creatureName == PET_NAME then
            if not isSummoned then
                -- Dismiss any active critter first, then summon Scavenger
                if DismissCompanion then
                    DismissCompanion("CRITTER")
                end
                CallCompanion("CRITTER", i)
            end
            EC_addonDismissed = false
            if DB and DB.autoLootCycle then
                EC_lootCycleState = STATE.LOOTING
            end
            return
        end
    end
end

local function DismissGreedyScavenger()
    EC_addonDismissed = true
    if DismissCompanion then
        DismissCompanion("CRITTER")
    else
        local num = GetNumCompanions("CRITTER")
        if not num or num <= 0 then
            return
        end
        for i = 1, num do
            local _, creatureName, _, _, isSummoned = GetCompanionInfo("CRITTER", i)
            if creatureName == PET_NAME and isSummoned then
                CallCompanion("CRITTER", i)
                return
            end
        end
    end
end

-- The spellID branch is the localisation escape hatch. If a future Ebonhold
-- realm ships with a non-enUS name for the Goblin Merchant companion, the
-- name match fails but the spellID match still finds it. See TARGET_NAME
-- note at the top of the file.
local GOBLIN_MERCHANT_SPELL_ID = 600126

-- The "CRITTER" companion type in the 3.3.5a API covers both cosmetic vanity
-- pets AND functional companions like the Goblin Merchant on Project Ebonhold
-- -- they share one companion slot. That's why summoning the Merchant
-- dismisses the Scavenger and vice versa: they can't coexist.
local function FindGoblinMerchantIndex()
    local num = GetNumCompanions("CRITTER")
    if not num or num <= 0 then
        return nil
    end
    for i = 1, num do
        local _, creatureName, spellID, _, isSummoned = GetCompanionInfo("CRITTER", i)
        if creatureName == TARGET_NAME or spellID == GOBLIN_MERCHANT_SPELL_ID then
            return i, isSummoned
        end
    end
    return nil
end

local function SummonGoblinMerchant()
    local idx = FindGoblinMerchantIndex()
    if not idx then
        return
    end
    -- Dismiss any active critter first
    if DismissCompanion then
        DismissCompanion("CRITTER")
    end
    CallCompanion("CRITTER", idx)
end

local function DismissGoblinMerchant()
    local idx, isSummoned = FindGoblinMerchantIndex()
    if idx and isSummoned then
        if DismissCompanion then
            DismissCompanion("CRITTER")
        else
            CallCompanion("CRITTER", idx)
        end
    end
end

-- Returns a coloured string describing the user's current binding for the
-- "Target Goblin Merchant" action, or a prompt if none is bound. Used in
-- the summon-confirmation chat line so users can discover the keybind.
local function EC_FormatTargetMerchantBinding()
    if not GetBindingKey then
        return "your bound key"
    end
    local key = GetBindingKey("CLICK EbonClearanceTargetMerchantButton:LeftButton")
    if key and key ~= "" then
        return "|cffffff00" .. key .. "|r"
    end
    return "|cffaaaaaaa key|r (bind one in ESC > Key Bindings > EbonClearance)"
end

local EC_wasMounted = false
local EC_mountDismissTime = 0
-- STATE, EC_lootCycleState, EC_addonDismissed are forward-declared at the
-- top of the file so functions compiled earlier capture them as upvalues.

local EC_delayFrame = CreateFrame("Frame")
local EC_timers = {}

local function EC_Delay(seconds, func)
    if type(func) ~= "function" then
        return
    end
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then
        func()
        return
    end
    EC_timers[#EC_timers + 1] = { t = seconds, f = func }
end

EC_delayFrame:SetScript("OnUpdate", function(self, elapsed)
    if #EC_timers == 0 then
        return
    end
    for i = #EC_timers, 1, -1 do
        local item = EC_timers[i]
        item.t = item.t - elapsed
        if item.t <= 0 then
            table.remove(EC_timers, i)
            local ok, err = pcall(item.f)
            if not ok and geterrorhandler then
                geterrorhandler()(err)
            end
        end
    end
end)

local function EC_SummonGreedyWithDelay()
    if not DB or not DB.summonGreedy then
        return
    end
    EC_Delay((DB and DB.summonDelay) or 1.6, SummonGreedyScavenger)
end

local function EC_GetFreeBagSlots()
    local free = 0
    for bag = 0, 4 do
        local numFree = GetContainerNumFreeSlots(bag)
        if numFree then
            free = free + numFree
        end
    end
    return free
end

-- Yards. If the Scavenger drifts further than this from the player during a
-- loot cycle we dismiss it so the next tick can re-summon at the player's
-- position. Too low = false positives on normal follow-lag (pet briefly out
-- of range while the player runs); too high = stuck pet sits for minutes
-- before recovery. 5 yards matches in-game follow-leash behaviour reasonably.
-- Note: EC_GetCompanionDistance depends on UnitPosition, which is Legion-era
-- and does not exist on stock 3.3.5a -- the whole check no-ops there.
local EC_MAX_PET_DISTANCE = 5

local function EC_GetCompanionDistance()
    if not UnitPosition then
        return nil
    end
    local px, py = UnitPosition("player")
    local cx, cy = UnitPosition("pet")
    if not px or not cx then
        return nil
    end
    local dx, dy = px - cx, py - cy
    return math.sqrt(dx * dx + dy * dy)
end

-- Fast Mode: when enabled, pin the per-item vendor interval to the 0.05 s
-- floor and double the per-run cap. Opt-in via DB.fastMode.
local function EC_EffectiveVendorInterval()
    if DB and DB.fastMode then
        return 0.05
    end
    local i = (DB and DB.vendorInterval) or 0.1
    if i < 0.05 then
        i = 0.05
    end
    return i
end

local function EC_EffectiveMaxItemsPerRun()
    if DB and DB.fastMode then
        return 160
    end
    return (DB and DB.maxItemsPerRun) or 80
end

-- Pet-cycle timer/flag locals. MUST be declared before EC_HandleBagFullForCycle:
-- that function (BAG_UPDATE handler) writes EC_summonGoblinPending /
-- EC_summonGoblinTimer, and Lua resolves writes to whatever is in scope at the
-- function's parse site. If these aren't locals yet, the writes leak to _G and
-- the OnUpdate consumer at the bottom (which captures them as locals) never
-- sees them - the cycle hangs in WAITING_MERCHANT forever. This is the same
-- trap v2.0.13 fixed for STATE / running / EC_lootCycleState; see CLAUDE.md
-- convention #4.
local EC_petCheckElapsed = 0
local EC_summonGoblinPending = false
local EC_summonGoblinTimer = 0
local EC_targetGoblinPending = false
local EC_targetGoblinTimer = 0
local EC_merchantReminderPending = false
local EC_merchantReminderTimer = 0
-- Auto-open container in-flight flag. Same forward-declaration discipline as
-- the timers above: EC_HandleAutoOpenContainers writes this, and we don't want
-- the write to leak into _G if the function is parsed before the local exists.
local EC_autoOpenInFlight = false

-- Auto-loot cycle: react to bag-full as soon as the game tells us a bag
-- changed. Same body as the old 5-second poll; called from BAG_UPDATE so the
-- Goblin Merchant is summoned within a tick of the threshold being crossed.
-- Idempotent: the STATE.LOOTING guard prevents double-summon under burst events.
local function EC_HandleBagFullForCycle()
    if not DB or not DB.autoLootCycle then
        return
    end
    if EC_lootCycleState ~= STATE.LOOTING then
        return
    end
    if not EC_IsAddonEnabledForChar() then
        return
    end
    if running then
        return
    end
    if IsMounted() then
        return
    end
    local free = EC_GetFreeBagSlots()
    if free > (DB.bagFullThreshold or 2) then
        return
    end
    EC_lootCycleState = STATE.WAITING_MERCHANT
    PrintNicef("|cffffff00%d free bag slots remaining. Summoning Goblin Merchant...|r", free)
    if DismissCompanion then
        DismissCompanion("CRITTER")
    end
    EC_summonGoblinPending = true
    EC_summonGoblinTimer = 1.5
end

-- ===========================================================================
-- Auto-open lootable containers
-- ---------------------------------------------------------------------------
-- Hidden tooltip used to scan bag items for the "Right Click to Open" line.
-- Anchored offscreen via SetOwner(UIParent, "ANCHOR_NONE") so it never flashes
-- on the user's screen during scans.
local EC_scanTooltip = CreateFrame("GameTooltip", "EbonClearanceScanTooltip", UIParent, "GameTooltipTemplate")
EC_scanTooltip:SetOwner(UIParent, "ANCHOR_NONE")

-- True iff the slotted item shows ITEM_OPENABLE in its tooltip and is not
-- locked. ITEM_OPENABLE is the standard Blizzard locale string ("<Right
-- Click to Open>" in enUS) used by every container, gift bag, and
-- treasure pouch in 3.3.5a. LOCKED is the same string that gets shown on
-- junkboxes / lockpickable containers; we exclude those because the user
-- needs a key or lockpicking skill to open them.
local function EC_IsOpenable(bag, slot)
    local _, itemCount, locked = GetContainerItemInfo(bag, slot)
    if not itemCount or itemCount <= 0 or locked then
        return false
    end
    EC_scanTooltip:ClearLines()
    EC_scanTooltip:SetBagItem(bag, slot)
    -- Cap iterations: tooltips can technically grow long; 30 lines is more
    -- than any container we care about will produce.
    for i = 1, 30 do
        local line = _G["EbonClearanceScanTooltipTextLeft" .. i]
        if not line then
            break
        end
        local txt = line:GetText()
        if txt == ITEM_OPENABLE then
            return true
        end
        if txt == LOCKED then
            return false
        end
    end
    return false
end

-- Driver. Walks bags, opens the first openable item, and recurses via
-- EC_Delay if more remain. EC_autoOpenInFlight coalesces BAG_UPDATE bursts
-- so we never stack `UseContainerItem` calls within the inter-item delay.
local function EC_HandleAutoOpenContainers()
    if not DB or not DB.autoOpenContainers then
        return
    end
    if running then
        return
    end
    if InCombatLockdown() then
        return
    end
    if EC_autoOpenInFlight then
        return
    end
    if not EC_IsAddonEnabledForChar() then
        return
    end
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag)
        for slot = 1, slots do
            if EC_IsOpenable(bag, slot) then
                EC_autoOpenInFlight = true
                UseContainerItem(bag, slot)
                -- 0.4 s gives the prior open's cast room to finish before we
                -- trigger the next one. Tunable; lower would feel snappier
                -- but risks interrupting the previous use.
                EC_Delay(0.4, function()
                    EC_autoOpenInFlight = false
                    EC_HandleAutoOpenContainers()
                end)
                return
            end
        end
    end
end

-- ===========================================================================

-- ===========================================================================
-- Right-click bag-item context menu (Alt+Right-Click)
-- ---------------------------------------------------------------------------
-- Adds an EbonClearance popup to bag items: Whitelist (Character/Account),
-- Blacklist, Deletion List, Sell Now. Triggered by Alt+Right-Click so it
-- doesn't override the default right-click-to-use behaviour. We replace
-- (rather than hooksecurefunc) ContainerFrameItemButton_OnClick because we
-- need to *suppress* the default action on our modifier combo, not just
-- append.
--
-- Implementation: a hand-built popup frame with regular Buttons. We avoid
-- UIDropDownMenu in "MENU" mode because 3.3.5a's implementation has a known
-- issue where the click handlers on menu items silently no-op when parented
-- to a custom frame.

local EC_CTX_PANEL_FOR = {
    whitelist = "EbonClearanceOptionsWhitelist",
    accountWhitelist = "EbonClearanceOptionsAccountWhitelist",
    blacklist = "EbonClearanceOptionsBlacklist",
    deleteList = "EbonClearanceOptionsDeletion",
}

local function EC_AddItemToList(setName, itemID, label)
    if not itemID then
        return
    end
    local t = EC_GetListTable(setName)
    if not t then
        PrintNicef("|cffff4444Could not resolve list: %s|r", tostring(setName))
        return
    end
    local itemName = GetItemInfo(itemID) or ("ItemID:" .. itemID)
    if t[itemID] then
        PrintNicef("|cffaaaaaa%s already on %s.|r", itemName, label)
        return
    end
    t[itemID] = true
    PrintNicef("Added |cffb6ffb6%s|r to %s.", itemName, label)
    -- Refresh the corresponding settings panel if it's been opened.
    local panelName = EC_CTX_PANEL_FOR[setName]
    if panelName then
        local p = _G[panelName]
        if p and p.listUI then
            p.listUI:Refresh()
        end
    end
end

local function EC_SellNowAt(bag, slot)
    if not (MerchantFrame and MerchantFrame:IsShown()) then
        PrintNice("|cffff4444Open a merchant first to sell.|r")
        return
    end
    if not bag or not slot then
        return
    end
    local itemID = GetContainerItemID(bag, slot)
    if not itemID then
        return
    end
    if IsEquippedItem(itemID) then
        PrintNice("|cffff4444Cannot sell equipped items.|r")
        return
    end
    UseContainerItem(bag, slot)
    local itemName = GetItemInfo(itemID) or ("ItemID:" .. itemID)
    PrintNicef("Sold |cffb6ffb6%s|r.", itemName)
end

-- Action list. `requireMerchant = true` greys the row when no merchant is
-- open. Cancel just closes the popup.
local EC_CTX_ACTIONS = {
    {
        label = "Add to Whitelist (Character)",
        run = function(bag, slot, id)
            EC_AddItemToList("whitelist", id, "Whitelist - Character")
        end,
    },
    {
        label = "Add to Whitelist (Account)",
        run = function(bag, slot, id)
            EC_AddItemToList("accountWhitelist", id, "Whitelist - Account")
        end,
    },
    {
        label = "Add to Blacklist (Do Not Sell)",
        run = function(bag, slot, id)
            EC_AddItemToList("blacklist", id, "Blacklist")
        end,
    },
    {
        label = "Add to Deletion List",
        run = function(bag, slot, id)
            EC_AddItemToList("deleteList", id, "Deletion List")
        end,
    },
    {
        label = "Sell Now",
        run = function(bag, slot, id)
            EC_SellNowAt(bag, slot)
        end,
        requireMerchant = true,
    },
    {
        label = "Cancel",
        run = function() end,
    },
}

local EC_ctxFrame

local function EC_BuildCtxFrame()
    if EC_ctxFrame then
        return EC_ctxFrame
    end
    local rowCount = #EC_CTX_ACTIONS
    -- Layout: 8 top pad + 22 title + 6 gap + rows*22 + 8 bottom pad
    local frameHeight = 8 + 22 + 6 + (rowCount * 22) + 8
    local frame = CreateFrame("Frame", "EbonClearanceCtxFrame", UIParent)
    frame:SetFrameStrata("DIALOG")
    frame:SetSize(240, frameHeight)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:EnableMouse(true)
    frame:Hide()

    local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetPoint("TOPRIGHT", -10, -8)
    title:SetJustifyH("LEFT")
    if title.SetWordWrap then
        title:SetWordWrap(false)
    end
    frame.title = title

    frame.buttons = {}
    for i, action in ipairs(EC_CTX_ACTIONS) do
        local btn = CreateFrame("Button", nil, frame)
        btn:SetSize(220, 20)
        btn:SetPoint("TOPLEFT", 10, -(8 + 22 + 6) - (i - 1) * 22)
        btn:SetNormalFontObject("GameFontHighlightSmall")
        btn:SetHighlightFontObject("GameFontGreenSmall")
        btn:SetDisabledFontObject("GameFontDisableSmall")
        btn:SetText(action.label)
        local fs = btn:GetFontString()
        if fs then
            fs:ClearAllPoints()
            fs:SetPoint("LEFT", btn, "LEFT", 4, 0)
            fs:SetJustifyH("LEFT")
        end
        -- Highlight texture so hover gives feedback.
        local hl = btn:CreateTexture(nil, "BACKGROUND")
        hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        hl:SetBlendMode("ADD")
        hl:SetAllPoints(btn)
        hl:SetAlpha(0)
        btn:SetScript("OnEnter", function()
            hl:SetAlpha(0.4)
        end)
        btn:SetScript("OnLeave", function()
            hl:SetAlpha(0)
        end)
        btn:SetScript("OnClick", function()
            local id = GetContainerItemID(frame.bag, frame.slot)
            action.run(frame.bag, frame.slot, id)
            frame:Hide()
        end)
        frame.buttons[i] = btn
    end

    -- Escape closes the popup. Standard Blizzard pattern: anything in the
    -- UISpecialFrames table is auto-hidden on Escape. Avoids the previous
    -- fullscreen-overlay approach which could intercept bag clicks if it ever
    -- got stuck shown after a disable/enable cycle.
    if type(UISpecialFrames) == "table" then
        table.insert(UISpecialFrames, "EbonClearanceCtxFrame")
    end
    frame:SetScript("OnHide", function()
        frame.bag = nil
        frame.slot = nil
    end)

    EC_ctxFrame = frame
    return frame
end

local function EC_ShowItemContextMenu(button)
    local frame = EC_BuildCtxFrame()
    local bag = button:GetParent():GetID()
    local slot = button:GetID()
    local itemID = GetContainerItemID(bag, slot)
    if not itemID then
        return
    end
    frame.bag = bag
    frame.slot = slot

    local itemName = GetItemInfo(itemID) or ("ItemID:" .. itemID)
    frame.title:SetText("|cff4db8ffEbonClearance|r: " .. itemName)

    local merchantOpen = MerchantFrame and MerchantFrame:IsShown()
    for i, action in ipairs(EC_CTX_ACTIONS) do
        local btn = frame.buttons[i]
        if action.requireMerchant and not merchantOpen then
            btn:Disable()
        else
            btn:Enable()
        end
    end

    -- Position at the cursor. WoW's GetCursorPosition returns screen pixels;
    -- divide by UIParent's effective scale to get UIParent-local coords.
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale, y / scale)
    frame:Show()
end

local EC_bagContextHookInstalled = false

-- 3.3.5a routes any modifier+click on a bag item through
-- ContainerFrameItemButton_OnModifiedClick (NOT _OnClick). _OnModifiedClick
-- has Shift/Ctrl handlers, then falls through to _OnClick for the unhandled
-- modifiers. We intercept pure Alt+RightClick (no Shift, no Ctrl) before that
-- fall-through. Replace rather than hooksecurefunc because we need to suppress
-- the fall-through, not just append.
local function EC_InstallBagContextHookOnce()
    if EC_bagContextHookInstalled then
        return
    end
    if type(ContainerFrameItemButton_OnModifiedClick) ~= "function" then
        return
    end
    EC_bagContextHookInstalled = true
    local orig = ContainerFrameItemButton_OnModifiedClick
    ContainerFrameItemButton_OnModifiedClick = function(self, button)
        if
            button == "RightButton"
            and IsAltKeyDown()
            and not IsShiftKeyDown()
            and not IsControlKeyDown()
        then
            EC_ShowItemContextMenu(self)
            return
        end
        return orig(self, button)
    end
end

-- ===========================================================================

-- Pet stuck detection + auto-loot cycle bag monitoring
local EC_petCheckFrame = CreateFrame("Frame")

EC_petCheckFrame:SetScript("OnUpdate", function(self, elapsed)
    -- Delayed Goblin Merchant summon (after dismiss completes)
    if EC_summonGoblinPending then
        EC_summonGoblinTimer = EC_summonGoblinTimer - elapsed
        if EC_summonGoblinTimer <= 0 then
            EC_summonGoblinPending = false
            local idx = FindGoblinMerchantIndex()
            if idx then
                CallCompanion("CRITTER", idx)
                EC_targetGoblinPending = true
                EC_targetGoblinTimer = 2.0
            else
                PrintNice("|cffff4444Goblin Merchant not found in companion list!|r")
                EC_lootCycleState = STATE.LOOTING
            end
        end
        return
    end

    -- Delayed target after Goblin Merchant summon
    if EC_targetGoblinPending then
        EC_targetGoblinTimer = EC_targetGoblinTimer - elapsed
        if EC_targetGoblinTimer <= 0 then
            EC_targetGoblinPending = false
            local _, nowSummoned = FindGoblinMerchantIndex()
            if nowSummoned then
                PrintNicef(
                    "|cff00ff00Goblin Merchant summoned|r - press %s or right-click to sell.",
                    EC_FormatTargetMerchantBinding()
                )
                EC_merchantReminderPending = true
                EC_merchantReminderTimer = 8.0
            else
                PrintNice("|cffff4444Goblin Merchant failed to summon. Resuming looting.|r")
                EC_lootCycleState = STATE.LOOTING
            end
        end
        return
    end

    -- 8-second reminder if merchant window hasn't been opened
    if EC_merchantReminderPending then
        EC_merchantReminderTimer = EC_merchantReminderTimer - elapsed
        if EC_merchantReminderTimer <= 0 then
            EC_merchantReminderPending = false
            if EC_lootCycleState == STATE.WAITING_MERCHANT then
                PrintNice("|cffffff00Reminder: right-click the Goblin Merchant to open the vendor window.|r")
            end
        end
    end

    EC_petCheckElapsed = EC_petCheckElapsed + elapsed
    if EC_petCheckElapsed < 5 then
        return
    end
    EC_petCheckElapsed = 0

    if not DB or not DB.summonGreedy then
        return
    end
    if not EC_IsAddonEnabledForChar() then
        return
    end
    if IsMounted() then
        return
    end
    if running then
        return
    end

    -- If auto-loot cycle is on and Scavenger is already out, ensure state is "looting"
    if DB.autoLootCycle and EC_lootCycleState == STATE.IDLE then
        local num = GetNumCompanions("CRITTER")
        for i = 1, (num or 0) do
            local _, creatureName, _, _, isSummoned = GetCompanionInfo("CRITTER", i)
            if creatureName == PET_NAME and isSummoned then
                EC_lootCycleState = STATE.LOOTING
                break
            end
        end
    end

    -- Bag-full detection moved to BAG_UPDATE event handler (EC_HandleBagFullForCycle).

    -- Don't re-summon scavenger while waiting for merchant or selling
    if EC_lootCycleState == STATE.WAITING_MERCHANT or EC_lootCycleState == STATE.SELLING then
        return
    end

    -- Stuck detection: re-summon Greedy Scavenger if it despawned or is stuck on terrain
    -- Respects: addon enabled, mounted state, mount cooldown, manual unsummon, other companions
    local num = GetNumCompanions("CRITTER")
    if not num or num <= 0 then
        return
    end
    local greedyIndex = nil
    local scavengerOut = false
    local anyPetOut = false
    for i = 1, num do
        local _, creatureName, _, _, isSummoned = GetCompanionInfo("CRITTER", i)
        if isSummoned then
            anyPetOut = true
        end
        if creatureName == PET_NAME then
            greedyIndex = i
            if isSummoned then
                scavengerOut = true
            end
        end
    end

    -- Distance check: if Scavenger is out but stuck far away, dismiss and let next tick re-summon
    if scavengerOut then
        local dist = EC_GetCompanionDistance()
        if dist and dist > EC_MAX_PET_DISTANCE then
            EC_addonDismissed = true
            DismissGreedyScavenger()
        end
        return
    end

    -- Scavenger is not out - check if we should re-summon
    -- Don't re-summon if another companion is active (bank mule, mailbox)
    if anyPetOut then
        return
    end

    -- Don't re-summon if we recently dismissed for mounting
    if (GetTime() - EC_mountDismissTime) <= 10 then
        return
    end

    -- Only re-summon if our code dismissed it (mount, cycle, distance-stuck)
    -- If the user manually unsummoned, respect that
    if not EC_addonDismissed then
        return
    end

    if greedyIndex then
        EC_addonDismissed = false
        CallCompanion("CRITTER", greedyIndex)
        if DB and DB.autoLootCycle then
            EC_lootCycleState = STATE.LOOTING
        end
    end
end)

local pendingDelete = nil
local deletePopupHooked = false

local function HookDeletePopupOnce()
    if deletePopupHooked then
        return
    end
    deletePopupHooked = true

    local f = CreateFrame("Frame")
    local popupElapsed = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        -- Skip entirely unless a deletion is queued. Without this gate the
        -- handler would tick ~60 times/s for the life of the session.
        if not pendingDelete then
            popupElapsed = 0
            return
        end
        popupElapsed = popupElapsed + (elapsed or 0)
        if popupElapsed < 0.1 then
            return
        end
        popupElapsed = 0

        local popup = StaticPopup1
        if popup and popup:IsShown() and popup.which == "DELETE_ITEM" then
            local id = pendingDelete.itemID
            if id and IsInSet(DB.deleteList, id) then
                local editBox = StaticPopup1EditBox
                if editBox then
                    editBox:SetText("DELETE")
                    editBox:HighlightText()
                end
                local button1 = StaticPopup1Button1
                if button1 and button1:IsEnabled() then
                    button1:Click()
                    pendingDelete = nil
                end
            else
                pendingDelete = nil
            end
        end
    end)
end

local EC_IsMerchantAllowed -- forward declaration for FinishRun
-- `running` is forward-declared at the top of the file.
local queue = {}
local queueIndex = 1
local goldThisVendoring = 0
local EC_batchTotalSold = 0
local EC_batchTotalGold = 0

local worker = CreateFrame("Frame")
worker:Hide()

-- Shared sell predicate. Used by BuildQueue to build the vendor queue and by
-- EC_PreviewSellable to drive the minimap mouse-over preview. Returns:
--   sellable (bool), link, sellPrice, itemCount.
-- `junkOnly` restricts matches to quality-0 items (used when the current
-- merchant mode disallows the whitelist/quality threshold).
--
-- INVARIANT: Grey items (quality == 0) with a positive sell price ALWAYS
-- match via isJunk, independent of DB.whitelist, DB.whitelistQualityEnabled,
-- or DB.whitelistMinQuality. The quality threshold only gates non-grey
-- items. Do not "simplify" the three independent passes (isJunk /
-- qualityPass / whitelistPass) into one combined check -- you will silently
-- break the grey-always-sold guarantee that users and docs rely on.
-- Blacklist and IsEquippedItem are the only things that can veto a sale.
local function EC_IsSellable(bag, slot, junkOnly)
    local itemID = GetContainerItemID(bag, slot)
    if not itemID then
        return false
    end
    local _, itemCount, locked = GetContainerItemInfo(bag, slot)
    if not itemCount or itemCount <= 0 or locked then
        return false
    end
    local _, link, quality, _, _, _, _, _, _, _, sellPrice = GetItemInfo(itemID)
    local hasSellPrice = sellPrice and sellPrice > 0
    local isJunk = (quality ~= nil) and (quality == 0) and hasSellPrice
    local whitelistPass = not junkOnly
        and hasSellPrice
        and (IsInSet(DB.whitelist, itemID) or (ADB and IsInSet(ADB.whitelist, itemID)))
    local qualityPass = false
    if not junkOnly and DB.whitelistQualityEnabled == true and hasSellPrice then
        qualityPass = (quality ~= nil) and (quality <= DB.whitelistMinQuality)
    end
    local blacklisted = IsInSet(DB.blacklist, itemID)
    if not (isJunk or qualityPass or whitelistPass) then
        return false
    end
    if IsEquippedItem(itemID) or blacklisted then
        return false
    end
    return true, link, itemID, sellPrice, itemCount
end

local function BuildQueue(junkOnly)
    wipe(queue)
    queueIndex = 1
    goldThisVendoring = 0
    -- Grey items (quality 0) are always sold as junk at any merchant.
    -- Whitelist/quality threshold selling only runs when the merchant mode allows it.
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag)
        for slot = 1, slots do
            local sellable, link, itemID, sellPrice, itemCount = EC_IsSellable(bag, slot, junkOnly)
            if sellable then
                queue[#queue + 1] = {
                    type = "sell",
                    bag = bag,
                    slot = slot,
                    itemID = itemID,
                    count = itemCount,
                    price = sellPrice or 0,
                }
                if sellPrice and sellPrice > 0 then
                    goldThisVendoring = goldThisVendoring + EC_GetItemPrice(link, itemID, sellPrice, itemCount)
                end
            end
        end
    end

    if DB.enableDeletion == true then
        for bag = 0, 4 do
            local slots = GetContainerNumSlots(bag)
            for slot = 1, slots do
                local itemID = GetContainerItemID(bag, slot)
                if itemID and IsInSet(DB.deleteList, itemID) and not IsEquippedItem(itemID) then
                    local texture, itemCount, locked = GetContainerItemInfo(bag, slot)
                    if itemCount and itemCount > 0 and not locked then
                        queue[#queue + 1] = {
                            type = "delete",
                            bag = bag,
                            slot = slot,
                            itemID = itemID,
                            count = itemCount,
                        }
                    end
                end
            end
        end
    end

    local cap = EC_EffectiveMaxItemsPerRun()
    if #queue > cap then
        local removed = #queue - cap
        for i = #queue, cap + 1, -1 do
            queue[i] = nil
        end
        PrintNicef("|cffffff00Capped at %d items this run (%d skipped). Visit again to sell the rest.|r", cap, removed)
    end
end

local function FinishRun()
    running = false
    worker:Hide()

    DB.totalCopper = (DB.totalCopper or 0) + (goldThisVendoring or 0)
    EC_session.copper = EC_session.copper + (goldThisVendoring or 0)
    EC_batchTotalSold = EC_batchTotalSold + #queue
    EC_batchTotalGold = EC_batchTotalGold + (goldThisVendoring or 0)

    -- Check if merchant is still open - delay re-scan so server can process sold items
    if MerchantFrame and MerchantFrame:IsShown() then
        PrintNicef("Batch sold |cffffff00%d|r items. Checking for more...", EC_batchTotalSold)
        EC_Delay(1.0, function()
            if not MerchantFrame or not MerchantFrame:IsShown() then
                return
            end
            local merchantAllowed = EC_IsMerchantAllowed()
            BuildQueue(not merchantAllowed)
            if #queue > 0 then
                running = true
                worker.t = 0
                worker:Show()
            else
                -- Nothing left - print final summary
                PrintNicef(
                    "Vendoring complete! Sold |cffffff00%d|r items. |cffb6ffb6Money Collected:|r %s",
                    EC_batchTotalSold,
                    CopperToColoredText(EC_batchTotalGold)
                )
                if DB and DB.autoLootCycle then
                    EC_lootCycleState = STATE.IDLE
                    EC_SummonGreedyWithDelay()
                else
                    EC_SummonGreedyWithDelay()
                end
            end
        end)
        return
    end

    -- All done - print final summary
    PrintNicef(
        "Vendoring complete! Sold |cffffff00%d|r items. |cffb6ffb6Money Collected:|r %s",
        EC_batchTotalSold,
        CopperToColoredText(EC_batchTotalGold)
    )

    if DB and DB.autoLootCycle then
        EC_lootCycleState = STATE.IDLE
        EC_SummonGreedyWithDelay()
    else
        EC_SummonGreedyWithDelay()
    end
end

local function DoNextAction()
    if not MerchantFrame or not MerchantFrame:IsShown() then
        running = false
        worker:Hide()
        return
    end

    local action = queue[queueIndex]
    if not action then
        FinishRun()
        return
    end

    -- Safety: verify the item at this slot still matches what we queued.
    -- Bags can shift between queue build and execution (player moves items, etc).
    local currentID = GetContainerItemID(action.bag, action.slot)
    if currentID ~= action.itemID then
        queueIndex = queueIndex + 1
        return
    end

    if action.type == "sell" then
        UseContainerItem(action.bag, action.slot)
        DB.totalItemsSold = (DB.totalItemsSold or 0) + (action.count or 1)
        EC_session.sold = EC_session.sold + (action.count or 1)
        DB.soldItemCounts = DB.soldItemCounts or {}
        if action.itemID then
            DB.soldItemCounts[action.itemID] = (DB.soldItemCounts[action.itemID] or 0) + (action.count or 1)
        end
    elseif action.type == "delete" then
        ClearCursor()
        PickupContainerItem(action.bag, action.slot)
        local cursorType, cursorID = GetCursorInfo()

        if cursorType == "item" then
            pendingDelete = { bag = action.bag, slot = action.slot, itemID = action.itemID }
            DeleteCursorItem()
            ClearCursor()
            DB.totalItemsDeleted = (DB.totalItemsDeleted or 0) + (action.count or 1)
            EC_session.deleted = EC_session.deleted + (action.count or 1)
            DB.deletedItemCounts = DB.deletedItemCounts or {}
            if action.itemID then
                DB.deletedItemCounts[action.itemID] = (DB.deletedItemCounts[action.itemID] or 0) + (action.count or 1)
            end
        else
            ClearCursor()
            pendingDelete = nil
        end
    end

    queueIndex = queueIndex + 1
end

-- The 0.05s interval floor is an anti-disconnect guarantee, not a performance
-- tuning choice. Faster per-item pacing floods the server with UseContainerItem
-- packets and trips a server-side rate limit that boots the client. See
-- docs/ADDON_GUIDE.md "Performance rules" and v2.0.11 in the README changelog.
worker:SetScript("OnUpdate", function(self, elapsed)
    self.t = (self.t or 0) + elapsed
    local interval = EC_EffectiveVendorInterval()
    if self.t >= interval then
        self.t = 0
        DoNextAction()
    end
end)

local function ShouldRunNow()
    -- Called from MERCHANT_SHOW so the merchant is always open at this point.
    -- DoNextAction has its own MerchantFrame:IsShown() guard for mid-sell safety.
    return true
end

EC_IsMerchantAllowed = function()
    local mode = DB and DB.merchantMode or "goblin"
    if mode == "any" then
        -- Only normal merchants (not Goblin Merchant)
        local targetName = UnitExists("target") and UnitName("target") or ""
        return targetName ~= TARGET_NAME
    elseif mode == "both" then
        return true
    else
        -- "goblin" (default): only the Goblin Merchant
        return UnitExists("target") and UnitName("target") == TARGET_NAME
    end
end

-- Mouse-over preview: counts what BuildQueue would sell right now. When no
-- merchant is targeted, fall back to the broadest case (merchantAllowed=true)
-- so the preview reflects the whitelist/quality threshold, not only greys.
local function EC_PreviewSellable()
    if not DB then
        return 0, 0
    end
    local merchantAllowed = true
    if UnitExists("target") then
        merchantAllowed = EC_IsMerchantAllowed()
    end
    local junkOnly = not merchantAllowed
    local count, copper = 0, 0
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local sellable, link, itemID, sellPrice, itemCount = EC_IsSellable(bag, slot, junkOnly)
            if sellable then
                count = count + (itemCount or 1)
                if sellPrice and sellPrice > 0 then
                    copper = copper + EC_GetItemPrice(link, itemID, sellPrice, itemCount)
                end
            end
        end
    end
    return count, copper
end

local function StartRun()
    if not EC_IsAddonEnabledForChar() then
        return
    end
    if running then
        return
    end
    if not ShouldRunNow() then
        return
    end

    local merchantAllowed = EC_IsMerchantAllowed()

    HookDeletePopupOnce()

    running = true

    EC_RecordInventoryWorthSample()

    if
        DB
        and DB.repairGear == true
        and CanMerchantRepair
        and CanMerchantRepair()
        and GetRepairAllCost
        and RepairAllItems
    then
        local repairCost, canRepair = GetRepairAllCost()
        if canRepair and repairCost and repairCost > 0 and GetMoney and GetMoney() >= repairCost then
            RepairAllItems()
            DB.totalRepairs = (DB.totalRepairs or 0) + 1
            DB.totalRepairCopper = (DB.totalRepairCopper or 0) + repairCost
            EC_session.repairs = EC_session.repairs + 1
            EC_session.repairCopper = EC_session.repairCopper + repairCost
        end
    end

    BuildQueue(not merchantAllowed)

    if #queue == 0 then
        PrintNice("Found nothing to sell.")
        running = false
        if UnitExists("target") and UnitName("target") == TARGET_NAME and MerchantFrame and MerchantFrame:IsShown() then
            EC_SummonGreedyWithDelay()
        end
        return
    end

    worker.t = 0
    worker:Show()
end

-- Tooltip annotation. Adds a coloured line indicating whether EbonClearance
-- will sell, protect, or delete the hovered item. Hooked once on addon load
-- against GameTooltip and ItemRefTooltip (chat-linked items use the latter).
--
-- Dedupe: recipe tooltips fire OnTooltipSetItem twice (once for the recipe,
-- once for the embedded result), so we flag the tooltip after adding a line
-- and clear the flag when the tooltip is reset.
local EC_tooltipHooked = false

local function EC_AnnotateTooltip(tooltip)
    if not DB or not tooltip or not tooltip.GetItem then
        return
    end
    -- Honour the addon-enabled toggle and per-character allowlist. If the
    -- addon won't act on the item, don't mislead the user by annotating it.
    if EC_IsAddonEnabledForChar and not EC_IsAddonEnabledForChar() then
        return
    end
    if tooltip.__EC_annotated then
        return
    end
    local _, link = tooltip:GetItem()
    if not link then
        return
    end
    local id = tonumber(link:match("|Hitem:(%d+)"))
    if not id then
        return
    end

    local statusLine
    if IsInSet(DB.blacklist, id) then
        statusLine = "|cff4db8ff[EC]|r |cffffb84dProtected - Blacklisted|r"
    elseif IsInSet(DB.deleteList, id) and DB.enableDeletion then
        statusLine = "|cff4db8ff[EC]|r |cffff4444Will Delete - Deletion List|r"
    elseif IsInSet(DB.whitelist, id) or (ADB and IsInSet(ADB.whitelist, id)) then
        statusLine = "|cff4db8ff[EC]|r |cffb6ffb6Will Sell - Whitelisted|r"
    elseif DB.whitelistQualityEnabled then
        local _, _, quality, _, _, _, _, _, _, _, sellPrice = GetItemInfo(id)
        if quality and quality > 0 and quality <= (DB.whitelistMinQuality or 1) and sellPrice and sellPrice > 0 then
            statusLine = "|cff4db8ff[EC]|r |cffb6ffb6Will Sell - Quality Threshold|r"
        end
    end

    if statusLine then
        tooltip:AddLine(statusLine)
    end
    -- Discoverability hint for the v2.3.0 right-click context menu. Shown on
    -- every bag/item-link tooltip so users know the action is available.
    tooltip:AddLine("|cff666666Alt+Right-Click for EbonClearance menu|r")
    tooltip.__EC_annotated = true
    tooltip:Show()
end

local function EC_ClearTooltipFlag(tooltip)
    if tooltip then
        tooltip.__EC_annotated = nil
    end
end

local function EC_InstallTooltipHookOnce()
    if EC_tooltipHooked then
        return
    end
    EC_tooltipHooked = true
    if GameTooltip and GameTooltip.HookScript then
        GameTooltip:HookScript("OnTooltipSetItem", EC_AnnotateTooltip)
        GameTooltip:HookScript("OnTooltipCleared", EC_ClearTooltipFlag)
    end
    if ItemRefTooltip and ItemRefTooltip.HookScript then
        ItemRefTooltip:HookScript("OnTooltipSetItem", EC_AnnotateTooltip)
        ItemRefTooltip:HookScript("OnTooltipCleared", EC_ClearTooltipFlag)
    end
end

local MainOptions = CreateFrame("Frame", "EbonClearanceOptionsMain", InterfaceOptionsFramePanelContainer)
MainOptions.name = "EbonClearance"

local function MakeHeader(parent, text, y)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    fs:SetPoint("TOPLEFT", 16, y)
    fs:SetText(text)
    return fs
end

local EC_PANEL_WIDTH = 440 -- default fallback; updated dynamically in OnShow

local function EC_UpdatePanelWidth()
    local container = InterfaceOptionsFramePanelContainer
    if container and container.GetWidth then
        local w = container:GetWidth()
        if w and w > 100 then
            EC_PANEL_WIDTH = w - 40
        end
    end
end

local function MakeLabel(parent, text, x, y)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetWidth(EC_PANEL_WIDTH - x)
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    if fs.SetWordWrap then
        fs:SetWordWrap(true)
    end
    fs:SetText(text)
    return fs
end

local function StyleInputBox(editBox)
    if not editBox then
        return
    end
    if editBox.SetTextInsets then
        editBox:SetTextInsets(6, 6, 0, 0)
    end

    local fs = editBox.GetFontString and editBox:GetFontString()
    if fs and fs.SetDrawLayer then
        fs:SetDrawLayer("OVERLAY")
    end
    if fs and fs.SetAlpha then
        fs:SetAlpha(1)
    end

    local n = editBox.GetName and editBox:GetName()
    if n then
        local left = _G[n .. "Left"]
        local mid = _G[n .. "Middle"]
        local right = _G[n .. "Right"]
        if left and left.SetDrawLayer then
            left:SetDrawLayer("BACKGROUND")
        end
        if mid and mid.SetDrawLayer then
            mid:SetDrawLayer("BACKGROUND")
        end
        if right and right.SetDrawLayer then
            right:SetDrawLayer("BACKGROUND")
        end
    end
    editBox:SetFrameLevel((editBox:GetParent() and editBox:GetParent():GetFrameLevel() or editBox:GetFrameLevel()) + 2)

    if editBox.GetText and editBox.SetText then
        local t = editBox:GetText() or ""
        editBox:SetText(t)
        if editBox.SetCursorPosition then
            editBox:SetCursorPosition(0)
        end
    end
end

local function CreateListUI(parent, titleText, setTableName, x, y)
    local w = EC_PANEL_WIDTH - x
    local box = CreateFrame("Frame", nil, parent)
    box:SetPoint("TOPLEFT", x, y)
    -- Height chosen to keep the whole box inside a standard InterfaceOptions
    -- sub-panel. Callers may override via listUI:SetHeight(n) if they need more
    -- or less room (e.g. WhitelistPanel has extra controls above it).
    box:SetSize(w, 280)

    local title = box:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOPLEFT", 0, 0)
    title:SetText(titleText)

    local input = CreateFrame("EditBox", "EbonClearanceIDInput_" .. setTableName, box, "InputBoxTemplate")
    input:SetAutoFocus(false)
    input:SetSize(140, 20)
    input:SetPoint("TOPLEFT", 0, -24)
    input:SetNumeric(true)
    input:SetMaxLetters(10)
    input:SetText("")
    StyleInputBox(input)

    local addBtn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    addBtn:SetSize(60, 20)
    addBtn:SetPoint("LEFT", input, "RIGHT", 8, 0)
    addBtn:SetText("Add")

    -- "Clear All" button on the input row, anchored hard-right and visually
    -- separated from the Add flow. Wipes every entry in the list with a
    -- confirmation popup. Wired below.
    local clearAllBtn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    clearAllBtn:SetSize(80, 20)
    clearAllBtn:SetPoint("TOPRIGHT", box, "TOPRIGHT", 0, -24)
    clearAllBtn:SetText("Clear All")

    input:SetScript("OnEditFocusGained", function(self)
        EC_activeIDBox = self
    end)
    input:SetScript("OnEditFocusLost", function(self)
        if EC_activeIDBox == self then
            EC_activeIDBox = nil
        end
    end)
    input:SetScript("OnReceiveDrag", function(self)
        local ctype, cid = GetCursorInfo()
        if ctype == "item" and cid then
            self:SetText(tostring(cid))
            self:HighlightText()
            ClearCursor()
        end
    end)

    local sortMode = "id_asc" -- default: sort by ID ascending

    -- Search row: Search box then ID, Name sort buttons all on one line
    local searchLabel = box:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    searchLabel:SetPoint("TOPLEFT", 0, -52)
    searchLabel:SetText("Search:")

    local sortNameBtn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    sortNameBtn:SetSize(62, 20)
    sortNameBtn:SetPoint("TOPRIGHT", box, "TOPRIGHT", 0, -52)
    sortNameBtn:SetText("Name \226\150\178")

    local sortIDBtn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    sortIDBtn:SetSize(50, 20)
    sortIDBtn:SetPoint("RIGHT", sortNameBtn, "LEFT", -4, 0)
    sortIDBtn:SetText("ID \226\150\178")

    local search = CreateFrame("EditBox", "EbonClearanceSearchInput_" .. setTableName, box, "InputBoxTemplate")
    search:SetAutoFocus(false)
    search:SetHeight(20)
    search:SetPoint("LEFT", searchLabel, "RIGHT", 8, 0)
    search:SetPoint("RIGHT", sortIDBtn, "LEFT", -8, 0)
    search:SetMaxLetters(40)
    search:SetText("")
    StyleInputBox(search)

    -- Bag-scan "Add matching" row: scan bags for items whose name contains the
    -- typed substring and add each match to this list.
    local matchLabel = box:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    matchLabel:SetPoint("TOPLEFT", 0, -76)
    matchLabel:SetText("Add matching in bags:")

    local matchBtn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    matchBtn:SetSize(80, 20)
    matchBtn:SetPoint("TOPRIGHT", box, "TOPRIGHT", 0, -76)
    matchBtn:SetText("Add Match")

    local matchInput =
        CreateFrame("EditBox", "EbonClearanceMatchInput_" .. setTableName, box, "InputBoxTemplate")
    matchInput:SetAutoFocus(false)
    matchInput:SetHeight(20)
    matchInput:SetPoint("LEFT", matchLabel, "RIGHT", 8, 0)
    matchInput:SetPoint("RIGHT", matchBtn, "LEFT", -8, 0)
    matchInput:SetMaxLetters(40)
    matchInput:SetText("")
    StyleInputBox(matchInput)

    local scroll =
        CreateFrame("ScrollFrame", "EbonClearanceListScroll_" .. setTableName, box, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -102)
    scroll:SetPoint("BOTTOMRIGHT", -26, 8)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(w - 26, 1)
    scroll:SetScrollChild(content)

    local rowPool = {}
    local activeRows = 0

    local function GetRow(index)
        if rowPool[index] then
            return rowPool[index]
        end
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(w - 26, 22)

        local rm = CreateFrame(
            "Button",
            "EbonClearanceListRM_" .. setTableName .. "_" .. index,
            content,
            "UIPanelButtonTemplate"
        )
        rm:SetSize(72, 18)
        rm:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        rm:SetText("Remove")

        local text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        text:SetPoint("LEFT", row, "LEFT", 2, 0)
        text:SetWidth(w - 106)
        text:SetJustifyH("LEFT")

        row.rm = rm
        row.text = text
        rowPool[index] = row
        return row
    end

    local function HideAllRows()
        for i = 1, activeRows do
            if rowPool[i] then
                rowPool[i]:Hide()
                rowPool[i].rm:Hide()
            end
        end
        activeRows = 0
    end

    local function MatchesSearch(id, name, searchText)
        if not searchText or searchText == "" then
            return true
        end
        local idStr = tostring(id or "")
        if idStr:find(searchText, 1, true) then
            return true
        end
        local nameStr = tostring(name or ""):lower()
        if nameStr:find(searchText, 1, true) then
            return true
        end
        return false
    end

    local pendingRetry = false

    local function Refresh()
        HideAllRows()

        local searchText = ""
        if search and search.GetText then
            searchText = (search:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
        end

        local setTable = EC_GetListTable(setTableName)
        if type(setTable) ~= "table" then
            return
        end
        local keys = {}
        for k in pairs(setTable) do
            if type(k) == "number" then
                keys[#keys + 1] = k
            end
        end
        if sortMode == "id_desc" then
            table.sort(keys, function(a, b)
                return a > b
            end)
        elseif sortMode == "name_asc" then
            table.sort(keys, function(a, b)
                local na = GetItemInfo(a) or ""
                local nb = GetItemInfo(b) or ""
                return na:lower() < nb:lower()
            end)
        elseif sortMode == "name_desc" then
            table.sort(keys, function(a, b)
                local na = GetItemInfo(a) or ""
                local nb = GetItemInfo(b) or ""
                return na:lower() > nb:lower()
            end)
        else
            table.sort(keys) -- id_asc (default)
        end

        local shown = 0
        local rowY = -4
        local hasUncached = false
        for i = 1, #keys do
            local id = keys[i]
            local name = GetItemInfo(id)
            if not name then
                hasUncached = true
                -- Request item data from server via tooltip query
                if GameTooltip and GameTooltip.SetHyperlink then
                    GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
                    GameTooltip:SetHyperlink("item:" .. id .. ":0:0:0:0:0:0:0")
                    GameTooltip:Hide()
                end
                name = "ItemID: " .. id
            end

            if MatchesSearch(id, name, searchText) then
                shown = shown + 1
                local row = GetRow(shown)
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", 0, rowY)
                row.text:SetText(string.format("|cffb6ffb6%d|r  %s", id, name))
                row.rm:SetScript("OnClick", function()
                    local t = EC_GetListTable(setTableName)
                    if t then
                        t[id] = nil
                    end
                    Refresh()
                end)
                row:Show()
                row.rm:Show()
                rowY = rowY - 22
            end
        end

        activeRows = shown
        content:SetHeight(math.max(1, (shown * 22) + 8))

        -- If any items were uncached, retry after a delay to pick up server responses
        if hasUncached and not pendingRetry then
            pendingRetry = true
            EC_Delay(1.5, function()
                pendingRetry = false
                Refresh()
            end)
        end
    end

    addBtn:SetScript("OnClick", function()
        local v = tonumber(input:GetText() or "")
        if not v or v <= 0 then
            PlaySound("igMainMenuOptionCheckBoxOff")
            return
        end
        local t = EC_GetListTable(setTableName)
        if t then
            t[v] = true
        end
        input:SetText("")
        Refresh()
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)

    input:SetScript("OnEnterPressed", function()
        addBtn:Click()
        input:ClearFocus()
    end)

    clearAllBtn:SetScript("OnClick", function()
        local t = EC_GetListTable(setTableName)
        if not t or not next(t) then
            PrintNicef("|cff888888%s is already empty.|r", titleText)
            PlaySound("igMainMenuOptionCheckBoxOff")
            return
        end
        local dialog = StaticPopup_Show("EC_CONFIRM_CLEAR_LIST", titleText)
        if dialog then
            dialog.data = function()
                local target = EC_GetListTable(setTableName)
                if target then
                    wipe(target)
                end
                Refresh()
                PrintNicef('Cleared every item from "|cffffff00%s|r".', titleText)
                PlaySound("igMainMenuOptionCheckBoxOn")
            end
        end
    end)

    local function AddMatchingFromBags(substr)
        local t = EC_GetListTable(setTableName)
        if not t or not substr or substr == "" then
            return 0
        end
        local needle = substr:lower()
        local added = 0
        for bag = 0, 4 do
            local slots = GetContainerNumSlots(bag)
            for slot = 1, slots do
                local itemID = GetContainerItemID(bag, slot)
                if itemID and not t[itemID] then
                    local name = GetItemInfo(itemID)
                    if name and name:lower():find(needle, 1, true) then
                        t[itemID] = true
                        added = added + 1
                    end
                end
            end
        end
        return added
    end

    matchBtn:SetScript("OnClick", function()
        local txt = (matchInput:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if txt == "" then
            PlaySound("igMainMenuOptionCheckBoxOff")
            return
        end
        local added = AddMatchingFromBags(txt)
        PrintNicef(
            "Scanned bags: added |cffffff00%d|r matching item(s) (substring: |cffffff00%s|r).",
            added,
            txt
        )
        matchInput:SetText("")
        Refresh()
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)

    matchInput:SetScript("OnEnterPressed", function()
        matchBtn:Click()
        matchInput:ClearFocus()
    end)

    search:SetScript("OnTextChanged", function()
        Refresh()
    end)

    sortIDBtn:SetScript("OnClick", function()
        if sortMode == "id_asc" then
            sortMode = "id_desc"
        else
            sortMode = "id_asc"
        end
        sortIDBtn:SetText(sortMode == "id_asc" and "ID \226\150\178" or "ID \226\150\188")
        sortNameBtn:SetText("Name \226\150\178")
        Refresh()
    end)
    sortNameBtn:SetScript("OnClick", function()
        if sortMode == "name_asc" then
            sortMode = "name_desc"
        else
            sortMode = "name_asc"
        end
        sortNameBtn:SetText(sortMode == "name_asc" and "Name \226\150\178" or "Name \226\150\188")
        sortIDBtn:SetText("ID \226\150\178")
        Refresh()
    end)

    box.Refresh = Refresh
    return box
end

local function AddCheckbox(parent, name, anchor, labelText, getter, setter, yOff)
    local cb = CreateFrame("CheckButton", name, parent, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yOff or -6)
    cb:SetChecked(getter())

    local t = _G[name .. "Text"]
    if t then
        t:SetText(labelText)
        t:SetWidth(420)
        t:SetJustifyH("LEFT")
    end

    cb:SetScript("OnClick", function()
        setter(cb:GetChecked() and true or false)
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)
    return cb
end

local function ColorTextByQuality(quality, text)
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    local hex = (c and c.hex) or "|cffffffff"
    return hex .. text .. "|r"
end

local function AddSlider(parent, name, anchor, labelText, minVal, maxVal, step, getter, setter, yOff, fmt)
    fmt = fmt or "%.3fs"
    local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    s:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yOff or -16)
    s:SetMinMaxValues(minVal, maxVal)
    if s.SetValueStep then
        s:SetValueStep(step)
    end
    if s.SetObeyStepOnDrag then
        s:SetObeyStepOnDrag(true)
    end
    s:SetValue(getter())

    local low = _G[name .. "Low"]
    local high = _G[name .. "High"]
    local text = _G[name .. "Text"]

    if low then
        low:SetText(string.format(fmt, minVal))
    end
    if high then
        high:SetText(string.format(fmt, maxVal))
    end

    local function RefreshText(v)
        if text then
            text:SetText(labelText .. ": " .. string.format(fmt, v))
        end
    end
    RefreshText(getter())

    s:SetScript("OnValueChanged", function(self, value)
        value = tonumber(value) or minVal
        if step and step > 0 then
            value = math.floor((value / step) + 0.5) * step
        end
        if value < minVal then
            value = minVal
        end
        if value > maxVal then
            value = maxVal
        end
        setter(value)
        RefreshText(value)
    end)

    return s
end

local function EC_UpdateMinimapPos()
    local btn = _G["EbonClearanceMinimapButton"]
    if not btn then
        return
    end
    local angle = math.rad(DB and DB.minimapButtonAngle or 220)
    local x = math.cos(angle) * 80
    local y = math.sin(angle) * 80
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function EC_CreateMinimapButton()
    if not DB then
        return
    end
    if _G["EbonClearanceMinimapButton"] then
        return
    end -- only create once

    local btn = CreateFrame("Button", "EbonClearanceMinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")

    -- Circular background
    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Background")
    bg:SetSize(53, 53)
    bg:SetPoint("CENTER", btn, "CENTER", -1, 1)

    -- Icon
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", btn, "CENTER", 0, 0)
    btn.icon = icon

    -- Border ring
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("CENTER", btn, "CENTER", 10, -10)

    EC_UpdateMinimapPos()

    local dragging = false

    btn:SetScript("OnDragStart", function(self)
        dragging = true
    end)

    btn:SetScript("OnDragStop", function(self)
        dragging = false
        EC_UpdateMinimapPos()
    end)

    btn:SetScript("OnUpdate", function(self)
        if not dragging then
            return
        end
        if not IsMouseButtonDown("LeftButton") then
            dragging = false
            return
        end
        local mx, my = Minimap:GetCenter()
        local scale = Minimap:GetEffectiveScale()
        local cx, cy = GetCursorPosition()
        cx = cx / scale
        cy = cy / scale
        local angle = math.deg(math.atan2(cy - my, cx - mx))
        if DB then
            DB.minimapButtonAngle = angle
        end
        EC_UpdateMinimapPos()
    end)

    btn:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            InterfaceOptionsFrame_OpenToCategory(MainOptions)
            InterfaceOptionsFrame_OpenToCategory(MainOptions)
        elseif button == "RightButton" then
            if not DB then
                return
            end
            DB.enabled = not DB.enabled
            local state = DB.enabled and "|cff00ff00Enabled|r" or "|cffff4444Disabled|r"
            PrintNice("Addon " .. state)
            if self.icon then
                self.icon:SetDesaturated(not DB.enabled)
            end
        end
    end)

    -- Apply initial desaturation if disabled
    if DB and DB.enabled == false then
        icon:SetDesaturated(true)
    end

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("EbonClearance")
        GameTooltip:AddLine("Left-click: Options  |  Right-click: Toggle Addon", 1, 1, 1)
        local stateStr = (DB and DB.enabled ~= false) and "|cff00ff00Enabled|r" or "|cffff4444Disabled|r"
        GameTooltip:AddLine("Status: " .. stateStr)
        local freeSlots = EC_GetFreeBagSlots()
        local slotColor = freeSlots >= 10 and "|cff00ff00" or (freeSlots >= 5 and "|cffffff00" or "|cffff4444")
        GameTooltip:AddLine("Free bag slots: " .. slotColor .. freeSlots .. "|r")

        local sellCount, sellCopper = EC_PreviewSellable()
        GameTooltip:AddLine(string.format("Sellable now: |cffffff00%d|r items", sellCount))
        if sellCopper > 0 then
            GameTooltip:AddLine("Est. value: " .. CopperToColoredText(sellCopper))
        end
        GameTooltip:Show()
    end)

    btn:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)
end

-- Hidden SecureActionButton that registers a keybinding to /target the Goblin
-- Merchant. The button is never shown; its only job is to sink the keybind
-- registered via BINDING_HEADER_EBONCLEARANCE near the slash commands. The
-- macrotext attribute is set at creation so it remains functional inside
-- InCombatLockdown() (secure click from a player hardware event).
local function EC_CreateTargetMerchantButton()
    if _G.EbonClearanceTargetMerchantButton then
        return
    end
    local btn = CreateFrame("Button", "EbonClearanceTargetMerchantButton", UIParent, "SecureActionButtonTemplate")
    btn:RegisterForClicks("AnyUp")
    btn:SetAttribute("type", "macro")
    btn:SetAttribute("macrotext", "/target " .. TARGET_NAME)
    btn:Hide()
end

-- Optional LibDataBroker-1.0 launcher. No-op if LibStub or LDB is not present,
-- so users on Titan Panel / Bazooka / ChocolateBar / etc. get an entry in
-- their display addon without us taking a hard dependency on anything.
local function EC_CreateLDBLauncher()
    if not _G.LibStub then
        return
    end
    local LDB = _G.LibStub("LibDataBroker-1.0", true)
    if not LDB then
        return
    end
    if LDB.GetDataObjectByName and LDB:GetDataObjectByName("EbonClearance") then
        return
    end

    LDB:NewDataObject("EbonClearance", {
        type = "launcher",
        label = "EbonClearance",
        icon = "Interface\\Icons\\INV_Misc_Coin_01",
        OnClick = function(_, button)
            if button == "RightButton" then
                if not DB then
                    return
                end
                DB.enabled = not DB.enabled
                PrintNice("Addon " .. (DB.enabled and "|cff00ff00Enabled|r" or "|cffff4444Disabled|r"))
            else
                InterfaceOptionsFrame_OpenToCategory(MainOptions)
                InterfaceOptionsFrame_OpenToCategory(MainOptions)
            end
        end,
        OnTooltipShow = function(tt)
            tt:AddLine("EbonClearance")
            tt:AddLine("Left-click: Options  |  Right-click: Toggle", 1, 1, 1)
            local stateStr = (DB and DB.enabled ~= false) and "|cff00ff00Enabled|r" or "|cffff4444Disabled|r"
            tt:AddLine("Status: " .. stateStr)
            local freeSlots = EC_GetFreeBagSlots()
            local slotColor = freeSlots >= 10 and "|cff00ff00" or (freeSlots >= 5 and "|cffffff00" or "|cffff4444")
            tt:AddLine("Free bag slots: " .. slotColor .. freeSlots .. "|r")
            local count, copper = EC_PreviewSellable()
            tt:AddLine(string.format("Sellable now: |cffffff00%d|r items", count))
            if copper > 0 then
                tt:AddLine("Est. value: " .. CopperToColoredText(copper))
            end
        end,
    })
end

-- DORMANT: on-screen vendor button. The user-facing toggle is intentionally
-- not wired up right now (held as a future opt-in); the helpers below are
-- kept intact so the option can be re-introduced later by adding a checkbox
-- that calls EC_UpdateVendorButtonVisibility(). The DB.vendorBtnShown saved
-- variable is preserved for the same reason.
-- SecureActionButtonTemplate that runs `/target`, so it only sets a target;
-- the player still presses their Interact-With-Target keybind to open the
-- vendor. This keeps the flow combat-safe.
local EC_vendorButton

local function EC_SaveVendorButtonPos(btn)
    if not DB then
        return
    end
    local point, _, relPoint, x, y = btn:GetPoint(1)
    DB.vendorBtnPoint = point or "CENTER"
    DB.vendorBtnRelPoint = relPoint or "CENTER"
    DB.vendorBtnX = x or 0
    DB.vendorBtnY = y or -200
end

local function EC_CreateVendorButton()
    if EC_vendorButton then
        return EC_vendorButton
    end
    local btn = CreateFrame("Button", "EbonClearanceVendorButton", UIParent, "SecureActionButtonTemplate")
    btn:SetSize(48, 48)
    btn:SetFrameStrata("MEDIUM")
    btn:SetAttribute("type", "macro")
    btn:SetAttribute("macrotext", "/target " .. TARGET_NAME)

    local point = (DB and DB.vendorBtnPoint) or "CENTER"
    local relPoint = (DB and DB.vendorBtnRelPoint) or "CENTER"
    local px = (DB and DB.vendorBtnX) or 0
    local py = (DB and DB.vendorBtnY) or -200
    btn:ClearAllPoints()
    btn:SetPoint(point, UIParent, relPoint, px, py)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")
    icon:SetAllPoints(btn)
    btn.icon = icon

    btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    local hl = btn:GetHighlightTexture()
    if hl then
        hl:SetBlendMode("ADD")
    end

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    border:SetBlendMode("ADD")
    border:SetVertexColor(1, 0.85, 0.3, 1)
    border:SetPoint("TOPLEFT", btn, "TOPLEFT", -6, 6)
    border:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 6, -6)

    btn:SetMovable(true)
    btn:EnableMouse(true)
    btn:RegisterForDrag("LeftButton")
    btn:SetScript("OnDragStart", function(self)
        if IsAltKeyDown() then
            self:StartMoving()
        end
    end)
    btn:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        EC_SaveVendorButtonPos(self)
    end)

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("EbonClearance Vendor")
        GameTooltip:AddLine("Click: target " .. TARGET_NAME .. ".", 1, 1, 1, true)
        GameTooltip:AddLine("Alt+Drag to reposition.", 0.7, 0.7, 0.7, true)
        GameTooltip:AddLine(
            "In combat: click, then press your Interact-With-Target keybind to open the vendor.",
            1,
            0.82,
            0.4,
            true
        )
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    EC_vendorButton = btn
    return btn
end

-- luacheck: ignore EC_UpdateVendorButtonVisibility
local function EC_UpdateVendorButtonVisibility()
    if DB and DB.vendorBtnShown then
        local btn = EC_CreateVendorButton()
        if not InCombatLockdown() then
            btn:Show()
        end
    elseif EC_vendorButton and not InCombatLockdown() then
        EC_vendorButton:Hide()
    end
end

StaticPopupDialogs["EC_CONFIRM_RESET_LIFETIME"] = {
    text = "Reset |cffb6ffb6EbonClearance|r lifetime stats?\n|cffaaaaaaThis clears money earned, items sold, items deleted, repair totals, and per-item counters. Session stats are not affected.|r",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["EC_CONFIRM_RESET_SESSION"] = {
    text = "Reset session stats?",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["EC_CONFIRM_DELETE_PROFILE"] = {
    text = 'Delete profile "|cffffff00%s|r"?\n|cffaaaaaaThis cannot be undone.|r',
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["EC_CONFIRM_CLEAR_PROFILE"] = {
    text = 'Clear all items from profile "|cffffff00%s|r"?\n|cffaaaaaaThe profile itself will remain.|r',
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Generic confirmation for the per-list "Clear All" button on every list panel
-- (Whitelist - Character / Whitelist - Account / Blacklist / Deletion List).
-- The %s slot is filled with the list's user-facing title.
StaticPopupDialogs["EC_CONFIRM_CLEAR_LIST"] = {
    text = 'Remove every item from "|cffffff00%s|r"?\n|cffaaaaaaThis cannot be undone.|r',
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if type(data) == "function" then
            data()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Build the static widgets for the main options panel. Called once per panel
-- (guarded by `panel.inited` in OnShow). `refreshStats` is the dynamic refresh
-- callback captured by the Reset button.
local function BuildMainPanel(panel, refreshStats)
    local addonVersion = GetAddOnMetadata("EbonClearance", "Version") or "unknown"
    MakeHeader(panel, "EbonClearance " .. addonVersion, -16)

    -- Byline (required by LICENSE; do not remove in derivatives).
    local byline = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    byline:SetPoint("TOPLEFT", 16, -32)
    byline:SetText("|cff888866by " .. ADDON_AUTHOR .. "  \194\183  " .. ADDON_URL .. "|r")

    local welcomeLabel = MakeLabel(
        panel,
        "Welcome to |cffb6ffb6EbonClearance|r! Automatic vendoring and item management for Project Ebonhold.",
        16,
        -52
    )
    local descLabel2 = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    descLabel2:SetPoint("TOPLEFT", welcomeLabel, "BOTTOMLEFT", 0, -4)
    descLabel2:SetWidth(EC_PANEL_WIDTH - 16)
    descLabel2:SetJustifyH("LEFT")
    descLabel2:SetJustifyV("TOP")
    if descLabel2.SetWordWrap then
        descLabel2:SetWordWrap(true)
    end
    descLabel2:SetText(
        "Grey junk is sold automatically. Add items to your whitelist to sell them too, or enable the quality threshold to sell everything up to a chosen rarity. Configure which merchants to use under Merchant Settings."
    )

    -- Stats fontstrings. Stacked vertically; each attaches its ref to `panel`
    -- so RefreshStats can find them across subsequent OnShow calls.
    local money = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    money:SetPoint("TOPLEFT", descLabel2, "BOTTOMLEFT", 0, -16)
    panel.statsMoney = money

    local sold = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    sold:SetPoint("TOPLEFT", money, "BOTTOMLEFT", 0, -6)
    panel.statsSold = sold

    local deleted = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    deleted:SetPoint("TOPLEFT", sold, "BOTTOMLEFT", 0, -6)
    panel.statsDeleted = deleted

    local repairs = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    repairs:SetPoint("TOPLEFT", deleted, "BOTTOMLEFT", 0, -6)
    panel.statsRepairs = repairs

    local repairCost = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    repairCost:SetPoint("TOPLEFT", repairs, "BOTTOMLEFT", 0, -6)
    panel.statsRepairCost = repairCost

    local avgWorth = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    avgWorth:SetPoint("TOPLEFT", repairCost, "BOTTOMLEFT", 0, -6)
    panel.statsAvgWorth = avgWorth

    local mostSold = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    mostSold:SetPoint("TOPLEFT", avgWorth, "BOTTOMLEFT", 0, -6)
    mostSold:SetWidth(EC_PANEL_WIDTH - 16)
    mostSold:SetJustifyH("LEFT")
    panel.statsMostSold = mostSold

    local statsNote = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    statsNote:SetPoint("TOPLEFT", mostSold, "BOTTOMLEFT", 0, -4)
    statsNote:SetWidth(EC_PANEL_WIDTH - 16)
    statsNote:SetJustifyH("LEFT")
    statsNote:SetText("|cff888888Stats don't account for items bought back from a merchant.|r")

    local resetBtn = CreateFrame("Button", "EbonClearanceResetStatsBtn", panel, "UIPanelButtonTemplate")
    resetBtn:SetSize(170, 22)
    resetBtn:SetPoint("TOPLEFT", statsNote, "BOTTOMLEFT", 0, -8)
    resetBtn:SetText("Reset Lifetime Stats")
    resetBtn:SetScript("OnClick", function()
        local dialog = StaticPopup_Show("EC_CONFIRM_RESET_LIFETIME")
        if dialog then
            dialog.data = function()
                DB.totalCopper = 0
                DB.totalItemsSold = 0
                DB.totalItemsDeleted = 0
                DB.totalRepairs = 0
                DB.totalRepairCopper = 0
                DB.inventoryWorthTotal = 0
                DB.inventoryWorthCount = 0
                wipe(DB.soldItemCounts)
                wipe(DB.deletedItemCounts)
                refreshStats()
                PlaySound("igMainMenuOptionCheckBoxOn")
            end
        end
    end)

    -- Session delta is inlined into each lifetime stat line by RefreshStats (EC_session).
    -- The Reset Session button sits side-by-side with Reset Lifetime to avoid adding vertical space.
    local resetSessionBtn =
        CreateFrame("Button", "EbonClearanceResetSessionBtn", panel, "UIPanelButtonTemplate")
    resetSessionBtn:SetSize(170, 22)
    resetSessionBtn:SetPoint("LEFT", resetBtn, "RIGHT", 8, 0)
    resetSessionBtn:SetText("Reset Session Stats")
    resetSessionBtn:SetScript("OnClick", function()
        local dialog = StaticPopup_Show("EC_CONFIRM_RESET_SESSION")
        if dialog then
            dialog.data = function()
                EC_ResetSession()
                refreshStats()
                PlaySound("igMainMenuOptionCheckBoxOn")
            end
        end
    end)

    -- Slash commands reference.
    local cmdHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    cmdHeader:SetPoint("TOPLEFT", resetBtn, "BOTTOMLEFT", 0, -16)
    cmdHeader:SetText("Slash Commands")

    local cmdText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    cmdText:SetPoint("TOPLEFT", cmdHeader, "BOTTOMLEFT", 0, -6)
    cmdText:SetWidth(EC_PANEL_WIDTH - 16)
    cmdText:SetJustifyH("LEFT")
    if cmdText.SetWordWrap then
        cmdText:SetWordWrap(true)
    end
    cmdText:SetText(
        "|cffffff00/ec|r  Open settings\n"
            .. "|cffffff00/ec profile list|r  Show all saved profiles\n"
            .. "|cffffff00/ec profile save <name>|r  Save current whitelist as a profile\n"
            .. "|cffffff00/ec profile load <name>|r  Load a saved profile\n"
            .. "|cffffff00/ec profile delete <name>|r  Delete a profile\n"
            .. "|cffffff00/ec clean|r  Report items present in more than one list\n"
            .. "|cffffff00/ec clean apply|r  Auto-resolve conflicts (blacklist > deleteList > whitelist)\n"
            .. "|cffffff00/ec bugreport|r  Generate a diagnostic report for bug reports\n"
            .. "|cffffff00/ecdebug|r  Show debug info and bag scan"
    )
end

MainOptions:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()

    local function GetMostItem(countTable)
        local bestID, bestCount = nil, 0
        if type(countTable) ~= "table" then
            return nil, 0
        end
        for id, cnt in pairs(countTable) do
            if type(id) == "number" and type(cnt) == "number" and cnt > bestCount then
                bestID, bestCount = id, cnt
            end
        end
        return bestID, bestCount
    end

    local function ItemLabel(id)
        if not id then
            return "None"
        end
        local name = GetItemInfo(id)
        if name then
            return string.format("|cff24ffb6%s|r", name)
        end
        return "ItemID: " .. tostring(id)
    end

    local function RefreshStats()
        if not self.statsMoney then
            return
        end
        local function sessionSuffix(n)
            return string.format("  |cff888888(session +%s)|r", tostring(n or 0))
        end
        local function sessionMoneySuffix(c)
            return "  |cff888888(session +" .. CopperToColoredText(c or 0) .. "|cff888888)|r"
        end
        self.statsMoney:SetText(
            "Total Money Made: " .. CopperToColoredText(DB.totalCopper or 0) .. sessionMoneySuffix(EC_session.copper)
        )
        self.statsSold:SetText("Total Items Sold: " .. tostring(DB.totalItemsSold or 0) .. sessionSuffix(EC_session.sold))
        self.statsDeleted:SetText(
            "Total Items Deleted: " .. tostring(DB.totalItemsDeleted or 0) .. sessionSuffix(EC_session.deleted)
        )
        self.statsRepairs:SetText(
            "Total Repairs: " .. tostring(DB.totalRepairs or 0) .. sessionSuffix(EC_session.repairs)
        )
        self.statsRepairCost:SetText(
            "Total Repair Cost: "
                .. CopperToColoredText(DB.totalRepairCopper or 0)
                .. sessionMoneySuffix(EC_session.repairCopper)
        )
        if self.statsAvgWorth then
            local cnt = DB.inventoryWorthCount or 0
            local total = DB.inventoryWorthTotal or 0
            local avg = 0
            if cnt > 0 then
                avg = math.floor((total / cnt) + 0.5)
            end
            self.statsAvgWorth:SetText("Average Inventory Worth: " .. CopperToColoredText(avg))
        end

        local mostID, mostCount = GetMostItem(DB.soldItemCounts)
        if mostID then
            self.statsMostSold:SetText("Most Sold Item: " .. ItemLabel(mostID) .. " (x" .. tostring(mostCount) .. ")")
        else
            self.statsMostSold:SetText("Most Sold Item: None")
        end

    end

    if self.inited then
        RefreshStats()
        return
    end
    self.inited = true

    BuildMainPanel(self, RefreshStats)
    RefreshStats()
end)

InterfaceOptions_AddCategory(MainOptions)

-- Quality-threshold options shared by the Merchant Settings panel. Declared
-- here so the panel's OnShow closure resolves it as an upvalue.
local EC_WHITELIST_QUALITIES = {
    { text = ColorTextByQuality(1, "White (Common)"), value = 1 },
    { text = ColorTextByQuality(2, "Green (Uncommon)"), value = 2 },
    { text = ColorTextByQuality(3, "Blue (Rare)"), value = 3 },
}

local MerchantPanel = CreateFrame("Frame", "EbonClearanceOptionsMerchant", InterfaceOptionsFramePanelContainer)
MerchantPanel.name = "Merchant Settings"
MerchantPanel.parent = "EbonClearance"

local EC_MERCHANT_MODES = {
    { text = "|cffb6ffb6Goblin Merchant|r Only", value = "goblin" },
    { text = "Normal Merchants Only", value = "any" },
    { text = "Both (All Merchants)", value = "both" },
}

MerchantPanel:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then
        if self.repairCB then
            self.repairCB:SetChecked(DB.repairGear)
        end
        if self.keepBagsCB then
            self.keepBagsCB:SetChecked(DB.keepBagsOpen)
        end
        if self.speedSlider then
            self.speedSlider:SetValue(DB.vendorInterval or 0.1)
        end
        if self.fastModeCB then
            self.fastModeCB:SetChecked(DB.fastMode)
        end
        if self.RefreshMerchantModeDropDown then
            self:RefreshMerchantModeDropDown()
        end
        if self.whitelistQualityCB then
            self.whitelistQualityCB:SetChecked(DB.whitelistQualityEnabled)
        end
        if self.RefreshQualityDropDown then
            self:RefreshQualityDropDown()
        end
        return
    end
    self.inited = true

    MakeHeader(self, "Merchant Settings", -16)
    MakeLabel(self, "These settings control automatic vendoring behaviour.", 16, -44)
    MakeLabel(self, "Grey items are always sold as junk at any merchant.", 16, -60)

    -- Merchant mode dropdown
    local modeLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    modeLabel:SetPoint("TOPLEFT", 16, -90)
    modeLabel:SetText("Sell at:")

    local modeDD = CreateFrame("Frame", "EbonClearanceMerchantModeDD", self, "UIDropDownMenuTemplate")
    modeDD:SetPoint("LEFT", modeLabel, "RIGHT", -8, -2)

    local function GetModeText(mode)
        for _, entry in ipairs(EC_MERCHANT_MODES) do
            if entry.value == mode then
                return entry.text
            end
        end
        return EC_MERCHANT_MODES[1].text
    end

    local function MerchantModeInit(frame, level)
        for _, entry in ipairs(EC_MERCHANT_MODES) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = entry.text
            info.value = entry.value
            info.checked = (DB.merchantMode == entry.value)
            info.func = function()
                DB.merchantMode = entry.value
                UIDropDownMenu_SetText(modeDD, entry.text)
                PlaySound("igMainMenuOptionCheckBoxOn")
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end

    UIDropDownMenu_SetWidth(modeDD, 180)
    UIDropDownMenu_SetText(modeDD, GetModeText(DB.merchantMode))
    UIDropDownMenu_Initialize(modeDD, MerchantModeInit)

    self.RefreshMerchantModeDropDown = function()
        UIDropDownMenu_SetText(modeDD, GetModeText(DB.merchantMode))
    end

    local repairCB =
        CreateFrame("CheckButton", "EbonClearanceRepairGearCB", self, "InterfaceOptionsCheckButtonTemplate")
    repairCB:SetPoint("TOPLEFT", 16, -110)
    repairCB:SetChecked(DB.repairGear)
    local rt = _G[repairCB:GetName() .. "Text"]
    if rt then
        rt:SetText("Repair Gear while Vendoring")
        rt:SetWidth(420)
        rt:SetJustifyH("LEFT")
    end
    repairCB:SetScript("OnClick", function()
        DB.repairGear = repairCB:GetChecked() and true or false
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)
    self.repairCB = repairCB

    local keepBagsCB =
        CreateFrame("CheckButton", "EbonClearanceKeepBagsOpenCB", self, "InterfaceOptionsCheckButtonTemplate")
    keepBagsCB:SetPoint("TOPLEFT", repairCB, "BOTTOMLEFT", 0, -6)
    keepBagsCB:SetChecked(DB.keepBagsOpen)
    local kbt = _G[keepBagsCB:GetName() .. "Text"]
    if kbt then
        kbt:SetText("Keep bags open when merchant window closes")
        kbt:SetWidth(EC_PANEL_WIDTH - 60)
        kbt:SetJustifyH("LEFT")
    end
    keepBagsCB:SetScript("OnClick", function()
        DB.keepBagsOpen = keepBagsCB:GetChecked() and true or false
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)
    self.keepBagsCB = keepBagsCB

    local speedSlider = AddSlider(
        self,
        "EbonClearanceVendoringSpeedSlider",
        keepBagsCB,
        "Vendoring Speed",
        0.05,
        0.500,
        0.01,
        function()
            return DB.vendorInterval or 0.1
        end,
        function(v)
            DB.vendorInterval = v
        end,
        -16
    )
    self.speedSlider = speedSlider
    speedSlider:SetWidth(200)

    local fastModeCB = AddCheckbox(
        self,
        "EbonClearanceFastModeCB",
        speedSlider,
        "Fast Mode (0.05 s interval, 160-item cap)",
        function()
            return DB.fastMode
        end,
        function(v)
            DB.fastMode = v
        end,
        -16
    )
    self.fastModeCB = fastModeCB

    local fastModeNote = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    fastModeNote:SetPoint("TOPLEFT", fastModeCB, "BOTTOMLEFT", 26, -2)
    fastModeNote:SetWidth(EC_PANEL_WIDTH - 60)
    fastModeNote:SetJustifyH("LEFT")
    if fastModeNote.SetWordWrap then
        fastModeNote:SetWordWrap(true)
    end
    fastModeNote:SetText(
        "|cff888888Higher throughput. Increases disconnect risk on unstable connections - disable if you DC mid-vendor.|r"
    )

    -- Quality threshold: when enabled, every item at or below the chosen
    -- quality with a vendor price is sold in addition to the whitelist. Lives
    -- here (rather than on the Whitelist panel) because it's a sell behaviour.
    local thresholdHeader = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    thresholdHeader:SetPoint("TOPLEFT", fastModeNote, "BOTTOMLEFT", -26, -24)
    thresholdHeader:SetText("Quality Threshold")

    local thresholdDesc = self:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    thresholdDesc:SetPoint("TOPLEFT", thresholdHeader, "BOTTOMLEFT", 0, -4)
    thresholdDesc:SetWidth(EC_PANEL_WIDTH - 16)
    thresholdDesc:SetJustifyH("LEFT")
    if thresholdDesc.SetWordWrap then
        thresholdDesc:SetWordWrap(true)
    end
    thresholdDesc:SetText(
        "When enabled, every item at or below the chosen quality with a vendor price is sold, in addition to your whitelist. Blacklisted items are still protected."
    )

    local whitelistQualityCB =
        CreateFrame("CheckButton", "EbonClearanceWhitelistQualityCB", self, "InterfaceOptionsCheckButtonTemplate")
    whitelistQualityCB:SetPoint("TOPLEFT", thresholdDesc, "BOTTOMLEFT", 0, -8)
    whitelistQualityCB:SetChecked(DB.whitelistQualityEnabled)
    local wqt = _G["EbonClearanceWhitelistQualityCBText"]
    if wqt then
        wqt:SetText("Sell items by quality threshold")
        wqt:SetWidth(260)
        wqt:SetJustifyH("LEFT")
    end
    whitelistQualityCB:SetScript("OnClick", function()
        DB.whitelistQualityEnabled = whitelistQualityCB:GetChecked() and true or false
        PlaySound("igMainMenuOptionCheckBoxOn")
        if self.RefreshQualityDropDown then
            self:RefreshQualityDropDown()
        end
    end)
    self.whitelistQualityCB = whitelistQualityCB

    local ddLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    ddLabel:SetPoint("TOPLEFT", whitelistQualityCB, "BOTTOMLEFT", 0, -4)
    ddLabel:SetText("Sell items up to quality:")

    local qualityDD = CreateFrame("Frame", "EbonClearanceWhitelistQualityDropDown", self, "UIDropDownMenuTemplate")
    qualityDD:SetPoint("LEFT", ddLabel, "RIGHT", -8, -2)
    UIDropDownMenu_SetWidth(qualityDD, 160)

    UIDropDownMenu_Initialize(qualityDD, function(frame, level)
        local info = UIDropDownMenu_CreateInfo()
        for i = 1, #EC_WHITELIST_QUALITIES do
            local opt = EC_WHITELIST_QUALITIES[i]
            info.text = opt.text
            info.value = opt.value
            info.checked = (DB.whitelistMinQuality == opt.value)
            info.func = function()
                DB.whitelistMinQuality = opt.value
                UIDropDownMenu_SetSelectedValue(qualityDD, opt.value)
                UIDropDownMenu_SetText(qualityDD, opt.text)
                PlaySound("igMainMenuOptionCheckBoxOn")
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    function self:RefreshQualityDropDown()
        local cur = DB.whitelistMinQuality or 1
        if cur < 1 then
            cur = 1
            DB.whitelistMinQuality = 1
        end
        local label = EC_WHITELIST_QUALITIES[1].text
        for i = 1, #EC_WHITELIST_QUALITIES do
            if EC_WHITELIST_QUALITIES[i].value == cur then
                label = EC_WHITELIST_QUALITIES[i].text
                break
            end
        end
        UIDropDownMenu_SetSelectedValue(qualityDD, cur)
        UIDropDownMenu_SetText(qualityDD, label)
        if DB.whitelistQualityEnabled then
            if UIDropDownMenu_EnableDropDown then
                UIDropDownMenu_EnableDropDown(qualityDD)
            end
        else
            if UIDropDownMenu_DisableDropDown then
                UIDropDownMenu_DisableDropDown(qualityDD)
            end
        end
    end
    self:RefreshQualityDropDown()
end)

-- Shared "Add from bags" scan row used by both whitelist panels.
-- setTableName resolves to the underlying list via EC_GetListTable, so the same
-- helper drives the per-character whitelist and the account whitelist.
local function EC_AddScanByQualityRow(parent, setTableName, listLabel, refreshFn, x, y)
    local function ScanBagsForQuality(quality)
        local t = EC_GetListTable(setTableName)
        if not t then
            return 0
        end
        local added = 0
        for bag = 0, 4 do
            local slots = GetContainerNumSlots(bag)
            for slot = 1, slots do
                local itemID = GetContainerItemID(bag, slot)
                if itemID then
                    local _, _, q, _, _, _, _, _, _, _, sellPrice = GetItemInfo(itemID)
                    if q == quality and sellPrice and sellPrice > 0 and not t[itemID] then
                        t[itemID] = true
                        added = added + 1
                    end
                end
            end
        end
        return added
    end

    local scanLabel = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    scanLabel:SetPoint("TOPLEFT", x, y)
    scanLabel:SetText("Add from bags:")

    local function MakeBtn(prevAnchor, leftPad, label, qualityNum, colorWord)
        local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        b:SetSize(55, 20)
        b:SetPoint("LEFT", prevAnchor, "RIGHT", leftPad, 0)
        b:SetText(label)
        b:SetScript("OnClick", function()
            local added = ScanBagsForQuality(qualityNum)
            PrintNicef("Scanned bags: added |cffffff00%d|r %s items to %s.", added, colorWord, listLabel)
            if refreshFn then
                refreshFn()
            end
            PlaySound("igMainMenuOptionCheckBoxOn")
        end)
        return b
    end

    local btnWhite = MakeBtn(scanLabel, 8, "|cffffffffWhite|r", 1, "white")
    local btnGreen = MakeBtn(btnWhite, 4, "|cff1eff00Green|r", 2, "green")
    MakeBtn(btnGreen, 4, "|cff0070ddBlue|r", 3, "blue")
end

local WhitelistPanel = CreateFrame("Frame", "EbonClearanceOptionsWhitelist", InterfaceOptionsFramePanelContainer)
WhitelistPanel.name = "Whitelist - Character"
WhitelistPanel.parent = "EbonClearance"

WhitelistPanel:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then
        if self.listUI then
            self.listUI:Refresh()
        end
        return
    end
    self.inited = true

    MakeHeader(self, "Whitelist Settings", -16)

    MakeLabel(
        self,
        "Items below are sold on this character. They're saved and restored by profiles. For items you want sold on every alt, use |cffb6ffb6Whitelist - Account|r instead. Grey junk is always sold automatically; the quality threshold lives on Merchant Settings.",
        16,
        -44
    )

    EC_AddScanByQualityRow(self, "whitelist", "your character whitelist", function()
        if self.listUI then
            self.listUI:Refresh()
        end
    end, 16, -94)

    self.listUI = CreateListUI(self, "Manual Add (Shift-click item or type ID)", "whitelist", 16, -118)
    self.listUI:SetHeight(290)
    self.listUI:Refresh()
end)

-- ============================================================
-- Whitelist Profiles Panel
-- ============================================================
local ProfilesPanel = CreateFrame("Frame", "EbonClearanceOptionsProfiles", InterfaceOptionsFramePanelContainer)
ProfilesPanel.name = "Profiles"
ProfilesPanel.parent = "EbonClearance"

ProfilesPanel:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then
        if self.RefreshProfileList then
            self:RefreshProfileList()
        end
        return
    end
    self.inited = true

    MakeHeader(self, "Profiles", -16)
    local descLabel = MakeLabel(
        self,
        "Profiles save and restore your |cffb6ffb6Whitelist - Character|r and |cffb6ffb6Blacklist - Keep|r as a named pair. Switching profiles overwrites the live character lists with the saved snapshot. Handy for swapping between farming spots.",
        16,
        -44
    )
    -- Cascade-anchored to descLabel so the layout adapts to whatever number of
    -- lines the description wraps to (fixed-y caused overlap on narrower panels).
    local clarifyLabel = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    clarifyLabel:SetPoint("TOPLEFT", descLabel, "BOTTOMLEFT", 0, -8)
    clarifyLabel:SetWidth(EC_PANEL_WIDTH - 32)
    clarifyLabel:SetJustifyH("LEFT")
    clarifyLabel:SetJustifyV("TOP")
    if clarifyLabel.SetWordWrap then
        clarifyLabel:SetWordWrap(true)
    end
    clarifyLabel:SetText(
        "|cffaaaaaaProfiles do NOT touch the |cffb6ffb6Whitelist - Account|r|cffaaaaaa list (which is shared across every alt and never replaced). The |cffb6ffb6Default|r|cffaaaaaa profile is permanently empty - give your profile a real name before saving.|r"
    )

    -- Active profile indicator
    local activeLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    activeLabel:SetPoint("TOPLEFT", clarifyLabel, "BOTTOMLEFT", 0, -16)
    activeLabel:SetWidth(EC_PANEL_WIDTH - 16)
    activeLabel:SetJustifyH("LEFT")
    self.activeLabel = activeLabel

    -- Save row: input + Save button (relative to activeLabel so it follows
    -- whatever the wrap above ends up at).
    local saveLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    saveLabel:SetPoint("TOPLEFT", activeLabel, "BOTTOMLEFT", 0, -10)
    saveLabel:SetText("Profile name:")

    local saveInput = CreateFrame("EditBox", "EbonClearanceProfileSaveInput", self, "InputBoxTemplate")
    saveInput:SetAutoFocus(false)
    saveInput:SetSize(180, 20)
    saveInput:SetPoint("LEFT", saveLabel, "RIGHT", 8, 0)
    saveInput:SetMaxLetters(30)
    saveInput:SetText(DB.activeProfileName or "Default")
    StyleInputBox(saveInput)

    local saveBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
    saveBtn:SetSize(80, 22)
    saveBtn:SetPoint("LEFT", saveInput, "RIGHT", 8, 0)
    saveBtn:SetText("Save")

    -- Status text (relative to the save row above it).
    local statusFS = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    statusFS:SetPoint("TOPLEFT", saveLabel, "BOTTOMLEFT", 0, -10)
    statusFS:SetWidth(EC_PANEL_WIDTH - 16)
    statusFS:SetJustifyH("LEFT")
    statusFS:SetText("")
    self.statusFS = statusFS

    -- Profile list scroll area
    local listLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    listLabel:SetPoint("TOPLEFT", statusFS, "BOTTOMLEFT", 0, -8)
    listLabel:SetText("Saved Profiles")

    local scroll = CreateFrame("ScrollFrame", "EbonClearanceProfileListScroll", self, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", listLabel, "BOTTOMLEFT", 0, -4)
    scroll:SetSize(EC_PANEL_WIDTH - 42, 160)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(EC_PANEL_WIDTH - 42, 1)
    scroll:SetScrollChild(content)

    local rowPool = {}
    local activeRows = 0
    local listW = EC_PANEL_WIDTH - 42

    local function GetRow(index)
        if rowPool[index] then
            return rowPool[index]
        end
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(listW, 22)

        local delBtn = CreateFrame("Button", "EbonClearanceProfileDel_" .. index, content, "UIPanelButtonTemplate")
        delBtn:SetSize(58, 18)
        delBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        delBtn:SetText("Delete")

        local clearBtn = CreateFrame("Button", "EbonClearanceProfileClear_" .. index, content, "UIPanelButtonTemplate")
        clearBtn:SetSize(52, 18)
        clearBtn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
        clearBtn:SetText("Clear")

        local loadBtn = CreateFrame("Button", "EbonClearanceProfileLoad_" .. index, content, "UIPanelButtonTemplate")
        loadBtn:SetSize(52, 18)
        loadBtn:SetPoint("RIGHT", clearBtn, "LEFT", -4, 0)
        loadBtn:SetText("Load")

        local text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        text:SetPoint("LEFT", row, "LEFT", 2, 0)
        text:SetPoint("RIGHT", loadBtn, "LEFT", -4, 0)
        text:SetJustifyH("LEFT")

        row.text = text
        row.loadBtn = loadBtn
        row.clearBtn = clearBtn
        row.delBtn = delBtn
        rowPool[index] = row
        return row
    end

    local function HideAllRows()
        for i = 1, activeRows do
            if rowPool[i] then
                rowPool[i]:Hide()
                rowPool[i].loadBtn:Hide()
                rowPool[i].clearBtn:Hide()
                rowPool[i].delBtn:Hide()
            end
        end
        activeRows = 0
    end

    -- Rename row
    local renameLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    renameLabel:SetPoint("TOPLEFT", scroll, "BOTTOMLEFT", 0, -12)
    renameLabel:SetText("Rename active profile:")

    local renameInput = CreateFrame("EditBox", "EbonClearanceProfileRenameInput", self, "InputBoxTemplate")
    renameInput:SetAutoFocus(false)
    renameInput:SetSize(150, 20)
    renameInput:SetPoint("LEFT", renameLabel, "RIGHT", 8, 0)
    renameInput:SetMaxLetters(30)
    renameInput:SetText("")
    StyleInputBox(renameInput)

    local renameBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
    renameBtn:SetSize(70, 22)
    renameBtn:SetPoint("LEFT", renameInput, "RIGHT", 8, 0)
    renameBtn:SetText("Rename")

    function self:RefreshProfileList()
        HideAllRows()

        -- Update active indicator
        local activeName = DB.activeProfileName or "Default"
        activeLabel:SetText("Active profile: |cff00ff00" .. activeName .. "|r")
        saveInput:SetText(activeName)
        renameInput:SetText(activeName)

        -- Collect and sort profile names
        local names = {}
        for name in pairs(DB.whitelistProfiles) do
            if type(name) == "string" then
                names[#names + 1] = name
            end
        end
        table.sort(names, function(a, b)
            return a:lower() < b:lower()
        end)

        local shown = 0
        local rowY = -4
        for i = 1, #names do
            local pName = names[i]
            shown = shown + 1
            local row = GetRow(shown)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, rowY)

            local isActive = (pName == DB.activeProfileName)
            local wlCount = EC_CountItems(DB.whitelistProfiles[pName])
            local blCount = DB.blacklistProfiles[pName] and EC_CountItems(DB.blacklistProfiles[pName]) or 0
            local label = isActive
                    and string.format(
                        "|cff00ff00%s|r  |cff888888(%d whitelist, %d blacklist, active)|r",
                        pName,
                        wlCount,
                        blCount
                    )
                or string.format("|cffffff00%s|r  |cff888888(%d whitelist, %d blacklist)|r", pName, wlCount, blCount)
            row.text:SetText(label)

            row.loadBtn:SetScript("OnClick", function()
                local ok, msg = EC_LoadProfile(pName)
                statusFS:SetText(ok and ("|cff00ff00" .. msg .. "|r") or ("|cffff4444" .. msg .. "|r"))
                if ok then
                    PrintNice(msg)
                    PlaySound("igMainMenuOptionCheckBoxOn")
                end
                self:RefreshProfileList()
            end)

            row.delBtn:SetScript("OnClick", function()
                local dialog = StaticPopup_Show("EC_CONFIRM_DELETE_PROFILE", pName)
                if dialog then
                    dialog.data = function()
                        local ok, msg = EC_DeleteProfile(pName)
                        statusFS:SetText(
                            ok and ("|cff00ff00" .. msg .. "|r") or ("|cffff4444" .. msg .. "|r")
                        )
                        if ok then
                            PrintNice(msg)
                            PlaySound("igMainMenuOptionCheckBoxOn")
                        end
                        self:RefreshProfileList()
                    end
                end
            end)

            row.clearBtn:SetScript("OnClick", function()
                local dialog = StaticPopup_Show("EC_CONFIRM_CLEAR_PROFILE", pName)
                if dialog then
                    dialog.data = function()
                        if DB.whitelistProfiles[pName] then
                            wipe(DB.whitelistProfiles[pName])
                            if pName == DB.activeProfileName then
                                wipe(DB.whitelist)
                                local wp = _G["EbonClearanceOptionsWhitelist"]
                                if wp and wp.listUI then
                                    wp.listUI:Refresh()
                                end
                            end
                            statusFS:SetText(
                                '|cff00ff00Cleared profile "|cffffff00' .. pName .. '|r|cff00ff00".|r'
                            )
                            PrintNicef('Cleared profile "|cffffff00%s|r".', pName)
                            PlaySound("igMainMenuOptionCheckBoxOn")
                        end
                        self:RefreshProfileList()
                    end
                end
            end)

            local isDefault = (pName == "Default")
            row:Show()
            row.loadBtn:Show()
            if isDefault then
                row.clearBtn:Hide()
                row.delBtn:Hide()
            else
                row.clearBtn:Show()
                row.delBtn:Show()
            end
            rowY = rowY - 22
        end

        activeRows = shown
        content:SetHeight(math.max(1, (shown * 22) + 8))
    end

    saveBtn:SetScript("OnClick", function()
        local name = saveInput:GetText()
        local ok, msg = EC_SaveProfile(name)
        statusFS:SetText(ok and ("|cff00ff00" .. msg .. "|r") or ("|cffff4444" .. msg .. "|r"))
        if ok then
            PrintNice(msg)
            PlaySound("igMainMenuOptionCheckBoxOn")
            self:RefreshProfileList()
        else
            PlaySound("igMainMenuOptionCheckBoxOff")
        end
    end)

    saveInput:SetScript("OnEnterPressed", function()
        saveBtn:Click()
        saveInput:ClearFocus()
    end)

    renameBtn:SetScript("OnClick", function()
        local newName = renameInput:GetText()
        local ok, msg = EC_RenameProfile(DB.activeProfileName, newName)
        statusFS:SetText(ok and ("|cff00ff00" .. msg .. "|r") or ("|cffff4444" .. msg .. "|r"))
        if ok then
            PrintNice(msg)
            PlaySound("igMainMenuOptionCheckBoxOn")
            self:RefreshProfileList()
        else
            PlaySound("igMainMenuOptionCheckBoxOff")
        end
    end)

    renameInput:SetScript("OnEnterPressed", function()
        renameBtn:Click()
        renameInput:ClearFocus()
    end)

    self:RefreshProfileList()
end)

-- ============================================================
-- Whitelist Import / Export Panel
-- ============================================================
local ImportExportPanel = CreateFrame("Frame", "EbonClearanceOptionsImportExport", InterfaceOptionsFramePanelContainer)
ImportExportPanel.name = "Import/Export"
ImportExportPanel.parent = "EbonClearance"

local EC_EXPORT_PREFIX = "EC:"

-- Resolve the export/import target table. scope is "character" (default) or
-- "account"; the latter touches the account-wide whitelist (ADB).
local function EC_GetWhitelistForScope(scope)
    if scope == "account" then
        return ADB and ADB.whitelist
    end
    return DB and DB.whitelist
end

local function EC_ExportWhitelist(listName, scope)
    local source = EC_GetWhitelistForScope(scope)
    if not source then
        return ""
    end
    local ids = {}
    for k, v in pairs(source) do
        if type(k) == "number" and (v == true or v == 1) then
            ids[#ids + 1] = k
        end
    end
    table.sort(ids)
    local name = (listName and listName ~= "") and listName or "Unnamed"
    name = name:gsub("[:|]", "_")
    return EC_EXPORT_PREFIX .. name .. ":" .. table.concat(ids, ",")
end

local function EC_ImportWhitelist(str, mode, scope)
    if type(str) ~= "string" or str == "" then
        return false, "Empty string."
    end
    str = str:gsub("^%s+", ""):gsub("%s+$", "")
    if str:sub(1, #EC_EXPORT_PREFIX) ~= EC_EXPORT_PREFIX then
        return false, "Invalid format. String must start with EC:"
    end
    local body = str:sub(#EC_EXPORT_PREFIX + 1)
    local name, idStr = body:match("^([^:]*):(.+)$")
    if not idStr or idStr == "" then
        return false, "No item IDs found after the list name."
    end
    local ids = {}
    for token in idStr:gmatch("([^,]+)") do
        local n = tonumber(token:match("^%s*(%d+)%s*$"))
        if n and n > 0 then
            ids[#ids + 1] = n
        end
    end
    if #ids == 0 then
        return false, "No valid item IDs found."
    end
    local target = EC_GetWhitelistForScope(scope)
    if not target then
        return false, "Target list unavailable."
    end
    if mode == "replace" then
        wipe(target)
    end
    local added = 0
    for i = 1, #ids do
        if not target[ids[i]] then
            added = added + 1
        end
        target[ids[i]] = true
    end
    local scopeLabel = (scope == "account") and "account whitelist" or "character whitelist"
    return true,
        string.format(
            'Imported |cffffff00%d|r items from "%s" into the %s (%d new).',
            #ids,
            name or "Unnamed",
            scopeLabel,
            added
        )
end

ImportExportPanel:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then
        return
    end
    self.inited = true

    MakeHeader(self, "Import / Export", -16)

    -- === EXPORT SECTION ===
    -- Each section owns its own scope radio so it's obvious which list a
    -- click reads from (Source list) versus writes to (Target list).
    MakeLabel(
        self,
        "Export a whitelist to a string you can share. Pick which list to read from, then give the export a name.",
        16,
        -44
    )

    local exportScope = "character"

    local exportScopeLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    exportScopeLabel:SetPoint("TOPLEFT", 16, -72)
    exportScopeLabel:SetText("Source list:")

    local exportCharCB = CreateFrame("CheckButton", "EbonClearanceExportSourceCharCB", self, "UIRadioButtonTemplate")
    exportCharCB:SetPoint("LEFT", exportScopeLabel, "RIGHT", 8, 0)
    exportCharCB:SetChecked(true)
    local exportCharLbl = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    exportCharLbl:SetPoint("LEFT", exportCharCB, "RIGHT", 2, 1)
    exportCharLbl:SetText("Character")

    local exportAcctCB = CreateFrame("CheckButton", "EbonClearanceExportSourceAcctCB", self, "UIRadioButtonTemplate")
    exportAcctCB:SetPoint("LEFT", exportCharLbl, "RIGHT", 12, -1)
    exportAcctCB:SetChecked(false)
    local exportAcctLbl = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    exportAcctLbl:SetPoint("LEFT", exportAcctCB, "RIGHT", 2, 1)
    exportAcctLbl:SetText("Account")

    exportCharCB:SetScript("OnClick", function()
        exportScope = "character"
        exportCharCB:SetChecked(true)
        exportAcctCB:SetChecked(false)
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)
    exportAcctCB:SetScript("OnClick", function()
        exportScope = "account"
        exportAcctCB:SetChecked(true)
        exportCharCB:SetChecked(false)
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)

    local exportNameLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    exportNameLabel:SetPoint("TOPLEFT", 16, -100)
    exportNameLabel:SetText("List name:")

    local exportNameBox = CreateFrame("EditBox", "EbonClearanceExportNameBox", self, "InputBoxTemplate")
    exportNameBox:SetAutoFocus(false)
    exportNameBox:SetSize(200, 20)
    exportNameBox:SetPoint("LEFT", exportNameLabel, "RIGHT", 8, 0)
    exportNameBox:SetMaxLetters(40)
    exportNameBox:SetText("My Whitelist")
    StyleInputBox(exportNameBox)

    local exportBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
    exportBtn:SetSize(80, 22)
    exportBtn:SetPoint("LEFT", exportNameBox, "RIGHT", 8, 0)
    exportBtn:SetText("Export")

    local exportScroll = CreateFrame("ScrollFrame", "EbonClearanceExportScroll", self, "UIPanelScrollFrameTemplate")
    exportScroll:SetPoint("TOPLEFT", 16, -128)
    exportScroll:SetSize(EC_PANEL_WIDTH - 36, 50)

    local exportBox = CreateFrame("EditBox", "EbonClearanceExportBox", exportScroll)
    exportBox:SetAutoFocus(false)
    exportBox:SetMultiLine(true)
    exportBox:SetFontObject("GameFontHighlightSmall")
    -- Size the EditBox explicitly. Without SetHeight, an empty multiline
    -- EditBox has zero clickable area, so users can't focus it to paste.
    exportBox:SetSize(560, 50)
    exportBox:SetText("")
    exportBox:SetScript("OnEscapePressed", function(s)
        s:ClearFocus()
    end)
    exportScroll:SetScrollChild(exportBox)

    exportBtn:SetScript("OnClick", function()
        local str = EC_ExportWhitelist(exportNameBox:GetText(), exportScope)
        exportBox:SetText(str)
        exportBox:HighlightText()
        exportBox:SetFocus()
        PlaySound("igMainMenuOptionCheckBoxOn")
        local source = EC_GetWhitelistForScope(exportScope) or {}
        local count = 0
        for _, v in pairs(source) do
            if v == true or v == 1 then
                count = count + 1
            end
        end
        local scopeName = (exportScope == "account") and "account" or "character"
        PrintNicef("Exported |cffffff00%d|r %s whitelist items. Copy the text above.", count, scopeName)
    end)

    -- === IMPORT SECTION ===
    MakeLabel(self, "Paste a whitelist string and pick which list it imports into.", 16, -198)

    local importScope = "character"

    local importScopeLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    importScopeLabel:SetPoint("TOPLEFT", 16, -226)
    importScopeLabel:SetText("Target list:")

    local importCharCB = CreateFrame("CheckButton", "EbonClearanceImportTargetCharCB", self, "UIRadioButtonTemplate")
    importCharCB:SetPoint("LEFT", importScopeLabel, "RIGHT", 8, 0)
    importCharCB:SetChecked(true)
    local importCharLbl = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    importCharLbl:SetPoint("LEFT", importCharCB, "RIGHT", 2, 1)
    importCharLbl:SetText("Character")

    local importAcctCB = CreateFrame("CheckButton", "EbonClearanceImportTargetAcctCB", self, "UIRadioButtonTemplate")
    importAcctCB:SetPoint("LEFT", importCharLbl, "RIGHT", 12, -1)
    importAcctCB:SetChecked(false)
    local importAcctLbl = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    importAcctLbl:SetPoint("LEFT", importAcctCB, "RIGHT", 2, 1)
    importAcctLbl:SetText("Account")

    importCharCB:SetScript("OnClick", function()
        importScope = "character"
        importCharCB:SetChecked(true)
        importAcctCB:SetChecked(false)
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)
    importAcctCB:SetScript("OnClick", function()
        importScope = "account"
        importAcctCB:SetChecked(true)
        importCharCB:SetChecked(false)
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)

    local importScroll = CreateFrame("ScrollFrame", "EbonClearanceImportScroll", self, "UIPanelScrollFrameTemplate")
    importScroll:SetPoint("TOPLEFT", 16, -254)
    importScroll:SetSize(EC_PANEL_WIDTH - 36, 50)

    local importBox = CreateFrame("EditBox", "EbonClearanceImportBox", importScroll)
    importBox:SetAutoFocus(false)
    importBox:SetMultiLine(true)
    importBox:SetFontObject("GameFontHighlightSmall")
    -- Explicit size required so an empty EditBox still has a clickable area
    -- for paste. Without SetHeight, multiline EditBoxes collapse to zero.
    importBox:SetSize(560, 50)
    importBox:SetText("")
    importBox:SetScript("OnEscapePressed", function(s)
        s:ClearFocus()
    end)
    importScroll:SetScrollChild(importBox)

    local importMergeBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
    importMergeBtn:SetSize(120, 22)
    importMergeBtn:SetPoint("TOPLEFT", 16, -312)
    importMergeBtn:SetText("Import (Merge)")

    local importReplaceBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
    importReplaceBtn:SetSize(120, 22)
    importReplaceBtn:SetPoint("LEFT", importMergeBtn, "RIGHT", 8, 0)
    importReplaceBtn:SetText("Import (Replace)")

    local statusFS = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    statusFS:SetPoint("TOPLEFT", 16, -340)
    statusFS:SetWidth(EC_PANEL_WIDTH - 16)
    statusFS:SetJustifyH("LEFT")
    statusFS:SetText("")

    local function runImport(mode)
        local ok, msg = EC_ImportWhitelist(importBox:GetText(), mode, importScope)
        statusFS:SetText(ok and ("|cff00ff00" .. msg .. "|r") or ("|cffff4444" .. msg .. "|r"))
        if ok then
            PlaySound("igMainMenuOptionCheckBoxOn")
            PrintNice(msg)
            local panelName = (importScope == "account")
                and "EbonClearanceOptionsAccountWhitelist"
                or "EbonClearanceOptionsWhitelist"
            local wp = _G[panelName]
            if wp and wp.listUI then
                wp.listUI:Refresh()
            end
        else
            PlaySound("igMainMenuOptionCheckBoxOff")
        end
    end
    importMergeBtn:SetScript("OnClick", function()
        runImport("merge")
    end)
    importReplaceBtn:SetScript("OnClick", function()
        runImport("replace")
    end)

    -- Grey explanation is anchored to the status line so it naturally flows
    -- below, even when the status wraps to two lines (e.g. long error).
    local importNote = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    importNote:SetPoint("TOPLEFT", statusFS, "BOTTOMLEFT", 0, -8)
    importNote:SetWidth(EC_PANEL_WIDTH - 16)
    importNote:SetJustifyH("LEFT")
    importNote:SetJustifyV("TOP")
    if importNote.SetWordWrap then
        importNote:SetWordWrap(true)
    end
    importNote:SetText(
        "|cffaaaaaa'Merge' adds imported items to the target list. "
            .. "'Replace' clears the target list first, then adds the imported items.|r"
    )
end)

local DeletePanel = CreateFrame("Frame", "EbonClearanceOptionsDeletion", InterfaceOptionsFramePanelContainer)
DeletePanel.name = "Deletion List"
DeletePanel.parent = "EbonClearance"

DeletePanel:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then
        if self.listUI then
            self.listUI:Refresh()
        end
        return
    end
    self.inited = true

    MakeHeader(self, "Deletion Settings", -16)
    local delDesc = MakeLabel(self, "If enabled, items on this list will be deleted from your bags.", 16, -44)
    local delHint = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    delHint:SetPoint("TOPLEFT", delDesc, "BOTTOMLEFT", 0, -4)
    delHint:SetWidth(EC_PANEL_WIDTH - 16)
    delHint:SetJustifyH("LEFT")
    delHint:SetJustifyV("TOP")
    if delHint.SetWordWrap then
        delHint:SetWordWrap(true)
    end
    delHint:SetText(
        "Add Items by Shift-Clicking an item, drag & drop into the text field below, or type the ItemID and press Add."
    )

    local delCB = CreateFrame("CheckButton", "EbonClearanceEnableDeleteCB", self, "InterfaceOptionsCheckButtonTemplate")
    delCB:SetPoint("TOPLEFT", delHint, "BOTTOMLEFT", 0, -6)
    delCB:SetChecked(DB.enableDeletion)
    local dt = _G[delCB:GetName() .. "Text"]
    if dt then
        dt:SetText("Enable Item Deletion")
        dt:SetWidth(420)
        dt:SetJustifyH("LEFT")
    end
    delCB:SetScript("OnClick", function()
        DB.enableDeletion = delCB:GetChecked() and true or false
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)

    self.listUI = CreateListUI(self, "Deletion List", "deleteList", 16, -130)
    self.listUI:Refresh()
end)

local ScavengerPanel = CreateFrame("Frame", "EbonClearanceOptionsScavenger", InterfaceOptionsFramePanelContainer)

ScavengerPanel.name = "Scavenger Settings"
ScavengerPanel.parent = "EbonClearance"

ScavengerPanel:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then
        if self.sumCB then
            self.sumCB:SetChecked(DB.summonGreedy)
        end
        if self.delaySlider then
            self.delaySlider:SetValue(DB.summonDelay or 1.6)
        end
        if self.muteCB then
            self.muteCB:SetChecked(DB.muteGreedy)
        end
        if self.chatCB then
            self.chatCB:SetChecked(DB.hideGreedyChat)
        end
        if self.bubCB then
            self.bubCB:SetChecked(DB.hideGreedyBubbles)
        end
        if self.cycleCB then
            self.cycleCB:SetChecked(DB.autoLootCycle)
        end
        if self.threshSlider then
            self.threshSlider:SetValue(DB.bagFullThreshold or 2)
        end
        if self.autoOpenCB then
            self.autoOpenCB:SetChecked(DB.autoOpenContainers)
        end
        return
    end
    self.inited = true

    MakeHeader(self, "Scavenger Settings", -16)
    MakeLabel(
        self,
        "Controls summoning and muting of |cffff7f7fGreedy Scavenger|r. The auto-loot cycle will continuously loot and sell while your bags fill up.",
        16,
        -44
    )

    local sumCB = CreateFrame("CheckButton", "EbonClearanceSummonGreedyCB", self, "InterfaceOptionsCheckButtonTemplate")
    sumCB:SetPoint("TOPLEFT", 16, -96)
    sumCB:SetChecked(DB.summonGreedy)
    local st = _G[sumCB:GetName() .. "Text"]
    if st then
        st:SetText("Summon |cffff7f7fGreedy Scavenger|r after Vendoring")
        st:SetWidth(420)
        st:SetJustifyH("LEFT")
    end
    sumCB:SetScript("OnClick", function()
        DB.summonGreedy = sumCB:GetChecked() and true or false
        if not DB.summonGreedy and DB.autoLootCycle then
            DB.autoLootCycle = false
            if self.cycleCB then
                self.cycleCB:SetChecked(false)
            end
        end
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)
    self.sumCB = sumCB

    local chatCB = AddCheckbox(
        self,
        "EbonClearanceHideGreedyChatCB",
        sumCB,
        "Hide |cffff7f7fGreedy Scavenger|r's chat messages",
        function()
            return DB.hideGreedyChat
        end,
        function(v)
            DB.hideGreedyChat = v
            ApplyGreedyChatFilter()
        end,
        -8
    )
    self.chatCB = chatCB

    local bubCB = AddCheckbox(
        self,
        "EbonClearanceHideGreedyBubblesCB",
        chatCB,
        "Hide |cffff7f7fGreedy Scavenger|r's chat bubbles",
        function()
            return DB.hideGreedyBubbles
        end,
        function(v)
            DB.hideGreedyBubbles = v
        end,
        -8
    )
    self.bubCB = bubCB

    local delaySlider = AddSlider(
        self,
        "EbonClearanceSummonDelaySlider",
        bubCB,
        "Summon delay",
        0.0,
        3.0,
        0.1,
        function()
            return DB.summonDelay or 1.6
        end,
        function(v)
            DB.summonDelay = v
        end,
        -16
    )
    self.delaySlider = delaySlider
    delaySlider:SetWidth(200)

    local cycleCB = AddCheckbox(
        self,
        "EbonClearanceAutoLootCycleCB",
        delaySlider,
        "Enable auto-loot cycle (loot, sell, repeat)",
        function()
            return DB.autoLootCycle
        end,
        function(v)
            DB.autoLootCycle = v
            if v then
                DB.summonGreedy = true
                if self.sumCB then
                    self.sumCB:SetChecked(true)
                end
            end
        end,
        -16
    )
    self.cycleCB = cycleCB

    local cycleNote = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    cycleNote:SetPoint("TOPLEFT", cycleCB, "BOTTOMLEFT", 26, -2)
    cycleNote:SetWidth(EC_PANEL_WIDTH - 60)
    cycleNote:SetJustifyH("LEFT")
    cycleNote:SetText(
        "|cff888888When bags hit the threshold, Greedy is dismissed and the Goblin Merchant is summoned for you. Right-click the Goblin Merchant to open the vendor window - selling and re-summoning Greedy happens automatically from there.|r"
    )

    local threshSlider = AddSlider(
        self,
        "EbonClearanceBagThresholdSlider",
        cycleNote,
        "Bag slots remaining before selling",
        0,
        10,
        1,
        function()
            return DB.bagFullThreshold or 2
        end,
        function(v)
            DB.bagFullThreshold = v
        end,
        -16,
        "%d"
    )
    self.threshSlider = threshSlider
    threshSlider:SetWidth(200)

    local autoOpenCB = AddCheckbox(
        self,
        "EbonClearanceAutoOpenCB",
        threshSlider,
        "Auto-open lootable containers from your bags",
        function()
            return DB.autoOpenContainers
        end,
        function(v)
            DB.autoOpenContainers = v
        end,
        -16
    )
    self.autoOpenCB = autoOpenCB

    local autoOpenNote = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    autoOpenNote:SetPoint("TOPLEFT", autoOpenCB, "BOTTOMLEFT", 26, -2)
    autoOpenNote:SetWidth(EC_PANEL_WIDTH - 60)
    autoOpenNote:SetJustifyH("LEFT")
    if autoOpenNote.SetWordWrap then
        autoOpenNote:SetWordWrap(true)
    end
    autoOpenNote:SetText(
        "|cff888888Lockboxes that need a key or lockpick are skipped. Combat-paused.|r"
    )

    -- Discoverability hint for the right-click context menu. Lives on this
    -- panel because both v2.3.0 bag-action features cluster here.
    local rightClickHint = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    rightClickHint:SetPoint("TOPLEFT", autoOpenNote, "BOTTOMLEFT", 0, -16)
    rightClickHint:SetWidth(EC_PANEL_WIDTH - 60)
    rightClickHint:SetJustifyH("LEFT")
    if rightClickHint.SetWordWrap then
        rightClickHint:SetWordWrap(true)
    end
    rightClickHint:SetText(
        "|cffffb84dTip:|r |cff888888Alt+Right-Click any item in your bags for a quick-action menu (whitelist, blacklist, delete, sell now).|r"
    )
end)

local CharPanel = CreateFrame("Frame", "EbonClearanceOptionsCharacter", InterfaceOptionsFramePanelContainer)
CharPanel.name = "Character Settings"
CharPanel.parent = "EbonClearance"

local function CreateNameListUI(parent, titleText, setTableName, x, y)
    local w = EC_PANEL_WIDTH - x
    local box = CreateFrame("Frame", nil, parent)
    box:SetPoint("TOPLEFT", x, y)
    -- 280 matches CreateListUI's default; keeps the scroll arrows inside the
    -- InterfaceOptions sub-panel's visible area instead of clipping below it.
    box:SetSize(w, 280)

    local title = box:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOPLEFT", 0, 0)
    title:SetText(titleText)

    local input = CreateFrame("EditBox", "EbonClearanceIDInput_" .. setTableName, box, "InputBoxTemplate")
    input:SetAutoFocus(false)
    input:SetSize(180, 20)
    input:SetPoint("TOPLEFT", 0, -24)
    input:SetMaxLetters(24)
    input:SetText("")

    local addBtn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    addBtn:SetSize(60, 20)
    addBtn:SetPoint("LEFT", input, "RIGHT", 8, 0)
    addBtn:SetText("Add")

    local meBtn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    meBtn:SetSize(90, 20)
    meBtn:SetPoint("LEFT", addBtn, "RIGHT", 8, 0)
    meBtn:SetText("Add Me")
    meBtn:SetScript("OnClick", function()
        input:SetText(EC_GetPlayerName())
        input:HighlightText()
    end)

    local scroll =
        CreateFrame("ScrollFrame", "EbonClearanceNameListScroll_" .. setTableName, box, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -54)
    scroll:SetPoint("BOTTOMRIGHT", -26, 8)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(w - 26, 1)
    scroll:SetScrollChild(content)

    local rowPool = {}
    local activeRows = 0

    local function GetRow(index)
        if rowPool[index] then
            return rowPool[index]
        end
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(w - 26, 22)

        local rm = CreateFrame(
            "Button",
            "EbonClearanceNameRM_" .. setTableName .. "_" .. index,
            content,
            "UIPanelButtonTemplate"
        )
        rm:SetSize(72, 18)
        rm:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        rm:SetText("Remove")

        local text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        text:SetPoint("LEFT", row, "LEFT", 2, 0)
        text:SetWidth(w - 106)
        text:SetJustifyH("LEFT")

        row.rm = rm
        row.text = text
        rowPool[index] = row
        return row
    end

    local function HideAllRows()
        for i = 1, activeRows do
            if rowPool[i] then
                rowPool[i]:Hide()
                rowPool[i].rm:Hide()
            end
        end
        activeRows = 0
    end

    local function SortedNames(t)
        local names = {}
        for k in pairs(t) do
            if type(k) == "string" and k ~= "" then
                names[#names + 1] = k
            end
        end
        table.sort(names)
        return names
    end

    local function Refresh()
        HideAllRows()

        local setTable = DB[setTableName]
        local keys = SortedNames(setTable)

        local shown = 0
        local rowY = -4
        for i = 1, #keys do
            local name = keys[i]
            shown = shown + 1
            local row = GetRow(shown)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, rowY)
            row.text:SetText("|cffb6ffb6" .. name .. "|r")
            row.rm:SetScript("OnClick", function()
                DB[setTableName][name] = nil
                Refresh()
            end)
            row:Show()
            row.rm:Show()
            rowY = rowY - 22
        end

        activeRows = shown
        content:SetHeight(math.max(1, (shown * 22) + 8))
    end

    addBtn:SetScript("OnClick", function()
        local v = (input:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if v == "" then
            PlaySound("igMainMenuOptionCheckBoxOff")
            return
        end
        DB[setTableName][v] = true
        input:SetText("")
        Refresh()
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)

    input:SetScript("OnEnterPressed", function()
        addBtn:Click()
        input:ClearFocus()
    end)

    box.Refresh = Refresh
    return box
end

CharPanel:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then
        if self.onlyCB then
            self.onlyCB:SetChecked(DB.enableOnlyListedChars)
        end
        if self.listUI then
            self.listUI:Refresh()
        end
        return
    end
    self.inited = true

    MakeHeader(self, "Character Settings", -16)
    local charDesc = MakeLabel(
        self,
        "Prevents this addon from running on characters you didn't intend. If enabled, EbonClearance runs only on characters listed below.",
        16,
        -44
    )

    local cb =
        CreateFrame("CheckButton", "EbonClearanceEnableOnlyListedCharsCB", self, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", charDesc, "BOTTOMLEFT", 0, -8)
    cb:SetChecked(DB.enableOnlyListedChars)

    local t = _G[cb:GetName() .. "Text"]
    if t then
        t:SetText("Enable Only for Listed Characters")
        t:SetWidth(EC_PANEL_WIDTH - 60)
        t:SetJustifyH("LEFT")
    end

    cb:SetScript("OnClick", function()
        DB.enableOnlyListedChars = cb:GetChecked() and true or false
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)
    self.onlyCB = cb

    self.listUI = CreateNameListUI(self, "Allowed Characters", "allowedChars", 16, -130)
    self.listUI:Refresh()
end)

-- ============================================================
-- Blacklist (Do Not Sell) Panel
-- ============================================================
local BlacklistPanel = CreateFrame("Frame", "EbonClearanceOptionsBlacklist", InterfaceOptionsFramePanelContainer)
BlacklistPanel.name = "Blacklist - Keep"
BlacklistPanel.parent = "EbonClearance"

BlacklistPanel:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then
        if self.listUI then
            self.listUI:Refresh()
        end
        return
    end
    self.inited = true

    MakeHeader(self, "Blacklist (Do Not Sell)", -16)
    local blDesc = MakeLabel(
        self,
        "Items on this list will never be sold, even if they match the whitelist or quality threshold. Use this to protect valuable items you want to sell at the auction house.",
        16,
        -44
    )

    -- Anchored to blDesc so the hint stays below even when the description
    -- wraps to multiple lines (previous absolute y=-80 overlapped the wrap).
    local blHint = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    blHint:SetPoint("TOPLEFT", blDesc, "BOTTOMLEFT", 0, -8)
    blHint:SetWidth(EC_PANEL_WIDTH - 16)
    blHint:SetJustifyH("LEFT")
    blHint:SetJustifyV("TOP")
    if blHint.SetWordWrap then
        blHint:SetWordWrap(true)
    end
    blHint:SetText("Add items by Shift-Clicking, dragging, or typing the Item ID below.")

    self.listUI = CreateListUI(self, "Protected Items", "blacklist", 16, -130)
    self.listUI:Refresh()
end)

local AccountWhitelistPanel =
    CreateFrame("Frame", "EbonClearanceOptionsAccountWhitelist", InterfaceOptionsFramePanelContainer)
AccountWhitelistPanel.name = "Whitelist - Account"
AccountWhitelistPanel.parent = "EbonClearance"

AccountWhitelistPanel:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then
        if self.listUI then
            self.listUI:Refresh()
        end
        return
    end
    self.inited = true

    MakeHeader(self, "Account Whitelist", -16)
    MakeLabel(
        self,
        "Items here are sold on every character on this account, in addition to each character's personal whitelist. Useful for shared trash like reagents or seasonal items. |cffaaaaaaThis list is not part of profiles - it stays the same when you switch profiles.|r",
        16,
        -44
    )

    EC_AddScanByQualityRow(self, "accountWhitelist", "the account whitelist", function()
        if self.listUI then
            self.listUI:Refresh()
        end
    end, 16, -94)

    self.listUI = CreateListUI(self, "Account-Wide Items", "accountWhitelist", 16, -118)
    self.listUI:SetHeight(290)
    self.listUI:Refresh()
end)

-- Register sub-panels in alphabetical order
InterfaceOptions_AddCategory(CharPanel)
InterfaceOptions_AddCategory(ScavengerPanel)
InterfaceOptions_AddCategory(MerchantPanel)
InterfaceOptions_AddCategory(ProfilesPanel)
InterfaceOptions_AddCategory(ImportExportPanel)
InterfaceOptions_AddCategory(DeletePanel)
InterfaceOptions_AddCategory(BlacklistPanel)
InterfaceOptions_AddCategory(WhitelistPanel)
InterfaceOptions_AddCategory(AccountWhitelistPanel)

-- Bug report diagnostic snapshot
local function EC_CopperToPlainText(copper)
    if not copper or copper <= 0 then
        return "0"
    end
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local cop = copper % 100
    if gold > 0 then
        return string.format("%dg %ds %dc", gold, silver, cop)
    elseif silver > 0 then
        return string.format("%ds %dc", silver, cop)
    else
        return string.format("%dc", cop)
    end
end

local function EC_BuildBugReport()
    EnsureDB()
    local lines = {}
    local function add(s)
        lines[#lines + 1] = s
    end

    local version = GetAddOnMetadata("EbonClearance", "Version") or "unknown"
    local player = UnitName("player") or "Unknown"
    local realm = GetRealmName() or "Unknown"
    local dateStr = date("%Y-%m-%d %H:%M")

    add("=== EbonClearance Bug Report ===")
    add("Version: " .. version)
    add("Character: " .. player .. " - " .. realm)
    add("Date: " .. dateStr)
    add("")

    add("--- Settings ---")
    add("Enabled: " .. tostring(DB.enabled))
    add("Merchant Mode: " .. tostring(DB.merchantMode))
    add("Repair Gear: " .. tostring(DB.repairGear))
    add("Keep Bags Open: " .. tostring(DB.keepBagsOpen))
    add("Enable Deletion: " .. tostring(DB.enableDeletion))
    add("Vendor Interval: " .. tostring(DB.vendorInterval))
    add("Max Items Per Run: " .. tostring(DB.maxItemsPerRun))
    add("Fast Mode: " .. tostring(DB.fastMode))
    add("Enable Only Listed Chars: " .. tostring(DB.enableOnlyListedChars))
    add("")

    add("--- Scavenger ---")
    add("Summon Greedy: " .. tostring(DB.summonGreedy))
    add("Summon Delay: " .. tostring(DB.summonDelay))
    add("Mute Greedy: " .. tostring(DB.muteGreedy))
    add("Hide Chat: " .. tostring(DB.hideGreedyChat))
    add("Hide Bubbles: " .. tostring(DB.hideGreedyBubbles))
    add("Auto-Loot Cycle: " .. tostring(DB.autoLootCycle))
    add("Bag Full Threshold: " .. tostring(DB.bagFullThreshold))
    add("Auto-Open Containers: " .. tostring(DB.autoOpenContainers))
    add("")

    add("--- Whitelist ---")
    add("Quality Threshold Enabled: " .. tostring(DB.whitelistQualityEnabled))
    add("Quality Level: " .. tostring(DB.whitelistMinQuality))
    add("Active Profile: " .. tostring(DB.activeProfileName))
    add("Whitelist Items: " .. tostring(EC_CountItems(DB.whitelist)))
    add("Account Whitelist Items: " .. tostring(ADB and EC_CountItems(ADB.whitelist) or 0))
    add("Blacklist Items: " .. tostring(EC_CountItems(DB.blacklist)))
    add("Delete List Items: " .. tostring(EC_CountItems(DB.deleteList)))
    add("")

    add("--- Profiles ---")
    local names = {}
    for name in pairs(DB.whitelistProfiles) do
        if type(name) == "string" then
            names[#names + 1] = name
        end
    end
    table.sort(names, function(a, b)
        return a:lower() < b:lower()
    end)
    for i = 1, #names do
        local wlCount = EC_CountItems(DB.whitelistProfiles[names[i]])
        local blCount = DB.blacklistProfiles[names[i]] and EC_CountItems(DB.blacklistProfiles[names[i]]) or 0
        local tag = (names[i] == DB.activeProfileName) and " (active)" or ""
        add(names[i] .. " (" .. wlCount .. " whitelist, " .. blCount .. " blacklist)" .. tag)
    end
    add("")

    add("--- Stats ---")
    add("Total Money Made: " .. EC_CopperToPlainText(DB.totalCopper or 0))
    add("Total Items Sold: " .. tostring(DB.totalItemsSold or 0))
    add("Total Items Deleted: " .. tostring(DB.totalItemsDeleted or 0))
    add("Total Repairs: " .. tostring(DB.totalRepairs or 0))
    add("Total Repair Cost: " .. EC_CopperToPlainText(DB.totalRepairCopper or 0))
    add("")

    add("--- Bags ---")
    add("Free Slots: " .. tostring(EC_GetFreeBagSlots()))

    return table.concat(lines, "\n")
end

local EC_bugReportFrame = nil

local function EC_ShowBugReport()
    if not EC_bugReportFrame then
        local f = CreateFrame("Frame", "EbonClearanceBugReportFrame", UIParent)
        f:SetSize(460, 360)
        f:SetPoint("CENTER")
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true,
            tileSize = 32,
            edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f:SetFrameStrata("DIALOG")
        tinsert(UISpecialFrames, "EbonClearanceBugReportFrame")

        local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        title:SetPoint("TOP", 0, -14)
        title:SetText("EbonClearance Bug Report")

        local hint = f:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        hint:SetPoint("TOP", title, "BOTTOM", 0, -4)
        hint:SetText("|cff888888Press Ctrl+A then Ctrl+C to copy this report.|r")

        local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT", -4, -4)

        local scroll = CreateFrame("ScrollFrame", "EbonClearanceBugReportScroll", f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 16, -50)
        scroll:SetPoint("BOTTOMRIGHT", -32, 16)

        local editBox = CreateFrame("EditBox", "EbonClearanceBugReportBox", scroll)
        editBox:SetAutoFocus(false)
        editBox:SetMultiLine(true)
        editBox:SetFontObject("GameFontHighlightSmall")
        editBox:SetWidth(400)
        editBox:SetText("")
        editBox:SetScript("OnEscapePressed", function(s)
            s:ClearFocus()
        end)
        scroll:SetScrollChild(editBox)

        f.editBox = editBox
        EC_bugReportFrame = f
    end

    local report = EC_BuildBugReport()
    EC_bugReportFrame.editBox:SetText(report)
    EC_bugReportFrame:Show()
    EC_bugReportFrame.editBox:HighlightText()
    EC_bugReportFrame.editBox:SetFocus()
    PrintNice("Bug report generated. Copy the text from the window.")
end

-- Keybinding registration. Populates the "EbonClearance" section of
-- ESC -> Key Bindings. Four bindings:
--   - "Target Goblin Merchant" - dispatched through the hidden
--     EbonClearanceTargetMerchantButton SecureActionButton so it works in
--     combat lockdown.
--   - Three operational bindings (open/close settings, toggle enabled,
--     force sell at current merchant) declared in Bindings.xml and wired
--     to the EbonClearance_* global handlers further down this file.
BINDING_HEADER_EBONCLEARANCE = "EbonClearance"
_G["BINDING_NAME_CLICK EbonClearanceTargetMerchantButton:LeftButton"] = "Target Goblin Merchant"
BINDING_NAME_EBONCLEARANCE_TOGGLE_SETTINGS = "Open/close settings"
BINDING_NAME_EBONCLEARANCE_TOGGLE_ENABLED = "Toggle enabled"
BINDING_NAME_EBONCLEARANCE_FORCE_SELL = "Force sell at current merchant"
-- Conflict detection + resolution across whitelist/blacklist/deleteList.
-- Precedence when auto-resolving: blacklist > deleteList > whitelist.
local function EC_ScanListConflicts()
    local lists = {
        { name = "whitelist", data = DB.whitelist },
        { name = "blacklist", data = DB.blacklist },
        { name = "deleteList", data = DB.deleteList },
    }
    local where = {}
    for i = 1, #lists do
        local e = lists[i]
        if type(e.data) == "table" then
            for id in pairs(e.data) do
                if type(id) == "number" then
                    where[id] = where[id] or {}
                    where[id][#where[id] + 1] = e.name
                end
            end
        end
    end
    local conflicts = {}
    for id, names in pairs(where) do
        if #names >= 2 then
            conflicts[#conflicts + 1] = { id = id, lists = names }
        end
    end
    table.sort(conflicts, function(a, b)
        return a.id < b.id
    end)
    return conflicts
end

local function EC_PrintConflictReport(conflicts)
    if #conflicts == 0 then
        PrintNice("|cff00ff00No list conflicts found.|r")
        return
    end
    PrintNicef("Found |cffffff00%d|r item(s) present in multiple lists:", #conflicts)
    for i = 1, #conflicts do
        local c = conflicts[i]
        local name = GetItemInfo(c.id) or ("ItemID:" .. c.id)
        PrintNicef("  |cffb6ffb6%d|r  %s  [%s]", c.id, name, table.concat(c.lists, ", "))
    end
end

local function EC_ApplyCleanResolution(conflicts)
    local removed = 0
    for i = 1, #conflicts do
        local c = conflicts[i]
        local inBL, inDel, inWL = false, false, false
        for j = 1, #c.lists do
            local n = c.lists[j]
            if n == "blacklist" then
                inBL = true
            elseif n == "deleteList" then
                inDel = true
            elseif n == "whitelist" then
                inWL = true
            end
        end
        if inBL and inWL then
            DB.whitelist[c.id] = nil
            removed = removed + 1
        end
        if inBL and inDel then
            DB.deleteList[c.id] = nil
            removed = removed + 1
        end
        if inDel and inWL then
            DB.whitelist[c.id] = nil
            removed = removed + 1
        end
    end
    return removed
end

-- Handlers for the three operational keybindings (declared in Bindings.xml,
-- labels above with the binding registration block).
function EbonClearance_ToggleSettings()
    if InterfaceOptionsFrame and InterfaceOptionsFrame:IsShown() then
        InterfaceOptionsFrame:Hide()
    else
        InterfaceOptionsFrame_OpenToCategory(MainOptions)
        InterfaceOptionsFrame_OpenToCategory(MainOptions)
    end
end

function EbonClearance_ToggleEnabled()
    EnsureDB()
    DB.enabled = not DB.enabled
    PrintNicef(
        "EbonClearance is now %s.",
        DB.enabled and "|cff00ff00enabled|r" or "|cffff4444disabled|r"
    )
    PlaySound(DB.enabled and "igMainMenuOptionCheckBoxOn" or "igMainMenuOptionCheckBoxOff")
end

function EbonClearance_ForceSell()
    EnsureDB()
    if not MerchantFrame or not MerchantFrame:IsShown() then
        PrintNice("|cffff4444Force sell|r: open a merchant first.")
        return
    end
    StartRun()
end

SLASH_EBONCLEARANCE1 = "/ec"
SlashCmdList["EBONCLEARANCE"] = function(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "" then
        InterfaceOptionsFrame_OpenToCategory(MainOptions)
        InterfaceOptionsFrame_OpenToCategory(MainOptions)
        return
    end

    local cmd, rest = msg:match("^(%S+)%s*(.*)")
    cmd = (cmd or ""):lower()
    rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")

    if cmd == "profile" or cmd == "profiles" then
        local sub, arg = rest:match("^(%S+)%s*(.*)")
        sub = (sub or ""):lower()
        arg = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")

        if sub == "save" and arg ~= "" then
            EnsureDB()
            local ok, msg = EC_SaveProfile(arg)
            PrintNice(msg)
        elseif sub == "load" and arg ~= "" then
            EnsureDB()
            local ok, msg = EC_LoadProfile(arg)
            PrintNice(msg)
        elseif sub == "delete" and arg ~= "" then
            EnsureDB()
            local ok, msg = EC_DeleteProfile(arg)
            PrintNice(msg)
        elseif sub == "list" or sub == "" then
            EnsureDB()
            PrintNice("Whitelist Profiles:")
            local names = {}
            for name in pairs(DB.whitelistProfiles) do
                if type(name) == "string" then
                    names[#names + 1] = name
                end
            end
            table.sort(names, function(a, b)
                return a:lower() < b:lower()
            end)
            for i = 1, #names do
                local wlCount = EC_CountItems(DB.whitelistProfiles[names[i]])
                local blCount = DB.blacklistProfiles[names[i]] and EC_CountItems(DB.blacklistProfiles[names[i]]) or 0
                local tag = (names[i] == DB.activeProfileName) and " |cff00ff00(active)|r" or ""
                PrintNicef("  |cffffff00%s|r - %d whitelist, %d blacklist%s", names[i], wlCount, blCount, tag)
            end
        else
            PrintNice("Usage: /ec profile save|load|delete|list <name>")
        end
        return
    end

    if cmd == "bugreport" then
        EC_ShowBugReport()
        return
    end

    if cmd == "clean" then
        EnsureDB()
        local conflicts = EC_ScanListConflicts()
        EC_PrintConflictReport(conflicts)
        if rest == "apply" and #conflicts > 0 then
            local removed = EC_ApplyCleanResolution(conflicts)
            PrintNicef(
                "Removed |cffffff00%d|r duplicate entr%s (precedence: blacklist > deleteList > whitelist).",
                removed,
                removed == 1 and "y" or "ies"
            )
            local wp = _G["EbonClearanceOptionsWhitelist"]
            if wp and wp.listUI then
                wp.listUI:Refresh()
            end
            local bp = _G["EbonClearanceOptionsBlacklist"]
            if bp and bp.listUI then
                bp.listUI:Refresh()
            end
        elseif #conflicts > 0 then
            PrintNice("Run |cffffff00/ec clean apply|r to auto-resolve (blacklist > deleteList > whitelist).")
        end
        return
    end

    -- Unknown subcommand - open options
    InterfaceOptionsFrame_OpenToCategory(MainOptions)
    InterfaceOptionsFrame_OpenToCategory(MainOptions)
end

SLASH_ECDEBUG1 = "/ecdebug"
SlashCmdList["ECDEBUG"] = function()
    if not DB then
        PrintNice("|cffff4444DB not loaded.|r")
        return
    end
    PrintNice("|cffffff00=== EbonClearance Debug ===|r")
    PrintNice("whitelistQualityEnabled: " .. tostring(DB.whitelistQualityEnabled))
    PrintNice("whitelistMinQuality: " .. tostring(DB.whitelistMinQuality))

    -- Print whitelist contents
    local wlCount = 0
    for k, v in pairs(DB.whitelist or {}) do
        local n = GetItemInfo(k) or ("ItemID:" .. tostring(k))
        PrintNicef("  Whitelist[%s] = %s  (%s)", tostring(k), tostring(v), n)
        wlCount = wlCount + 1
    end
    if wlCount == 0 then
        PrintNice("  (whitelist is empty)")
    end

    -- Scan bags and check which items would be sold
    PrintNice("|cffffff00--- Bag scan ---|r")
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag)
        for slot = 1, slots do
            local itemID = GetContainerItemID(bag, slot)
            if itemID then
                local _, itemCount, locked = GetContainerItemInfo(bag, slot)
                if itemCount and itemCount > 0 and not locked then
                    local name, _, quality, _, _, _, _, _, _, _, sellPrice = GetItemInfo(itemID)
                    local junk = (quality ~= nil) and (quality == 0) and sellPrice and sellPrice > 0
                    local wp = IsInSet(DB.whitelist, itemID)
                    local qp = false
                    if DB.whitelistQualityEnabled == true and sellPrice and sellPrice > 0 then
                        qp = (quality ~= nil) and (quality <= (DB.whitelistMinQuality or 1))
                    end
                    if junk or wp or qp then
                        PrintNicef(
                            "|cff00ff00SELL|r bag=%d slot=%d id=%d q=%s junk=%s wp=%s qp=%s sp=%s name=%s",
                            bag,
                            slot,
                            itemID,
                            tostring(quality),
                            tostring(junk),
                            tostring(wp),
                            tostring(qp),
                            tostring(sellPrice),
                            tostring(name)
                        )
                    end
                end
            end
        end
    end
    PrintNice("|cffffff00=== End Debug ===|r")
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGOUT")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("MERCHANT_SHOW")
f:RegisterEvent("MERCHANT_CLOSED")
-- BAG_UPDATE drives auto-loot-cycle bag-full detection. Cheap handler;
-- early-returns unless STATE.LOOTING + cycle enabled. See EC_HandleBagFullForCycle.
f:RegisterEvent("BAG_UPDATE")
-- UNIT_AURA fires per-unit. The player-only form is much cheaper in raids
-- than an unfiltered registration; fall back on clients that lack it.
if f.RegisterUnitEvent then
    f:RegisterUnitEvent("UNIT_AURA", "player")
else
    f:RegisterEvent("UNIT_AURA")
end

f:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == ADDON_NAME then
            EnsureDB()
            -- Scrub orphans from the v2.2.0 scoping bug where these names
            -- briefly leaked into _G. Harmless if absent. See v2.2.1 fix.
            _G.EC_summonGoblinPending = nil
            _G.EC_summonGoblinTimer = nil
            HookDeletePopupOnce()
            if ApplyGreedyChatFilter then
                ApplyGreedyChatFilter()
            end
            EC_CreateMinimapButton()
            EC_InstallTooltipHookOnce()
            EC_CreateLDBLauncher()
            EC_CreateTargetMerchantButton()
            EC_InstallBagContextHookOnce()
        end
    elseif event == "PLAYER_LOGOUT" then
        if DB then
            EbonClearanceDB = DB
        end
    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        EnsureDB()
        if EC_InstallGreedyMuteOnce then
            EC_InstallGreedyMuteOnce()
        end
    elseif event == "BAG_UPDATE" then
        -- Bag-full handler runs first; the open driver yields via the `running`
        -- guard if the vendor cycle is already active.
        EC_HandleBagFullForCycle()
        EC_HandleAutoOpenContainers()
    elseif event == "MERCHANT_SHOW" then
        EnsureDB()
        EC_merchantReminderPending = false
        EC_batchTotalSold = 0
        EC_batchTotalGold = 0
        EC_keepBagsFlag = true
        if DB and DB.autoLootCycle then
            EC_lootCycleState = STATE.SELLING
        end
        if not EC_IsAddonEnabledForChar() then
            return
        end
        EC_InstallGreedyMuteOnce()
        StartRun()
    elseif event == "UNIT_AURA" then
        local unit = ...
        if unit == "player" and DB and DB.summonGreedy and EC_IsAddonEnabledForChar() then
            local mounted = IsMounted()
            if mounted and not EC_wasMounted then
                DismissGreedyScavenger()
                EC_mountDismissTime = GetTime()
            elseif not mounted and EC_wasMounted then
                EC_SummonGreedyWithDelay()
            end
            EC_wasMounted = mounted
        end
    elseif event == "MERCHANT_CLOSED" then
        running = false
        worker:Hide()
        pendingDelete = nil
        -- Reset cycle state so the stuck detection can re-summon the Scavenger
        if EC_lootCycleState == STATE.SELLING then
            EC_lootCycleState = STATE.IDLE
        end
        -- Reopen bags after merchant closes
        if DB and DB.keepBagsOpen and EC_keepBagsFlag then
            EC_Delay(0.8, EC_OpenAllBags)
        end
        EC_keepBagsFlag = false
    end

    if event == "PLAYER_LOGIN" then
        EC_Delay(1, function()
            DEFAULT_CHAT_FRAME:AddMessage("|cffffd100EbonClearance Enabled|r - Use |cff00ff00/ec|r to configure.")
        end)
    end
end)
