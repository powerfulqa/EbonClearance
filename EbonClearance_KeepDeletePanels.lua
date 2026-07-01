-- EbonClearance_KeepDeletePanels - Keep List + Delete List Interface Options panels.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8e-v of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- The Keep List + Delete List panels - sibling list-management UIs
-- bundled together. Both use the shared CreateListUI helper and have
-- the same panel rhythm (header + description + hint + list).
--
-- The Protection Settings panel (BlacklistSettingsPanel - auto-protect
-- toggles for equipped / upgrades / sets / affixes / chance-on-hit)
-- stays in EbonClearance_Events.lua for now; it's a different domain
-- (settings, not list management) and will move in a later stage.
--
-- Moved into this file:
--   * local DeletePanel = CreateFrame(...) + OnShow build (Delete List)
--   * local BlacklistPanel = CreateFrame(...) + OnShow build (Keep List)
--
-- Cross-file dependencies satisfied by NS:
--   * NS.compCache (Core) - initPanel, setPanelWidth, registerWidth
--   * NS.DB captured at each OnShow entry
--   * NS.MakeHeader / NS.MakeLabel (8e-i)
--   * NS.CreateListUI (8e-iv)
--   * NS.RefreshSellBorders (BagDisplay) - used by the Enable deletion
--     toggle's OnClick to repaint Delete category tints

local NS = select(2, ...)
local EC_compCache = NS.compCache
local L = NS.L

local DeletePanel = CreateFrame("Frame", "EbonClearanceOptionsDeletion", InterfaceOptionsFramePanelContainer)
DeletePanel.name = "Delete List"
DeletePanel.parent = "EbonClearance"

DeletePanel:SetScript("OnShow", function(self)
    local DB = NS.DB
    EC_compCache.initPanel(self, function(self)
        if self.listUI then
            self.listUI:Refresh()
        end
    end, function(self)
        -- v2.47.2: settings extracted to the sibling Delete Settings panel
        -- (see below). This panel now matches the Sell List / Keep List /
        -- Account Sell List rhythm: header + description + hint + list.
        -- Mirrors the v2.15.0 Keep List refactor's rationale: five
        -- checkboxes plus explanatory notes had pushed the actual list
        -- well below the fold on smaller Interface Options window sizes.
        local heading = NS.MakeHeader(self, L["Delete List"], -16)
        NS.AddHelpIcon(self, heading, "LEFT", "RIGHT", 8, 0, "what-are-the-lists")
        local delDesc = NS.MakeLabel(
            self,
            L["Items on this list are destroyed when bags are scanned. This cannot be undone."],
            16,
            -44
        )
        local delHint = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        delHint:SetPoint("TOPLEFT", delDesc, "BOTTOMLEFT", 0, -4)
        EC_compCache.setPanelWidth(delHint, 16)
        delHint:SetJustifyH("LEFT")
        delHint:SetJustifyV("TOP")
        if delHint.SetWordWrap then
            delHint:SetWordWrap(true)
        end
        delHint:SetText(
            L["Add items by shift-clicking them, dragging them in, or typing the item ID below."]
        )

        -- Grey pointer to the sibling Delete Settings panel. Mirrors the
        -- Keep List -> Protection Settings pointer added in v2.15.0.
        local settingsPtr = self:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        settingsPtr:SetPoint("TOPLEFT", delHint, "BOTTOMLEFT", 0, -6)
        EC_compCache.setPanelWidth(settingsPtr, 16)
        settingsPtr:SetJustifyH("LEFT")
        settingsPtr:SetJustifyV("TOP")
        if settingsPtr.SetWordWrap then
            settingsPtr:SetWordWrap(true)
        end
        settingsPtr:SetText(
            L["|cffaaaaaaAuto-delete, PvP Resilience marking, unsellable-affix marking, and chat announcements live on the |r|cffffb84dDelete Settings|r|cffaaaaaa panel.|r"]
        )

        self.listUI = NS.CreateListUI(self, L["Delete List"], "deleteList", 16, -130)
        -- v2.11.0: anchor BOTTOMRIGHT so the list stretches with the panel
        -- on Interface Options frame resize - mirrors the Whitelist /
        -- Blacklist / Account-Whitelist setups.
        self.listUI:ClearAllPoints()
        self.listUI:SetPoint("TOPLEFT", settingsPtr, "BOTTOMLEFT", 0, -12)
        self.listUI:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -16, 16)
        self.listUI:Refresh()
    end)
