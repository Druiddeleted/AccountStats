-- resolver.lua
--
-- All logic for turning a stat ID into an account-wide value: value parsing,
-- category/sibling lookups, "the most"-style resolution strategies, the
-- SummedStatistic memo cache, and background cache priming.
--
-- ui.lua is the only intended caller. Public surface goes on the AccountStatistics
-- namespace as AS.<Name>.

AccountStatistics = AccountStatistics or {}
local AS = AccountStatistics

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

-- Achievement name keywords that mark a stat as a "best-of"-style measurement
-- rather than a cumulative counter (e.g. "Most gold ever owned").
local MAX_KEYWORDS = {
    "most", "highest", "longest", "largest", "greatest", "biggest",
}

-- Sibling stat name keywords that imply an aggregate counter rather than a
-- single per-instance counter. Excluded from sibling-sum candidates.
local AGGREGATE_KEYWORDS = { "completed", "the most", "total" }

-- Trailing verbs we strip when grouping per-instance siblings by base name.
-- "Skorpyron kills" -> "Skorpyron".
local TRAILING_VERBS = { " kills", " defeated", " clears" }

local RAID_FINDER_TAG = "raid finder"  -- a difficulty marker that only appears on raid bosses
local TEXTURE_MARKER  = "|T"           -- start of inline icons in money/value strings

--------------------------------------------------------------------------------
-- Character / realm enable predicates
--------------------------------------------------------------------------------

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

AS.RealmFromKey   = RealmFromKey
AS.IsCharDisabled = IsCharDisabled

--------------------------------------------------------------------------------
-- Value parsing (per-character stat strings)
--------------------------------------------------------------------------------

-- Money values look like "176155 |TGoldIcon|t 48 |TSilverIcon|t 35 |TCopperIcon|t".
-- Returns total in copper, or nil if not a money string.
local function ParseMoneyToCopper(s)
    if type(s) ~= "string" or not s:find(TEXTURE_MARKER, 1, true) then return nil end
    -- Strip texture markers first; their internal coords (0:0:2:0) would
    -- otherwise be picked up as silver/copper.
    local stripped = s:gsub("|T[^|]+|t", " ")
    local g, sv, c
    for n in stripped:gmatch("([%d,]+)") do
        local v = tonumber((n:gsub(",", "")))
        if v then
            if not g then g = v
            elseif not sv then sv = v
            elseif not c then c = v; break end
        end
    end
    if not (g and sv and c) then return nil end
    return g * 10000 + sv * 100 + c
end

local function ParseNumericStat(s)
    if type(s) ~= "string" or s == "" or s == "--" then return nil end
    return tonumber((s:gsub("[,%s]", "")))
end

-- Match "N (Label)" — e.g. "7 (Portal to Dalaran)". Returns (count, label) when
-- a label is present, (count, nil) when parens are present but empty, or nil when
-- the string isn't in the labeled format at all.
local function ParseCountWithLabel(s)
    if type(s) ~= "string" then return nil end
    local n, label = s:match("^%s*([%d,]+)%s*%((.-)%)%s*$")
    if not n then return nil end
    local count = tonumber((n:gsub(",", "")))
    if not label or label:match("^%s*$") then return count, nil end
    return count, label
end

local function StripTrailingVerb(base)
    base = base:gsub("%s+$", "")
    for _, v in ipairs(TRAILING_VERBS) do
        local stripped = base:gsub(v .. "$", "")
        if stripped ~= base then return stripped end
    end
    return base
end

local function NameLooksLikeAggregate(lname)
    for _, kw in ipairs(AGGREGATE_KEYWORDS) do
        if lname:find(kw, 1, true) then return true end
    end
    return false
end

--------------------------------------------------------------------------------
-- Category map + sibling lookup
--
-- The CurseForge / Blizzard achievement category APIs return categories from
-- two separate lists (achievements and statistics) and don't always wire up
-- parent/child relationships consistently. We build one combined map of
-- category id -> { name, lname, stats[] } once, then sibling lookup becomes
-- table reads.
--------------------------------------------------------------------------------

local _catMap

local function IngestCategory(cid)
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
        name  = cname or "",
        lname = (cname or ""):lower(),
        stats = stats,
    }
end

local function BuildCategoryStatMap()
    if _catMap then return _catMap end
    _catMap = {}
    for _, src in ipairs({ GetStatisticsCategoryList, GetCategoryList }) do
        if type(src) == "function" then
            local ok, list = pcall(src)
            if ok and type(list) == "table" then
                for _, cid in ipairs(list) do IngestCategory(cid) end
            end
        end
    end
    return _catMap
end

local function CategoryNameMatchesStat(lname, statName)
    if lname == "" then return false end
    if statName:find(lname, 1, true) then return true end
    -- Match on any significant word so "Mists of Pandaria" still matches a stat
    -- that just says "Pandaria".
    for word in lname:gmatch("%S+") do
        if #word > 3 and statName:find(word, 1, true) then return true end
    end
    return false
