-- Luacheck configuration for EbonClearance (WoW 3.3.5a / WotLK / Lua 5.1)
-- Run:  luacheck *.lua
-- (The addon ships as 32 .lua files after the file split plus the later
-- panel / comms / guild-share / localization additions; the original monolith
-- EbonClearance.lua was renamed to EbonClearance_Events.lua.)
-- See docs/ADDON_GUIDE.md for the rationale behind these settings.

std = "lua51"
max_line_length = 140

-- Ignore (idiomatic WoW-UI noise, not defects; see docs/ADDON_GUIDE.md):
--   212 : unused function argument. WoW script handlers and panel-builder
--         callbacks have fixed positional signatures (self, event, elapsed,
--         slider, panel, ...); many callbacks legitimately use only some.
--   213 : unused loop variable (common in pairs/ipairs with only values).
--   431 : shadowing an upvalue. Nested closures re-localise `DB = NS.DB`
--         inside a builder/handler; harmless and common across the panels.
--   432 : shadowing an upvalue ARGUMENT. The pervasive pattern is the outer
--         `self` (the panel) vs an inner widget-handler `self`; the inner
--         one is the intended receiver at that scope.
--   631 : line is too long (some colour-coded strings are unavoidably long).
ignore = { "212", "213", "431", "432", "631" }

-- WoW saved variables and slash-command handles: addon writes to these at the
-- global scope. Everything else in the addon should stay local.
globals = {
    "EbonClearanceDB",
    "EbonClearanceAccountDB",   -- account-wide whitelist store
    "EbonholdStuffDB",          -- legacy, migrated-from
    "SLASH_EBONCLEARANCE1",
    "SLASH_ECDEBUG1",
    "SlashCmdList",
    "EC_IsMerchantAllowed",     -- assigned by module, read by vendor loop
    "ChatEdit_InsertLink",      -- replaced by module to capture shift-click links
    "ContainerFrameItemButton_OnModifiedClick", -- wrapped to add Alt+Right-Click context menu
    "BankFrameItemButtonGeneric_OnClick",       -- wrapped to add Alt+Right-Click context menu on the main bank bag
    -- Keybinding headers / names (read by Blizzard, set by addon)
    "BINDING_HEADER_EBONCLEARANCE",
    "BINDING_NAME_EBONCLEARANCE_TOGGLE_SETTINGS",
    "BINDING_NAME_EBONCLEARANCE_TOGGLE_ENABLED",
    "BINDING_NAME_EBONCLEARANCE_FORCE_SELL",
    -- Globally-exposed handlers called from Bindings.xml
    "EbonClearance_ToggleSettings",
    "EbonClearance_ToggleEnabled",
    "EbonClearance_ForceSell",
    -- Provenance / attribution globals (see LICENSE §2; do not remove).
    "EBONCLEARANCE_IDENT",
    "EBONCLEARANCE_AUTHOR",
    "EBONCLEARANCE_ORIGIN",
    "__EbonClearance_origin",
    "__EbonClearance_author",
    -- _G is writable because one binding name contains a space (standard
    -- Blizzard pattern for SecureActionButton-based keybinds, see
    -- EbonClearanceTargetMerchantButton wiring).
    "_G",
    -- DB and ADB are forward-declared locals at the file scope. Luacheck's
    -- static analysis can't follow forward declarations across the file, so
    -- treat them as writable globals here. They remain `local` in the actual
    -- source.
    "DB",
    "ADB",
    -- StaticPopupDialogs is read-only by Blizzard's API but we register
    -- our own dialog templates onto it (StaticPopupDialogs.EC_CONFIRM_*).
    -- Treating it as writable silences the "setting read-only field" noise
    -- on every dialog registration.
    "StaticPopupDialogs",
    -- v2.50.x: loot-log toggle handler + its Bindings.xml name (called from
    -- Bindings.xml / SlashCmdList, same pattern as the other handler globals).
    "EbonClearance_ToggleLootLog",
    "BINDING_NAME_EBONCLEARANCE_TOGGLE_LOOTLOG",
    -- SetItemRef is REPLACED (not hooked) so a custom "ecupdate:" chat link
    -- opens the update popup; the stock 3.3.5a handler errors on it. See the
    -- EC-TRAP in EbonClearance_Comms.lua. Written at file scope, so writable.
    "SetItemRef",
    -- GameTooltip / ItemRefTooltip get a custom `__EC_annotated` marker field
    -- written on them (dedupe guard for the tooltip annotation hook). Listed
    -- as writable so the field write isn't flagged read-only; still read
    -- elsewhere, which writable also permits.
    "GameTooltip",
    "ItemRefTooltip",
}