end)

-- v2.47.2: Delete Settings sub-panel. Extracted from the Delete List panel
-- so the list gets its full vertical space back (mirrors the v2.15.0 Keep
-- List -> Protection Settings extraction). All DB field names unchanged,
-- so slash commands / BugReport dumps / tooltip annotations continue to
-- work. Widget names unchanged so tests that read the source still resolve.
local DeletionSettingsPanel = CreateFrame(
    "Frame",
    "EbonClearanceOptionsDeletionSettings",
    InterfaceOptionsFramePanelContainer
)
DeletionSettingsPanel.name = "Delete Settings"
DeletionSettingsPanel.parent = "EbonClearance"

DeletionSettingsPanel:SetScript("OnShow", function(self)
    local DB = NS.DB
    EC_compCache.initPanel(self, function(self)
        -- Settings are DB-backed; nothing to refresh on re-show. Following
        -- the panel-refresh contract (empty refresh callback is fine).
    end, function(self)
        local heading = NS.MakeHeader(self, L["Delete Settings"], -16)
        NS.AddHelpIcon(self, heading, "LEFT", "RIGHT", 8, 0, "what-are-the-lists")

        local autoCB, refreshAutoCBEnabled

        -- Master switch. Off = nothing on the Delete List is destroyed,
        -- regardless of the sub-toggles.
        local delCB =
            CreateFrame("CheckButton", "EbonClearanceEnableDeleteCB", self, "InterfaceOptionsCheckButtonTemplate")
        delCB:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -28)
        delCB:SetChecked(DB.enableDeletion)
        local dt = _G[delCB:GetName() .. "Text"]
        if dt then
            dt:SetText(L["Allow items to be deleted"])
            dt:SetWidth(420)
            dt:SetJustifyH("LEFT")
        end
        local delNote = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        delNote:SetPoint("TOPLEFT", delCB, "BOTTOMLEFT", 26, -2)
        -- v2.47.2: reactive width. A bare SetWidth(<literal>) here freezes
        -- the note at build-time width and clips past the panel's right
        -- edge on Interface Options resize. Padding = 26 (indent from the
        -- checkbox anchor) + 16 (right margin). EC-TRAP per
        -- docs/ADDON_GUIDE.md's reactive-panel-layout invariant: any
        -- widget that snapshots panel width MUST go through setPanelWidth
        -- (test_layout_reactivity.lua enforces this for EC_PANEL_WIDTH-
        -- derived expressions but not for bare literals - see Test 105e
        -- in test_perf_guardrails.lua for the specific pin).
        EC_compCache.setPanelWidth(delNote, 42)
        delNote:SetJustifyH("LEFT")
        if delNote.SetWordWrap then
            delNote:SetWordWrap(true)
        end
        delNote:SetText(
            L["|cff888888Master switch. Off = nothing on the Delete List is destroyed, even if the sub-toggles below are on.|r"]
        )
        delCB:SetScript("OnClick", function()
            DB.enableDeletion = delCB:GetChecked() and true or false
            PlaySound("igMainMenuOptionCheckBoxOn")
            -- v2.42.0: turning deletion OFF also disarms auto-delete-on-pickup
            -- (not just greys it). Avoids an "armed but inactive" limbo, and
            -- means re-enabling deletion requires re-ticking auto-delete -
            -- which re-runs the confirm gate and kicks a fresh scan.
            if not DB.enableDeletion and DB.autoDeleteOnPickup then
                DB.autoDeleteOnPickup = false
                if autoCB then
                    autoCB:SetChecked(false)
                end
            end
            -- Toggling deletion changes EC_IsSellable / BuildQueue's
            -- delete-list verdict for every Delete List slot. Repaint so
            -- the slot tints track immediately without requiring a bag
            -- close/reopen. Same rule as the list-mutation refresh
            -- invariant (Test 26 in test_perf_guardrails.lua).
            if NS.RefreshSellBorders then
                NS.RefreshSellBorders()
            end
            if refreshAutoCBEnabled then
                refreshAutoCBEnabled()
            end
        end)

        -- v2.42.0: auto-delete-on-pickup sub-toggle. Greyed when deletion is
        -- off. Enabling requires an explicit confirm (irreversible) and
        -- kicks one debounce scan so items already in bags get cleaned.
        autoCB =
            CreateFrame("CheckButton", "EbonClearanceAutoDeleteCB", self, "InterfaceOptionsCheckButtonTemplate")
        autoCB:SetPoint("TOPLEFT", delNote, "BOTTOMLEFT", -26, -8)
        autoCB:SetChecked(DB.autoDeleteOnPickup)
        local autoText = _G[autoCB:GetName() .. "Text"]
        if autoText then
            autoText:SetText(L["Auto-delete these items the moment they enter your bags"])
            autoText:SetWidth(420)
            autoText:SetJustifyH("LEFT")
        end
        local autoNote = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        autoNote:SetPoint("TOPLEFT", autoCB, "BOTTOMLEFT", 26, -2)
        EC_compCache.setPanelWidth(autoNote, 42)
        autoNote:SetJustifyH("LEFT")
        if autoNote.SetWordWrap then
            autoNote:SetWordWrap(true)
        end
        autoNote:SetText(
            L["|cff888888Delete-List items are destroyed the instant they hit your bags. Skips the merchant round-trip; irreversible. Turning this on shows a confirm popup and clears any items already in bags right away.|r"]
        )

        -- v2.44.0: Resilience auto-mark sub-toggle. Adds PvP gear with the
        -- "Resilience" tooltip line to the Delete List on the next BAG_UPDATE.
        -- The existing vendor / auto-delete-on-pickup pipelines then destroy
        -- it. Same enabled-state rule as autoCB. Asked for by Murlocked:
        -- PvP gear on PE has sellPrice = 0 and clutters bags after farming.
        local resilienceCB = CreateFrame(
            "CheckButton",
            "EbonClearanceAutoMarkResilienceCB",
            self,
            "InterfaceOptionsCheckButtonTemplate"
        )
        resilienceCB:SetPoint("TOPLEFT", autoNote, "BOTTOMLEFT", -26, -8)
        resilienceCB:SetChecked(DB.autoMarkResilience)
        local resilienceText = _G[resilienceCB:GetName() .. "Text"]
        if resilienceText then
            resilienceText:SetText(L["Auto-mark PvP gear (Resilience) for deletion"])
            resilienceText:SetWidth(420)
            resilienceText:SetJustifyH("LEFT")
        end
        local resilienceNote = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        resilienceNote:SetPoint("TOPLEFT", resilienceCB, "BOTTOMLEFT", 26, -2)
        EC_compCache.setPanelWidth(resilienceNote, 42)
        resilienceNote:SetJustifyH("LEFT")
        if resilienceNote.SetWordWrap then
            resilienceNote:SetWordWrap(true)
        end
        resilienceNote:SetText(
            L["|cff888888PvP gear with 'Resilience' and no vendor value gets added to the Delete List automatically. Still needs 'Allow items to be deleted' above (plus a vendor visit or auto-delete-on-pickup) to actually be destroyed.|r"]
        )

        -- v2.47.0: affix-dupe auto-mark sub-toggle. Adds affixed Rare/Epic
        -- items whose affix you ALREADY own that are soulbound AND have no
        -- vendor value. Sellable dupes are deliberately left for the sell
        -- path. Also needs affix protection + "Allow selling affixes you
        -- already have" on. Asked for by Broyo.
        local affixDupeCB = CreateFrame(
            "CheckButton",
            "EbonClearanceAutoMarkAffixDupesCB",
            self,
            "InterfaceOptionsCheckButtonTemplate"
        )
        affixDupeCB:SetPoint("TOPLEFT", resilienceNote, "BOTTOMLEFT", -26, -8)
        affixDupeCB:SetChecked(DB.autoMarkAffixDupes)
        local affixDupeText = _G[affixDupeCB:GetName() .. "Text"]
        if affixDupeText then
            affixDupeText:SetText(L["Auto-mark unsellable affixes for deletion"])
            affixDupeText:SetWidth(420)
            affixDupeText:SetJustifyH("LEFT")
        end
        local affixDupeNote = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        affixDupeNote:SetPoint("TOPLEFT", affixDupeCB, "BOTTOMLEFT", 26, -2)
        EC_compCache.setPanelWidth(affixDupeNote, 42)
        affixDupeNote:SetJustifyH("LEFT")
        if affixDupeNote.SetWordWrap then
            affixDupeNote:SetWordWrap(true)
        end
        affixDupeNote:SetText(
            L["|cff888888Soulbound affixed items with no vendor value that EC would otherwise sell (a dupe you own, or a rank below your 'Sell affixes below rank' setting). Needs affix protection on in Protection settings.|r"]
        )

        -- v2.44.4: announce-in-chat toggle. Gates the "EC just deleted /
        -- marked X" lines. Default ON (destructive actions should be
        -- visible); turn off if the chat noise is unwelcome. Asked for
        -- by ayres.
        local announceCB = CreateFrame(
            "CheckButton",
            "EbonClearanceAnnounceAutoDeleteCB",
            self,
            "InterfaceOptionsCheckButtonTemplate"
        )
        announceCB:SetPoint("TOPLEFT", affixDupeNote, "BOTTOMLEFT", -26, -8)
        announceCB:SetChecked(DB.announceAutoDelete ~= false)
        local announceText = _G[announceCB:GetName() .. "Text"]
        if announceText then
            announceText:SetText(L["Announce auto-deletions in chat"])
            announceText:SetWidth(420)
            announceText:SetJustifyH("LEFT")
        end
        local announceNote = self:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        announceNote:SetPoint("TOPLEFT", announceCB, "BOTTOMLEFT", 26, -2)
        EC_compCache.setPanelWidth(announceNote, 42)
        announceNote:SetJustifyH("LEFT")
        if announceNote.SetWordWrap then
            announceNote:SetWordWrap(true)
        end
        announceNote:SetText(
            L["|cff888888One chat line per auto-delete or auto-mark event. Off is fine if the chat is too noisy while farming; your Delete List still tracks every destroyed item.|r"]
        )
        announceCB:SetScript("OnClick", function()
            DB.announceAutoDelete = announceCB:GetChecked() and true or false
            PlaySound(DB.announceAutoDelete and "igMainMenuOptionCheckBoxOn" or "igMainMenuOptionCheckBoxOff")
        end)

        refreshAutoCBEnabled = function()
            if DB.enableDeletion then
                autoCB:Enable()
                resilienceCB:Enable()
                affixDupeCB:Enable()
                announceCB:Enable()
                if autoText then
                    autoText:SetTextColor(1, 1, 1)
                end
                if resilienceText then
                    resilienceText:SetTextColor(1, 1, 1)
                end
                if affixDupeText then
                    affixDupeText:SetTextColor(1, 1, 1)
                end
                if announceText then
                    announceText:SetTextColor(1, 1, 1)
                end
            else
                autoCB:Disable()
                resilienceCB:Disable()
                affixDupeCB:Disable()
                announceCB:Disable()
                if autoText then
                    autoText:SetTextColor(0.5, 0.5, 0.5)
                end
                if resilienceText then
                    resilienceText:SetTextColor(0.5, 0.5, 0.5)
                end
                if affixDupeText then
                    affixDupeText:SetTextColor(0.5, 0.5, 0.5)
                end
                if announceText then
                    announceText:SetTextColor(0.5, 0.5, 0.5)
                end
            end
        end
        refreshAutoCBEnabled()

        autoCB:SetScript("OnClick", function()
            if autoCB:GetChecked() then
                autoCB:SetChecked(false) -- stay off until confirmed
                local dialog = StaticPopup_Show("EC_CONFIRM_AUTODELETE")
                if dialog then
                    dialog.data = function()
                        DB.autoDeleteOnPickup = true
                        autoCB:SetChecked(true)
                        PlaySound("igMainMenuOptionCheckBoxOn")
                        if EC_compCache.bagUpdateFrame then
                            EC_compCache.bagUpdatePending = true
                            EC_compCache.bagUpdateAccum = 0
                            EC_compCache.bagUpdateFrame:Show()
                        end
                    end
                end
            else
                DB.autoDeleteOnPickup = false
                PlaySound("igMainMenuOptionCheckBoxOff")
            end
        end)

        -- v2.44.0: Resilience auto-mark OnClick. No confirmation popup - it
        -- only adds items to the Delete List (reversible). Kicks a debounce
        -- scan so items already in bags get marked immediately.
        resilienceCB:SetScript("OnClick", function()
            DB.autoMarkResilience = resilienceCB:GetChecked() and true or false
            PlaySound(DB.autoMarkResilience and "igMainMenuOptionCheckBoxOn" or "igMainMenuOptionCheckBoxOff")
            if DB.autoMarkResilience and EC_compCache.bagUpdateFrame then
                EC_compCache.bagUpdatePending = true
                EC_compCache.bagUpdateAccum = 0
                EC_compCache.bagUpdateFrame:Show()
            end
        end)

        -- v2.47.0: affix-dupe auto-mark OnClick. Same shape as the resilience
        -- toggle: reversible, no confirm popup, kicks a debounce scan.
        affixDupeCB:SetScript("OnClick", function()
            DB.autoMarkAffixDupes = affixDupeCB:GetChecked() and true or false
            PlaySound(DB.autoMarkAffixDupes and "igMainMenuOptionCheckBoxOn" or "igMainMenuOptionCheckBoxOff")
            if DB.autoMarkAffixDupes and EC_compCache.bagUpdateFrame then
                EC_compCache.bagUpdatePending = true
                EC_compCache.bagUpdateAccum = 0
                EC_compCache.bagUpdateFrame:Show()
            end
        end)
    end)
