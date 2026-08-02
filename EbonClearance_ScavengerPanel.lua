-- EbonClearance_ScavengerPanel - Scavenger Settings Interface Options panel.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- Stage 8e-iii of the multi-stage file split (docs/CODE_REVIEW.md item 4).
-- The Scavenger Settings UI panel: companion automation toggles
-- (summon Greedy / dismiss in combat / mute chat / bubble killer /
-- auto-loot cycle / bag-full threshold) and the summon-delay slider.
--
-- v2.74.0: "auto-open lootable containers" and "Fast Loot" moved OUT to
-- EbonClearance_ProcessBagsPanel.lua. Neither depends on the companion
-- pets - they are stock 3.3.5a looting - and everything left here does,
-- so this panel now hides itself wholesale on a realm without the pets
-- (see UpdatePEVisibility in the build body). Leaving the two loot
-- toggles here would have taken them down with it.
--
-- Moved into this file:
--   * local ScavengerPanel = CreateFrame(...) frame creation
--   * The ScavengerPanel OnShow handler (the panel-build body that
--     constructs all the toggles + slider + description blocks)
--
-- Cross-file dependencies satisfied by NS (all NS-exposed in earlier
-- stages; zero new prep needed for this extraction):
--   * NS.compCache (Core) - initPanel, setPanelWidth, registerWidth,
--     refreshLayouts
--   * NS.DB captured at OnShow entry
--   * NS.MakeHeader / NS.MakeLabel (8e-i)
--   * NS.AddCheckbox / NS.AddSlider / NS.FitScrollContent (8e-ii)
--   * Various WoW globals - CreateFrame, PlaySound, etc.

local NS = select(2, ...)
local EC_compCache = NS.compCache
local L = NS.L

local ScavengerPanel = CreateFrame("Frame", "EbonClearanceOptionsScavenger", InterfaceOptionsFramePanelContainer)

ScavengerPanel.name = "Scavenger Settings"
ScavengerPanel.parent = "EbonClearance"

