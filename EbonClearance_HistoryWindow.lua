-- EbonClearance_HistoryWindow - interactive Sold History window.
-- Author:  Serv
-- Source:  https://github.com/powerfulqa/EbonClearance
-- License: see LICENSE; attribution preservation is required.
--
-- v2.57.0. Replaces the old copy-only /ec history text dump with a movable,
-- resizable window (modelled on the Loot Log window in
-- EbonClearance_StatsPanel.lua) that shows the WHOLE session's sell/delete
-- actions, newest-first, with All / Sold / Deleted filters and a search box.
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
local function historyBuildList(filter, search)
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
    -- Exact newest-first by insertion sequence (loggedAt only has 1 s
    -- granularity, so it would tie during a fast farm burst).
    table.sort(rows, function(a, b)
        return a.seq > b.seq
    end)
    return rows, soldN, deletedN
end

-- One display line for a row. Sold = green verb, Deleted = red verb; the item
-- link renders in its own quality colour; the reason trails in grey.
local function historyRowText(e)
    local verb = (e.action == "sold") and ("|cffb6ffb6" .. L["Sold"] .. "|r") or ("|cffff4444" .. L["Deleted"] .. "|r")
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
        end
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
    local rows = historyBuildList(win.filter, win.search)
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
    win:SetFrameStrata("FULLSCREEN_DIALOG")
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
    search:SetScript("OnTextChanged", function(self)
        win.search = self:GetText() or ""
        historyRefresh(win)
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
        local rows = historyBuildList(win.filter, win.search)
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

    -- Total line (under the search row).
    local totalLine = win:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    totalLine:SetPoint("TOPLEFT", searchLabel, "BOTTOMLEFT", 0, -10)
    totalLine:SetJustifyH("LEFT")
    win.totalLine = totalLine

    -- Scroll chrome (matches the list windows' backdrop look).
    local scrollBg = CreateFrame("Frame", nil, win)
    scrollBg:SetPoint("TOPLEFT", 12, -104)
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
            local sold, deleted = NS.recentSoldLog, NS.recentDeletedLog
            self._histLastToken = (sold and #sold or 0) + (deleted and #deleted or 0)
            historyRefresh(self)
        elseif self._histTick >= 2.0 then
            self._histTick = 0
            -- Safety-net rebuild only when the logs actually grew or shrank
            -- since the last render; the dirty flag above covers the normal
            -- path, so rebuilding (filter + sort of both full logs) every 2 s
            -- unconditionally was wasted work on an idle window.
            local sold, deleted = NS.recentSoldLog, NS.recentDeletedLog
            local token = (sold and #sold or 0) + (deleted and #deleted or 0)
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