end)

local BlacklistPanel = CreateFrame("Frame", "EbonClearanceOptionsBlacklist", InterfaceOptionsFramePanelContainer)
BlacklistPanel.name = "Keep List"
BlacklistPanel.parent = "EbonClearance"

BlacklistPanel:SetScript("OnShow", function(self)
    local DB = NS.DB
    EC_compCache.initPanel(self, function(self)
        if self.listUI then
            self.listUI:Refresh()
        end
    end, function(self)
        -- v2.15.0: the auto-protect toggles (autoAddEquipped, autoProtectUpgrades,
        -- autoProtectEquipmentSets) plus their explanatory notes used to live on
        -- this panel and dominated it visually - 3 checkboxes + 3 multi-line notes
        -- stacked above the actual list. They moved to the new `Protection Settings`
        -- sub-panel so this panel matches the Sell List / Delete List / Account
        -- Sell List rhythm (header + description + hint + list). DB field names
        -- unchanged so all event handlers, tooltip annotations, and slash commands
        -- continue to work without modification.
        local heading = NS.MakeHeader(self, L["Keep List"], -16)
        NS.AddHelpIcon(self, heading, "LEFT", "RIGHT", 8, 0, "what-are-the-lists")
        local blDesc = NS.MakeLabel(
            self,
            L["Items the addon should never touch. Good for things you'd rather sell at the auction house yourself."],
            16,
            -44
        )

        -- Grey side-note on its own line so it doesn't blend into the
        -- white action text above.
        local blNote = self:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        blNote:SetPoint("TOPLEFT", blDesc, "BOTTOMLEFT", 0, -6)
        EC_compCache.setPanelWidth(blNote, 16)
        blNote:SetJustifyH("LEFT")
        blNote:SetJustifyV("TOP")
        if blNote.SetWordWrap then
            blNote:SetWordWrap(true)
        end
        blNote:SetText(
            L["|cffaaaaaaAutomatic protection rules (equipped gear, upgrades, gear sets, affixes, chance-on-hit, tomes) are on the |r|cffffb84dProtection Settings|r|cffaaaaaa panel.|r"]
        )

        -- Anchored to blNote so the hint stays below even when the
        -- description wraps to multiple lines.
        local blHint = self:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        blHint:SetPoint("TOPLEFT", blNote, "BOTTOMLEFT", 0, -8)
        EC_compCache.setPanelWidth(blHint, 16)
        blHint:SetJustifyH("LEFT")
        blHint:SetJustifyV("TOP")
        if blHint.SetWordWrap then
            blHint:SetWordWrap(true)
        end
        blHint:SetText(L["Add items by shift-clicking them, dragging them in, or typing the item ID."])

        self.listUI = NS.CreateListUI(self, L["Protected Items"], "blacklist", 16, -130)
        self.listUI:ClearAllPoints()
        self.listUI:SetPoint("TOPLEFT", blHint, "BOTTOMLEFT", 0, -16)
        self.listUI:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -16, 16)
        self.listUI:Refresh()
    end)
end)
