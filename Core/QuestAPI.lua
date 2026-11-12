local _, ns = ...

-- Read-only view of the client's quest log API. Never writes to C_QuestLog:
-- writing a global the Blizzard UI reads taints protected frames on this client.
local shims = {}
local QuestLog = setmetatable({}, {
    __index = function(_, name)
        local game = _G.C_QuestLog
        local f = game and game[name]
        if f ~= nil then return f end
        return shims[name]
    end,
    __newindex = function() error("OurixsQuestHandbook: quest log API is read-only", 2) end,
})
local QL = QuestLog

local Q = {}
ns.Q = Q

-- One log row, from whichever API this client actually implements. The legacy flat
-- returns (GetQuestLogTitle) and the 8.0+ table form (C_QuestLog.GetInfo) are both
-- tried: on this client the legacy function exists but can answer nothing, which is
-- exactly how Shift+click used to conclude "not in log" for a freshly accepted quest.
local function logLine(index)
    if type(GetQuestLogTitle) == "function" then
        local ok, title, level, _, isHeader, _, isComplete, _, questID =
            pcall(GetQuestLogTitle, index)
        if ok and title then
            return { title = title, level = level, isHeader = isHeader and true or false,
                     isComplete = isComplete, questID = questID or 0 }
        end
    end
    local getInfo = _G.C_QuestLog and _G.C_QuestLog.GetInfo
    if type(getInfo) == "function" then
        local ok, info = pcall(getInfo, index)
        if ok and type(info) == "table" then
            return { title = info.title, level = info.level,
                     isHeader = info.isHeader and true or false,
                     isComplete = info.isComplete,
                     questID = info.questID or info.questId or 0 }
        end
    end
    return nil
end

local function logCount()
    local cl = _G.C_QuestLog
    if cl and type(cl.GetNumQuestLogEntries) == "function" then
        local ok, n = pcall(cl.GetNumQuestLogEntries)
        if ok and type(n) == "number" then return n end
    end
    if type(GetNumQuestLogEntries) == "function" then
        local ok, n = pcall(GetNumQuestLogEntries)
        if ok and type(n) == "number" then return n end
    end
    return 0
end

-- Log position of a quest. A direct index lookup is preferred (cheap and exact), then
-- the two legacy helpers, then a scan of the log rows.
local function logIndex(id)
    if not id then return nil end
    local cl = _G.C_QuestLog
    if cl and type(cl.GetLogIndexForQuestID) == "function" then
        local ok, idx = pcall(cl.GetLogIndexForQuestID, id)
        if ok and type(idx) == "number" and idx > 0 then return idx end
    end
    if type(_G.GetQuestLogIndexByID) == "function" then
        local ok, idx = pcall(_G.GetQuestLogIndexByID, id)
        if ok and type(idx) == "number" and idx > 0 then return idx end
    end
    for i = 1, logCount() do
        local info = logLine(i)
        if info and not info.isHeader and info.questID == id then return i, info end
    end
    return nil
end

-- Quests already in the log expose their real title / level synchronously.
local function logEntry(id)
    local _, info = logIndex(id)
    return info
end

if type(GetQuestLogTitle) == "function" or type(GetNumQuestLogEntries) == "function" or
    (_G.C_QuestLog and type(_G.C_QuestLog.GetInfo) == "function") then
    shims.GetInfo = logLine
    shims.GetNumQuestLogEntries = logCount
    shims.GetLogIndexForQuestID = function(id) return (logIndex(id)) end
    shims.IsOnQuest = function(id) return logIndex(id) ~= nil end
    shims.GetTitleForQuestID = function(id)
        if QL.GetQuestInfo then
            local ok, name = pcall(QL.GetQuestInfo, id)
            if ok and type(name) == "string" and name ~= "" then return name end
        end
        local _, info = logIndex(id)
        return info and info.title or nil
    end
    shims.IsComplete = function(id)
        local _, info = logIndex(id)
        return info ~= nil and (info.isComplete == 1 or info.isComplete == true)
    end
end
shims.RequestLoadQuestByID = function() end
shims.IsQuestFlaggedCompleted = function(id)
    return IsQuestFlaggedCompleted and IsQuestFlaggedCompleted(id) and true or false
end
if GetQuestLogSelection and SelectQuestLogEntry then
    shims.GetSelectedQuest = function()
        local info = logLine(GetQuestLogSelection())
        return info and info.questID or 0
    end
    shims.SetSelectedQuest = function(id)
        local index = logIndex(id)
        if index then SelectQuestLogEntry(index) end
    end
end

Q.HasAsyncLoad = type(_G.C_QuestLog) == "table" and type(_G.C_QuestLog.RequestLoadQuestByID) == "function"

local titleCache, missingTitle, requested, attempts = {}, {}, {}, {}

