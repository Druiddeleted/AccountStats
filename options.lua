AccountStatistics = AccountStatistics or {}
local AS = AccountStatistics

local panel = CreateFrame("Frame", "AccountStatisticsOptionsPanel")
panel.name = "Account Statistics"

local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("Account Statistics")

local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
subtitle:SetWidth(560)
subtitle:SetJustifyH("LEFT")
subtitle:SetText("Toggle which realms and characters are included in account-summed statistics. Excluded entries are skipped in sums and shown greyed out in the per-row breakdown.")

local debugCB = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
debugCB:SetSize(22, 22)
debugCB:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -12)
local debugLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
debugLabel:SetPoint("LEFT", debugCB, "RIGHT", 4, 1)
debugLabel:SetText("Print debug log messages to chat")
debugCB:SetScript("OnClick", function(self)
    AccountStatisticsDB = AccountStatisticsDB or {}
    AccountStatisticsDB.debug = self:GetChecked() or nil
end)

local charsHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
charsHeader:SetPoint("TOPLEFT", debugCB, "BOTTOMLEFT", 0, -16)
charsHeader:SetText("Characters")

local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", charsHeader, "BOTTOMLEFT", 0, -8)
scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -32, 16)

local content = CreateFrame("Frame", nil, scroll)
content:SetSize(1, 1)
scroll:SetScrollChild(content)

local CHAR_NAME_W, CHAR_RACE_W, CHAR_LEVEL_W = 180, 120, 60
local ROW_H = 22
local INDENT = 24

local realmFrames = {}  -- realm -> { header, rows = { [i] = rowFrame } }
local expanded = {}     -- realm -> bool

local function MakeCheck(parent)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(22, 22)
    return cb
end

local function MakeText(parent, template)
    return parent:CreateFontString(nil, "ARTWORK", template or "GameFontHighlight")
end

local function CharsByRealm()
    local map = {}
    for key, c in pairs(AccountStatisticsDB.characters or {}) do
        local realm = AS.RealmFromKey(key)
        map[realm] = map[realm] or {}
        table.insert(map[realm], { key = key, char = c })
    end
    for _, list in pairs(map) do
        table.sort(list, function(a, b) return a.key < b.key end)
    end
    return map
end

