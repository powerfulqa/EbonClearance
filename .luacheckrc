-- Luacheck configuration for EbonClearance (WoW 3.3.5a / WotLK / Lua 5.1)
-- Run:  luacheck EbonClearance.lua
-- See docs/ADDON_GUIDE.md for the rationale behind these settings.

std = "lua51"
max_line_length = 140

-- Ignore:
--   212/self  : unused function argument "self" (WoW script handlers are self-receiving)
--   213       : unused loop variable (common in pairs/ipairs with only values)
--   631       : line is too long (some colour-coded strings are unavoidably long)
ignore = { "212/self", "213", "631" }

-- WoW saved variables and slash-command handles: addon writes to these at the
-- global scope. Everything else in the addon should stay local.
globals = {
    "EbonClearanceDB",
    "EbonholdStuffDB",          -- legacy, migrated-from
    "SLASH_EC1", "SLASH_EC2",
    "SLASH_ECDEBUG1",
    "SlashCmdList",
    "EC_IsMerchantAllowed",     -- assigned by module, read by vendor loop
}

-- WoW 3.3.5a API surface this addon touches. Grouped loosely by subsystem.
-- If the addon starts using a new API, add it here rather than silencing
-- the whole check.
read_globals = {
    -- Frame/UI
    "CreateFrame", "UIParent", "GameTooltip", "Minimap",
    "MerchantFrame", "OpenAllBags", "ContainerFrame1",
    "InterfaceOptionsFramePanelContainer",
    "InterfaceOptions_AddCategory", "InterfaceOptionsFrame_OpenToCategory",
    "InterfaceOptionsFrame",
    "PlaySound", "StaticPopup_Show", "StaticPopupDialogs",

    -- Chat
    "DEFAULT_CHAT_FRAME",
    "ChatFrame_AddMessageEventFilter", "ChatFrame_RemoveMessageEventFilter",
    "ChatTypeInfo",

    -- Items / bags
    "GetItemInfo", "GetItemIcon",
    "GetContainerItemID", "GetContainerItemInfo", "GetContainerItemLink",
    "GetContainerNumSlots", "GetContainerNumFreeSlots",
    "UseContainerItem", "PickupContainerItem",
    "DeleteCursorItem", "ClearCursor",
    "IsEquippedItem",
    "GetItemQualityColor",

    -- Merchant
    "GetMerchantNumItems", "GetMerchantItemInfo", "GetMerchantItemLink",
    "BuyMerchantItem",
    "RepairAllItems", "GetRepairAllCost", "CanMerchantRepair",
    "GetMoney",

    -- Unit / player
    "UnitName", "UnitExists", "UnitAura", "UnitClass",
    "IsMounted", "Dismount",

    -- Companions (WotLK critter API)
    "GetNumCompanions", "GetCompanionInfo",
    "CallCompanion", "DismissCompanion",

    -- Addon metadata
    "GetAddOnInfo", "GetAddOnMetadata", "IsAddOnLoaded",

    -- Misc utilities
    "hooksecurefunc", "wipe", "select",
    "NORMAL_FONT_COLOR", "HIGHLIGHT_FONT_COLOR",
    "GetTime", "date", "time",
    "GetRealmName", "GetCurrentRegion",
    "_G",
}