end

local _siblingsCache = {}

-- Collect siblings the stat could be aggregating over: its immediate category,
-- plus every statistic category whose name appears in the stat's own name (so
-- "Legion raid boss defeated the most" -> "Legion").
local function GetSiblingStats(id)
    if _siblingsCache[id] ~= nil then return _siblingsCache[id] end
    local map = BuildCategoryStatMap()
    local list, seen = {}, {}

    local _ok, _id, raw = pcall(GetAchievementInfo, id)
    local statName = (type(raw) == "string") and raw:lower() or ""

    local function takeFrom(cid)
        local info = map[cid]
        if not info then return end
        for _, s in ipairs(info.stats) do
            if s.id ~= id and not seen[s.id] then
                seen[s.id] = true
                table.insert(list, s)
            end
        end
    end

    local catOK, catID = pcall(GetAchievementCategory, id)
    if catOK and catID then takeFrom(catID) end

    if statName ~= "" then
        for cid, info in pairs(map) do
            if CategoryNameMatchesStat(info.lname, statName) then takeFrom(cid) end
        end
    end

    _siblingsCache[id] = list
    return list
end

--------------------------------------------------------------------------------
-- Stat classification
--------------------------------------------------------------------------------

local _maxStyleCache = {}

local function IsMaxStyleStatistic(id)
    local cached = _maxStyleCache[id]
    if cached ~= nil then return cached end
    local result = false
    local ok, _, name = pcall(GetAchievementInfo, id)
    if ok and type(name) == "string" then
        local lower = name:lower()
        for _, kw in ipairs(MAX_KEYWORDS) do
            if lower:find("%f[%a]" .. kw .. "%f[%A]") then
                result = true
                break
            end
        end
    end
    _maxStyleCache[id] = result
    return result
end

local function StatNameLower(id)
    local ok, _, name = pcall(GetAchievementInfo, id)
    return (ok and type(name) == "string") and name:lower() or ""
end

--------------------------------------------------------------------------------
-- Per-stat data classification
--
-- One pass over enabled characters that bins each char's value into one of:
--   - money copper amount
--   - labeled count "N (Label)"
--   - empty-parens count "N ()"
--   - plain numeric
--   - fallback string (non-numeric, non-money)
--------------------------------------------------------------------------------

local function ClassifyValues(id)
    local chars = AccountStatisticsDB and AccountStatisticsDB.characters or {}
    local out = {
        chars       = chars,
        byLabel     = {},   -- label -> total of per-char "the most" counts
        labelOrder  = {},
        moneyCoppers = {},  -- list of copper amounts, one per char with money values
        plainNums   = {},   -- list of plain numeric values
        unlabeledCounts = {}, -- counts from "N ()" entries
        fallback    = nil,
    }
    for k, c in pairs(chars) do
        if not IsCharDisabled(k) then
            local v = c.stats and c.stats[id]
            if v then
                local copper = ParseMoneyToCopper(v)
                if copper then
                    table.insert(out.moneyCoppers, copper)
                else
                    local cn, lbl = ParseCountWithLabel(v)
                    if cn and lbl then
                        if out.byLabel[lbl] == nil then table.insert(out.labelOrder, lbl) end
                        out.byLabel[lbl] = (out.byLabel[lbl] or 0) + cn
                    elseif cn then
                        table.insert(out.unlabeledCounts, cn)
                    else
                        local n = ParseNumericStat(v)
                        if n then
                            table.insert(out.plainNums, n)
                        else
                            out.fallback = out.fallback or v
                        end
                    end
                end
            end
        end
    end
    return out
end

local function MaxOf(list)
    local m
    for _, v in ipairs(list) do
        if m == nil or v > m then m = v end
    end
    return m
end

local function SumOf(list)
    local s = 0
    for _, v in ipairs(list) do s = s + v end
    return s
end

--------------------------------------------------------------------------------
-- Resolution strategies
--
-- Each strategy returns a formatted display string (and optionally writes
-- AS._resolvedDetails) when it can resolve, or nil to defer to the next.
-- AS._resolvedDetails is consumed by the tooltip to show per-character
-- contributions to the displayed winner.
--------------------------------------------------------------------------------

AS._resolvedDetails = {}

local function FormatMoney(copper)
    return GetMoneyString and GetMoneyString(copper, true) or tostring(copper)
end

-- Strategy: max copper across chars (e.g. "Most gold ever owned").
local function TryMoneyMax(c)
    if #c.moneyCoppers == 0 then return nil end
    return FormatMoney(MaxOf(c.moneyCoppers))
end

