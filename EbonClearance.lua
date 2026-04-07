local ADDON_NAME = "EbonClearance"
local TARGET_NAME = "Goblin Merchant"
local PET_NAME = "Greedy scavenger"

local EHS_GetPlayerName
local EHS_IsAddonEnabledForChar

local EHS_greedyMessages = {}
local EHS_greedyFiltersInstalled = false

local function EHS_StripCodes(s)
    if type(s) ~= "string" then return nil end
    return s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h", ""):gsub("|h", "")
end

local PET_NAME_LC = PET_NAME:lower()
local function EHS_IsGreedyAuthor(author)
    if type(author) ~= "string" then return false end
    author = EHS_StripCodes(author)
    if not author or author == "" then return false end
    return author:lower() == PET_NAME_LC
end

local function EHS_TrackGreedySpeech(msg)
    msg = EHS_StripCodes(msg)
    if not msg or msg == "" then return end
    msg = msg:lower()
    EHS_greedyMessages[msg] = true
end

local function EHS_GreedyEventFilter(self, event, msg, author, ...)
    local hideChat = true
    local hideBubbles = true
    if DB then
        hideChat = (DB.muteGreedy == true) or (DB.hideGreedyChat == true)
        hideBubbles = (DB.muteGreedy == true) or (DB.hideGreedyBubbles == true)
    end

    if EHS_IsGreedyAuthor(author) then
        if hideBubbles and type(msg) == "string" then
            EHS_TrackGreedySpeech(msg)
        end
        if hideChat then
            return true
        end
    end

    if type(msg) == "string" then
        local clean = EHS_StripCodes(msg):lower()
        if clean:find("greedy scavenger", 1, true) and (clean:find(" says", 1, true) or clean:find(" yells", 1, true) or clean:find(" whispers", 1, true)) then
            if hideBubbles then
                local said = clean:match("greedy scavenger%s*says[:%s]*(.*)") or clean:match("greedy scavenger%s*yells[:%s]*(.*)") or clean:match("greedy scavenger%s*whispers[:%s]*(.*)")
                if said then EHS_TrackGreedySpeech(said) end
            end
            if hideChat then
                return true
            end
        end
    end

    return false
end