ScavengerPanel:SetScript("OnShow", function(self)
    local DB = NS.DB
    EC_compCache.initPanel(self, function(self)
        if self.sumCB then
            self.sumCB:SetChecked(DB.summonGreedy)
        end
        if self.restoreLoadCB then
            self.restoreLoadCB:SetChecked(DB.restoreScavengerAfterLoad)
        end
        if self.delaySlider then
            self.delaySlider:SetValue(DB.summonDelay or 1.6)
        end
        -- Hide chat + hide bubbles are no longer user-toggleable; their
        -- DB fields are forced true in EnsureDB. The muteCB OnShow guard
        -- predated the panel-split refactor and never had a backing
        -- checkbox; dropped along with the chat / bubble guards.
        if self.cycleCB then
            self.cycleCB:SetChecked(DB.autoLootCycle)
        end
        if self.threshSlider then
            self.threshSlider:SetValue(DB.bagFullThreshold or 2)
        end
        -- autoOpenCB / fastLootCB moved to the Process Bags panel in
        -- v2.74.0; their re-show sync lives there now.
        if self.UpdatePEVisibility then
            self.UpdatePEVisibility()
        end
    end, function(self, content)
        -- Captured so UpdatePEVisibility can keep the header on screen while
        -- hiding everything under it (v2.74.0).
        local header = NS.MakeHeader(content, L["Scavenger Settings"], -16)
        NS.MakeLabel(
            content,
            L["Manages your |cffff7f7fGreedy Scavenger|r. Turn on the loot cycle to keep looting and selling automatically while your bags fill up."],
            16,
            -44
        )

        local sumCB =
            CreateFrame("CheckButton", "EbonClearanceSummonGreedyCB", content, "InterfaceOptionsCheckButtonTemplate")
        sumCB:SetPoint("TOPLEFT", 16, -96)
        sumCB:SetChecked(DB.summonGreedy)
        local st = _G[sumCB:GetName() .. "Text"]
        if st then
            st:SetText(L["Summon |cffff7f7fGreedy Scavenger|r after selling"])
            -- v2.59.8: reactive width. v2.66.1 iter: bumped from 42 to 60
            -- (matching the shared NS.AddCheckbox helper's new default)
            -- so the [?] icon at text:RIGHT + 6 stays inside the scrollbar
            -- zone.
            EC_compCache.setPanelWidth(st, 60)
            st:SetJustifyH("LEFT")
            if st.SetWordWrap then
                st:SetWordWrap(true)
            end
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
        if st then
            -- v2.66.1 iter (Serv report): [?] icons now right-edge-align
            -- across the panel, matching the Keep Settings visual. The
            -- label FontString is already reactive-wide via
            -- EC_compCache.setPanelWidth(st, 42) above; anchoring LEFT-
            -- to-RIGHT puts the icon at the label's right edge (which
            -- is the panel edge minus the inset).
            NS.AddHelpIcon(content, st, "LEFT", "RIGHT", 6, 0, "scav-summon")
        end

        local combatOnlyCB = NS.AddCheckbox(
            content,
            "EbonClearanceSummonOnlyOutOfCombatCB",
            sumCB,
            L["Only summon |cffff7f7fGreedy Scavenger|r when out of combat"],
            function()
                return DB.summonOnlyOutOfCombat
            end,
            function(v)
                DB.summonOnlyOutOfCombat = v
            end,
            -8
        )
        self.combatOnlyCB = combatOnlyCB
        do
            local t = _G[combatOnlyCB:GetName() .. "Text"]
            if t then
                NS.AddHelpIcon(content, t, "LEFT", "RIGHT", 6, 0, "scav-combat-only")
            end
        end

        -- v2.65.0 (Alckor request): re-summon the Scavenger after ANY
        -- loading screen (dungeon / raid / bg / arena / hearth / teleport
        -- / continent-flight) if the pet was out immediately beforehand.
        -- Blizzard's engine dismisses CRITTER companions across every
        -- loading screen. Opt-in; the handler that reads this toggle
        -- lives in the PLAYER_ENTERING_WORLD branch of the event
        -- dispatcher and consults EC_compCache.lastScavengerOut to
        -- respect the user's pre-load-screen dismissal decision.
        local restoreLoadCB = NS.AddCheckbox(
            content,
            "EbonClearanceRestoreScavengerAfterLoadCB",
            combatOnlyCB,
            L["Re-summon |cffff7f7fGreedy Scavenger|r after loading screens (if it was out)"],
            function()
                return DB.restoreScavengerAfterLoad
            end,
            function(v)
                DB.restoreScavengerAfterLoad = v
            end,
            -8
        )
        self.restoreLoadCB = restoreLoadCB
        do
            local t = _G[restoreLoadCB:GetName() .. "Text"]
            if t then
                NS.AddHelpIcon(content, t, "LEFT", "RIGHT", 6, 0, "scav-restore-load")
            end
        end

        -- Hide chat + hide bubbles checkboxes were removed: this is now
        -- baked-in addon behaviour. DB.hideGreedyChat /
        -- DB.hideGreedyBubbles are forced true in EnsureDB so the
        -- Companion.lua filters keep working unchanged.

        local delaySlider = NS.AddSlider(
            content,
            "EbonClearanceSummonDelaySlider",
            restoreLoadCB,
            L["Summon delay"],
            0.0,
            20.0,
            0.1,
            function()
                return DB.summonDelay or 1.6
            end,
            function(v)
                DB.summonDelay = v
            end,
            -16,
            "%.1fs"
        )
        self.delaySlider = delaySlider
        delaySlider:SetWidth(200)
        -- v2.66.1 iter (Serv report): anchor to the slider's label
        -- FontString (which sits above the bar) instead of the slider
        -- frame's TOPRIGHT, so the [?] sits inline next to the label
        -- - matches the Keep Settings slider [?] pattern.
        local delaySliderText = _G["EbonClearanceSummonDelaySliderText"]
        NS.AddHelpIcon(
            content,
            delaySliderText or delaySlider,
            "LEFT",
            delaySliderText and "RIGHT" or "TOPRIGHT",
            6,
            0,
            "scav-summon-delay"
        )

        local cycleCB = NS.AddCheckbox(
            content,
            "EbonClearanceAutoLootCycleCB",
            delaySlider,
            L["Enable auto-loot cycle (loot, sell, repeat)"],
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
        local cycleCBText = _G[cycleCB:GetName() .. "Text"]
        if cycleCBText then
            NS.AddHelpIcon(content, cycleCBText, "LEFT", "RIGHT", 6, 0, "scav-autoloot-cycle")
        end

        -- threshSlider used to anchor to a multi-line cycleNote FontString
        -- that explained the bags-fill / Goblin Merchant summon mechanic.
        -- Task 17 stripped that note - the [?] icon next to the cycle
        -- toggle now deep-links to the same Help entry. The slider re-
        -- anchors to cycleCB directly with -16 below to keep separation
        -- between the toggle and the slider's label.
        local threshSlider = NS.AddSlider(
            content,
            "EbonClearanceBagThresholdSlider",
            cycleCB,
            L["Bag slots remaining before selling"],
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
        -- v2.66.1 iter: same slider-label anchor pattern as delaySlider above.
        local threshSliderText = _G["EbonClearanceBagThresholdSliderText"]
        NS.AddHelpIcon(
            content,
            threshSliderText or threshSlider,
            "LEFT",
            threshSliderText and "RIGHT" or "TOPRIGHT",
            6,
            0,
            "scav-bag-threshold"
        )

        -- v2.74.0: "Auto-open lootable containers" and "Fast Loot" moved to
        -- the Process Bags panel. Neither has anything to do with the
        -- companion pets - they are stock looting behaviour that works on
        -- any realm - and this panel goes dark where the pets do not exist,
        -- which would have taken them with it. Their DB fields
        -- (autoOpenContainers, fastLoot) and every runtime consumer are
        -- unchanged; only the widgets moved.

        -- v2.10.0: the v2.9.0 editable companion-name input boxes were removed
        -- from this panel after in-game testing showed the click-to-focus path
        -- was unreliable on PE-ElvUI; users could see the inputs but typing did
        -- not update DB.scavengerName / DB.merchantName consistently. The
        -- underlying mechanism (DB fields, EC_compCache.refreshNames, the
        -- EnsureDB defaults, and the spellID 600126 cold-cache fallback in
        -- FindGoblinMerchantIndex) all stay - they are still the source of
        -- truth for companion lookup and a future re-enable can drop the UI
        -- back in without touching the runtime path. For now if a user needs
        -- to override either name they can edit DB.scavengerName /
        -- DB.merchantName directly via /run on a single character.

        -- Discoverability hint for the right-click context menu.
        local rightClickHint = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        rightClickHint:SetPoint("TOPLEFT", threshSlider, "BOTTOMLEFT", 0, -24)
        EC_compCache.setPanelWidth(rightClickHint, 60)
        rightClickHint:SetJustifyH("LEFT")
        if rightClickHint.SetWordWrap then
            rightClickHint:SetWordWrap(true)
        end
        rightClickHint:SetText(
            L["|cffffb84dTip:|r |cff888888Alt+Right-Click any bag item to Sell, Keep, Delete, or override protection.|r"]
        )

        -- v2.74.0: every remaining control on this panel drives the
        -- companion pets, so on a realm without them the panel has nothing
        -- to configure. Hide the lot and leave one line saying so and where
        -- the two loot options went.
        --
        -- Enumerating children / regions instead of tracking each widget:
        -- this is the whole-panel case, and doing it structurally means a
        -- control added here later is covered without anyone remembering to
        -- register it. The header and the placeholder are the only regions
        -- deliberately excluded.
        local unavailableNote = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        unavailableNote:SetPoint("TOPLEFT", 16, -80)
        EC_compCache.setPanelWidth(unavailableNote, 60)
        unavailableNote:SetJustifyH("LEFT")
        if unavailableNote.SetWordWrap then
            unavailableNote:SetWordWrap(true)
        end
        unavailableNote:SetText(
            L["|cff888888This realm has no Scavenger or Goblin Merchant companion, so there is nothing to set up here. Auto-open containers and Fast Loot moved to the Process Bags panel.|r"]
        )
        unavailableNote:Hide()

        local function UpdatePEVisibility()
            local show = EC_compCache.peFeaturesVisible == nil or EC_compCache.peFeaturesVisible()
            local kids = { content:GetChildren() }
            for i = 1, #kids do
                if show then
                    kids[i]:Show()
                else
                    kids[i]:Hide()
                end
            end
            local regions = { content:GetRegions() }
            for i = 1, #regions do
                local r = regions[i]
                if r ~= header and r ~= unavailableNote then
                    if show then
                        r:Show()
                    else
                        r:Hide()
                    end
                end
            end
            if show then
                unavailableNote:Hide()
            else
                unavailableNote:Show()
            end
        end
        self.UpdatePEVisibility = UpdatePEVisibility
        UpdatePEVisibility()

        -- Size the scroll content to fit the bottom-most widget so the scrollbar
        -- range matches actual content (no excess empty space at the bottom).
        NS.FitScrollContent(content, rightClickHint)
    end, true)
end)
