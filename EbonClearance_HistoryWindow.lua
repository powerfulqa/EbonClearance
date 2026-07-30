-- EbonClearance_HistoryWindow - interactive Sold History window.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- v2.57.0. Replaces the old copy-only /ec history text dump with a movable,
-- resizable window (modelled on the Loot Log window in
-- EbonClearance_StatsPanel.lua) that shows the WHOLE session's sell/delete
-- actions, newest-first, with All / Sold / Deleted filters, a rarity filter
-- (v2.68.0) and a search box. The three narrow the same list together.
-- Backed by the full-session logs in EbonClearance_Events.lua
-- (NS.recentSoldLog / NS.recentDeletedLog, now capped at 5000 each with a trim
-- counter, not the old 20). A Copy button dumps the current filtered view as
-- text through the shared copy frame so a Discord paste is still one click.
--
-- Cross-file dependencies (all read at runtime through NS):
--   * NS.recentSoldLog / NS.recentDeletedLog - the session log arrays. Each
--     entry: { itemID, itemName (link), count, reason, loggedAt, seq,
--     copper (sold) / source (deleted) }.
--   * NS.SessionHistoryTrimmed() -> (soldTrimmed, deletedTrimmed) for the
--     "N earlier entries trimmed" note.
--   * NS.ClearSessionHistory() - Clear button.
--   * NS.ShowCopyFrame(title, body) - Copy button.
--   * EC_compCache.historyDirty - set true by the log writers; the open
--     window rebuilds on it (coalesced) so an ongoing farm updates live.
--   * NS.HookScrollbarAutoHide - optional scrollbar auto-hide (guarded).

local NS = select(2, ...)
local EC_compCache = NS.compCache
local L = NS.L

local HIST_ROW_H = 16
-- Rows actually rendered. The list can hold thousands; rendering every one as
-- a frame is neither necessary nor cheap, so the window shows the newest
-- HIST_DISPLAY_MAX matching the current filter and points at Copy for the
-- full set. Filters + search narrow it well below this in practice.
local HIST_DISPLAY_MAX = 500

local historyWindow
-- Forward declaration so the chrome closures below can call it as an upvalue;
-- assigned with `function historyRefresh(win)` further down (NOT local
-- function) so it stays the same upvalue everything captures.
local historyRefresh

-- Build the merged, filtered, newest-first list from the two session logs.
-- Returns (rows, soldN, deletedN): rows is every matching entry (uncapped -
-- the Copy button wants them all; the renderer caps to HIST_DISPLAY_MAX),
-- soldN / deletedN are the matching totals for the header line.
local function historyBuildList(filter, search, rarityFilter)
    local sold = NS.recentSoldLog or {}
    local deleted = NS.recentDeletedLog or {}
    local needle = (search and search ~= "") and search:lower() or nil
    local rows = {}
    local soldN, deletedN = 0, 0
    local function consider(e, action)
        if filter == "sold" and action ~= "sold" then
            return
        end
        if filter == "deleted" and action ~= "deleted" then
            return
        end
        -- v2.68.0: rarity filter, mirroring the Loot Log window. The log
        -- entries carry no quality field, so it comes from GetItemInfo.
        -- Unlike the Loot Log (whose account scope can name items this
        -- character never saw), everything here passed through the bags
        -- this session, so the client cache has it. An item that somehow
        -- fails the lookup is dropped from a filtered view rather than
        -- shown as an unknown - a rarity filter that leaks other
        -- rarities is worse than one that misses a row.
        if rarityFilter ~= nil then
            -- v2.68.1: memoise the quality onto the entry. The log entries
            -- are append-only (a ring slot is replaced whole, never edited),
            -- so the memo can't go stale - and without it a rarity-filtered
            -- refresh re-called GetItemInfo for up to 10k entries every
            -- rebuild.
            local q = e.quality
            if q == nil then
                q = select(3, GetItemInfo(e.itemID or 0))
                e.quality = q
            end
            if q ~= rarityFilter then
                return
            end
        end
        if needle then
            local name = tostring(e.itemName or ""):lower()
            local reason = tostring(e.reason or ""):lower()
            if not name:find(needle, 1, true) and not reason:find(needle, 1, true) then
                return
            end
        end
        if action == "sold" then
            soldN = soldN + 1
        else
            deletedN = deletedN + 1
        end
        rows[#rows + 1] = {
            seq = e.seq or 0,
            action = action,
            itemID = e.itemID,
            itemName = e.itemName,
            count = tonumber(e.count) or 1,
            reason = e.reason,
            copper = e.copper,
            loggedAt = e.loggedAt,
        }
    end
    for _, e in ipairs(sold) do
        consider(e, "sold")
    end
    for _, e in ipairs(deleted) do
        consider(e, "deleted")
    end
    -- v2.70.0: items SAVED by drain-time re-validation (a rule changed
    -- mid-run). Shown under the All filter only - the Sold/Deleted radio
    -- filters exclude them via the action checks in consider().
    for _, e in ipairs(NS.recentSavedLog or {}) do
        consider(e, "saved")
    end
    -- Exact newest-first by insertion sequence (loggedAt only has 1 s
    -- granularity, so it would tie during a fast farm burst).
    table.sort(rows, function(a, b)
        return a.seq > b.seq
    end)
    return rows, soldN, deletedN