-- WoW 3.3.5a API surface this addon touches. Grouped loosely by subsystem.
-- If the addon starts using a new API, add it here rather than silencing
-- the whole check.
read_globals = {
    -- Frame/UI
    -- (GameTooltip / ItemRefTooltip moved to the writable `globals` block:
    -- we set a custom __EC_annotated field on them.)
    "CreateFrame", "UIParent", "WorldFrame", "Minimap",
    "MerchantFrame", "OpenAllBags", "OpenBackpack", "OpenBag", "ContainerFrame1",
    "InterfaceOptionsFramePanelContainer",
    "InterfaceOptions_AddCategory", "InterfaceOptionsFrame_OpenToCategory",
    "InterfaceOptionsFrame",
    "PlaySound", "StaticPopup_Show", "StaticPopup_Hide",
    "GameTooltip_Hide", "UIFrameFlash",
    "BankFrame", "CharacterFrame", "InspectFrame", "ColorPickerFrame",
    "OpacitySliderFrame", "OpenColorPicker", "CloseDropDownMenus",
    "ChatFrame1EditBox", "ChatFrame_OpenChat",
    "CANCEL", "CLOSE",
    -- StaticPopup1 named globals are auto-created by Blizzard when a
    -- StaticPopup_Show fires; we read them to drive a few input-popup edge
    -- cases (Enter-to-confirm wiring, focus, etc).
    "StaticPopup1", "StaticPopup1EditBox", "StaticPopup1Button1",

    -- Error handler
    "geterrorhandler",

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
    -- Equipped inventory (v2.10.0 auto-protect-equipped path)
    "GetInventoryItemLink",

    -- Merchant
    "GetMerchantNumItems", "GetMerchantItemInfo", "GetMerchantItemLink",
    "BuyMerchantItem",
    "RepairAllItems", "GetRepairAllCost", "CanMerchantRepair",
    "GetMoney",
    -- Guild bank repair (v2.9.0 optional repair-funds path)
    "IsInGuild", "CanGuildBankRepair", "GetGuildBankWithdrawMoney",

    -- Unit / player
    "UnitName", "UnitExists", "UnitAura", "UnitClass",
    "IsMounted", "Dismount",
    "IsAltKeyDown", "IsShiftKeyDown", "IsControlKeyDown", "InCombatLockdown",
    "IsMouseButtonDown", "GetUnitSpeed",

    -- Blizzard constants / static popup buttons
    "YES", "NO", "OKAY",
    -- Locale strings used by the auto-open container tooltip scan
    "ITEM_OPENABLE", "LOCKED",
    -- Cursor positioning for the bag right-click popup
    "GetCursorPosition", "GetCursorInfo",
    -- Escape-key auto-hide for the bag right-click popup
    "UISpecialFrames",
    -- Dropdown menu API (used by Merchant settings dropdowns)
    "UIDropDownMenu_Initialize", "UIDropDownMenu_CreateInfo",
    "UIDropDownMenu_AddButton", "UIDropDownMenu_SetWidth",
    "UIDropDownMenu_SetText", "UIDropDownMenu_SetSelectedValue",
    "UIDropDownMenu_EnableDropDown", "UIDropDownMenu_DisableDropDown",

    -- Keybinding
    "GetBindingKey",

    -- Companions (WotLK critter API)
    "GetNumCompanions", "GetCompanionInfo",
    "CallCompanion", "DismissCompanion",

    -- Addon metadata
    "GetAddOnInfo", "GetAddOnMetadata", "IsAddOnLoaded",

    -- Loot
    "IsFishingLoot",

    -- Misc utilities
    "hooksecurefunc", "wipe", "select", "tinsert",
    "NORMAL_FONT_COLOR", "HIGHLIGHT_FONT_COLOR", "ITEM_QUALITY_COLORS",
    "GetTime", "date", "time", "debugprofilestop",
    "GetRealmName", "GetCurrentRegion",

    -- ------------------------------------------------------------------
    -- Additional 3.3.5a API surface reconciled when the luacheck CI gate
    -- was re-enabled (docs/CODE_REVIEW.md item 4). Grouped by subsystem.
    -- ------------------------------------------------------------------
    -- Items / bags (more)
    "GetItemCount", "GetItemFamily", "IsEquippableItem", "IsUsableItem",
    "HasRandomProperty", "CursorHasItem",
    "NUM_BAG_SLOTS", "NUM_BANKGENERIC_SLOTS", "NUM_CONTAINER_FRAMES",
    -- Item tooltip locale strings (Process Bags + protection scans)
    "ITEM_MILLABLE", "ITEM_PROSPECTABLE", "ITEM_SOULBOUND", "ITEM_SPELL_KNOWN",
    "ITEM_SPELL_TRIGGER_ONPROC", "ITEM_SPELL_TRIGGER_ONUSE",
    -- Merchant / buyback
    "GetBuybackItemLink", "BUYBACK_ITEMS_PER_PAGE", "MERCHANT_ITEMS_PER_PAGE",
    -- Loot
    "LootSlot", "GetLootSlotInfo", "GetLootSlotLink", "GetNumLootItems",
    "ConfirmLootSlot",
    -- Unit / player (more)
    "UnitLevel", "UnitCastingInfo", "UnitChannelInfo",
    -- Spellbook (affix / proc / recipe learn-state scans)
    "BOOKTYPE_SPELL", "GetNumSpellTabs", "GetSpellTabInfo",
    "GetSpellInfo", "GetSpellLink", "IsSpellKnown",
    -- Equipment Manager sets (auto-protect-sets path)
    "GetEquipmentSetInfo", "GetEquipmentSetItemIDs", "GetNumEquipmentSets",
    -- CVars / modified-click
    "GetCVarBool", "IsModifiedClick",
    -- Addon list + CPU/memory diagnostics (/ec bugreport)
    "GetNumAddOns", "GetAddOnCPUUsage", "GetAddOnMemoryUsage",
    "UpdateAddOnCPUUsage", "UpdateAddOnMemoryUsage",
    -- Money / coin text
    "GetCoinTextureString",
    -- Zone / locale / guild / group / perf
    "GetRealZoneText", "GetLocale", "GetGuildInfo", "GetInventoryItemID",
    "GetNumPartyMembers", "GetNumRaidMembers", "GetFramerate",
    -- Addon-to-addon comms transport
    "SendAddonMessage",
    -- Bit library (3.3.5a exposes the BitLib `bit` table globally)
    "bit",

    -- _G moved to the writable globals block above; we write to _G[...]
    -- for one keybinding name that contains a space.
}