local function EHS_InstallGreedyMuteOnce()
    if EHS_greedyFiltersInstalled then return end
    EHS_greedyFiltersInstalled = true

    ChatFrame_AddMessageEventFilter("CHAT_MSG_MONSTER_SAY", EHS_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_MONSTER_YELL", EHS_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_MONSTER_WHISPER", EHS_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_MONSTER_EMOTE", EHS_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_MONSTER_PARTY", EHS_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_SAY", EHS_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_YELL", EHS_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_TEXT_EMOTE", EHS_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_EMOTE", EHS_GreedyEventFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", EHS_GreedyEventFilter)
end

local EHS_bubbleFrame = CreateFrame("Frame")
local EHS_killedBubbles = setmetatable({}, { __mode = "k" })

local function EHS_KillBubbleFrame(frame)
    if not frame or frame.__EHS_killed then return end
    frame.__EHS_killed = true
    EHS_killedBubbles[frame] = true

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
EHS_bubbleFrame.elapsed = 0
EHS_bubbleFrame:SetScript("OnUpdate", function(self, elapsed)
    local hideBubbles = true
    if DB then
        hideBubbles = (DB.muteGreedy == true) or (DB.hideGreedyBubbles == true)
    end
    if not hideBubbles then return end

    for bubble in pairs(EHS_killedBubbles) do
        if bubble and bubble.IsShown and bubble:IsShown() then
            bubble:SetAlpha(0)
            bubble:Hide()
        end
    end

    if not next(EHS_greedyMessages) then return end

    self.elapsed = (self.elapsed or 0) + elapsed
    if self.elapsed < 0.05 then return end
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
                        local clean = EHS_StripCodes(text):lower()
                        if EHS_greedyMessages[clean] then
                            EHS_KillBubbleFrame(child)
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
    if EHS_IsGreedyAuthor(author) then
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

local function EHS_NormalizeBool(v, default)
    if v == true or v == 1 then return true end
    if v == false or v == 0 then return false end
    if v == nil then return default end
    return default
end

local function EnsureDB()
    -- Migrate data from old addon name if present
    if EbonholdStuffDB and not EbonClearanceDB then
        EbonClearanceDB = EbonholdStuffDB
        EbonholdStuffDB = nil
    end
    if EbonClearanceDB == nil then EbonClearanceDB = {} end
    DB = EbonClearanceDB

    if type(DB.deleteList) ~= "table" then DB.deleteList = {} end
    if type(DB.allowedChars) ~= "table" then DB.allowedChars = {} end

    if type(DB.totalCopper) ~= "number" then DB.totalCopper = 0 end


    if type(DB.totalItemsSold) ~= "number" then DB.totalItemsSold = 0 end
    if type(DB.totalItemsDeleted) ~= "number" then DB.totalItemsDeleted = 0 end
    if type(DB.totalRepairs) ~= "number" then DB.totalRepairs = 0 end
    if type(DB.totalRepairCopper) ~= "number" then DB.totalRepairCopper = 0 end

    if type(DB.soldItemCounts) ~= "table" then DB.soldItemCounts = {} end
    if type(DB.deletedItemCounts) ~= "table" then DB.deletedItemCounts = {} end

    if type(DB.repairGear) ~= "boolean" then DB.repairGear = true end

    if type(DB.enableDeletion) ~= "boolean" then DB.enableDeletion = true end
    if type(DB.summonGreedy) ~= "boolean" then DB.summonGreedy = true end
    if type(DB.summonDelay) ~= "number" then DB.summonDelay = 1.6 end

    if type(DB.vendorInterval) ~= "number" then DB.vendorInterval = 0.015 end
    if DB.merchantMode ~= "goblin" and DB.merchantMode ~= "any" and DB.merchantMode ~= "both" then DB.merchantMode = "goblin" end

    if type(DB.muteGreedy) ~= "boolean" then DB.muteGreedy = true end
    if type(DB.hideGreedyChat) ~= "boolean" then DB.hideGreedyChat = DB.muteGreedy end
    if type(DB.hideGreedyBubbles) ~= "boolean" then DB.hideGreedyBubbles = DB.muteGreedy end

    if type(DB.enabled) ~= "boolean" then DB.enabled = true end
    if type(DB.enableOnlyListedChars) ~= "boolean" then DB.enableOnlyListedChars = false end

    if type(DB.inventoryWorthTotal) ~= "number" then DB.inventoryWorthTotal = 0 end
    if type(DB.inventoryWorthCount) ~= "number" then DB.inventoryWorthCount = 0 end
    if type(DB.whitelist)               ~= "table"   then DB.whitelist               = {}    end
    if type(DB.whitelistMinQuality)     ~= "number"  then DB.whitelistMinQuality     = 1     end
    if type(DB.whitelistQualityEnabled) ~= "boolean" then DB.whitelistQualityEnabled = false end
    if type(DB.minimapButtonAngle)      ~= "number"  then DB.minimapButtonAngle      = 220   end
    if type(DB.keepBagsOpen)            ~= "boolean" then DB.keepBagsOpen            = true  end

    -- Whitelist profiles migration
    if type(DB.whitelistProfiles) ~= "table" then
        DB.whitelistProfiles = {}
        local snapshot = {}
        for k, v in pairs(DB.whitelist) do snapshot[k] = v end
        DB.whitelistProfiles["Default"] = snapshot
        DB.activeProfileName = "Default"
    end
    if type(DB.activeProfileName) ~= "string" then DB.activeProfileName = "Default" end

if not DB._seededLists then
    if DB.deleteList and not next(DB.deleteList) then
        DB.deleteList[300581] = true
        DB.deleteList[300574] = true
    end
    DB._seededLists = true
end

end

-- Keep bags open when merchant closes
local EC_keepBagsFlag = false

local function EC_OpenAllBags()
    if OpenAllBags then
        OpenAllBags()
    elseif OpenBackpack then
        OpenBackpack()
        for i = 1, 4 do
            if OpenBag then OpenBag(i) end
        end
    end
end

EHS_GetPlayerName = function()
    local n = UnitName("player")
    if not n or n == "" then return "" end
    return n
end

local function EHS_IsCharacterAllowed()
    if not DB or not DB.enableOnlyListedChars then
        return true
    end
    local name = EHS_GetPlayerName()
    return DB.allowedChars and DB.allowedChars[name] == true
end

EHS_IsAddonEnabledForChar = function()
    if DB and DB.enabled == false then return false end
    return EHS_IsCharacterAllowed()
end

local function IsInSet(setTable, itemID)
    if not itemID or not setTable then return false end
    local v = setTable[itemID]
    return (v == true) or (v == 1)
end

local function AddToSet(setTable, itemID)
    if itemID then setTable[itemID] = true end
end

local function RemoveFromSet(setTable, itemID)
    if itemID then setTable[itemID] = nil end
end

local function SortedKeys(setTable)
    local t = {}
    for k in pairs(setTable) do
        if type(k) == "number" then t[#t+1] = k end
    end
    table.sort(t)
    return t
end

-- Whitelist profile functions
local function EC_ValidateProfileName(name)
    if type(name) ~= "string" then return false, "Invalid name." end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return false, "Profile name cannot be empty." end
    if name:find("[:|]") then return false, "Profile name cannot contain : or | characters." end
    return true, name
end

local function EC_CountItems(tbl)
    local n = 0
    for k, v in pairs(tbl) do
        if type(k) == "number" and (v == true or v == 1) then n = n + 1 end
    end
    return n
end

local function EC_SaveProfile(name)
    local ok, cleaned = EC_ValidateProfileName(name)
    if not ok then return false, cleaned end
    name = cleaned
    local snapshot = {}
    for k, v in pairs(DB.whitelist) do snapshot[k] = v end
    DB.whitelistProfiles[name] = snapshot
    DB.activeProfileName = name
    local count = EC_CountItems(snapshot)
    return true, string.format("Saved profile \"|cffffff00%s|r\" (%d items).", name, count)
end

local function EC_LoadProfile(name)
    if type(name) ~= "string" or not DB.whitelistProfiles[name] then
        return false, string.format("Profile \"%s\" not found.", tostring(name))
    end
    wipe(DB.whitelist)
    for k, v in pairs(DB.whitelistProfiles[name]) do
        DB.whitelist[k] = v
    end
    DB.activeProfileName = name
    local count = EC_CountItems(DB.whitelist)
    -- Refresh the whitelist panel if it exists
    local wp = _G["EbonClearanceOptionsWhitelist"]
    if wp and wp.listUI then wp.listUI:Refresh() end
    return true, string.format("Loaded profile \"|cffffff00%s|r\" (%d items).", name, count)
end

local function EC_DeleteProfile(name)
    if type(name) ~= "string" or not DB.whitelistProfiles[name] then
        return false, string.format("Profile \"%s\" not found.", tostring(name))
    end
    -- Count remaining profiles
    local count = 0
    for _ in pairs(DB.whitelistProfiles) do count = count + 1 end
    if count <= 1 then
        return false, "Cannot delete the only remaining profile."
    end
    DB.whitelistProfiles[name] = nil
    if DB.activeProfileName == name then
        DB.activeProfileName = next(DB.whitelistProfiles) or "Default"
    end
    return true, string.format("Deleted profile \"|cffffff00%s|r\".", name)
end

local function EC_RenameProfile(oldName, newName)
    if type(oldName) ~= "string" or not DB.whitelistProfiles[oldName] then
        return false, string.format("Profile \"%s\" not found.", tostring(oldName))
    end
    local ok, cleaned = EC_ValidateProfileName(newName)
    if not ok then return false, cleaned end
    newName = cleaned
    if newName == oldName then return true, "Name unchanged." end
    if DB.whitelistProfiles[newName] then
        return false, string.format("A profile named \"%s\" already exists.", newName)
    end
    DB.whitelistProfiles[newName] = DB.whitelistProfiles[oldName]
    DB.whitelistProfiles[oldName] = nil
    if DB.activeProfileName == oldName then
        DB.activeProfileName = newName
    end
    return true, string.format("Renamed \"|cffffff00%s|r\" to \"|cffffff00%s|r\".", oldName, newName)
end

local function CopperToColoredText(copper)
    if not copper or copper < 0 then copper = 0 end
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


local function EHS_CalcInventoryWorthCopper()
    local total = 0
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag)
        for slot = 1, slots do
            local itemID = GetContainerItemID(bag, slot)
            if itemID then
                local texture, itemCount, locked = GetContainerItemInfo(bag, slot)
                if itemCount and itemCount > 0 then
                    local name, link, quality, level, minLevel, itemType, subType, stackCount, equipLoc, icon, sellPrice = GetItemInfo(itemID)
                    if sellPrice and sellPrice > 0 then
                        total = total + (sellPrice * itemCount)
                    end
                end
            end
        end
    end
    return total
end

local function EHS_RecordInventoryWorthSample()
    if not DB then return end
    local worth = EHS_CalcInventoryWorthCopper()
    DB.inventoryWorthTotal = (DB.inventoryWorthTotal or 0) + worth
    DB.inventoryWorthCount = (DB.inventoryWorthCount or 0) + 1
end


local EHS_activeIDBox = nil
local EHS_Original_ChatEdit_InsertLink = ChatEdit_InsertLink

local function EHS_ExtractItemID(link)
    if type(link) ~= "string" then return nil end
    local id = link:match("item:(%d+)")
    if id then return tonumber(id) end
    return nil
end

ChatEdit_InsertLink = function(link)
    if EHS_activeIDBox and EHS_activeIDBox:IsShown() then
        local id = EHS_ExtractItemID(link)
        if id then
            EHS_activeIDBox:SetText(tostring(id))
            EHS_activeIDBox:HighlightText()
            return true
        end
    end
    return EHS_Original_ChatEdit_InsertLink(link)
end

local function SummonGreedyScavenger()
    local num = GetNumCompanions("CRITTER")
    if not num or num <= 0 then return end

    for i = 1, num do
        local creatureID, creatureName, spellID, icon, isSummoned = GetCompanionInfo("CRITTER", i)
        if creatureName == PET_NAME then
            if not isSummoned then
                CallCompanion("CRITTER", i)
            end
            return
        end
    end
end

local function EHS_SummonGreedyWithDelay()
    if not DB or not DB.summonGreedy then return end
    local d = tonumber(DB.summonDelay) or 1.6
    if d < 0 then d = 0 end
    EHS_Delay(d, SummonGreedyScavenger)
end

local EHS_delayFrame = CreateFrame("Frame")
local EHS_timers = {}

local function EHS_Delay(seconds, func)
    if type(func) ~= "function" then return end
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then
        func()
        return
    end
    EHS_timers[#EHS_timers + 1] = { t = seconds, f = func }
end

EHS_delayFrame:SetScript("OnUpdate", function(self, elapsed)
    if #EHS_timers == 0 then return end
    for i = #EHS_timers, 1, -1 do
        local item = EHS_timers[i]
        item.t = item.t - elapsed
        if item.t <= 0 then
            table.remove(EHS_timers, i)
            local ok, err = pcall(item.f)
        end
    end
end)

local function EHS_SummonGreedyWithDelay()
    if not DB or not DB.summonGreedy then return end
    EHS_Delay((DB and DB.summonDelay) or 1.6, SummonGreedyScavenger)
end



local pendingDelete = nil
local deletePopupHooked = false

local function HookDeletePopupOnce()
    if deletePopupHooked then return end
    deletePopupHooked = true

    local f = CreateFrame("Frame")
    f:SetScript("OnUpdate", function()
        local popup = StaticPopup1
        if popup and popup:IsShown() and popup.which == "DELETE_ITEM" and pendingDelete then
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

local running = false
local queue = {}
local queueIndex = 1
local goldThisVendoring = 0

local worker = CreateFrame("Frame")
worker:Hide()

local function BuildQueue(junkOnly)
    wipe(queue)
    queueIndex = 1
    goldThisVendoring = 0
    -- Grey items (quality 0) are always sold as junk at any merchant.
    -- Whitelist/quality threshold selling only runs when the merchant mode allows it.
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag)
        for slot = 1, slots do
            local itemID = GetContainerItemID(bag, slot)
            if itemID then
                local texture, itemCount, locked = GetContainerItemInfo(bag, slot)
                if itemCount and itemCount > 0 and not locked then
                    local name, link, quality, level, minLevel, itemType, subType,
                          stackCount, equipLoc, icon, sellPrice = GetItemInfo(itemID)
                    local isJunk = (quality ~= nil) and (quality == 0) and sellPrice and sellPrice > 0
                    local whitelistPass = not junkOnly and IsInSet(DB.whitelist, itemID)
                    local qualityPass = false
                    if not junkOnly and DB.whitelistQualityEnabled == true and sellPrice and sellPrice > 0 then
                        qualityPass = (quality ~= nil) and (quality <= DB.whitelistMinQuality)
                    end
                    if isJunk or qualityPass or whitelistPass then
                        queue[#queue+1] = {
                            type   = "sell",
                            bag    = bag,
                            slot   = slot,
                            itemID = itemID,
                            count  = itemCount,
                            price  = sellPrice or 0
                        }
                        if sellPrice and sellPrice > 0 then
                            goldThisVendoring = goldThisVendoring + (sellPrice * itemCount)
                        end
                    end
                end
            end
        end
    end

    if DB.enableDeletion == true then
        for bag = 0, 4 do
            local slots = GetContainerNumSlots(bag)
            for slot = 1, slots do
                local itemID = GetContainerItemID(bag, slot)
                if itemID and IsInSet(DB.deleteList, itemID) then
                    local texture, itemCount, locked = GetContainerItemInfo(bag, slot)
                    if itemCount and itemCount > 0 and not locked then
                        queue[#queue+1] = {
                            type = "delete",
                            bag = bag,
                            slot = slot,
                            itemID = itemID,
                            count = itemCount
                        }
                    end
                end
            end
        end
    end
end

local function FinishRun()
    running = false
    worker:Hide()

    DB.totalCopper = (DB.totalCopper or 0) + (goldThisVendoring or 0)

    PrintNice(string.format("Vendoring complete! Sold |cffffff00%d|r items. |cffb6ffb6Money Collected:|r %s",
        #queue, CopperToColoredText(goldThisVendoring)))

    EHS_SummonGreedyWithDelay()
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

    if action.type == "sell" then
        
        DB.totalItemsSold = (DB.totalItemsSold or 0) + (action.count or 1)
        DB.soldItemCounts = DB.soldItemCounts or {}
        if action.itemID then
            DB.soldItemCounts[action.itemID] = (DB.soldItemCounts[action.itemID] or 0) + (action.count or 1)
        end
        UseContainerItem(action.bag, action.slot)

    elseif action.type == "delete" then
        
        DB.totalItemsDeleted = (DB.totalItemsDeleted or 0) + (action.count or 1)
        DB.deletedItemCounts = DB.deletedItemCounts or {}
        if action.itemID then
            DB.deletedItemCounts[action.itemID] = (DB.deletedItemCounts[action.itemID] or 0) + (action.count or 1)
        end
        ClearCursor()
        PickupContainerItem(action.bag, action.slot)
        local cursorType, cursorID = GetCursorInfo()

        if cursorType == "item" then
            pendingDelete = { bag = action.bag, slot = action.slot, itemID = action.itemID }
            DeleteCursorItem()
            ClearCursor()
        else
            ClearCursor()
            pendingDelete = nil
        end
    end

    queueIndex = queueIndex + 1
end

worker:SetScript("OnUpdate", function(self, elapsed)
    self.t = (self.t or 0) + elapsed
    local interval = (DB and DB.vendorInterval) or 0.015
    if interval < 0.005 then interval = 0.005 end
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

local function EHS_IsMerchantAllowed()
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

local function StartRun()
    if not EHS_IsAddonEnabledForChar() then return end
    if running then return end
    if not ShouldRunNow() then return end

    local merchantAllowed = EHS_IsMerchantAllowed()

    HookDeletePopupOnce()

    running = true


    EHS_RecordInventoryWorthSample()


    if DB and DB.repairGear == true and CanMerchantRepair and CanMerchantRepair() and GetRepairAllCost and RepairAllItems then
        local repairCost, canRepair = GetRepairAllCost()
        if canRepair and repairCost and repairCost > 0 and GetMoney and GetMoney() >= repairCost then
            RepairAllItems()
            DB.totalRepairs = (DB.totalRepairs or 0) + 1
            DB.totalRepairCopper = (DB.totalRepairCopper or 0) + repairCost
        end
    end

    BuildQueue(not merchantAllowed)

    if #queue == 0 then
        PrintNice("Found nothing to sell.")
        running = false
        if UnitExists("target") and UnitName("target") == TARGET_NAME and MerchantFrame and MerchantFrame:IsShown() then
            EHS_SummonGreedyWithDelay()
        end
        return
    end

    worker.t = 0
    worker:Show()
end

local MainOptions = CreateFrame("Frame", "EbonClearanceOptionsMain", InterfaceOptionsFramePanelContainer)
MainOptions.name = "EbonClearance"

local function MakeHeader(parent, text, y)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    fs:SetPoint("TOPLEFT", 16, y)
    fs:SetText(text)
    return fs
end

local EC_PANEL_WIDTH = 440  -- default fallback; updated dynamically in OnShow

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
    if fs.SetWordWrap then fs:SetWordWrap(true) end
    fs:SetText(text)
    return fs
end

local function StyleInputBox(editBox)
    if not editBox then return end
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
        local mid  = _G[n .. "Middle"]
        local right= _G[n .. "Right"]
        if left and left.SetDrawLayer then left:SetDrawLayer("BACKGROUND") end
        if mid and mid.SetDrawLayer then mid:SetDrawLayer("BACKGROUND") end
        if right and right.SetDrawLayer then right:SetDrawLayer("BACKGROUND") end
    end
    editBox:SetFrameLevel((editBox:GetParent() and editBox:GetParent():GetFrameLevel() or editBox:GetFrameLevel()) + 2)

    
    if editBox.GetText and editBox.SetText then
        local t = editBox:GetText() or ""
        editBox:SetText(t)
        if editBox.SetCursorPosition then editBox:SetCursorPosition(0) end
    end
end



local function CreateListUI(parent, titleText, setTableName, x, y)
    local w = EC_PANEL_WIDTH - x
    local box = CreateFrame("Frame", nil, parent)
    box:SetPoint("TOPLEFT", x, y)
    box:SetSize(w, 320)

    local title = box:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOPLEFT", 0, 0)
    title:SetText(titleText)

    local input = CreateFrame("EditBox", "EbonClearanceIDInput_"..setTableName, box, "InputBoxTemplate")
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

    input:SetScript("OnEditFocusGained", function(self) EHS_activeIDBox = self end)
    input:SetScript("OnEditFocusLost", function(self) if EHS_activeIDBox == self then EHS_activeIDBox = nil end end)
    input:SetScript("OnReceiveDrag", function(self)
        local ctype, cid = GetCursorInfo()
        if ctype == "item" and cid then
            self:SetText(tostring(cid))
            self:HighlightText()
            ClearCursor()
        end
    end)

    local sortMode = "id_asc"  -- default: sort by ID ascending

    -- Search row: Search box then Clear, Sort label, ID, Name buttons all on one line
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

    local clearSearch = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    clearSearch:SetSize(46, 20)
    clearSearch:SetPoint("RIGHT", sortIDBtn, "LEFT", -8, 0)
    clearSearch:SetText("Clear")

    local search = CreateFrame("EditBox", "EbonClearanceSearchInput_"..setTableName, box, "InputBoxTemplate")
    search:SetAutoFocus(false)
    search:SetHeight(20)
    search:SetPoint("LEFT", searchLabel, "RIGHT", 8, 0)
    search:SetPoint("RIGHT", clearSearch, "LEFT", -8, 0)
    search:SetMaxLetters(40)
    search:SetText("")
    StyleInputBox(search)

    local scroll = CreateFrame("ScrollFrame", "EbonClearanceListScroll_"..setTableName, box, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -78)
    scroll:SetPoint("BOTTOMRIGHT", -26, 8)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(w - 26, 1)
    scroll:SetScrollChild(content)

    local rowPool = {}
    local activeRows = 0

    local function GetRow(index)
        if rowPool[index] then return rowPool[index] end
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(w - 26, 22)

        local rm = CreateFrame("Button", "EbonClearanceListRM_"..setTableName.."_"..index, content, "UIPanelButtonTemplate")
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
        if not searchText or searchText == "" then return true end
        local idStr = tostring(id or "")
        if idStr:find(searchText, 1, true) then return true end
        local nameStr = tostring(name or ""):lower()
        if nameStr:find(searchText, 1, true) then return true end
        return false
    end

    local pendingRetry = false

    local function Refresh()
        HideAllRows()

        local searchText = ""
        if search and search.GetText then
            searchText = (search:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
        end

        local setTable = DB[setTableName]
        local keys = {}
        for k in pairs(setTable) do
            if type(k) == "number" then keys[#keys+1] = k end
        end
        if sortMode == "id_desc" then
            table.sort(keys, function(a, b) return a > b end)
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
            table.sort(keys)  -- id_asc (default)
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
                    GameTooltip:SetHyperlink("item:"..id..":0:0:0:0:0:0:0")
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
                    DB[setTableName][id] = nil
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
            EHS_Delay(1.5, function()
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
        DB[setTableName][v] = true
        input:SetText("")
        Refresh()
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)

    input:SetScript("OnEnterPressed", function()
        addBtn:Click()
        input:ClearFocus()
    end)

    search:SetScript("OnTextChanged", function()
        Refresh()
    end)

    clearSearch:SetScript("OnClick", function()
        search:SetText("")
        Refresh()
    end)

    sortIDBtn:SetScript("OnClick", function()
        if sortMode == "id_asc" then sortMode = "id_desc" else sortMode = "id_asc" end
        sortIDBtn:SetText(sortMode == "id_asc" and "ID \226\150\178" or "ID \226\150\188")
        sortNameBtn:SetText("Name \226\150\178")
        Refresh()
    end)
    sortNameBtn:SetScript("OnClick", function()
        if sortMode == "name_asc" then sortMode = "name_desc" else sortMode = "name_asc" end
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

local function AddSlider(parent, name, anchor, labelText, minVal, maxVal, step, getter, setter, yOff)
    local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    s:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yOff or -16)
    s:SetMinMaxValues(minVal, maxVal)
    if s.SetValueStep then s:SetValueStep(step) end
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
    s:SetValue(getter())

    local low = _G[name .. "Low"]
    local high = _G[name .. "High"]
    local text = _G[name .. "Text"]

    if low then low:SetText(string.format("%.3fs", minVal)) end
    if high then high:SetText(string.format("%.3fs", maxVal)) end

    local function RefreshText(v)
        if text then
            text:SetText(labelText .. ": " .. string.format("%.3fs", v))
        end
    end
    RefreshText(getter())

    s:SetScript("OnValueChanged", function(self, value)
        value = tonumber(value) or minVal
        if step and step > 0 then
            value = math.floor((value / step) + 0.5) * step
        end
        if value < minVal then value = minVal end
        if value > maxVal then value = maxVal end
        setter(value)
        RefreshText(value)
    end)

    return s
end


local function EHS_UpdateMinimapPos()
    local btn = _G["EbonClearanceMinimapButton"]
    if not btn then return end
    local angle = math.rad(DB and DB.minimapButtonAngle or 220)
    local x = math.cos(angle) * 80
    local y = math.sin(angle) * 80
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function EHS_CreateMinimapButton()
    if not DB then return end
    if _G["EbonClearanceMinimapButton"] then return end  -- only create once

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

    EHS_UpdateMinimapPos()

    local dragging = false

    btn:SetScript("OnDragStart", function(self)
        dragging = true
    end)

    btn:SetScript("OnDragStop", function(self)
        dragging = false
        EHS_UpdateMinimapPos()
    end)

    btn:SetScript("OnUpdate", function(self)
        if not dragging then return end
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
        if DB then DB.minimapButtonAngle = angle end
        EHS_UpdateMinimapPos()
    end)

    btn:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            InterfaceOptionsFrame_OpenToCategory(MainOptions)
            InterfaceOptionsFrame_OpenToCategory(MainOptions)
        elseif button == "RightButton" then
            if not DB then return end
            DB.enabled = not DB.enabled
            local state = DB.enabled
                and "|cff00ff00Enabled|r"
                or  "|cffff4444Disabled|r"
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
        local stateStr = (DB and DB.enabled ~= false)
            and "|cff00ff00Enabled|r"
            or  "|cffff4444Disabled|r"
        GameTooltip:AddLine("Status: " .. stateStr)
        GameTooltip:Show()
    end)

    btn:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)
end

MainOptions:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()

    local function GetMostItem(countTable)
        local bestID, bestCount = nil, 0
        if type(countTable) ~= "table" then return nil, 0 end
        for id, cnt in pairs(countTable) do
            if type(id) == "number" and type(cnt) == "number" and cnt > bestCount then
                bestID, bestCount = id, cnt
            end
        end
        return bestID, bestCount
    end

    local function ItemLabel(id)
        if not id then return "None" end
        local name = GetItemInfo(id)
        if name then
            return string.format("|cff24ffb6%d|r - %s", id, name)
        end
        return "ItemID: " .. tostring(id)
    end

    local function RefreshStats()
        if not self.statsMoney then return end
        self.statsMoney:SetText("Total Money Made: " .. CopperToColoredText(DB.totalCopper or 0))
        self.statsSold:SetText("Total Items Sold: " .. tostring(DB.totalItemsSold or 0))
        self.statsDeleted:SetText("Total Items Deleted: " .. tostring(DB.totalItemsDeleted or 0))
        self.statsRepairs:SetText("Total Repairs: " .. tostring(DB.totalRepairs or 0))
        self.statsRepairCost:SetText("Total Repair Cost: " .. CopperToColoredText(DB.totalRepairCopper or 0))
        if self.statsAvgWorth then
            local cnt = DB.inventoryWorthCount or 0
            local total = DB.inventoryWorthTotal or 0
            local avg = 0
            if cnt > 0 then avg = math.floor((total / cnt) + 0.5) end
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

    MakeHeader(self, "EbonClearance v2.0.2", -16)

    local welcomeLabel = MakeLabel(self, "Welcome to |cffb6ffb6EbonClearance|r! Whitelist-based vendoring and item management.", 16, -44)
    local descLabel2 = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    descLabel2:SetPoint("TOPLEFT", welcomeLabel, "BOTTOMLEFT", 0, -4)
    descLabel2:SetWidth(EC_PANEL_WIDTH - 16)
    descLabel2:SetJustifyH("LEFT")
    descLabel2:SetJustifyV("TOP")
    if descLabel2.SetWordWrap then descLabel2:SetWordWrap(true) end
    descLabel2:SetText("Automatically sells non-whitelisted items at merchants. Configure which merchants to use under Merchant Settings.")

    local money = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    money:SetPoint("TOPLEFT", descLabel2, "BOTTOMLEFT", 0, -16)
    self.statsMoney = money

    local sold = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    sold:SetPoint("TOPLEFT", money, "BOTTOMLEFT", 0, -6)
    self.statsSold = sold

    local deleted = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    deleted:SetPoint("TOPLEFT", sold, "BOTTOMLEFT", 0, -6)
    self.statsDeleted = deleted

    local repairs = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    repairs:SetPoint("TOPLEFT", deleted, "BOTTOMLEFT", 0, -6)
    self.statsRepairs = repairs

    local repairCost = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    repairCost:SetPoint("TOPLEFT", repairs, "BOTTOMLEFT", 0, -6)
    self.statsRepairCost = repairCost

    local avgWorth = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    avgWorth:SetPoint("TOPLEFT", repairCost, "BOTTOMLEFT", 0, -6)
    self.statsAvgWorth = avgWorth


    local mostSold = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    mostSold:SetPoint("TOPLEFT", avgWorth, "BOTTOMLEFT", 0, -6)
    mostSold:SetWidth(EC_PANEL_WIDTH - 16)
    mostSold:SetJustifyH("LEFT")
    self.statsMostSold = mostSold

    local resetBtn = CreateFrame("Button", "EbonClearanceResetStatsBtn", self, "UIPanelButtonTemplate")
    resetBtn:SetSize(170, 22)
    resetBtn:SetPoint("TOPLEFT", mostSold, "BOTTOMLEFT", 0, -12)
    resetBtn:SetText("Reset All Stats")
    resetBtn:SetScript("OnClick", function()
        DB.totalCopper = 0
        DB.totalItemsSold = 0
        DB.totalItemsDeleted = 0
        DB.totalRepairs = 0
        DB.totalRepairCopper = 0
        DB.inventoryWorthTotal = 0
        DB.inventoryWorthCount = 0
        wipe(DB.soldItemCounts)
        wipe(DB.deletedItemCounts)
        RefreshStats()
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)

    -- Slash commands reference
    local cmdHeader = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    cmdHeader:SetPoint("TOPLEFT", resetBtn, "BOTTOMLEFT", 0, -16)
    cmdHeader:SetText("Slash Commands")

    local cmdText = self:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    cmdText:SetPoint("TOPLEFT", cmdHeader, "BOTTOMLEFT", 0, -6)
    cmdText:SetWidth(EC_PANEL_WIDTH - 16)
    cmdText:SetJustifyH("LEFT")
    if cmdText.SetWordWrap then cmdText:SetWordWrap(true) end
    cmdText:SetText(
        "|cffffff00/ec|r  Open settings\n" ..
        "|cffffff00/ec profile list|r  Show all saved profiles\n" ..
        "|cffffff00/ec profile save <name>|r  Save current whitelist as a profile\n" ..
        "|cffffff00/ec profile load <name>|r  Load a saved profile\n" ..
        "|cffffff00/ec profile delete <name>|r  Delete a profile\n" ..
        "|cffffff00/ecdebug|r  Show debug info and bag scan")

    RefreshStats()
end)

InterfaceOptions_AddCategory(MainOptions)


local MerchantPanel = CreateFrame("Frame", "EbonClearanceOptionsMerchant", InterfaceOptionsFramePanelContainer)
MerchantPanel.name = "Merchant Settings"
MerchantPanel.parent = "EbonClearance"

local EHS_MERCHANT_MODES = {
    { text = "|cffb6ffb6Goblin Merchant|r Only",   value = "goblin" },
    { text = "Normal Merchants Only",               value = "any"    },
    { text = "Both (All Merchants)",                value = "both"   },
}

MerchantPanel:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then
        if self.repairCB then self.repairCB:SetChecked(DB.repairGear) end
        if self.keepBagsCB then self.keepBagsCB:SetChecked(DB.keepBagsOpen) end
        if self.speedSlider then self.speedSlider:SetValue(DB.vendorInterval or 0.015) end
        if self.RefreshMerchantModeDropDown then self:RefreshMerchantModeDropDown() end
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
        for _, entry in ipairs(EHS_MERCHANT_MODES) do
            if entry.value == mode then return entry.text end
        end
        return EHS_MERCHANT_MODES[1].text
    end

    local function MerchantModeInit(frame, level)
        for _, entry in ipairs(EHS_MERCHANT_MODES) do
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

    local repairCB = CreateFrame("CheckButton", "EbonClearanceRepairGearCB", self, "InterfaceOptionsCheckButtonTemplate")
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

    local keepBagsCB = CreateFrame("CheckButton", "EbonClearanceKeepBagsOpenCB", self, "InterfaceOptionsCheckButtonTemplate")
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

    local speedSlider = AddSlider(self, "EbonClearanceVendoringSpeedSlider", keepBagsCB,
        "Vendoring Speed", 0.005, 0.250, 0.005,
        function() return DB.vendorInterval or 0.015 end,
        function(v) DB.vendorInterval = v end,
        -16)
    self.speedSlider = speedSlider
	speedSlider:SetWidth(200)
end)

InterfaceOptions_AddCategory(MerchantPanel)

local EHS_WHITELIST_QUALITIES = {
    { text = ColorTextByQuality(1, "White (Common)"),   value = 1 },
    { text = ColorTextByQuality(2, "Green (Uncommon)"), value = 2 },
    { text = ColorTextByQuality(3, "Blue (Rare)"),      value = 3 },
    { text = ColorTextByQuality(4, "Epic (Purple)"),    value = 4 },
}

local WhitelistPanel = CreateFrame("Frame", "EbonClearanceOptionsWhitelist", InterfaceOptionsFramePanelContainer)
WhitelistPanel.name = "Whitelist Settings"
WhitelistPanel.parent = "EbonClearance"

WhitelistPanel:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then
        if self.whitelistQualityCB then self.whitelistQualityCB:SetChecked(DB.whitelistQualityEnabled) end
        if self.RefreshQualityDropDown then self:RefreshQualityDropDown() end
        if self.listUI then self.listUI:Refresh() end
        return
    end
    self.inited = true

    MakeHeader(self, "Whitelist Settings", -16)

    local descLabel = MakeLabel(self,
        "Grey items are always sold as junk automatically. Items on the whitelist below are also sold by Item ID.",
        16, -44)

    local warnLabel = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    warnLabel:SetPoint("TOPLEFT", descLabel, "BOTTOMLEFT", 0, -6)
    warnLabel:SetWidth(EC_PANEL_WIDTH - 16)
    warnLabel:SetJustifyH("LEFT")
    warnLabel:SetJustifyV("TOP")
    if warnLabel.SetWordWrap then warnLabel:SetWordWrap(true) end
    warnLabel:SetText(
        "|cffff4444WARNING:|r When the quality threshold below is enabled, ALL items at or below the " ..
        "chosen quality level will be sold in addition to the whitelist. " ..
        "Use either the whitelist for selective selling, or the quality threshold for bulk selling.")

    local whitelistQualityCB = CreateFrame("CheckButton", "EbonClearanceWhitelistQualityCB",
        self, "InterfaceOptionsCheckButtonTemplate")
    whitelistQualityCB:SetPoint("TOPLEFT", warnLabel, "BOTTOMLEFT", 0, -8)
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
        if self.RefreshQualityDropDown then self:RefreshQualityDropDown() end
    end)
    self.whitelistQualityCB = whitelistQualityCB

    local ddLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    ddLabel:SetPoint("TOPLEFT", whitelistQualityCB, "BOTTOMLEFT", 0, -4)
    ddLabel:SetText("Sell items up to quality:")

    local qualityDD = CreateFrame("Frame", "EbonClearanceWhitelistQualityDropDown",
        self, "UIDropDownMenuTemplate")
    qualityDD:SetPoint("LEFT", ddLabel, "RIGHT", -8, -2)
    UIDropDownMenu_SetWidth(qualityDD, 160)

    UIDropDownMenu_Initialize(qualityDD, function(frame, level)
        local info = UIDropDownMenu_CreateInfo()
        for i = 1, #EHS_WHITELIST_QUALITIES do
            local opt = EHS_WHITELIST_QUALITIES[i]
            info.text    = opt.text
            info.value   = opt.value
            info.checked = (DB.whitelistMinQuality == opt.value)
            info.func    = function()
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
        if cur < 1 then cur = 1; DB.whitelistMinQuality = 1 end
        local label = EHS_WHITELIST_QUALITIES[1].text  -- fallback to White
        for i = 1, #EHS_WHITELIST_QUALITIES do
            if EHS_WHITELIST_QUALITIES[i].value == cur then
                label = EHS_WHITELIST_QUALITIES[i].text
                break
            end
        end
        UIDropDownMenu_SetSelectedValue(qualityDD, cur)
        UIDropDownMenu_SetText(qualityDD, label)
        if DB.whitelistQualityEnabled then
            if UIDropDownMenu_EnableDropDown  then UIDropDownMenu_EnableDropDown(qualityDD)  end
        else
            if UIDropDownMenu_DisableDropDown then UIDropDownMenu_DisableDropDown(qualityDD) end
        end
    end
    self:RefreshQualityDropDown()

    self.listUI = CreateListUI(self, "Whitelist Items", "whitelist", 16, -190)
    self.listUI:SetHeight(200)
    self.listUI:Refresh()

    local noteFS = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    noteFS:SetPoint("BOTTOMLEFT", 16, 8)
    noteFS:SetWidth(EC_PANEL_WIDTH - 16)
    noteFS:SetJustifyH("LEFT")
    noteFS:SetText("|cffaaaaaa Grey items are always sold as junk. Listed items are also sold regardless of the quality threshold.|r")
end)

InterfaceOptions_AddCategory(WhitelistPanel)

-- ============================================================
-- Whitelist Profiles Panel
-- ============================================================
local ProfilesPanel = CreateFrame("Frame", "EbonClearanceOptionsProfiles", InterfaceOptionsFramePanelContainer)
ProfilesPanel.name = "Whitelist Profiles"
ProfilesPanel.parent = "EbonClearance"

ProfilesPanel:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then
        if self.RefreshProfileList then self:RefreshProfileList() end
        return
    end
    self.inited = true

    MakeHeader(self, "Whitelist Profiles", -16)
    MakeLabel(self, "Save and load different whitelists as named profiles. Useful for swapping between farming locations.", 16, -44)

    -- Active profile indicator
    local activeLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    activeLabel:SetPoint("TOPLEFT", 16, -76)
    activeLabel:SetWidth(EC_PANEL_WIDTH - 16)
    activeLabel:SetJustifyH("LEFT")
    self.activeLabel = activeLabel

    -- Save row: input + Save button
    local saveLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    saveLabel:SetPoint("TOPLEFT", 16, -98)
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

    -- Status text
    local statusFS = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    statusFS:SetPoint("TOPLEFT", 16, -120)
    statusFS:SetWidth(EC_PANEL_WIDTH - 16)
    statusFS:SetJustifyH("LEFT")
    statusFS:SetText("")
    self.statusFS = statusFS

    -- Profile list scroll area
    local listLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    listLabel:SetPoint("TOPLEFT", 16, -140)
    listLabel:SetText("Saved Profiles")

    local scroll = CreateFrame("ScrollFrame", "EbonClearanceProfileListScroll", self, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -158)
    scroll:SetSize(EC_PANEL_WIDTH - 42, 160)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(EC_PANEL_WIDTH - 42, 1)
    scroll:SetScrollChild(content)

    local rowPool = {}
    local activeRows = 0
    local listW = EC_PANEL_WIDTH - 42

    local function GetRow(index)
        if rowPool[index] then return rowPool[index] end
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(listW, 22)

        local delBtn = CreateFrame("Button", "EbonClearanceProfileDel_"..index, content, "UIPanelButtonTemplate")
        delBtn:SetSize(58, 18)
        delBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        delBtn:SetText("Delete")

        local loadBtn = CreateFrame("Button", "EbonClearanceProfileLoad_"..index, content, "UIPanelButtonTemplate")
        loadBtn:SetSize(52, 18)
        loadBtn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
        loadBtn:SetText("Load")

        local text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        text:SetPoint("LEFT", row, "LEFT", 2, 0)
        text:SetPoint("RIGHT", loadBtn, "LEFT", -4, 0)
        text:SetJustifyH("LEFT")

        row.text = text
        row.loadBtn = loadBtn
        row.delBtn = delBtn
        rowPool[index] = row
        return row
    end

    local function HideAllRows()
        for i = 1, activeRows do
            if rowPool[i] then
                rowPool[i]:Hide()
                rowPool[i].loadBtn:Hide()
                rowPool[i].delBtn:Hide()
            end
        end
        activeRows = 0
    end

    -- Rename row
    local renameLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    renameLabel:SetPoint("TOPLEFT", 16, -328)
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
            if type(name) == "string" then names[#names + 1] = name end
        end
        table.sort(names, function(a, b) return a:lower() < b:lower() end)

        local shown = 0
        local rowY = -4
        for i = 1, #names do
            local pName = names[i]
            shown = shown + 1
            local row = GetRow(shown)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, rowY)

            local isActive = (pName == DB.activeProfileName)
            local count = EC_CountItems(DB.whitelistProfiles[pName])
            local label = isActive
                and string.format("|cff00ff00%s|r  |cff888888(%d items, active)|r", pName, count)
                or  string.format("|cffffff00%s|r  |cff888888(%d items)|r", pName, count)
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
                local ok, msg = EC_DeleteProfile(pName)
                statusFS:SetText(ok and ("|cff00ff00" .. msg .. "|r") or ("|cffff4444" .. msg .. "|r"))
                if ok then
                    PrintNice(msg)
                    PlaySound("igMainMenuOptionCheckBoxOn")
                end
                self:RefreshProfileList()
            end)

            row:Show()
            row.loadBtn:Show()
            row.delBtn:Show()
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

InterfaceOptions_AddCategory(ProfilesPanel)

-- ============================================================
-- Whitelist Import / Export Panel
-- ============================================================
local ImportExportPanel = CreateFrame("Frame", "EbonClearanceOptionsImportExport", InterfaceOptionsFramePanelContainer)
ImportExportPanel.name = "Whitelist Import/Export"
ImportExportPanel.parent = "EbonClearance"

local EC_EXPORT_PREFIX = "EC:"

local function EC_ExportWhitelist(listName)
    if not DB or not DB.whitelist then return "" end
    local ids = {}
    for k, v in pairs(DB.whitelist) do
        if type(k) == "number" and (v == true or v == 1) then
            ids[#ids + 1] = k
        end
    end
    table.sort(ids)
    local name = (listName and listName ~= "") and listName or "Unnamed"
    name = name:gsub("[:|]", "_")
    return EC_EXPORT_PREFIX .. name .. ":" .. table.concat(ids, ",")
end

local function EC_ImportWhitelist(str, mode)
    if type(str) ~= "string" or str == "" then return false, "Empty string." end
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
        if n and n > 0 then ids[#ids + 1] = n end
    end
    if #ids == 0 then
        return false, "No valid item IDs found."
    end
    if mode == "replace" then
        wipe(DB.whitelist)
    end
    local added = 0
    for i = 1, #ids do
        if not DB.whitelist[ids[i]] then
            added = added + 1
        end
        DB.whitelist[ids[i]] = true
    end
    return true, string.format("Imported |cffffff00%d|r items from \"%s\" (%d new).", #ids, name or "Unnamed", added)
end

ImportExportPanel:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then return end
    self.inited = true

    MakeHeader(self, "Whitelist Import / Export", -16)

    -- === EXPORT SECTION ===
    MakeLabel(self, "Export your current whitelist to a string. Give it a name so others know what it is.", 16, -44)

    local exportNameLabel = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    exportNameLabel:SetPoint("TOPLEFT", 16, -68)
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
    exportScroll:SetPoint("TOPLEFT", 16, -96)
    exportScroll:SetSize(EC_PANEL_WIDTH - 36, 50)

    local exportBox = CreateFrame("EditBox", "EbonClearanceExportBox", exportScroll)
    exportBox:SetAutoFocus(false)
    exportBox:SetMultiLine(true)
    exportBox:SetFontObject("GameFontHighlightSmall")
    exportBox:SetWidth(560)
    exportBox:SetText("")
    exportBox:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    exportScroll:SetScrollChild(exportBox)

    exportBtn:SetScript("OnClick", function()
        local str = EC_ExportWhitelist(exportNameBox:GetText())
        exportBox:SetText(str)
        exportBox:HighlightText()
        exportBox:SetFocus()
        PlaySound("igMainMenuOptionCheckBoxOn")
        local count = 0
        for k, v in pairs(DB.whitelist) do
            if (v == true or v == 1) then count = count + 1 end
        end
        PrintNice(string.format("Exported |cffffff00%d|r whitelist items. Copy the text above.", count))
    end)

    -- === IMPORT SECTION ===
    MakeLabel(self, "Paste an exported whitelist string below and click Import.", 16, -158)

    local importScroll = CreateFrame("ScrollFrame", "EbonClearanceImportScroll", self, "UIPanelScrollFrameTemplate")
    importScroll:SetPoint("TOPLEFT", 16, -178)
    importScroll:SetSize(EC_PANEL_WIDTH - 36, 50)

    local importBox = CreateFrame("EditBox", "EbonClearanceImportBox", importScroll)
    importBox:SetAutoFocus(false)
    importBox:SetMultiLine(true)
    importBox:SetFontObject("GameFontHighlightSmall")
    importBox:SetWidth(560)
    importBox:SetText("")
    importBox:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    importScroll:SetScrollChild(importBox)

    local importMergeBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
    importMergeBtn:SetSize(120, 22)
    importMergeBtn:SetPoint("TOPLEFT", 16, -236)
    importMergeBtn:SetText("Import (Merge)")

    local importReplaceBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
    importReplaceBtn:SetSize(120, 22)
    importReplaceBtn:SetPoint("LEFT", importMergeBtn, "RIGHT", 8, 0)
    importReplaceBtn:SetText("Import (Replace)")

    local statusFS = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    statusFS:SetPoint("TOPLEFT", 16, -264)
    statusFS:SetWidth(EC_PANEL_WIDTH - 16)
    statusFS:SetJustifyH("LEFT")
    statusFS:SetText("")

    importMergeBtn:SetScript("OnClick", function()
        local ok, msg = EC_ImportWhitelist(importBox:GetText(), "merge")
        statusFS:SetText(ok and ("|cff00ff00" .. msg .. "|r") or ("|cffff4444" .. msg .. "|r"))
        if ok then
            PlaySound("igMainMenuOptionCheckBoxOn")
            PrintNice(msg)
            local wp = _G["EbonClearanceOptionsWhitelist"]
            if wp and wp.listUI then wp.listUI:Refresh() end
        else
            PlaySound("igMainMenuOptionCheckBoxOff")
        end
    end)

    importReplaceBtn:SetScript("OnClick", function()
        local ok, msg = EC_ImportWhitelist(importBox:GetText(), "replace")
        statusFS:SetText(ok and ("|cff00ff00" .. msg .. "|r") or ("|cffff4444" .. msg .. "|r"))
        if ok then
            PlaySound("igMainMenuOptionCheckBoxOn")
            PrintNice(msg)
            local wp = _G["EbonClearanceOptionsWhitelist"]
            if wp and wp.listUI then wp.listUI:Refresh() end
        else
            PlaySound("igMainMenuOptionCheckBoxOff")
        end
    end)

    MakeLabel(self,
        "|cffaaaaaa'Merge' adds imported items to your existing whitelist. " ..
        "'Replace' clears your whitelist first, then adds the imported items.|r",
        16, -282)
end)

InterfaceOptions_AddCategory(ImportExportPanel)

local DeletePanel = CreateFrame("Frame", "EbonClearanceOptionsDeletion", InterfaceOptionsFramePanelContainer)
DeletePanel.name = "Deletion Settings"
DeletePanel.parent = "EbonClearance"

DeletePanel:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then
        if self.listUI then self.listUI:Refresh() end
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
    if delHint.SetWordWrap then delHint:SetWordWrap(true) end
    delHint:SetText("Add Items by Shift-Clicking an item, drag & drop into the text field below, or type the ItemID and press Add.")

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


InterfaceOptions_AddCategory(DeletePanel)


local ScavengerPanel = CreateFrame("Frame", "EbonClearanceOptionsScavenger", InterfaceOptionsFramePanelContainer)

ScavengerPanel.name = "Scavenger Settings"
ScavengerPanel.parent = "EbonClearance"

ScavengerPanel:SetScript("OnShow", function(self)
    EnsureDB()
    EC_UpdatePanelWidth()
    if self.inited then
        if self.sumCB then self.sumCB:SetChecked(DB.summonGreedy) end
        if self.delaySlider then self.delaySlider:SetValue(DB.summonDelay or 1.6) end
        if self.muteCB then self.muteCB:SetChecked(DB.muteGreedy) end
        if self.chatCB then self.chatCB:SetChecked(DB.hideGreedyChat) end
        if self.bubCB then self.bubCB:SetChecked(DB.hideGreedyBubbles) end
        return
    end
    self.inited = true

    MakeHeader(self, "Scavenger Settings", -16)
    MakeLabel(self, "Controls summoning and muting of |cffff7f7fGreedy Scavenger|r.", 16, -44)

    local sumCB = CreateFrame("CheckButton", "EbonClearanceSummonGreedyCB", self, "InterfaceOptionsCheckButtonTemplate")
    sumCB:SetPoint("TOPLEFT", 16, -76)
    sumCB:SetChecked(DB.summonGreedy)
    local st = _G[sumCB:GetName() .. "Text"]
    if st then
        st:SetText("Summon |cffff7f7fGreedy Scavenger|r after Vendoring")
        st:SetWidth(420)
        st:SetJustifyH("LEFT")
    end
    sumCB:SetScript("OnClick", function()
        DB.summonGreedy = sumCB:GetChecked() and true or false
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)
    self.sumCB = sumCB
    


    local chatCB = AddCheckbox(self, "EbonClearanceHideGreedyChatCB", sumCB, "Hide |cffff7f7fGreedy Scavenger|r's chat messages",
        function() return DB.hideGreedyChat end,
        function(v) DB.hideGreedyChat = v; ApplyGreedyChatFilter() end,
        -8)
    self.chatCB = chatCB

    local bubCB = AddCheckbox(self, "EbonClearanceHideGreedyBubblesCB", chatCB, "Hide |cffff7f7fGreedy Scavenger|r's chat bubbles",
        function() return DB.hideGreedyBubbles end,
        function(v) DB.hideGreedyBubbles = v end,
        -8)
    self.bubCB = bubCB

    local delaySlider = AddSlider(self, "EbonClearanceSummonDelaySlider", bubCB, "Summon delay", 0.0, 3.0, 0.1,
        function() return DB.summonDelay or 1.6 end,
        function(v) DB.summonDelay = v end,
        -16)
    self.delaySlider = delaySlider
	delaySlider:SetWidth(200)
end)

InterfaceOptions_AddCategory(ScavengerPanel)


local CharPanel = CreateFrame("Frame", "EbonClearanceOptionsCharacter", InterfaceOptionsFramePanelContainer)
CharPanel.name = "Character Settings"
CharPanel.parent = "EbonClearance"

local function CreateNameListUI(parent, titleText, setTableName, x, y)
    local w = EC_PANEL_WIDTH - x
    local box = CreateFrame("Frame", nil, parent)
    box:SetPoint("TOPLEFT", x, y)
    box:SetSize(w, 320)

    local title = box:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOPLEFT", 0, 0)
    title:SetText(titleText)

    local input = CreateFrame("EditBox", "EbonClearanceIDInput_"..setTableName, box, "InputBoxTemplate")
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
        input:SetText(EHS_GetPlayerName())
        input:HighlightText()
    end)

    local scroll = CreateFrame("ScrollFrame", "EbonClearanceNameListScroll_"..setTableName, box, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -54)
    scroll:SetPoint("BOTTOMRIGHT", -26, 8)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(w - 26, 1)
    scroll:SetScrollChild(content)

    local rowPool = {}
    local activeRows = 0

    local function GetRow(index)
        if rowPool[index] then return rowPool[index] end
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(w - 26, 22)

        local rm = CreateFrame("Button", "EbonClearanceNameRM_"..setTableName.."_"..index, content, "UIPanelButtonTemplate")
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
            if type(k) == "string" and k ~= "" then names[#names+1] = k end
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
            row.text:SetText("|cffb6ffb6"..name.."|r")
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
        if self.onlyCB then self.onlyCB:SetChecked(DB.enableOnlyListedChars) end
        if self.listUI then self.listUI:Refresh() end
        return
    end
    self.inited = true

    MakeHeader(self, "Character Settings", -16)
    local charDesc = MakeLabel(self, "Prevents this addon from running on characters you didn't intend. If enabled, EbonClearance runs only on characters listed below.", 16, -44)

    local cb = CreateFrame("CheckButton", "EbonClearanceEnableOnlyListedCharsCB", self, "InterfaceOptionsCheckButtonTemplate")
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

    self.listUI = CreateNameListUI(self, "Allowed Characters", "allowedChars", 16, -100)
    self.listUI:Refresh()
end)

InterfaceOptions_AddCategory(CharPanel)

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
                if type(name) == "string" then names[#names + 1] = name end
            end
            table.sort(names, function(a, b) return a:lower() < b:lower() end)
            for i = 1, #names do
                local count = EC_CountItems(DB.whitelistProfiles[names[i]])
                local tag = (names[i] == DB.activeProfileName) and " |cff00ff00(active)|r" or ""
                PrintNice(string.format("  |cffffff00%s|r - %d items%s", names[i], count, tag))
            end
        else
            PrintNice("Usage: /ec profile save|load|delete|list <name>")
        end
        return
    end

    -- Unknown subcommand - open options
    InterfaceOptionsFrame_OpenToCategory(MainOptions)
    InterfaceOptionsFrame_OpenToCategory(MainOptions)
end

SLASH_ECDEBUG1 = "/ecdebug"
SlashCmdList["ECDEBUG"] = function()
    if not DB then PrintNice("|cffff4444DB not loaded.|r"); return end
    PrintNice("|cffffff00=== EbonClearance Debug ===|r")
    PrintNice("whitelistQualityEnabled: " .. tostring(DB.whitelistQualityEnabled))
    PrintNice("whitelistMinQuality: "     .. tostring(DB.whitelistMinQuality))

    -- Print whitelist contents
    local wlCount = 0
    for k, v in pairs(DB.whitelist or {}) do
        local n = GetItemInfo(k) or ("ItemID:"..tostring(k))
        PrintNice(string.format("  Whitelist[%s] = %s  (%s)", tostring(k), tostring(v), n))
        wlCount = wlCount + 1
    end
    if wlCount == 0 then PrintNice("  (whitelist is empty)") end

    -- Scan bags and check which items would be sold
    PrintNice("|cffffff00--- Bag scan ---)|r")
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
                        PrintNice(string.format("|cff00ff00SELL|r bag=%d slot=%d id=%d q=%s junk=%s wp=%s qp=%s sp=%s name=%s",
                            bag, slot, itemID, tostring(quality), tostring(junk), tostring(wp), tostring(qp), tostring(sellPrice), tostring(name)))
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


f:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == ADDON_NAME then
            EnsureDB()
            HookDeletePopupOnce()
            if ApplyGreedyChatFilter then ApplyGreedyChatFilter() end
            EHS_CreateMinimapButton()
        end

    elseif event == "PLAYER_LOGOUT" then
        if DB then EbonClearanceDB = DB end

    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        EnsureDB()
        if EHS_InstallGreedyMuteOnce then EHS_InstallGreedyMuteOnce() end

    elseif event == "MERCHANT_SHOW" then
        EnsureDB()
        EC_keepBagsFlag = true
        if not EHS_IsAddonEnabledForChar() then
            return
        end
        EHS_InstallGreedyMuteOnce()
        StartRun()

    elseif event == "MERCHANT_CLOSED" then
        running = false
        worker:Hide()
        pendingDelete = nil
        -- Reopen bags after merchant closes
        if DB and DB.keepBagsOpen and EC_keepBagsFlag then
            EHS_Delay(0.8, EC_OpenAllBags)
        end
        EC_keepBagsFlag = false

    end

    if event == "PLAYER_LOGIN" then
        EHS_Delay(1, function()
            DEFAULT_CHAT_FRAME:AddMessage("|cffffd100EbonClearance Enabled|r - Use |cff00ff00/ec|r to configure.")
        end)
    end
end)