end

-- One display line for a row. Sold = green verb, Deleted = red verb,
-- Kept (v2.70.0 drain-time save) = gold verb; the item link renders in its
-- own quality colour; the reason trails in grey.
local function historyRowText(e)
    local verb
    if e.action == "sold" then
        verb = "|cffb6ffb6" .. L["Sold"] .. "|r"
    elseif e.action == "saved" then
        verb = "|cffffd700" .. L["Kept"] .. "|r"
    else
        verb = "|cffff4444" .. L["Deleted"] .. "|r"
    end
    return string.format(
        "|cff888888[%s]|r %s %dx %s  |cff888888- %s|r",
        tostring(e.loggedAt or "?"),
        verb,
        e.count,
        tostring(e.itemName or "?"),
        tostring(e.reason or "?")
    )
end

-- Pooled row factory. Rows anchor to content's TOPLEFT/TOPRIGHT so they
-- stretch with the resizable content width; reused across refreshes.
local function historyGetRow(win, i)
    win.rows = win.rows or {}
    local row = win.rows[i]
    if row then
        return row
    end
    row = CreateFrame("Frame", nil, win.content)
    row:SetHeight(HIST_ROW_H)
    row:SetPoint("TOPLEFT", win.content, "TOPLEFT", 0, -(i - 1) * HIST_ROW_H)
    row:SetPoint("TOPRIGHT", win.content, "TOPRIGHT", 0, -(i - 1) * HIST_ROW_H)
    row:EnableMouse(true)
    -- Plain hover shows the full line in a tooltip, so a long reason clipped by
    -- the single-line row is still fully readable. Alt+hover instead shows the
    -- item's own tooltip (EC's hook annotates it with the verdict you see in
    -- bags); the item is usually gone from bags by now, so it falls back to a
    -- generic item tooltip.
    row:SetScript("OnEnter", function(self)
        if IsAltKeyDown() and self.itemID then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink("item:" .. self.itemID)
            GameTooltip:Show()
        elseif self.fullText then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.fullText, 1, 1, 1, 1, true)
            GameTooltip:Show()
        else
            return
        end
        -- This window is TOOLTIP strata, so the tooltip renders behind it
        -- without an absolute level stamp. See the EC-TRAP note on the
        -- helper in EbonClearance_PanelWidgets.lua. Both branches need it:
        -- the plain-hover text is the one carrying the untruncated row.
        NS.RaiseTooltipAboveWindows()
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    label:SetPoint("LEFT", row, "LEFT", 4, 0)
    label:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    label:SetJustifyH("LEFT")
    -- Single line per row. The label has a constrained width (LEFT+RIGHT
    -- anchored), and FontStrings word-wrap by default - a long
    -- "[time] Deleted 3x [Item] - reason" line would wrap to 2-3 lines and
    -- overflow into the rows beneath it (overlapping text). Force one line;
    -- overly long lines clip at the right edge (widen the window, or use Copy
    -- for the untruncated text).
    if label.SetWordWrap then
        label:SetWordWrap(false)
    end
    row.label = label
    -- Store in the pool. Without this every refresh created a fresh frame on
    -- top of the last (the pool lookup always missed), stacking overlapping
    -- rows and defeating the surplus-hide loop (which iterates #win.rows).
    win.rows[i] = row
    return row
end

function historyRefresh(win)
    if not win then
        return
    end
    local rows = historyBuildList(win.filter, win.search, win.rarityFilter)
    local soldTrimmed, deletedTrimmed = 0, 0
    if NS.SessionHistoryTrimmed then
        soldTrimmed, deletedTrimmed = NS.SessionHistoryTrimmed()
    end

    -- Header totals. Counts are of the CURRENT filter/search match.
    local total = #rows
    local trimmed = (soldTrimmed or 0) + (deletedTrimmed or 0)
    local header
    if total == 0 then
        header = L["Nothing matches this session."]
    else
        header = string.format(L["%d actions shown this session."], total)
    end
    if trimmed > 0 then
        header = header .. string.format(L["  |cffff8000(%d earlier entries trimmed)|r"], trimmed)
    end
    win.totalLine:SetText(header)

    -- Render the newest HIST_DISPLAY_MAX; note the remainder.
    local shown = math.min(total, HIST_DISPLAY_MAX)
    for i = 1, shown do
        local row = historyGetRow(win, i)
        row.itemID = rows[i].itemID
        local text = historyRowText(rows[i])
        row.fullText = text
        row.label:SetText(text)
        row:Show()
    end
    -- Hide surplus pooled rows from a previous, larger refresh.
    if win.rows then
        for i = shown + 1, #win.rows do
            win.rows[i]:Hide()
            win.rows[i].itemID = nil
            win.rows[i].fullText = nil
        end
    end

    local contentRows = shown
    if total > HIST_DISPLAY_MAX then
        -- One extra info row telling the player the list was capped for display
        -- (the full set is available via Copy).
        local moreRow = historyGetRow(win, shown + 1)
        moreRow.itemID = nil
        moreRow.label:SetText(
            string.format(
                "|cff888888" .. L["... and %d more. Use Copy for the full list."] .. "|r",
                total - HIST_DISPLAY_MAX
            )
        )
        moreRow:Show()
        contentRows = shown + 1
    end

    win.content:SetHeight(math.max(1, contentRows * HIST_ROW_H))
end

local function historyEnsureWindow()
    if historyWindow then
        return historyWindow
    end
    local win = CreateFrame("Frame", "EbonClearanceHistoryWindow", UIParent)
    -- v2.66.1 (Serv report): TOOLTIP strata (not FULLSCREEN_DIALOG) so the
    -- window sits above the Interface Options frame. Same reason the
    -- Quickstart panel uses TOOLTIP - FULLSCREEN_DIALOG ties in strata
    -- with the Interface Options container, and whichever is shown last
    -- wins the z-order tiebreaker. Opening Options after the pop-out
    -- would hide it.
    win:SetFrameStrata("TOOLTIP")
    win:SetSize(420, 460)
    win:SetPoint("CENTER")
    win:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    win:EnableMouse(true)
    win:SetMovable(true)
    win:SetResizable(true)
    if win.SetMinResize then
        win:SetMinResize(340, 280)
    end
    if win.SetMaxResize then
        win:SetMaxResize(760, 900)
    end
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    win:Hide()
    win.filter = "all" -- "all" | "sold" | "deleted"
    win.search = ""
    win.rarityFilter = nil -- nil = all; otherwise a quality number 0-4

    local title = win:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -12)
    title:SetText("|cff66ccffEbonClearance|r: " .. L["Sold History"])

    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    -- Filter radios: All / Sold / Deleted. Exactly one checked; re-render on
    -- change.
    local filterRadios = {}
    local function setFilter(f)
        win.filter = f
        for k, r in pairs(filterRadios) do
            r:SetChecked(k == f)
        end
        historyRefresh(win)
        PlaySound("igMainMenuOptionCheckBoxOn")
    end
    local function makeFilterRadio(f, labelText, anchorTo)
        local r = CreateFrame("CheckButton", nil, win, "UIRadioButtonTemplate")
        if anchorTo then
            r:SetPoint("LEFT", anchorTo, "RIGHT", 12, 0)
        else
            r:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
        end
        local lbl = win:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        lbl:SetPoint("LEFT", r, "RIGHT", 4, 0)
        lbl:SetText(labelText)
        r:SetScript("OnClick", function()
            setFilter(f)
        end)
        filterRadios[f] = r
        return lbl
    end
    local allLbl = makeFilterRadio("all", L["All"], nil)
    local soldLbl = makeFilterRadio("sold", L["Sold"], allLbl)
    makeFilterRadio("deleted", L["Deleted"], soldLbl)
    filterRadios.all:SetChecked(true)

    -- Search box (filters by item name or reason text).
    local searchLabel = win:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    searchLabel:SetPoint("TOPLEFT", filterRadios.all, "BOTTOMLEFT", 0, -12)
    searchLabel:SetText(L["Search:"])
    local search = CreateFrame("EditBox", "EbonClearanceHistorySearch", win, "InputBoxTemplate")
    search:SetSize(180, 20)
    search:SetPoint("LEFT", searchLabel, "RIGHT", 8, 0)
    search:SetAutoFocus(false)
    -- v2.68.1: debounced via the shared helper - each keystroke used to
    -- re-filter the full session logs (up to 10k entries, worse with a
    -- rarity filter active). One rebuild per 250 ms typing idle instead.
    NS.MakeSearchDebounce(search, function()
        historyRefresh(win)
    end, function(text)
        win.search = text
    end)
    search:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    -- Clear + Copy on the top-right, under the close button.
    local clearBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    clearBtn:SetSize(70, 20)
    clearBtn:SetPoint("TOPRIGHT", win, "TOPRIGHT", -14, -36)
    clearBtn:SetText(L["Clear"])
    clearBtn:SetScript("OnClick", function()
        if NS.ClearSessionHistory then
            NS.ClearSessionHistory()
        end
        historyRefresh(win)
        PlaySound("igMainMenuOptionCheckBoxOn")
    end)

    local copyBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    copyBtn:SetSize(70, 20)
    copyBtn:SetPoint("RIGHT", clearBtn, "LEFT", -6, 0)
    copyBtn:SetText(L["Copy"])
    copyBtn:SetScript("OnClick", function()
        local rows = historyBuildList(win.filter, win.search, win.rarityFilter)
        local body
        if #rows == 0 then
            body = L["Nothing matches this session."]
        else
            local lines = {}
            for i = 1, #rows do
                lines[i] = historyRowText(rows[i])
            end
            body = table.concat(lines, "\n")
        end
        if NS.ShowCopyFrame then
            NS.ShowCopyFrame(L["EbonClearance: Sold History"], body)
        end
    end)

    -- v2.68.0 (Serv request): rarity filter, the same control the Loot
    -- Log window uses (NS.MakeRarityDropdown - shared so both windows
    -- also get the TOOLTIP-strata flyout fix). Own row rather than
    -- sharing the search row: this window resizes down to 340 px wide,
    -- where "Search:" + the 180 px box + a label + the dropdown collide.
    -- Combines with the All / Sold / Deleted radios and the search box;
    -- all three narrow the same list.
    local rarityLabel = win:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    rarityLabel:SetPoint("TOPLEFT", searchLabel, "BOTTOMLEFT", 0, -16)
    rarityLabel:SetText(L["Show:"])
    local rarityDD = NS.MakeRarityDropdown(win, "EbonClearanceHistoryRarityDD", function(q)
        win.rarityFilter = q
        historyRefresh(win)
    end)
    rarityDD:SetPoint("LEFT", rarityLabel, "RIGHT", -6, -2)

    -- Total line (under the rarity row).
    local totalLine = win:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    totalLine:SetPoint("TOPLEFT", rarityLabel, "BOTTOMLEFT", 0, -12)
    totalLine:SetJustifyH("LEFT")
    win.totalLine = totalLine

    -- Scroll chrome (matches the list windows' backdrop look).
    local scrollBg = CreateFrame("Frame", nil, win)
    -- v2.68.0: anchored to the last chrome row instead of the old fixed
    -- -104 offset. That magic number had to be hand-bumped every time a
    -- chrome row was added (the new rarity row needed exactly that), and
    -- a missed bump overlaps the list on top of the row above it.
    -- Chaining it removes the trap. Matches the Loot Log window.
    scrollBg:SetPoint("TOPLEFT", totalLine, "BOTTOMLEFT", 0, -8)
    scrollBg:SetPoint("BOTTOMRIGHT", -12, 12)
    scrollBg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    scrollBg:SetBackdropColor(0, 0, 0, 0.6)
    scrollBg:SetBackdropBorderColor(0.4, 0.35, 0.25, 1)

    local scroll = CreateFrame("ScrollFrame", "EbonClearanceHistoryScroll", scrollBg, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", -28, 6)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(360, 1)
    scroll:SetScrollChild(content)
    if NS.HookScrollbarAutoHide then
        NS.HookScrollbarAutoHide(scroll)
    end
    win.content = content
    scroll:SetScript("OnSizeChanged", function(_, w)
        if w and w > 0 then
            content:SetWidth(w)
        end
    end)

    -- Bottom-right resize grip.
    local grip = CreateFrame("Button", nil, win)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -5, 5)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function()
        win:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function()
        win:StopMovingOrSizing()
        historyRefresh(win)
    end)

    -- Live refresh while shown: actions accrue in the background during a farm,
    -- so rebuild when the log actually changed (EC_compCache.historyDirty),
    -- coalesced to at most ~once a second, with a 2 s safety fallback. Cheap
    -- when idle (one flag check per frame).
    win:SetScript("OnUpdate", function(self, elapsed)
        if not self:IsShown() then
            return
        end
        self._histTick = (self._histTick or 0) + elapsed
        if EC_compCache.historyDirty and self._histTick >= 1.0 then
            self._histTick = 0
            EC_compCache.historyDirty = false
            self._histLastToken = EC_compCache.historySeq or 0
            historyRefresh(self)
        elseif self._histTick >= 2.0 then
            self._histTick = 0
            -- Safety-net rebuild only when the logs actually changed since
            -- the last render. v2.68.1: the token is the monotonic write
            -- sequence (EC_compCache.historySeq), NOT the log lengths - the
            -- logs are ring buffers now, so their lengths freeze at the
            -- 5000 cap while writes keep happening.
            local token = EC_compCache.historySeq or 0
            if token ~= self._histLastToken then
                self._histLastToken = token
                historyRefresh(self)
            end
        end
    end)

    if type(UISpecialFrames) == "table" then
        table.insert(UISpecialFrames, "EbonClearanceHistoryWindow")
    end

    historyWindow = win
    return win
end

-- Toggle the Sold History window. Named NS.ShowHistoryWindow because the
-- callers (/ec history, the Main panel button, the Alt+Right-Click menu) all
-- go through NS.ShowSessionHistory, which prefers this when present.
function NS.ShowHistoryWindow()
    local win = historyEnsureWindow()
    if win:IsShown() then
        win:Hide()
        return
    end
    historyRefresh(win)
    win:Show()
    if win.Raise then
        win:Raise()
    end
end
