local _, ns = ...

-- Quest reward items.
--
-- QuestieDB's Quest entity has no reward-item field, so the only static source is the
-- inverted ItemDB.questRewards index (built in DataSource). That reverse map cannot say
-- whether an item is a guaranteed reward or one of several "choose one" rewards, so the UI
-- simply shows every reward item with no such distinction. (The live client is the only
-- authority on that split, and only for quests in the player's log — intentionally not used
-- here, per design.)

local R = {}
ns.Rewards = R

-- All reward item ids for a quest, or nil when the quest has no known rewards.
function R.ForQuest(id)
    if not id then return nil end
    local items = ns.Source.Rewards and ns.Source.Rewards(id)
    if items and #items > 0 then return items end
    return nil
end

-- Base experience reward for a quest.
--
-- QuestieDB's Quest entity has no XP field. The static, session-wide table lives in
-- QuestieDB's own support data (LibQuestieDB.Support.Get("QuestXP").db), keyed by quest
-- id as { questLevel, baseXP }. It covers every quest in the database -- including ones
-- the player never picked up -- which is exactly what a chain handbook needs. This is
-- the quest's base XP (not the level-scaled amount the client pays out), so it stays
-- stable and reads the same on every row, like the reward-item icons.
local xpDB
local function getXPDB()
    if xpDB ~= nil then return xpDB end
    local lib = _G.LibQuestieDB
    local ok, mod = pcall(function()
        return lib and lib.Support and lib.Support.Get and lib.Support.Get("QuestXP")
    end)
    if ok and mod and type(mod.db) == "table" then
        xpDB = mod.db
    else
        xpDB = false  -- probed once, unavailable: don't re-probe on every row
    end
    return xpDB
end

-- Base XP as an integer, or nil when the quest has no known XP reward.
function R.XP(id)
    if not id then return nil end
    local db = getXPDB()
    if not db then return nil end
    local e = db[id]
    if type(e) ~= "table" then return nil end
    local xp = e[2]
    if type(xp) ~= "number" or xp <= 0 then return nil end
    return math.floor(xp)
end

-- Money reward in copper, or nil when there is none / the API is unavailable.
-- On this client GetQuestLogRewardMoney is keyed by quest id (Questie and
-- DungeonsForever both query it that way), so it also works for quests not in the log.
function R.Money(id)
    if not id or type(GetQuestLogRewardMoney) ~= "function" then return nil end
    local ok, copper = pcall(GetQuestLogRewardMoney, id)
    if ok and type(copper) == "number" and copper > 0 then
        return math.floor(copper)
    end
    return nil
end