-- Quest status is asked for *every* quest in the index on every refresh (the category
-- tree's counts), which is thousands of client calls per pass. Memoising the two answers
-- per log generation is what makes switching pages cheap: after the first pass only table
-- lookups happen. Q.Bump() is called whenever the log can have changed.
local doneCache, activeCache, readyCache = {}, {}, {}
local stamp = 0

function Q.Stamp()
    return stamp
end

function Q.Bump()
    stamp = stamp + 1
    wipe(doneCache)
    wipe(activeCache)
    wipe(readyCache)
end

-- One trickle queue for every "please load this quest" request. The client parses quest
-- data on demand and each request is expensive, so the paint path only enqueues; a few
-- entries are drained per tick. Requesting a 60-row page used to fire 60 loads inside a
-- single frame, which is exactly where the pause came from.
local pending, head, tail, inQueue = {}, 1, 0, {}
-- Each of these is a query to the SERVER: the client does not keep a name or the objectives
-- text for a quest it has never accepted, so RequestLoadQuestByID asks and the answer
-- arrives later as QUEST_DATA_LOAD_RESULT. That is why the budget is deliberately small -- a
-- page of 150 rows must not turn into a burst of 150 round trips.
local TICK, PER_TICK, MAX_QUEUE = 0.2, 2, 200

local function fire(id)
    if not id or requested[id] then return end
    if (attempts[id] or 0) >= 2 then return end
    requested[id] = true
    -- The modern client exposes this on C_QuestLog; the legacy QuestLog proxy is only a
    -- stub fallback (it is read-only and may be nil). Always prefer the real entry point so
    -- the request actually reaches the server on the client that ships this API.
    local cl = _G.C_QuestLog
    if cl and type(cl.RequestLoadQuestByID) == "function" then
        pcall(cl.RequestLoadQuestByID, id)
    elseif QL and QL.RequestLoadQuestByID then
        pcall(QL.RequestLoadQuestByID, id)
    end
end

-- Drain the queue at a bounded rate. Split out so the pump frame and the tests drive the
-- very same code.
function Q.PumpNow()
    local n = 0
    while head <= tail and n < PER_TICK do
        local id = pending[head]
        pending[head] = nil
        head = head + 1
        n = n + 1
        if id then
            inQueue[id] = nil
            fire(id)
        end
    end
    if head > tail then
        wipe(pending)
        head, tail = 1, 0
        return true
    end
    return false
end

-- Driven by a frame, not by C_Timer: one OnUpdate only runs while there is work, and a
-- dropped timer can never wedge the queue.
local pumpFrame, pumpAcc
local function ensurePump()
    if pumpFrame then return pumpFrame end
    pumpFrame = CreateFrame("Frame", nil, _G.UIParent)
    pumpFrame:SetSize(1, 1)
    pumpAcc = 0
    pumpFrame:SetScript("OnUpdate", function(self, elapsed)
        pumpAcc = pumpAcc + (elapsed or 0)
        if pumpAcc < TICK then return end
        pumpAcc = 0
        if Q.PumpNow() then self:Hide() end
    end)
    pumpFrame:Hide()
    return pumpFrame
end

function Q.Request(id)
    if not id or requested[id] or inQueue[id] then return end
    if (attempts[id] or 0) >= 2 then return end
    if tail - head + 1 >= MAX_QUEUE then return end
    inQueue[id] = true
    tail = tail + 1
    pending[tail] = id
    local frame = ensurePump()
    frame:Show()
end

function Q.Invalidate(id)
    if id then
        titleCache[id] = nil
        missingTitle[id] = nil
        doneCache[id] = nil
        activeCache[id] = nil
        readyCache[id] = nil
        requested[id] = nil
    else
        wipe(titleCache)
        wipe(missingTitle)
        wipe(requested)
        wipe(attempts)
        wipe(inQueue)
        wipe(pending)
        head, tail = 1, 0
        if pumpFrame then pumpFrame:Hide() end
    end
    Q.Bump()
end

-- QUEST_DATA_LOAD_RESULT: the client now knows this quest. On an explicit
-- failure we allow one retry, but never loop on our own event.
function Q.OnLoaded(id, success)
    if not id then return end
    titleCache[id] = nil
    missingTitle[id] = nil
    if success == false then
        attempts[id] = (attempts[id] or 0) + 1
        requested[id] = nil
    end
end

-- Synchronous only: never triggers an async request. Used to match a quest
-- title shown in an NPC dialog against quests the client already knows.
function Q.CachedTitle(id)
    if not id then return nil end
    local cached = titleCache[id]
    if cached then return cached end
    -- A miss is remembered as well: the paint path asks for the same handful of titles
    -- on every repaint, and four client calls per miss per row adds up. Cleared by
    -- Invalidate / OnLoaded, which is exactly when the answer can change.
    if missingTitle[id] then return nil end
    local ok, name = pcall(QL.GetTitleForQuestID, id)
    if ok and type(name) == "string" and name ~= "" then
        titleCache[id] = name
        return name
    end
    -- Some clients only expose GetQuestInfo, or only expose a title through
    -- the quest hyperlink. Try both before falling back to an ID label.
    local raw = _G.C_QuestLog
    if raw and raw.GetQuestInfo then
        local ok2, name2 = pcall(raw.GetQuestInfo, id)
        if ok2 and type(name2) == "string" and name2 ~= "" then
            titleCache[id] = name2
            return name2
        end
    end
    if GetQuestLink then
        local ok2, link = pcall(GetQuestLink, id)
        if ok2 and type(link) == "string" then
            local name2 = link:match("%[([^%]]+)%]")
            if name2 and name2 ~= "" then
                titleCache[id] = name2
                return name2
            end
        end
    end
    local info = logEntry(id)
    if info and info.title and info.title ~= "" then
        titleCache[id] = info.title
        return info.title
    end
    missingTitle[id] = true
    return nil
end

-- Title for the list. Identical to Q.Title except that it never asks the client to load
-- the quest: QuestieDB already carries a localised name, so a row can be painted without
-- a single client call. Loading stays with the trickle queue, which repaints that one row
-- when the answer arrives.
function Q.FastTitle(id, fallback)
    if not id then return fallback or "" end
    local name = Q.CachedTitle(id)
    if name then return name end
    local t = fallback
    if not t and ns.Source and ns.Source.Get then
        local q = ns.Source.Get(id)
        t = q and q.titleFallback
    end
    return t or ns.L["Quest #%d"]:format(id)
end

function Q.Title(id, fallback)
    if not id then return fallback or "" end
    local name = Q.CachedTitle(id)
    if name then return name end
    Q.Request(id)
    if fallback ~= nil then return fallback end
    -- Quests the client cannot name by id fall back to the localized name
    -- supplied by QuestieDB (captured in ns.Source by DataSource.lua).
    local t
    if ns.Source and ns.Source.Get then
        local q = ns.Source.Get(id)
        t = q and q.titleFallback
    end
    return t or ns.L["Quest #%d"]:format(id)
end

function Q.Level(id, fallback)
    local info = logEntry(id)
    if info and type(info.level) == "number" and info.level > 0 then return info.level end
    if QL.GetQuestDifficultyLevel then
        local ok, level = pcall(QL.GetQuestDifficultyLevel, id)
        if ok and type(level) == "number" and level > 0 then return level end
    end
    return fallback
end

function Q.Done(id)
    local hit = doneCache[id]
    if hit ~= nil then return hit end
    local ok, v = pcall(QL.IsQuestFlaggedCompleted, id)
    hit = ok and v and true or false
    if id then doneCache[id] = hit end
    return hit
end

function Q.Active(id)
    local hit = activeCache[id]
    if hit ~= nil then return hit end
    local ok, v = pcall(QL.IsOnQuest, id)
    hit = ok and v and true or false
    if id then activeCache[id] = hit end
    return hit
end

function Q.Ready(id)
    local hit = readyCache[id]
    if hit ~= nil then return hit end
    hit = false
    if Q.Active(id) then
        if QL.ReadyForTurnIn then
            local ok, v = pcall(QL.ReadyForTurnIn, id)
            hit = ok and v and true or false
        elseif QL.IsComplete then
            local ok, v = pcall(QL.IsComplete, id)
            hit = ok and v and true or false
        end
    end
    if id then readyCache[id] = hit end
    return hit
end

function Q.NativeLink(id)
    if GetQuestLink then
        local ok, link = pcall(GetQuestLink, id)
        if ok and type(link) == "string" and link ~= "" then return link end
    end
    -- Classic clients sometimes have no GetQuestLink for quests outside the
    -- log. The quest: hyperlink format is native, so build it directly.
    local name = Q.Title(id, nil)
    local level = Q.Level(id, nil) or 1
    if name and name ~= "" then
        return ("|cffffff00|Hquest:%d:%d|h[%s]|h|r"):format(id, level, name)
    end
    return nil
end

-- The native quest log container, named differently across client generations.
local function questLogFrame()
    local f = _G.QuestLogFrame
    if type(f) == "table" and f.IsShown then return f end
    local log = _G.QuestLog
    if type(log) == "table" and log.frame then return log.frame end
    return nil
end

local function showQuestLog()
    local f = questLogFrame()
    if f and f.IsShown and f:IsShown() then return true, f end
    if f then
        if type(_G.ShowUIPanel) == "function" then pcall(_G.ShowUIPanel, f) end
        if (not f.IsShown or not f:IsShown()) and type(f.Show) == "function" then
            pcall(f.Show, f)
        end
        if not f.IsShown or f:IsShown() then return true, f end
    end
    if type(_G.ToggleQuestLog) == "function" then
        local ok = pcall(_G.ToggleQuestLog)
        if ok and (not f or not f.IsShown or f:IsShown()) then return true, true end
    end
    return false, f
end

-- Open the native quest log on a specific quest. Different clients expose wildly
-- different ways of doing this, so every known shape is tried in order and only a path
-- that actually exists is used.
-- Returns (found, shown): "found" answers "is this quest in the log", "shown" reports
-- whether the native panel is actually on screen, so the caller only closes its own
-- window when there is something behind it.
function Q.OpenInLog(id)
    if not id then return false, false end

    -- 1) Clients with a direct helper.
    if type(_G.QuestLog_OpenToQuest) == "function" then
        local ok, res = pcall(_G.QuestLog_OpenToQuest, id)
        if ok and res ~= false then return true, true end
    end
    if _G.C_QuestLog and type(_G.C_QuestLog.OpenQuestLogToQuest) == "function" then
        local ok, res = pcall(_G.C_QuestLog.OpenQuestLogToQuest, id)
        if ok and res ~= false then return true, true end
    end

    -- 2) "In the log" and "has a log index" are separate questions: the client can
    -- answer the first while exposing no index at all. Only a quest that the client
    -- denies knowing is reported as missing.
    local index = logIndex(id)
    local onQuest = Q.Active(id)
    if not index and not onQuest then return false, false end

    if QL.SetSelectedQuest then pcall(QL.SetSelectedQuest, id) end
    if index then
        if type(_G.QuestLog_SetSelection) == "function" then
            pcall(_G.QuestLog_SetSelection, index)
        end
        if type(_G.SelectQuestLogEntry) == "function" then
            pcall(_G.SelectQuestLogEntry, index)
        end
    end

    local shown, frame = showQuestLog()
    if index and frame and type(frame.SelectQuestLogEntry) == "function" then
        pcall(frame.SelectQuestLogEntry, frame, index)
    end

    if type(_G.QuestLog_Update) == "function" then pcall(_G.QuestLog_Update) end
    if type(_G.QuestLogFrame_Update) == "function" then pcall(_G.QuestLogFrame_Update) end
    return true, shown
