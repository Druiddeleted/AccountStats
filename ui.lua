AccountStatistics = AccountStatistics or {}
local AS = AccountStatistics

local accountMode = false

-- When SummedStatistic resolves a "the most" answer via sibling stats (delves, raid
-- bosses, etc.), it stashes the winning label and the sibling IDs that contributed
-- here. The tooltip uses this so per-character breakdown lines reflect each char's
-- contribution to the displayed winner -- otherwise the screen would show "60
-- (Shade of Xavius)" while the tooltip showed each char's per-char-most boss
-- counts (5/1/4/2) and they wouldn't add up.
AS._resolvedDetails = {}

local function RealmFromKey(key)
    return key and key:match("^([^-]+)") or "?"
end

local function IsCharDisabled(key)
    if not AccountStatisticsDB then return false end
    if AccountStatisticsDB.disabledChars and AccountStatisticsDB.disabledChars[key] then
        return true
    end
    if AccountStatisticsDB.disabledRealms
        and AccountStatisticsDB.disabledRealms[RealmFromKey(key)] then
        return true
    end
    return false
end

AccountStatistics.RealmFromKey = RealmFromKey
AccountStatistics.IsCharDisabled = IsCharDisabled

-- Money-format stats render as e.g. "176155 |TGold|t 48 |TSilver|t 35 |TCopper|t".
-- Detect by the texture marker so we can sum in copper instead of choking on the
-- non-numeric icon strings.
local function ParseMoneyToCopper(s)
    if type(s) ~= "string" or not s:find("|T", 1, true) then return nil end
    -- Strip texture markers (|T...|t) so their internal coords like 0:0:2:0 don't
    -- get mistaken for silver/copper amounts.
    local stripped = s:gsub("|T[^|]+|t", " ")
    local nums = {}
    for n in stripped:gmatch("([%d,]+)") do
        local v = tonumber((n:gsub(",", "")))
        if v then table.insert(nums, v) end
    end
    if #nums < 3 then return nil end
    return nums[1] * 10000 + nums[2] * 100 + nums[3]
end

local function ParseNumericStat(s)
    if type(s) ~= "string" or s == "" or s == "--" then return nil end
    return tonumber((s:gsub("[,%s]", "")))
end

-- Match "N (Label)" — e.g. "7 (Portal to Dalaran)" or "6 (Kriegval's Rest)".
-- Returns (count, label) or (count, nil) when the parens are empty (Blizzard
-- sometimes returns "16 ()" for "the most"-style stats with no leader yet).
local function ParseCountWithLabel(s)
    if type(s) ~= "string" then return nil end
    local n, label = s:match("^%s*([%d,]+)%s*%((.-)%)%s*$")
    if not n then return nil end
    local count = tonumber((n:gsub(",", "")))
    if not label or label:match("^%s*$") then
        return count, nil
    end
    return count, label
end

-- Cache per stat id: true if the achievement name suggests a "max" stat (most gold,
-- longest streak, etc) rather than a cumulative one.
local _maxStyleCache = {}
local _MAX_KEYWORDS = { "most", "highest", "longest", "largest", "greatest", "biggest" }

-- Cached list of sibling statistic ids (in the same achievement category, plus its
-- direct child categories) so we can resolve "the most"-style stats by summing the
-- sibling that actually corresponds to each label. We include child categories
-- because parent stats like "Pandaria dungeon boss defeated the most" live in
-- "Dungeons & Raids", while the per-boss kill stats live in the "Mists of Pandaria"
-- child category beneath it.
local _siblingsCache = {}
local _categoryChildrenBuilt = false
local _categoryChildren = {}

