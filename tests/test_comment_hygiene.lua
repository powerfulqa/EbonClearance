#!/usr/bin/env lua
-- Comment hygiene check for EbonClearance.
--
-- Run from repo root:    lua tests/test_comment_hygiene.lua
--
-- The v2.29.0 implementation constraint: EC's shipped source MUST NOT
-- gain new third-party addon mentions in Lua comments. Existing
-- mentions (the baselines below) are grandfathered per the rule's
-- forward-only clause.
--
-- This test is a static-pattern check against the source. It enforces:
--   * Lua comment lines (those starting with optional whitespace and `--`)
--     are scanned for each forbidden addon name.
--   * Each pattern has a BASELINE count below; the test fails if the
--     observed count exceeds it.
--
-- When a baseline grows legitimately (e.g. a new fix needs to call
-- out a prior incident or a NOTICE-style cross-reference), update the
-- baseline here in the same commit that adds the comment. Do NOT
-- silence violations by bumping baselines blindly - bump only after
-- review concludes the new mention is genuinely needed.
--
-- Code outside comments (string literals, identifier references like
-- `LibStub:GetAddon("SomeBagAddon")`, table keys, etc.) is NOT scanned here.
-- API calls into specific third-party globals are necessary for the
-- integrations to work; this test only polices the prose.

-- Post-split: concat every shipped .lua source file. See the matching
-- comment in tests/test_perf_guardrails.lua for the rationale. List
-- order matches the .toc load order.
local SOURCE_PATHS = {
    "EbonClearance_Core.lua",
    "EbonClearance_Companion.lua",
    "EbonClearance_Protection.lua",
    "EbonClearance_Vendor.lua",
    "EbonClearance_Process.lua",
    "EbonClearance_ProcessBagsPanel.lua",
    "EbonClearance_MerchantPanel.lua",
    "EbonClearance_ScavengerPanel.lua",
    "EbonClearance_SellListPanels.lua",
    "EbonClearance_KeepDeletePanels.lua",
    "EbonClearance_ProtectionPanel.lua",
    "EbonClearance_ItemHighlightingPanel.lua",
    "EbonClearance_ProfilesPanel.lua",
    "EbonClearance_MainPanel.lua",
    "EbonClearance_StatsPanel.lua",
    "EbonClearance_GuildPanel.lua",
    "EbonClearance_PanelInfra.lua",
    "EbonClearance_PanelWidgets.lua",
    "EbonClearance_ListWidget.lua",
    "EbonClearance_QuickstartPanel.lua",
    "EbonClearance_Events.lua",
    "EbonClearance_Comms.lua",
    "EbonClearance_GuildShare.lua",
    "EbonClearance_BagDisplay.lua",
    "EbonClearance_BugReport.lua",
    "EbonClearance_Minimap.lua",
    "EbonClearance_Tooltip.lua",
    "EbonClearance_BagContextMenu.lua",
    "EbonClearance_HelpPanel.lua",
}

local pieces = {}
for _, path in ipairs(SOURCE_PATHS) do
    local f, err = io.open(path, "r")
    if not f then
        io.stderr:write("FAIL: cannot open " .. path .. ": " .. tostring(err) .. "\n")
        os.exit(1)
    end
    pieces[#pieces + 1] = f:read("*a")
    f:close()
end
local src = table.concat(pieces, "\n")

local fails = 0
local function check(name, ok, message)
    if ok then
        print("PASS  " .. name)
    else
        print("FAIL  " .. name)
        if message then
            print("      " .. message)
        end
        fails = fails + 1
    end
end

-- Baselines reflect the count of comment-line occurrences as of v2.29.0.
-- Any future contributor who genuinely needs to add a new mention must
-- bump the matching baseline here in the same commit.
local BASELINES = {
    AutoDelete   = 3,
    AutoLoot     = 0,
    AdiBags      = 0,
    Bagnon       = 0,
    ElvUI        = 15,
    BagSync      = 0,
    DataStore    = 0,
    Vendorer     = 0,
    Peddler      = 0,
    BankStack    = 0,
    ArkInventory = 0,
    Auctioneer   = 1,
    Auctionator  = 3,
    FasterLoot   = 1,
}

-- Count comment-line occurrences of each pattern. A "comment line" is
-- one whose first non-whitespace characters are `--`. Inline trailing
-- comments (`code -- comment`) are NOT scanned here because Lua doesn't
-- have a cheap way to tell the comment portion from a string literal
-- containing `--` without a real lexer. Whole-line comments cover the
-- common case where author voice / rationale lives.
local counts = {}
for line in src:gmatch("([^\n]+)") do
    local stripped = line:match("^%s*(.-)%s*$") or ""
    if stripped:sub(1, 2) == "--" then
        for pat in pairs(BASELINES) do
            if stripped:find(pat, 1, true) then
                counts[pat] = (counts[pat] or 0) + 1
            end
        end
    end
end

-- Check every pattern, but DO NOT print one line per addon name. CI logs are
-- public, and an enumerated pass-list of the names we police is itself the
-- thing we don't want to broadcast. On success we emit a single nameless
-- summary; a specific name is surfaced only when a baseline is actually
-- exceeded, where the maintainer needs it to locate and fix the violation.
local patternCount = 0
local overruns = {}
for pat, baseline in pairs(BASELINES) do
    patternCount = patternCount + 1
    local observed = counts[pat] or 0
    if observed > baseline then
        overruns[#overruns + 1] = string.format("%s (%d > baseline %d)", pat, observed, baseline)
    end
end
check(
    string.format("no new third-party comment references (%d patterns checked)", patternCount),
    #overruns == 0,
    (#overruns > 0)
            and ("baseline exceeded for: "
                .. table.concat(overruns, "; ")
                .. ". Trim the new mention, or if intentional bump the matching BASELINE "
                .. "in tests/test_comment_hygiene.lua in the same commit.")
        or nil
)

-- Additional check: the forbidden set is itself enumerated. Catches a
-- subtle regression where someone might remove a pattern from the list
-- to silence its baseline-overrun failure.
local EXPECTED_PATTERN_COUNT = 14
local actual = 0
for _ in pairs(BASELINES) do
    actual = actual + 1
end
check(
    "BASELINES table covers " .. EXPECTED_PATTERN_COUNT .. " forbidden patterns",
    actual == EXPECTED_PATTERN_COUNT,
    string.format(
        "BASELINES has %d entries, expected %d. If you added or removed " ..
        "a forbidden pattern, update EXPECTED_PATTERN_COUNT in lockstep.",
        actual, EXPECTED_PATTERN_COUNT
    )
)

print()
if fails > 0 then
    io.stderr:write("RESULT: " .. fails .. " test(s) failed\n")
    os.exit(1)
else
    print("RESULT: all tests passed")
    os.exit(0)
end