end

function Q.PlayerLevel()
    return UnitLevel("player") or 1
end

function Q.DifficultyColor(level)
    if GetQuestDifficultyColor and type(level) == "number" then
        local ok, c = pcall(GetQuestDifficultyColor, level)
        if ok and type(c) == "table" and c.r then return c.r, c.g, c.b end
    end
    return 0.75, 0.75, 0.75
end

function Q.ColorEscape(level)
    local r, g, b = Q.DifficultyColor(level)
    return ("|cff%02x%02x%02x"):format(math.floor(r * 255 + 0.5),
        math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

-- "done" | "ready" | "active" | "available" | "locked" plus lock reasons.
-- opts.skipPre suppresses prerequisites already expressed by the chain UI.
function Q.Status(q, opts)
    if not q or not q.id then return "locked", {} end
    if Q.Done(q.id) then return "done" end
    if Q.Active(q.id) then
        return Q.Ready(q.id) and "ready" or "active"
    end
    -- Start-point-only records have no level or prerequisite data. Never
    -- claim they are available; show a neutral "details unavailable" state.
    if q.sparse then return "unknown", {} end
    local reasons, flags = {}, {}
    local mine = Q.PlayerLevel()
    if q.minLevel and mine < q.minLevel then
        flags.level = q.minLevel
        reasons[#reasons + 1] = ns.L["Requires level %d"]:format(q.minLevel)
    end
    local skip = opts and opts.skipPre
    for _, p in ipairs(q.pre or {}) do
        if type(p) == "number" and not (skip and skip[p]) and not Q.Done(p) then
            flags.pre = true
            reasons[#reasons + 1] = ns.L["Requires: "] .. Q.FastTitle(p, nil)
        end
    end
    if #reasons > 0 then return "locked", reasons, flags end
    return "available"
end

Q.STATUS_COLOR = {
    done      = { 0.55, 0.85, 0.32 },
    ready     = { 0.30, 0.90, 0.60 },
    active    = { 1.00, 0.72, 0.20 },
    available = { 0.62, 0.78, 0.95 },
    locked    = { 0.48, 0.46, 0.44 },
    unknown   = { 0.58, 0.55, 0.49 },
}

function Q.StatusColor(status)
    return unpack(Q.STATUS_COLOR[status] or Q.STATUS_COLOR.locked)
end

function Q.StatusLabel(status)
    if status == "done" then return ns.L["Completed"] end
    if status == "ready" then return ns.L["Ready to turn in"] end
    if status == "active" then return ns.L["In Progress"] end
    if status == "available" then return ns.L["Available"] end
    if status == "unknown" then return ns.L["Details unavailable"] end
    return ns.L["Locked"]
end