local function EnsureCategoryChildren()
    if _categoryChildrenBuilt then return end
    _categoryChildrenBuilt = true
    if type(GetCategoryInfo) ~= "function" then return end
    local seen = {}
    local function add(cid)
        if seen[cid] then return end
        seen[cid] = true
        local ok, _, parent = pcall(GetCategoryInfo, cid)
        if ok and parent and parent ~= -1 then
            _categoryChildren[parent] = _categoryChildren[parent] or {}
            table.insert(_categoryChildren[parent], cid)
        end
    end
    -- Use both achievement and statistic category lists; statistics live in their
    -- own category tree which may not appear in GetCategoryList().
    if type(GetCategoryList) == "function" then
        local ok, list = pcall(GetCategoryList)
        if ok and type(list) == "table" then
            for _, cid in ipairs(list) do add(cid) end
        end
    end
    if type(GetStatisticsCategoryList) == "function" then
        local ok, list = pcall(GetStatisticsCategoryList)
        if ok and type(list) == "table" then
            for _, cid in ipairs(list) do add(cid) end
        end
    end
end

-- Pre-build a single map of categoryID -> { name, lname, stats = {{id, name}, ...} }
-- the first time we need it. Each GetSiblingStats call then becomes table reads
-- instead of hundreds of GetCategoryNumAchievements/GetAchievementInfo round trips.
local _catMap
local function BuildCategoryStatMap()
    if _catMap then return _catMap end
    _catMap = {}
    local function ingest(cid)
        if _catMap[cid] then return end
        local cname
        local ok, name = pcall(GetCategoryInfo, cid)
        if ok and type(name) == "string" then cname = name end
        local stats = {}
        local ok2, n = pcall(GetCategoryNumAchievements, cid)
        if ok2 and n then
            for i = 1, n do
                local ok3, sid, sname = pcall(GetAchievementInfo, cid, i)
                if ok3 and sid and type(sname) == "string" then
                    table.insert(stats, { id = sid, name = sname })
                end
            end
        end
        _catMap[cid] = {
            name = cname or "",
            lname = (cname or ""):lower(),
            stats = stats,
        }
    end
    if type(GetStatisticsCategoryList) == "function" then
        local ok, list = pcall(GetStatisticsCategoryList)
        if ok and type(list) == "table" then
            for _, cid in ipairs(list) do ingest(cid) end
        end
    end
    if type(GetCategoryList) == "function" then
        local ok, list = pcall(GetCategoryList)
        if ok and type(list) == "table" then
            for _, cid in ipairs(list) do ingest(cid) end
        end
    end
    return _catMap
end

-- Collect siblings the stat *could* be aggregating over: its immediate category,
-- plus every statistic category whose name (or a significant word) also appears
-- in the stat's own name (so "Legion raid boss defeated the most" -> "Legion").
local function GetSiblingStats(id)
    if _siblingsCache[id] ~= nil then return _siblingsCache[id] end
    local map = BuildCategoryStatMap()
    local list = {}
    local seenIDs = {}

    local _ok, _id, statNameRaw = pcall(GetAchievementInfo, id)
    local statName = (type(statNameRaw) == "string") and statNameRaw:lower() or ""

    local function takeFrom(cid)
        local info = map[cid]
        if not info then return end
        for _, s in ipairs(info.stats) do
            if s.id ~= id and not seenIDs[s.id] then
                seenIDs[s.id] = true
                table.insert(list, s)
            end
        end
    end

    local catOK, catID = pcall(GetAchievementCategory, id)
    if catOK and catID then takeFrom(catID) end

    if statName ~= "" then
        for cid, info in pairs(map) do
            local lc = info.lname
            if lc ~= "" then
                local match = statName:find(lc, 1, true) ~= nil
                if not match then
                    for word in lc:gmatch("%S+") do
                        if #word > 3 and statName:find(word, 1, true) then
                            match = true
                            break
                        end
                    end
                end
                if match then takeFrom(cid) end
            end
        end
    end

    _siblingsCache[id] = list
    return list
end

local function IsMaxStyleStatistic(id)
    local cached = _maxStyleCache[id]
    if cached ~= nil then return cached end
    local result = false
    local name
    if type(GetAchievementInfo) == "function" then
        -- pcall: GetAchievementInfo throws "Usage:" for some ids and would otherwise
        -- skip the whole detection.
        local ok, _, n = pcall(GetAchievementInfo, id)
        if ok and type(n) == "string" then name = n end
    end
    if name then
        local lower = name:lower()
        for _, kw in ipairs(_MAX_KEYWORDS) do
            if lower:find("%f[%a]" .. kw .. "%f[%A]") then
                result = true
                break
            end
        end
    end
    _maxStyleCache[id] = result
    if AS.Log then AS.Log("max-style? id=%s name=%s -> %s", tostring(id), tostring(name), tostring(result)) end
    return result
