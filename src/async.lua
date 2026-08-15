AccountStatistics = AccountStatistics or {}
local AS = AccountStatistics

-- Background work that yields back to the client so the game doesn't hitch.
--
-- The scrape and the cache priming each carried their own copy of this: a
-- yielder, a coroutine, a runner frame, a re-entrancy guard and an error
-- handler, ~35 lines apiece. The copies had already drifted in their
-- no-`debugprofilestop` fallback (one returned nil, the other a no-op
-- function), which is the kind of difference that turns into a real bug the
-- moment either side starts relying on it.

local runners = {}   -- name -> { frame, co }

-- Yields whenever more than budgetMs of wall-clock has passed since the last
-- yield, so a long job is spread across frames instead of blocking one.
local function makeYielder(budgetMs)
    local lastYield = debugprofilestop()
    return function()
        if debugprofilestop() - lastYield > budgetMs then
            coroutine.yield()
            lastYield = debugprofilestop()
        end
    end
end

-- Run `body(yield)` in the background, giving it roughly budgetMs per frame.
-- `body` must call the yield function it is handed at safe points; everything
-- between two yields runs in a single frame.
--
-- Returns false if a job of this name is already running.
function AS.RunBudgeted(name, body, budgetMs)
    local existing = runners[name]
    if existing and existing.co then return false end

    -- Without a frame clock there is nothing to budget against, so run the job
    -- straight through rather than building a coroutine that can never yield.
    if not debugprofilestop then
        body(function() end)
        return true
    end

    local entry = existing or {}
    runners[name] = entry
    entry.co = coroutine.create(function()
        body(makeYielder(budgetMs or 4))
    end)
    entry.frame = entry.frame or CreateFrame("Frame")

    entry.frame:SetScript("OnUpdate", function(self)
        local co = entry.co
        if not co then self:SetScript("OnUpdate", nil); return end
        local ok, err = coroutine.resume(co)
        if not ok then
            AS.Log("%s error: %s", name, tostring(err))
            entry.co = nil
            self:SetScript("OnUpdate", nil)
            return
        end
        if coroutine.status(co) == "dead" then
            entry.co = nil
            self:SetScript("OnUpdate", nil)
        end
    end)
    return true
end

function AS.IsRunning(name)
    local entry = runners[name]
    return (entry and entry.co) and true or false
end
