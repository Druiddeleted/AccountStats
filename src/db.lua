AccountStatistics = AccountStatistics or {}
local AS = AccountStatistics

-- The SavedVariables layer. Every read and write of AccountStatisticsDB goes
-- through here; no other module touches the global.
--
-- Before this existed, five modules poked the global directly across ~40 sites,
-- each re-deriving its own nil-guards and defaults, and the rule "a write to
-- disabledChars/disabledRealms must invalidate the summed cache" was copy-pasted
-- at three call sites -- guarded with `if AS.InvalidateSummed then`, which is a
-- caller admitting it doesn't know whether load order has run yet.

AS.DB = {}
local DB = AS.DB

local function root()
    AccountStatisticsDB = AccountStatisticsDB or {}
    local db = AccountStatisticsDB
    db.characters = db.characters or {}
    db.disabledChars = db.disabledChars or {}
    db.disabledRealms = db.disabledRealms or {}
    return db
end

function DB.Init()
    root()
end

----------------------------------------------------------------------
-- Characters
----------------------------------------------------------------------

-- Character keys are "<Realm>-<Name>".
function DB.RealmFromKey(key)
    return key and key:match("^([^-]+)") or "?"
end

function DB.Characters()
    return root().characters
end

function DB.Character(key)
    return root().characters[key]
end

-- Deliberately does NOT invalidate the summed cache. Scrapes run on a timer and
-- on every achievement update; invalidating here means recomputing every
-- max-style statistic constantly, which is slow enough to be felt in game.
function DB.SetCharacter(key, entry)
    root().characters[key] = entry
end

function DB.RemoveCharacter(key)
    root().characters[key] = nil
end

----------------------------------------------------------------------
-- Enabled / disabled
--
-- These are the writes that DO invalidate: what's summed just changed.
----------------------------------------------------------------------

function DB.IsRealmDisabled(realm)
    return root().disabledRealms[realm] == true
end

function DB.IsCharDisabled(key)
    local db = root()
    if db.disabledChars[key] then return true end
    return db.disabledRealms[DB.RealmFromKey(key)] == true
end

function DB.SetCharEnabled(key, enabled)
    root().disabledChars[key] = (not enabled) or nil
    DB.InvalidateSummed()
end

function DB.SetRealmEnabled(realm, enabled)
    root().disabledRealms[realm] = (not enabled) or nil
    DB.InvalidateSummed()
end

-- Callers never reach for the resolver's cache themselves.
function DB.InvalidateSummed()
    if AS.InvalidateSummed then AS.InvalidateSummed() end
end

-- Iterate the characters that count toward account totals.
function DB.EnabledCharacters()
    local chars, key = root().characters, nil
    return function()
        local entry
        repeat
            key, entry = next(chars, key)
            if key == nil then return nil end
        until not DB.IsCharDisabled(key)
        return key, entry
    end
end

----------------------------------------------------------------------
-- Debug flag
----------------------------------------------------------------------

function DB.Debug()
    return AccountStatisticsDB and AccountStatisticsDB.debug == true
end

function DB.SetDebug(on)
    root().debug = on and true or nil
end

function DB.ToggleDebug()
    DB.SetDebug(not DB.Debug())
    return DB.Debug()
end
