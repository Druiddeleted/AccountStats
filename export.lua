AccountStatistics = AccountStatistics or {}
local AS = AccountStatistics

local frame

local function BuildCSV()
    AccountStatisticsDB = AccountStatisticsDB or {}
    AccountStatisticsDB.characters = AccountStatisticsDB.characters or {}

    local chars = {}
    for k in pairs(AccountStatisticsDB.characters) do table.insert(chars, k) end
    table.sort(chars)

    -- Collect every stat id seen across the account.
    local idSet = {}
    for _, c in pairs(AccountStatisticsDB.characters) do
        for id in pairs(c.stats or {}) do idSet[id] = true end
    end
    local ids = {}
    for id in pairs(idSet) do table.insert(ids, id) end
    table.sort(ids)

    -- Look up each stat's name once via GetAchievementInfo. Cache because the
    -- API call is the slow part of building the CSV.
    local nameCache = {}
    local function NameFor(id)
        if nameCache[id] ~= nil then return nameCache[id] end
        local ok, _, name = pcall(GetAchievementInfo, id)
        nameCache[id] = (ok and type(name) == "string") and name or ""
        return nameCache[id]
    end

    local function csvCell(s)
        s = tostring(s or "")
        if s:find('[",\n]') then
            s = '"' .. s:gsub('"', '""') .. '"'
        end
        return s
    end

    local lines = {}
    -- Header: stat_id, name, account_total (if applicable), one column per char.
    local header = { "stat_id", "name" }
    for _, k in ipairs(chars) do table.insert(header, k) end
    table.insert(lines, table.concat(header, ","))

    for _, id in ipairs(ids) do
        local row = { tostring(id), csvCell(NameFor(id)) }
        for _, k in ipairs(chars) do
            local c = AccountStatisticsDB.characters[k]
            local v = c.stats and c.stats[id]
            -- Strip texture markers from money so the CSV stays readable.
            if type(v) == "string" and v:find("|T", 1, true) then
                v = v:gsub("|T[^|]+|t", " "):gsub("%s+", " ")
            end
            table.insert(row, csvCell(v))
        end
        table.insert(lines, table.concat(row, ","))
    end
    return table.concat(lines, "\n")
end

local function CreateFrameOnce()
    if frame then return frame end
    frame = CreateFrame("Frame", "AccountStatisticsExportFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(720, 480)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetFrameStrata("DIALOG")
    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOP", 0, -5)
    frame.title:SetText("Account Statistics — CSV Export")

    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 12, -28)
    hint:SetText("Ctrl+A to select all, Ctrl+C to copy.")

    local scroll = CreateFrame("ScrollFrame", "$parentScroll", frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -48)
    scroll:SetPoint("BOTTOMRIGHT", -32, 12)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject("ChatFontNormal")
    edit:SetWidth(660)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(edit)
    frame.edit = edit
    return frame
end

function AS.ShowExport()
    local f = CreateFrameOnce()
    f.edit:SetText(BuildCSV())
    f.edit:HighlightText()
    f.edit:SetFocus()
    f:Show()
end
