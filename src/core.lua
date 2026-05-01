local ADDON_NAME = ...

AccountStatistics = AccountStatistics or {}
local AS = AccountStatistics

function AS.Log(fmt, ...)
    if not (AccountStatisticsDB and AccountStatisticsDB.debug) then return end
    local msg = (select("#", ...) > 0) and fmt:format(...) or fmt
    print("|cff33ff99[AS]|r " .. msg)
end

local function CharKey()
    return GetRealmName() .. "-" .. UnitName("player")
end

-- Stat IDs don't change during a session, so collect them once and reuse the
-- list. Halves the per-scrape API calls (no more GetAchievementInfo per stat).
local _statIDsCache = nil
local function GetAllStatIDs()
    if _statIDsCache then return _statIDsCache end
    local list = {}
    local categories = GetStatisticsCategoryList()
    if categories then
        for _, catID in ipairs(categories) do
            local n = GetCategoryNumAchievements(catID) or 0
            for i = 1, n do
                local id = GetAchievementInfo(catID, i)
                if id then table.insert(list, id) end
            end
        end
    end
    _statIDsCache = list
    return list
end
AS.GetAllStatIDs = GetAllStatIDs

-- Walk the cached stat ID list and copy the current values into a new table.
-- The yieldFn callback is invoked after each stat; in async mode it yields back
-- to the runner whenever the per-frame budget is exhausted, so the scrape no
-- longer freezes the game while iterating hundreds of API calls.
local function DoScrape(yieldFn)
    if not AccountStatisticsDB then return end
    AccountStatisticsDB.characters = AccountStatisticsDB.characters or {}

    local key = CharKey()
    local entry = AccountStatisticsDB.characters[key] or {}
    local startTime = debugprofilestop and debugprofilestop() or 0
    entry.class = select(2, UnitClass("player"))
    entry.classLocalized = UnitClass("player")
    local raceName, raceFile = UnitRace("player")
    entry.race = raceFile
    entry.raceLocalized = raceName
    entry.faction = UnitFactionGroup("player")
    entry.level = UnitLevel("player")
    entry.lastUpdate = time()

    local newStats = {}
    local getStat = AS.RawGetStatistic or GetStatistic
    for _, id in ipairs(GetAllStatIDs()) do
        local val = getStat(id)
        if val and val ~= "" and val ~= "--" then
            newStats[id] = val
        end
        if yieldFn then yieldFn() end
    end

    entry.stats = newStats
    AccountStatisticsDB.characters[key] = entry
    -- Don't invalidate the SummedStatistic cache here; the rendering cost is much
    -- higher than the staleness cost. Manual /as scrape and option toggles still
    -- invalidate.

    local count = 0
    for _ in pairs(newStats) do count = count + 1 end
    if debugprofilestop then
        AS.Log("ScrapeStats: %s -> %d stats in %.0fms", key, count, debugprofilestop() - startTime)
    else
        AS.Log("ScrapeStats: %s -> %d stats", key, count)
    end
end

