local _, ns = ...

-- NPC quest detection only. All quest data comes from QuestieDB; nothing is
-- observed, recorded or written to SavedVariables here.
local C = {}
ns.Collector = C

function C.NewestLogQuestID()
    if not GetNumQuestLogEntries or not GetQuestLogTitle then return nil end
    for i = GetNumQuestLogEntries(), 1, -1 do
        local title, _, _, isHeader, _, _, _, questID = GetQuestLogTitle(i)
        if title and not isHeader and type(questID) == "number" and questID > 0 then
            return questID
        end
    end
    return nil
end

local function findByTitle(text)
    if type(text) ~= "string" or text == "" then return nil end
    text = strtrim and strtrim(text) or text
    -- QuestieDB maintains a name -> ids index; an exact match is all we need.
    local QuestDB = _G.QuestDB
    if QuestDB and QuestDB.IdsByName then
        local ids = QuestDB.IdsByName(text)
        if ids and ids[1] then return ids[1] end
    end
    if QuestDB and QuestDB.GetAllIds then
        for _, id in ipairs(QuestDB.GetAllIds()) do
            if ns.Q.CachedTitle(id) == text then return id end
        end
    end
    return nil
end

local TITLE_REGIONS = {
    "QuestFrameTitleText", "QuestTitleText", "QuestInfoTitleHeader",
    "QuestFrameNpcNameText", "QuestLogQuestTitle",
}

-- Quest ID of the quest currently shown in Blizzard's quest frame. Tries the
-- modern API first, then the greeting/gossip list, then a title match against
-- QuestieDB. Returns nil when nothing is reliable.
function C.CurrentQuestID()
    C.lastMethod = nil
    if GetQuestID then
        local ok, id = pcall(GetQuestID)
        if ok and type(id) == "number" and id > 0 then
            C.lastMethod = "GetQuestID"
            return id
        end
    end
    if QuestFrame and type(QuestFrame.questID) == "number" and QuestFrame.questID > 0 then
        C.lastMethod = "QuestFrame.questID"
        return QuestFrame.questID
    end
    if GetNumAvailableQuests and GetAvailableQuestID then
        local ok, n = pcall(GetNumAvailableQuests)
        if ok and type(n) == "number" then
            for i = 1, n do
                local ok2, id = pcall(GetAvailableQuestID, i)
                if ok2 and type(id) == "number" and id > 0 then
                    C.lastMethod = "GetAvailableQuestID"
                    return id
                end
            end
        end
    end
    if GetNumActiveQuests and GetActiveQuestID then
        local ok, n = pcall(GetNumActiveQuests)
        if ok and type(n) == "number" then
            for i = 1, n do
                local ok2, id = pcall(GetActiveQuestID, i)
                if ok2 and type(id) == "number" and id > 0 then
                    C.lastMethod = "GetActiveQuestID"
                    return id
                end
            end
        end
    end
    if GetTitleText then
        local ok, title = pcall(GetTitleText)
        if ok then
            local id = findByTitle(title)
            if id then C.lastMethod = "GetTitleText" return id end
        end
    end
    for _, name in ipairs(TITLE_REGIONS) do
        local region = _G[name]
        if region and region.GetText then
            local ok, title = pcall(region.GetText, region)
            if ok then
                local id = findByTitle(title)
                if id then C.lastMethod = name return id end
            end
        end
    end
    return nil
end

-- Called on QUEST_ACCEPTED: remember the id so the NPC companion panel can
-- still show a chain after the dialog closes. Memory only, never persisted.
function C.OnAccepted(arg1)
    local qid
    if type(arg1) == "number" and arg1 > 1000 then qid = arg1 end
    qid = qid or C.CurrentQuestID() or C.NewestLogQuestID()
    if qid then C.lastQuestID = qid end
    return qid
end