-- Strategy: max numeric across chars (e.g. "Highest 3v3 personal rating").
local function TryNumericMax(c)
    local fromCounts = MaxOf(c.unlabeledCounts) or 0
    local fromNums   = MaxOf(c.plainNums) or 0
    local m = math.max(fromCounts, fromNums)
    if m > 0 or #c.unlabeledCounts > 0 or #c.plainNums > 0 then
        return BreakUpLargeNumbers(m)
    end
    return nil
end

-- Strategy: per-character labels match named sibling stats (e.g. delve "label
-- = Kriegval's Rest" matches sibling "Kriegval's Rest clears"). Sum the matched
-- siblings across chars; the label whose siblings sum highest wins.
--
-- Skipped when the stat name carries a qualifier the per-instance siblings
-- don't share -- "Rated battleground played the most" has per-BG siblings but
-- they count general (unrated + rated) play, not rated specifically.
local function TryLabeledSiblingSum(id, c)
    if #c.labelOrder == 0 then return nil end
    if StatNameLower(id):find("rated", 1, true) then return nil end

    local siblings = GetSiblingStats(id)
    local bestLabel, bestSum, bestIDs

    for _, lbl in ipairs(c.labelOrder) do
        local sum, any, ids = 0, false, {}
        for _, s in ipairs(siblings) do
            local lname = s.name:lower()
            if not NameLooksLikeAggregate(lname) and s.name:find(lbl, 1, true) then
                for k, char in pairs(c.chars) do
                    if not IsCharDisabled(k) then
                        local sv = char.stats and char.stats[s.id]
                        local nval = sv and ParseNumericStat(sv)
                        if nval then sum = sum + nval; any = true end
                    end
                end
                table.insert(ids, s.id)
            end
        end
        if any and (bestSum == nil or sum > bestSum) then
            bestLabel, bestSum, bestIDs = lbl, sum, ids
        end
    end
    if not bestLabel then return nil end
    AS._resolvedDetails[id] = { label = bestLabel, siblingIDs = bestIDs }
    return ("%s (%s)"):format(BreakUpLargeNumbers(bestSum), bestLabel)
end

-- Strategy: aggregate per-char "the most" labeled counts. Best signal we have
-- when raw siblings don't exist (Pandaria dungeon boss defeated the most) or
-- shouldn't be summed (rated stats).
local function TryLabelAggregation(c)
    if #c.labelOrder == 0 then return nil end
    local bestLabel, bestSum
    for lbl, total in pairs(c.byLabel) do
        if bestSum == nil or total > bestSum then
            bestLabel, bestSum = lbl, total
        end
    end
    if not bestLabel then return nil end
    return ("%s (%s)"):format(BreakUpLargeNumbers(bestSum), bestLabel)
end

-- Strategy: for "N ()" empty-paren stats, walk per-instance siblings, group by
-- base name (combining all difficulties of the same boss), sum across chars,
-- pick the highest. Filters dungeon vs raid by detecting Raid Finder difficulty.
local function TryEmptyParensGrouped(id, c)
    if #c.unlabeledCounts == 0 then return nil end

    local statLower  = StatNameLower(id)
    local wantRaid   = statLower:find("raid", 1, true) ~= nil
    local wantDungeon = statLower:find("dungeon", 1, true) ~= nil

    local siblings = GetSiblingStats(id)
    local byBase = {}
    for _, s in ipairs(siblings) do
        local lname = s.name:lower()
        if s.name:find("%(") and not NameLooksLikeAggregate(lname) then
            local base, paren = s.name:match("^(.-)%s*%((.-)%)%s*$")
            if base then
                base = StripTrailingVerb(base)
                local sum, any = 0, false
                for k, char in pairs(c.chars) do
                    if not IsCharDisabled(k) then
                        local sv = char.stats and char.stats[s.id]
                        local nval = sv and ParseNumericStat(sv)
                        if nval then sum = sum + nval; any = true end
                    end
                end
                if any then
                    local g = byBase[base] or { sum = 0, hasRaidFinder = false, ids = {} }
                    g.sum = g.sum + sum
                    table.insert(g.ids, s.id)
                    if paren and paren:lower():find(RAID_FINDER_TAG, 1, true) then
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
    if not bestName then return nil end
    AS._resolvedDetails[id] = { label = bestName, siblingIDs = bestIDs }
    return ("%s (%s)"):format(BreakUpLargeNumbers(bestSum), bestName)
end

-- Strategy: plain max from any classified bucket, used as a final fallback for
-- max-style stats whose values were just numbers / empty parens with no
-- resolvable label.
local function TryPlainMax(c)
    local m = TryMoneyMax(c)
    if m then return m end
    return TryNumericMax(c)
end

-- Non-max-style stats: prefer money sum, then numeric sum, then first non-numeric.
local function ResolveCumulative(c)
    if #c.moneyCoppers > 0 then return FormatMoney(SumOf(c.moneyCoppers)) end
    if #c.plainNums > 0 then return BreakUpLargeNumbers(SumOf(c.plainNums)) end
    return c.fallback or "--"
end

-- Pipeline for max-style stats. Order matters: prefer the most data-faithful
-- resolution that succeeds.
local function ResolveMaxStyle(id, c)
    return TryLabeledSiblingSum(id, c)
        or TryLabelAggregation(c)
        or TryEmptyParensGrouped(id, c)
        or TryPlainMax(c)
        or "--"
end

--------------------------------------------------------------------------------
-- SummedStatistic (memoized public entry point)
--------------------------------------------------------------------------------

local function SummedStatisticUncached(id)
    local chars = AccountStatisticsDB and AccountStatisticsDB.characters
    if not chars then return "--" end
    local classified = ClassifyValues(id)
    if IsMaxStyleStatistic(id) then
        return ResolveMaxStyle(id, classified)
    end
    return ResolveCumulative(classified)
end

local _summedCache = {}

local function SummedStatistic(id)
    local cached = _summedCache[id]
    if cached ~= nil then return cached end
    local result = SummedStatisticUncached(id)
    _summedCache[id] = result
    return result
end

AS.SummedStatistic = SummedStatistic

function AS.InvalidateSummed()
    wipe(_summedCache)
    wipe(AS._resolvedDetails)
end

-- Used by core.lua's ScrapeStats to record per-character values without going
-- through any wrapper.
AS.RawGetStatistic = function(id) return _G.GetStatistic(id) end

--------------------------------------------------------------------------------
-- Per-character leader resolution (tooltip helper)
--
-- For "the most" stats with empty parens, figure out which boss this character
-- has actually killed the most by walking sibling per-instance kill stats.
--------------------------------------------------------------------------------

local function ResolvePerCharLeader(charStats, id)
    if type(charStats) ~= "table" then return nil end
    local statLower = StatNameLower(id)
    local wantRaid    = statLower:find("raid", 1, true) ~= nil
    local wantDungeon = statLower:find("dungeon", 1, true) ~= nil

    local siblings = GetSiblingStats(id)
    local byBase = {}
    for _, s in ipairs(siblings) do
        local lname = s.name:lower()
        if s.name:find("%(") and not NameLooksLikeAggregate(lname) then
            local base, paren = s.name:match("^(.-)%s*%((.-)%)%s*$")
            if base then
                base = StripTrailingVerb(base)
                local nval = charStats[s.id] and ParseNumericStat(charStats[s.id])
                if nval then
                    local g = byBase[base] or { sum = 0, hasRaidFinder = false }
                    g.sum = g.sum + nval
                    if paren and paren:lower():find(RAID_FINDER_TAG, 1, true) then
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

function AS.FormatPerCharValue(value, charStats, id)
    if type(value) ~= "string" then return tostring(value or "--") end
    local cn, lbl = ParseCountWithLabel(value)
    if cn and (lbl == nil or lbl == "") then
        local resolved = ResolvePerCharLeader(charStats, id)
        if resolved then
            return ("%s (%s)"):format(BreakUpLargeNumbers(cn), resolved)
        end
        return BreakUpLargeNumbers(cn)
    end
    return value
end

--------------------------------------------------------------------------------
-- Cache priming
--
-- Build _catMap and pre-compute every max-style stat's SummedStatistic in the
-- background so the first click on a "the most"-heavy category (Dungeons & Raids)
-- doesn't freeze the game.
--------------------------------------------------------------------------------

local function MakeBudgetedYielder(budgetMs)
    if not debugprofilestop then return function() end end
    local lastYield = debugprofilestop()
    return function()
        if debugprofilestop() - lastYield > budgetMs then
            coroutine.yield()
            lastYield = debugprofilestop()
        end
    end
end

local _primeCo, _primeRunner = nil, nil

function AS.PrimeCachesAsync()
    if _primeCo then return end
    _primeCo = coroutine.create(function()
        local yielder = MakeBudgetedYielder(4)

        -- Phase 1: build category map incrementally with yields per stat.
        if not _catMap then
            _catMap = {}
            local seen = {}
            for _, src in ipairs({ GetStatisticsCategoryList, GetCategoryList }) do
                if type(src) == "function" then
                    local ok, list = pcall(src)
                    if ok and type(list) == "table" then
                        for _, cid in ipairs(list) do
                            if not seen[cid] then
                                seen[cid] = true
                                IngestCategory(cid)
                                yielder()
                            end
                        end
                    end
                end
            end
        end

        -- Phase 2: warm SummedStatistic for every max-style stat.
        local ids = (AS.GetAllStatIDs and AS.GetAllStatIDs()) or {}
        for _, id in ipairs(ids) do
            if IsMaxStyleStatistic(id) then SummedStatistic(id) end
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