end

local function _SummedStatisticUncached(id)
    local chars = AccountStatisticsDB and AccountStatisticsDB.characters or nil
    if not chars then return "--" end

    if IsMaxStyleStatistic(id) then
        -- Collect per-char labeled counts and any plain numeric/money values.
        local byLabel = {}            -- label -> total (sum of per-char "the most" counts)
        local labelOrder = {}         -- preserve insertion order for matching siblings
        local plainMax, plainMaxIsMoney = nil, false
        local hasEmptyParens = false  -- "16 ()" — no leader; try sibling sum as fallback
        for k, c in pairs(chars) do
            if not IsCharDisabled(k) then
                local v = c.stats and c.stats[id]
                if v then
                    local copper = ParseMoneyToCopper(v)
                    if copper then
                        if plainMax == nil or copper > plainMax then
                            plainMax, plainMaxIsMoney = copper, true
                        end
                    else
                        local cn, lbl = ParseCountWithLabel(v)
                        if cn and lbl then
                            if byLabel[lbl] == nil then table.insert(labelOrder, lbl) end
                            byLabel[lbl] = (byLabel[lbl] or 0) + cn
                        elseif cn then
                            -- Parens were present but empty (Blizzard returns "N ()" when
                            -- no single sub-stat dominates). Track this so we can fall
                            -- back to summing per-instance siblings below.
                            hasEmptyParens = true
                            if plainMax == nil or cn > plainMax then plainMax = cn end
                        else
                            local n = ParseNumericStat(v)
                            if n and (plainMax == nil or n > plainMax) then plainMax = n end
                        end
                    end
                end
            end
        end

        -- If we have labels, try sibling-stat sums first: for each per-char label,
        -- find a sibling whose name contains the label (e.g. "Kriegval's Rest" matches
        -- sibling "Kriegval's Rest clears"). Sum that sibling across chars. The label
        -- with the highest account-wide sibling total wins. This recovers true totals
        -- for stats like delve clears where per-stat raw counts are exposed as siblings.
        if #labelOrder > 0 then
            local siblings = GetSiblingStats(id)
            local matchedAny = false
            local bestLabel, bestSum, bestSiblingIDs
            for _, lbl in ipairs(labelOrder) do
                local sum, any, matchedIDs = 0, false, {}
                for _, s in ipairs(siblings) do
                    local lower = s.name:lower()
                    -- Don't require parens here -- delve siblings are named like
                    -- "Kriegval's Rest clears" without parens. The label match below
                    -- already scopes us to the right boss/delve.
                    local notAggregate = not lower:find("completed")
                        and not lower:find("the most")
                        and not lower:find("total")
                    if notAggregate and s.name:find(lbl, 1, true) then
                        for k, c in pairs(chars) do
                            if not IsCharDisabled(k) then
                                local sv = c.stats and c.stats[s.id]
                                if sv then
                                    local nval = ParseNumericStat(sv)
                                    if nval then sum = sum + nval; any = true end
                                end
                            end
                        end
                        table.insert(matchedIDs, s.id)
                    end
                end
                if any then
                    matchedAny = true
                    if bestSum == nil or sum > bestSum then
                        bestLabel, bestSum, bestSiblingIDs = lbl, sum, matchedIDs
                    end
                end
            end
            if matchedAny and bestLabel then
                AS._resolvedDetails[id] = { label = bestLabel, siblingIDs = bestSiblingIDs }
                return ("%s (%s)"):format(BreakUpLargeNumbers(bestSum), bestLabel)
            end

            -- Sibling lookup didn't yield anything; fall back to aggregating the
            -- per-char "the most" counts (best signal we have when raw siblings
            -- aren't exposed -- e.g. Pandaria dungeon boss defeated the most).
            local fbLabel, fbTotal
            for lbl, total in pairs(byLabel) do
                if fbTotal == nil or total > fbTotal then
                    fbLabel, fbTotal = lbl, total
                end
            end
            if fbLabel then
                return ("%s (%s)"):format(BreakUpLargeNumbers(fbTotal), fbLabel)
            end
        end

        -- No labels matched siblings, but parens were present (e.g. "16 ()"): scan
        -- siblings for whichever per-instance stat has the highest account-wide sum
        -- and use it as the answer. Only consider siblings that look like per-instance
        -- kill/clear stats -- otherwise an unrelated aggregate like "Cataclysm dungeons
        -- completed (final boss defeated)" would dominate by raw sum.
        -- Per-instance siblings come split by difficulty for raids ("Skorpyron kills
        -- (Raid Finder Nighthold)", "(Normal Nighthold)", etc.). Group by the base
        -- name (everything before the parenthetical) and sum across difficulties so
        -- the answer matches Blizzard's per-character "the most", which itself is
        -- aggregated across difficulties.
        if hasEmptyParens then
            -- Detect dungeon vs. raid intent from the stat's own name. A category
            -- like "Legion" contains BOTH dungeon and raid per-boss stats; we want
            -- to filter to one or the other based on what the user is looking at.
            local _okN, _idN, statNameRaw = pcall(GetAchievementInfo, id)
            local statLower = (type(statNameRaw) == "string") and statNameRaw:lower() or ""
            local wantRaid = statLower:find("raid", 1, true) ~= nil
            local wantDungeon = statLower:find("dungeon", 1, true) ~= nil

            local siblings = GetSiblingStats(id)
            local byBase = {}            -- base -> { sum, hasRaidFinder, ids = {} }
            local considered = 0
            for _, s in ipairs(siblings) do
                local name = s.name
                local lower = name:lower()
                local looksLikeInstance = name:find("%(")
                    and not lower:find("completed")
                    and not lower:find("the most")
                    and not lower:find("total")
                if looksLikeInstance then
                    considered = considered + 1
                    local base, paren = name:match("^(.-)%s*%((.-)%)%s*$")
                    if base then
                        base = base:gsub("%s+$", "")
                            :gsub("%s+kills$", "")
                            :gsub("%s+defeated$", "")
                            :gsub("%s+clears$", "")
                        local sum, any = 0, false
                        for k, c in pairs(chars) do
                            if not IsCharDisabled(k) then
                                local sv = c.stats and c.stats[s.id]
                                if sv then
                                    local nval = ParseNumericStat(sv)
                                    if nval then sum = sum + nval; any = true end
                                end
                            end
                        end
                        if any then
                            local g = byBase[base] or { sum = 0, hasRaidFinder = false, ids = {} }
                            g.sum = g.sum + sum
                            table.insert(g.ids, s.id)
                            if paren and paren:lower():find("raid finder", 1, true) then
                                g.hasRaidFinder = true
                            end
                            byBase[base] = g
                        end
                    end
                end
            end

            local bestName, bestSum, bestIDs
            for base, g in pairs(byBase) do
                local include = true
                if wantRaid and not g.hasRaidFinder then include = false end
                if wantDungeon and g.hasRaidFinder then include = false end
                if include and (bestSum == nil or g.sum > bestSum) then
                    bestName, bestSum, bestIDs = base, g.sum, g.ids
                end
            end

            if AS.Log then
                AS.Log("empty-parens fallback id=%d siblings=%d considered=%d groups=%d wantRaid=%s wantDungeon=%s best=%s/%s",
                    id, #siblings, considered,
                    (function() local n = 0 for _ in pairs(byBase) do n = n + 1 end return n end)(),
                    tostring(wantRaid), tostring(wantDungeon),
                    tostring(bestName), tostring(bestSum))
            end
            if bestName and bestSum then
                AS._resolvedDetails[id] = { label = bestName, siblingIDs = bestIDs }
                return ("%s (%s)"):format(BreakUpLargeNumbers(bestSum), bestName)
            end
        end

        if plainMax then
            if plainMaxIsMoney then
                return GetMoneyString and GetMoneyString(plainMax, true) or tostring(plainMax)
            end
            return BreakUpLargeNumbers(plainMax)
        end
        return "--"
    end

    local numSum, anyNumeric = 0, false
    local moneySum, anyMoney = 0, false
    local fallback
    for k, c in pairs(chars) do
        if not IsCharDisabled(k) then
            local v = c.stats and c.stats[id]
            if v then
                local copper = ParseMoneyToCopper(v)
                if copper then
                    moneySum = moneySum + copper
                    anyMoney = true
                else
                    local n = ParseNumericStat(v)
                    if n then
                        numSum = numSum + n
                        anyNumeric = true
                    else
                        fallback = fallback or v
                    end
                end
            end
        end
    end
    if anyMoney then
        return GetMoneyString and GetMoneyString(moneySum, true) or tostring(moneySum)
    end
    if anyNumeric then return BreakUpLargeNumbers(numSum) end
    return fallback or "--"
end

-- Memoize: rendering the Statistics page calls SummedStatistic for every visible
-- row on every ScrollBox update, and "the most" stats walk many siblings each time.
-- The result for a given stat id is stable until either the underlying data changes
-- (a scrape completes) or the user toggles a character/realm in options. Both call
-- AS.InvalidateSummed to wipe the cache.
local _summedCache = {}

local function SummedStatistic(id)
    local cached = _summedCache[id]
    if cached ~= nil then return cached end
    local result = _SummedStatisticUncached(id)
    _summedCache[id] = result
    return result
end

function AS.InvalidateSummed()
    wipe(_summedCache)
    -- AS._resolvedDetails will be repopulated on the next compute pass; clear so
    -- tooltips don't show stale sibling-id mappings if the user opens the panel
    -- again before the next render.
    wipe(AS._resolvedDetails)
end

-- Prime the heavy caches in the background so the first click on Dungeons &
-- Raids (or any other category dense with "the most" stats) doesn't freeze the
-- game. Two phases, each yielding every ~4ms:
--   1. Build the category -> stats map (replaces hundreds of GetCategoryInfo /
--      GetAchievementInfo calls per sibling lookup).
--   2. Compute SummedStatistic for every max-style stat id so the value is
--      already cached when the row first becomes visible.
local _primeCo, _primeRunner = nil, nil

local function _MakeYielder(budgetMs)
    if not debugprofilestop then return function() end end
    local lastYield = debugprofilestop()
    return function()
        if debugprofilestop() - lastYield > budgetMs then
            coroutine.yield()
            lastYield = debugprofilestop()
        end
    end
end

function AS.PrimeCachesAsync()
    if _primeCo then return end
    _primeCo = coroutine.create(function()
        local yielder = _MakeYielder(4)

        -- Phase 1: ensure category map is built incrementally.
        if not _catMap then
            _catMap = {}
            local function ingest(cid)
                if _catMap[cid] then return end
                local cname
                local ok, name = pcall(GetCategoryInfo, cid)
                if ok and type(name) == "string" then cname = name end
                local stats = {}
                local ok2, n = pcall(GetCategoryNumAchievements, cid)
                if ok2 and n then
                    for i = 1, n do
                        local ok3, sid, sname = pcall(GetAchievementInfo, cid, i)
                        if ok3 and sid and type(sname) == "string" then
                            table.insert(stats, { id = sid, name = sname })
                        end
                        yielder()
                    end
                end
                _catMap[cid] = {
                    name = cname or "",
                    lname = (cname or ""):lower(),
                    stats = stats,
                }
            end
            local seen = {}
            for _, src in ipairs({ GetStatisticsCategoryList, GetCategoryList }) do
                if type(src) == "function" then
                    local ok, list = pcall(src)
                    if ok and type(list) == "table" then
                        for _, cid in ipairs(list) do
                            if not seen[cid] then
                                seen[cid] = true
                                ingest(cid)
                            end
                        end
                    end
                end
            end
        end

        -- Phase 2: pre-compute every max-style stat so display is instant later.
        local ids = (AS.GetAllStatIDs and AS.GetAllStatIDs()) or {}
        for _, id in ipairs(ids) do
            if IsMaxStyleStatistic(id) then
                SummedStatistic(id)
            end
            yielder()
        end

        if AS.Log then AS.Log("cache priming complete") end
    end)
    if not _primeRunner then _primeRunner = CreateFrame("Frame") end
    _primeRunner:SetScript("OnUpdate", function(self)
        if not _primeCo then self:SetScript("OnUpdate", nil); return end
        local ok, err = coroutine.resume(_primeCo)
        if not ok then
            if AS.Log then AS.Log("prime error: %s", tostring(err)) end
            _primeCo = nil
            self:SetScript("OnUpdate", nil)
            return
        end
        if coroutine.status(_primeCo) == "dead" then
            _primeCo = nil
            self:SetScript("OnUpdate", nil)
        end
    end)
end

-- core.lua's ScrapeStats uses this to record per-character values.
AS.RawGetStatistic = function(id) return _G.GetStatistic(id) end

-- For "the most" stats with empty parens (the API only gives an aggregate count),
-- resolve which boss is THIS character's actual leader by walking the sibling
-- per-instance kill stats and grouping by base name. Returns the leader's name
-- (or nil if we can't determine).
local function ResolvePerCharLeader(charStats, id)
    if type(charStats) ~= "table" then return nil end
    local _okN, _idN, statNameRaw = pcall(GetAchievementInfo, id)
    local statLower = (type(statNameRaw) == "string") and statNameRaw:lower() or ""
    local wantRaid = statLower:find("raid", 1, true) ~= nil
    local wantDungeon = statLower:find("dungeon", 1, true) ~= nil

    local siblings = GetSiblingStats(id)
    local byBase = {}
    for _, s in ipairs(siblings) do
        local name = s.name
        local lower = name:lower()
        if name:find("%(") and not lower:find("completed")
            and not lower:find("the most") and not lower:find("total") then
            local base, paren = name:match("^(.-)%s*%((.-)%)%s*$")
            if base then
                base = base:gsub("%s+$", "")
                    :gsub("%s+kills$", "")
                    :gsub("%s+defeated$", "")
                    :gsub("%s+clears$", "")
                local val = charStats[s.id]
                local nval = val and ParseNumericStat(val)
                if nval then
                    local g = byBase[base] or { sum = 0, hasRaidFinder = false }
                    g.sum = g.sum + nval
                    if paren and paren:lower():find("raid finder", 1, true) then
                        g.hasRaidFinder = true
                    end
                    byBase[base] = g
                end
            end
        end
    end

    local bestName, bestSum
    for base, g in pairs(byBase) do
        local include = true
        if wantRaid and not g.hasRaidFinder then include = false end
        if wantDungeon and g.hasRaidFinder then include = false end
        if include and (bestSum == nil or g.sum > bestSum) then
            bestName, bestSum = base, g.sum
        end
    end
    return bestName, bestSum
end

local function FormatPerCharValue(value, charStats, id)
    if type(value) ~= "string" then return tostring(value or "--") end
    local cn, lbl = ParseCountWithLabel(value)
    if cn and (lbl == nil or lbl == "") then
        -- Empty parens — try to resolve which boss this character's count refers to.
        local resolved = ResolvePerCharLeader(charStats, id)
        if resolved then
            return ("%s (%s)"):format(BreakUpLargeNumbers(cn), resolved)
        end
        return BreakUpLargeNumbers(cn)
    end
    return value
end

local function ShowAccountBreakdownTooltip(row)
    if not accountMode then return end
    local data = row.GetElementData and row:GetElementData() or row.elementData
    if not data or data.header or not data.id then return end
    local id = data.id
    local title = (row.Title and row.Title:GetText()) or (row.Text and row.Text:GetText()) or "Statistic"
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetText(title, 1, 1, 1)

    GameTooltip:AddLine("Per-character leader", 0.7, 0.7, 0.7)
    local chars = (AccountStatisticsDB and AccountStatisticsDB.characters) or {}
    local keys = {}
    for k in pairs(chars) do table.insert(keys, k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local rawV = chars[k].stats and chars[k].stats[id] or "--"
        local display = FormatPerCharValue(rawV, chars[k].stats, id)
        if IsCharDisabled(k) then
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

-- Normalize every visible stat-row's value based on the current mode, and attach a
-- per-row tooltip hook the first time we see each (recycled) row frame. The hook is
-- on ScrollBox:Update (post-render) and also runs directly when toggling, since
-- Blizzard's data provider doesn't always re-run row init when state flips.
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
            child.Value:SetText(SummedStatistic(id))
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

-- Coalesce many ScrollBox:Update fires (Blizzard's category change can produce
-- a bursty sequence) into one rewrite per frame.
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

local function EnableAccountMode()
    accountMode = true
    if AS.Log then AS.Log("account mode ON") end
end
local function DisableAccountMode()
    if not accountMode then return end
    accountMode = false
    if AS.Log then AS.Log("account mode OFF") end
    RewriteVisibleStatRows()
end

local function SwitchToAccountTab()
    EnableAccountMode()
    local tab3 = _G.AchievementFrameTab3
    local tab3Click = tab3 and tab3:GetScript("OnClick")
    if tab3Click then tab3Click(tab3, "LeftButton") end
    if PanelTemplates_SetTab then PanelTemplates_SetTab(AchievementFrame, 4) end
    HookScrollBox()
    -- Force a re-render to trigger our rewrite.
    if _G.AchievementFrameStats and _G.AchievementFrameStats.ScrollBox
        and _G.AchievementFrameStats.ScrollBox.FullUpdate then
        _G.AchievementFrameStats.ScrollBox:FullUpdate()
    end
end

local function CreateUI()
    if not AchievementFrame or _G.AchievementFrameTab4 then return end
    if not AchievementFrameTab3 then return end

    local tab = CreateFrame("Button", "AchievementFrameTab4", AchievementFrame, "PanelTabButtonTemplate")
    tab:SetID(4)
    tab:SetText("Account")
    if PanelTemplates_TabResize then PanelTemplates_TabResize(tab, 0) end
    AchievementFrame.numTabs = 4
    if AchievementFrame.Tabs then table.insert(AchievementFrame.Tabs, tab) end
    tab:SetScript("OnClick", SwitchToAccountTab)

    local ElvUI = _G.ElvUI
    local E = ElvUI and ElvUI[1]
    local S = E and E:GetModule("Skins", true)
    if S and S.HandleTab then
        S:HandleTab(tab)
        tab:ClearAllPoints()
        tab:SetPoint("TOPLEFT", AchievementFrameTab3, "TOPRIGHT", -5, 0)
    else
        tab:ClearAllPoints()
        tab:SetPoint("LEFT", AchievementFrameTab3, "RIGHT", -16, 0)
    end

    local refText = AchievementFrameTab3:GetFontString()
    local myText = tab:GetFontString()
    if refText and myText then
        local font, size, flags = refText:GetFont()
        if font then myText:SetFont(font, size, flags) end
        myText:ClearAllPoints()
        for i = 1, refText:GetNumPoints() do
            local point, _, relPoint, x, y = refText:GetPoint(i)
            myText:SetPoint(point, tab, relPoint, x, y)
        end
    end

    tab:Show()

    for i = 1, 3 do
        local t = _G["AchievementFrameTab" .. i]
        if t then
            t:HookScript("OnMouseDown", function() DisableAccountMode() end)
        end
    end

    AchievementFrame:HookScript("OnHide", DisableAccountMode)
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(_, _, name)
    if name == "Blizzard_AchievementUI" then
        CreateUI()
    end
end)

local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_AchievementUI"))
    or (IsAddOnLoaded and IsAddOnLoaded("Blizzard_AchievementUI"))
if isLoaded then
    CreateUI()
end
