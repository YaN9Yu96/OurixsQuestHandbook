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
