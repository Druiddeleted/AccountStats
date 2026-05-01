-- ui.lua
--
-- Account tab on the Achievements window: tab creation (with ElvUI skin
-- integration), the ScrollBox post-render hook that swaps per-character values
-- for account-wide ones, the per-row breakdown tooltip, and the loader event.
--
-- All resolution logic (parsers, sibling lookup, "the most" strategies, caches)
-- lives in resolver.lua and is consumed via the AS namespace.

local AS = AccountStatistics

local accountMode = false

--------------------------------------------------------------------------------
-- ScrollBox row rewrite
--------------------------------------------------------------------------------

local function ShowAccountBreakdownTooltip(row)
    if not accountMode then return end
    local data = row.GetElementData and row:GetElementData() or row.elementData
    if not data or data.header or not data.id then return end
    local id = data.id
    local title = (row.Title and row.Title:GetText())
        or (row.Text and row.Text:GetText())
        or "Statistic"
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetText(title, 1, 1, 1)
    GameTooltip:AddLine("Per-character leader", 0.7, 0.7, 0.7)

    local chars = (AccountStatisticsDB and AccountStatisticsDB.characters) or {}
    local keys = {}
    for k in pairs(chars) do table.insert(keys, k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local raw = chars[k].stats and chars[k].stats[id] or "--"
        local display = AS.FormatPerCharValue(raw, chars[k].stats, id)
        if AS.IsCharDisabled(k) then
            GameTooltip:AddDoubleLine(k .. " (disabled)", display, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5)
        else
            GameTooltip:AddDoubleLine(k, display, 0.9, 0.9, 0.9, 1, 1, 1)
        end
    end
    GameTooltip:Show()
end

local function HideAccountBreakdownTooltip()
    GameTooltip:Hide()
end

-- Walk every visible stat-row and set its value text based on the current mode.
-- Tooltip hooks are attached lazily the first time we see each (recycled) row
-- frame and stay attached -- the handler itself short-circuits when account
-- mode is off so they're inert outside our tab.
local function RewriteVisibleStatRows()
    local stats = _G.AchievementFrameStats
    local sb = stats and stats.ScrollBox
    if not sb or not sb.ForEachFrame then return end
    sb:ForEachFrame(function(child)
        local data = child.GetElementData and child:GetElementData() or child.elementData
        if not data or data.header then return end
        local id = data.id
        if not id or not child.Value then return end
        if accountMode then
            child.Value:SetText(AS.SummedStatistic(id))
        else
            child.Value:SetText(_G.GetStatistic(id) or "--")
        end
        if not child._asTipHooked then
            child._asTipHooked = true
            child:HookScript("OnEnter", ShowAccountBreakdownTooltip)
            child:HookScript("OnLeave", HideAccountBreakdownTooltip)
        end
    end)
end

-- Coalesce the bursty sequence of ScrollBox:Update fires Blizzard's category
-- change produces into a single rewrite per frame.
local _rewritePending = false
local function ScheduleRewrite()
    if _rewritePending then return end
    _rewritePending = true
    C_Timer.After(0, function()
        _rewritePending = false
        local t0 = debugprofilestop and debugprofilestop()
        RewriteVisibleStatRows()
        if t0 and AS.Log then
            local elapsed = debugprofilestop() - t0
            if elapsed > 5 then AS.Log("rewrite took %.0fms", elapsed) end
        end
    end)
end

local function HookScrollBox()
    local stats = _G.AchievementFrameStats
    if not stats or not stats.ScrollBox or stats.ScrollBox._asHooked then return end
    stats.ScrollBox._asHooked = true
    hooksecurefunc(stats.ScrollBox, "Update", ScheduleRewrite)
end

--------------------------------------------------------------------------------
-- Mode toggle
--------------------------------------------------------------------------------

local function EnableAccountMode()
    accountMode = true
    if AS.Log then AS.Log("account mode ON") end
end

local function DisableAccountMode()
    if not accountMode then return end
    accountMode = false
    if AS.Log then AS.Log("account mode OFF") end
    -- Repaint visible rows immediately; toggling state without a render leaves
    -- our summed text stuck on rows until Blizzard next updates the data.
    RewriteVisibleStatRows()
end

local function SwitchToAccountTab()
    EnableAccountMode()
    -- Reuse tab3's (Statistics) click handler so we follow whatever Blizzard's
    -- current code does to switch to the Statistics view.
    local tab3 = _G.AchievementFrameTab3
    local tab3Click = tab3 and tab3:GetScript("OnClick")
    if tab3Click then tab3Click(tab3, "LeftButton") end
    if PanelTemplates_SetTab then PanelTemplates_SetTab(AchievementFrame, 4) end
    HookScrollBox()
    if _G.AchievementFrameStats and _G.AchievementFrameStats.ScrollBox
        and _G.AchievementFrameStats.ScrollBox.FullUpdate then
        _G.AchievementFrameStats.ScrollBox:FullUpdate()
    end
end

--------------------------------------------------------------------------------
-- Account tab creation
--------------------------------------------------------------------------------

local function ApplyElvUITabSkin(tab, refTab)
    local ElvUI = _G.ElvUI
    local E = ElvUI and ElvUI[1]
    local S = E and E:GetModule("Skins", true)
    if S and S.HandleTab then
        S:HandleTab(tab)
        tab:ClearAllPoints()
        -- Match ElvUI's own tab spacing for AchievementFrameTab1..3.
        tab:SetPoint("TOPLEFT", refTab, "TOPRIGHT", -5, 0)
        return true
    end
    return false
end

-- Tab3 uses Blizzard's inline AchievementFrame tab template; our generic
-- PanelTabButtonTemplate puts the text fontstring at a different offset.
-- Mirror tab3's font + text anchors so labels line up vertically.
local function MirrorTabTextAnchors(tab, refTab)
    local refText = refTab:GetFontString()
    local myText  = tab:GetFontString()
    if not (refText and myText) then return end
    local font, size, flags = refText:GetFont()
    if font then myText:SetFont(font, size, flags) end
    myText:ClearAllPoints()
    for i = 1, refText:GetNumPoints() do
        local point, _, relPoint, x, y = refText:GetPoint(i)
        myText:SetPoint(point, tab, relPoint, x, y)
    end
end

local function CreateUI()
    if not AchievementFrame or _G.AchievementFrameTab4 then return end
    if not AchievementFrameTab3 then return end

    local tab = CreateFrame(
        "Button", "AchievementFrameTab4", AchievementFrame, "PanelTabButtonTemplate"
    )
    tab:SetID(4)
    tab:SetText("Account")
    if PanelTemplates_TabResize then PanelTemplates_TabResize(tab, 0) end

    -- Set numTabs directly. PanelTemplates_SetNumTabs would call AnchorTabs,
    -- which conflicts with custom anchor chains (e.g. ElvUI re-anchors
    -- Tab2->Tab1, Tab3->Tab2) and errors with "Cannot anchor to a region
    -- dependent on it".
    AchievementFrame.numTabs = 4
    if AchievementFrame.Tabs then table.insert(AchievementFrame.Tabs, tab) end

    tab:SetScript("OnClick", SwitchToAccountTab)

    local skinned = ApplyElvUITabSkin(tab, AchievementFrameTab3)
    if not skinned then
        tab:ClearAllPoints()
        tab:SetPoint("LEFT", AchievementFrameTab3, "RIGHT", -16, 0)
    end
    MirrorTabTextAnchors(tab, AchievementFrameTab3)
    tab:Show()

    -- Disable account mode whenever the user navigates back to a built-in tab
    -- or closes the achievement frame.
    for i = 1, 3 do
        local t = _G["AchievementFrameTab" .. i]
        if t then
            t:HookScript("OnMouseDown", function() DisableAccountMode() end)
        end
    end
    AchievementFrame:HookScript("OnHide", DisableAccountMode)
end

--------------------------------------------------------------------------------
-- Loader
--------------------------------------------------------------------------------

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(_, _, name)
    if name == "Blizzard_AchievementUI" then CreateUI() end
end)

local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_AchievementUI"))
    or (IsAddOnLoaded and IsAddOnLoaded("Blizzard_AchievementUI"))
if isLoaded then CreateUI() end