-- Synchronous path used at logout (no frame ticks after PLAYER_LOGOUT, so we
-- can't rely on a coroutine runner finishing).
function AS.ScrapeStatsSync()
    DoScrape(nil)
end

-- Async path: budget ~4ms of work per frame and resume on the next OnUpdate.
local _scrapeCo = nil
local _scrapeRunner = nil

local function MakeBudgetedYielder(budgetMs)
    if not debugprofilestop then return nil end
    local lastYield = debugprofilestop()
    return function()
        if debugprofilestop() - lastYield > budgetMs then
            coroutine.yield()
            lastYield = debugprofilestop()
        end
    end
end

function AS.ScrapeStats()
    if _scrapeCo then return end  -- already in progress
    AS._eventsSinceLastScrape = 0
    _scrapeCo = coroutine.create(function()
        DoScrape(MakeBudgetedYielder(4))
    end)
    if not _scrapeRunner then _scrapeRunner = CreateFrame("Frame") end
    _scrapeRunner:SetScript("OnUpdate", function(self)
        if not _scrapeCo then self:SetScript("OnUpdate", nil); return end
        local ok, err = coroutine.resume(_scrapeCo)
        if not ok then
            AS.Log("ScrapeStats error: %s", tostring(err))
            _scrapeCo = nil
            self:SetScript("OnUpdate", nil)
            return
        end
        if coroutine.status(_scrapeCo) == "dead" then
            _scrapeCo = nil
            self:SetScript("OnUpdate", nil)
        end
    end)
end

function AS.WipeCharacter(key)
    if AccountStatisticsDB and AccountStatisticsDB.characters then
        AccountStatisticsDB.characters[key] = nil
    end
end

-- Debounced scrape so a flurry of events (turn-in chains, encounter wraps) only
-- triggers one scrape a few seconds later, rather than dozens.
local _pendingScrape = nil
AS._eventsSinceLastScrape = 0
local function ScheduleScrape(delay, reason)
    AS._eventsSinceLastScrape = AS._eventsSinceLastScrape + 1
    if _pendingScrape then return end
    delay = delay or 5
    AS.Log("scrape scheduled in %ds (%s)", delay, reason or "?")
    _pendingScrape = C_Timer.NewTimer(delay, function()
        _pendingScrape = nil
        AS.ScrapeStats()
    end)
end


-- Events likely to change a stat the user can see. Anything that changes a stat
-- counter on the Statistics page belongs here. We don't need every event in the
-- world -- the 60s ticker plus PLAYER_LOGOUT cover the rest.
local SCRAPE_EVENTS = {
    "ACHIEVEMENT_EARNED",         -- any achievement progress
    "PLAYER_DEAD",                -- death counters
    "BOSS_KILL",                  -- raid bosses
    "ENCOUNTER_END",              -- dungeon/raid encounter completion
    "CHALLENGE_MODE_COMPLETED",   -- mythic+ key complete
    "LFG_COMPLETION_REWARD",      -- random dungeon/raid reward
    "PVP_MATCH_COMPLETE",         -- battleground / arena finish
    "QUEST_TURNED_IN",            -- quest counters
}

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_LOGOUT")
for _, ev in ipairs(SCRAPE_EVENTS) do f:RegisterEvent(ev) end

f:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            AccountStatisticsDB = AccountStatisticsDB or { characters = {} }
            AccountStatisticsDB.characters = AccountStatisticsDB.characters or {}
        end
        -- Other addons loading (Blizzard_AchievementUI, etc.) shouldn't trigger a
        -- scrape -- they fire ADDON_LOADED constantly during a session.
        return
    elseif event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(8, AS.ScrapeStats)
        if not AS._ticker then
            -- Stretched to 5 minutes since the event-driven path now handles the
            -- actively-changing stats; this is just the safety net for time-based
            -- ones (/played, zone counts) that don't fire events.
            AS._ticker = C_Timer.NewTicker(300, AS.ScrapeStats)
        end
        -- Warm up the heavy "the most" caches in the background after the initial
        -- scrape so the first click on Dungeons & Raids isn't a 3-5s freeze.
        C_Timer.After(15, function()
            if AS.PrimeCachesAsync then AS.PrimeCachesAsync() end
        end)
    elseif event == "PLAYER_LOGOUT" then
        -- Synchronous final scrape so the latest values land in SavedVariables
        -- before the client serializes them.
        if _pendingScrape then _pendingScrape:Cancel(); _pendingScrape = nil end
        AS.ScrapeStatsSync()
    else
        -- Any of SCRAPE_EVENTS: server-side stats lag a bit, debounce and scrape.
        ScheduleScrape(5, event)
    end
end)

SLASH_ACCOUNTSTATS1 = "/acctstats"
SLASH_ACCOUNTSTATS2 = "/as"
SlashCmdList.ACCOUNTSTATS = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "scrape" then
        AS.ScrapeStats()
        if AS.InvalidateSummed then AS.InvalidateSummed() end
        print("|cff33ff99AccountStatistics|r: scraped stats for " .. CharKey())
    elseif msg:match("^forget ") then
        local key = msg:sub(8)
        AS.WipeCharacter(key)
        print("|cff33ff99AccountStatistics|r: forgot " .. key)
    elseif msg == "list" then
        for k, c in pairs(AccountStatisticsDB.characters) do
            local n = 0
            for _ in pairs(c.stats or {}) do n = n + 1 end
            print(("  %s  (lvl %s %s, %d stats, updated %s)"):format(k, c.level or "?", c.class or "?", n, date("%Y-%m-%d %H:%M", c.lastUpdate or 0)))
        end
    elseif msg:match("^stat ") then
        local id = tonumber(msg:sub(6))
        if not id then print("|cff33ff99AccountStatistics|r: usage /as stat <statID>") return end
        print(("|cff33ff99AccountStatistics|r stat %d:"):format(id))
        for k, c in pairs(AccountStatisticsDB.characters or {}) do
            print(("  %s = %s"):format(k, tostring(c.stats and c.stats[id])))
        end
        print(("  GetStatistic(current) = %s"):format(tostring(GetStatistic(id))))
    elseif msg == "" or msg == "options" or msg == "config" then
        if AS.OpenOptions then AS.OpenOptions() end
    elseif msg == "debug" then
        AccountStatisticsDB.debug = not AccountStatisticsDB.debug
        print(("|cff33ff99AccountStatistics|r debug = %s"):format(tostring(AccountStatisticsDB.debug)))
    elseif msg == "export" or msg == "csv" then
        if AS.ShowExport then AS.ShowExport() end
    elseif msg == "help" then
        print("|cff33ff99AccountStatistics|r commands:")
        print("  /as                  - open settings panel")
        print("  /as debug            - toggle debug logging")
        print("  /as export           - open a CSV view of all stats x characters")
        print("  /as scrape           - capture this character's stats now")
        print("  /as list             - list known characters")
        print("  /as stat <id>        - show one stat across all characters")
        print("  /as forget <Realm-Name>")
    else
        print(("|cff33ff99AccountStatistics|r unknown command: %s (try /as help)"):format(msg))
    end
end