local function Refresh()
    AccountStatisticsDB = AccountStatisticsDB or {}
    AccountStatisticsDB.characters = AccountStatisticsDB.characters or {}
    AccountStatisticsDB.disabledChars = AccountStatisticsDB.disabledChars or {}
    AccountStatisticsDB.disabledRealms = AccountStatisticsDB.disabledRealms or {}
    debugCB:SetChecked(AccountStatisticsDB.debug == true)

    -- Hide all existing widgets; we re-show what's needed below.
    for _, rf in pairs(realmFrames) do
        rf.header:Hide()
        for _, row in pairs(rf.rows) do row:Hide() end
    end

    local byRealm = CharsByRealm()
    local realms = {}
    for realm in pairs(byRealm) do table.insert(realms, realm) end
    table.sort(realms)

    local y = 0
    for _, realm in ipairs(realms) do
        local rf = realmFrames[realm]
        if not rf then
            rf = { rows = {} }
            local header = CreateFrame("Frame", nil, content)
            header:SetSize(500, ROW_H)
            rf.header = header

            local toggle = CreateFrame("Button", nil, header)
            toggle:SetSize(18, 18)
            toggle:SetPoint("LEFT", 0, 0)
            toggle:SetNormalTexture("Interface\\Buttons\\UI-PlusButton-Up")
            toggle:SetPushedTexture("Interface\\Buttons\\UI-PlusButton-Down")
            toggle:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")
            rf.toggle = toggle

            local check = MakeCheck(header)
            check:SetPoint("LEFT", toggle, "RIGHT", 4, 0)
            rf.check = check

            local label = MakeText(header, "GameFontNormal")
            label:SetPoint("LEFT", check, "RIGHT", 4, 1)
            rf.label = label

            realmFrames[realm] = rf
        end

        rf.header:Show()
        rf.header:ClearAllPoints()
        rf.header:SetPoint("TOPLEFT", 0, -y)

        local list = byRealm[realm]
        rf.label:SetText(("%s  |cff888888(%d %s)|r"):format(realm, #list, #list == 1 and "char" or "chars"))
        rf.check:SetChecked(not AccountStatisticsDB.disabledRealms[realm])
        rf.check:SetScript("OnClick", function(self)
            if self:GetChecked() then
                AccountStatisticsDB.disabledRealms[realm] = nil
            else
                AccountStatisticsDB.disabledRealms[realm] = true
            end
            if AS.InvalidateSummed then AS.InvalidateSummed() end
            Refresh()
        end)

        local isExpanded = expanded[realm]
        rf.toggle:SetNormalTexture(isExpanded
            and "Interface\\Buttons\\UI-MinusButton-Up"
            or  "Interface\\Buttons\\UI-PlusButton-Up")
        rf.toggle:SetPushedTexture(isExpanded
            and "Interface\\Buttons\\UI-MinusButton-Down"
            or  "Interface\\Buttons\\UI-PlusButton-Down")
        rf.toggle:SetHighlightTexture(isExpanded
            and "Interface\\Buttons\\UI-MinusButton-Hilight"
            or  "Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")
        rf.toggle:SetScript("OnClick", function()
            expanded[realm] = not expanded[realm]
            Refresh()
        end)

        y = y + ROW_H

        if isExpanded then
            for i, entry in ipairs(list) do
                local row = rf.rows[i]
                if not row then
                    row = CreateFrame("Frame", nil, content)
                    row:SetSize(500, ROW_H)

                    row.check = MakeCheck(row)
                    row.check:SetPoint("LEFT", INDENT, 0)

                    row.name = MakeText(row, "GameFontHighlight")
                    row.name:SetPoint("LEFT", row.check, "RIGHT", 4, 1)
                    row.name:SetWidth(CHAR_NAME_W)
                    row.name:SetJustifyH("LEFT")

                    row.race = MakeText(row, "GameFontHighlightSmall")
                    row.race:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
                    row.race:SetWidth(CHAR_RACE_W)
                    row.race:SetJustifyH("LEFT")

                    row.level = MakeText(row, "GameFontHighlightSmall")
                    row.level:SetPoint("LEFT", row.race, "RIGHT", 4, 0)
                    row.level:SetWidth(CHAR_LEVEL_W)
                    row.level:SetJustifyH("LEFT")

                    rf.rows[i] = row
                end

                row:Show()
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", 0, -y)

                local key = entry.key
                local c = entry.char
                local nameOnly = key:gsub("^[^-]+%-", "")
                row.name:SetText(nameOnly)
                row.race:SetText(c.raceLocalized or c.race or "?")
                row.level:SetText("Lvl " .. tostring(c.level or "?"))
                row.check:SetChecked(not AccountStatisticsDB.disabledChars[key])
                row.check:SetEnabled(not AccountStatisticsDB.disabledRealms[realm])
                row.check:SetScript("OnClick", function(self)
                    if self:GetChecked() then
                        AccountStatisticsDB.disabledChars[key] = nil
                    else
                        AccountStatisticsDB.disabledChars[key] = true
                    end
                    if AS.InvalidateSummed then AS.InvalidateSummed() end
                end)

                y = y + ROW_H
            end
            -- Hide unused rows past the visible count for this realm.
            for i = #list + 1, #rf.rows do rf.rows[i]:Hide() end
        else
            for _, row in pairs(rf.rows) do row:Hide() end
        end
    end

    -- Hide realm frames whose realm is no longer present.
    for realm, rf in pairs(realmFrames) do
        if not byRealm[realm] then
            rf.header:Hide()
            for _, row in pairs(rf.rows) do row:Hide() end
        end
    end

    content:SetHeight(math.max(1, y))
end

panel:SetScript("OnShow", Refresh)

if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
    local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
    Settings.RegisterAddOnCategory(category)
    AS._optionsCategory = category
elseif _G.InterfaceOptions_AddCategory then
    _G.InterfaceOptions_AddCategory(panel)
end

function AS.OpenOptions()
    if Settings and Settings.OpenToCategory and AS._optionsCategory and AS._optionsCategory.GetID then
        Settings.OpenToCategory(AS._optionsCategory:GetID())
    elseif _G.InterfaceOptionsFrame_OpenToCategory then
        _G.InterfaceOptionsFrame_OpenToCategory(panel)
        _G.InterfaceOptionsFrame_OpenToCategory(panel)
    end
end
