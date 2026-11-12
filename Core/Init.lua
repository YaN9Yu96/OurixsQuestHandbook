local ADDON, ns = ...

-- Entry point. Quest data comes exclusively from the external QuestieDB
-- library (a hard .toc dependency). The only local state is view options and
-- window position; no quest data is observed, corrected or persisted.

function ns.Print(msg)
    local text = "|cff46bf72OQH|r " .. tostring(msg)
    local f = _G.DEFAULT_CHAT_FRAME
    if f and f.AddMessage then
        f:AddMessage(text)
    elseif _G.print then
        _G.print(text)
    end
end

local function applyDefaults()
    _G.OurixsQuestHandbookDB = _G.OurixsQuestHandbookDB or {}
    _G.OurixsQuestHandbookCharDB = _G.OurixsQuestHandbookCharDB or {}
    ns.db = _G.OurixsQuestHandbookDB
    ns.char = _G.OurixsQuestHandbookCharDB

    ns.db.minimap = ns.db.minimap or {}
    if ns.db.minimap.show == nil then ns.db.minimap.show = true end
    if ns.db.minimap.angle == nil then ns.db.minimap.angle = 215 end

    ns.char.collected = nil -- legacy self-collected data is intentionally dropped
    ns.char.collapsed = ns.char.collapsed or {}
    ns.char.chainCollapsed = ns.char.chainCollapsed or {}
    if ns.char.npcPanel == nil then ns.char.npcPanel = true end
    if ns.char.showAllClasses == nil then ns.char.showAllClasses = false end
    if ns.char.showAllRaces == nil then ns.char.showAllRaces = false end
    if ns.char.hideCompleted == nil then ns.char.hideCompleted = false end
    if ns.char.followZone == nil then ns.char.followZone = true end
    if ns.char.faction ~= "Alliance" and ns.char.faction ~= "Horde" then
        ns.char.faction = (UnitFactionGroup and UnitFactionGroup("player")) or "Alliance"
    end
    ns.faction = ns.char.faction
    ns.search = ""
    ns.selectedQuest = nil
end

-- Default page: the player's own faction and the map they are standing on.
-- The client may not report a map yet during PLAYER_LOGIN, so fall back to a
-- busy low-level zone for the current faction instead of an empty enemy zone.
local function defaultEntry()
    if ns.char.followZone ~= false then
        local here = ns.Chains.CurrentZoneEntry and ns.Chains.CurrentZoneEntry()
        if here and ns.Source.byId[here] then return here end
    end
    local best, bestScore = nil, -math.huge
    for _, e in ipairs(ns.Source.entries or {}) do
        if e.cat == "zones" or e.cat == "dungeons" then
            local n, linked = 0, 0
            for _, id in ipairs(e.quests or {}) do
                local q = ns.Source.Get(id)
                if ns.Chains.Visible(q, ns.faction) then
                    n = n + 1
                    if q.pre and #q.pre > 0 then linked = linked + 1 end
                end
            end
            if n > 0 then
                local score = n + linked * 3 - (e.minLevel or 60) * 2
                if score > bestScore then best, bestScore = e.id, score end
            end
        end
    end
    if best then return best end
    return ns.Source.entries[1] and ns.Source.entries[1].id
end
ns.PickDefaultEntry = defaultEntry

-- Build the quest index the first time something actually needs it, and then keep it for
-- the rest of the session. The index is one pass over every quest QuestieDB knows, which
-- is the only expensive thing this addon ever does; doing it on the first window open
-- would put that cost in front of the player's click, so initialize() warms it up a few
-- seconds after login instead and nothing is ever thrown away afterwards.
function ns.EnsureData()
    if not ns.Source.IsBuilt() then ns.Chains.Build() end
    if ns.selectedEntry and ns.Source.byId[ns.selectedEntry] then return end
    local saved = ns.char.selectedEntry
    local eid = (saved and ns.Source.byId[saved]) and saved or defaultEntry()
    ns.selectedEntry = eid
    ns.char.selectedEntry = eid
end

-- Cheap refresh: only when something is actually visible.
function ns.Refresh()
    if ns.Main:IsShown() then ns.Main:Refresh() end
end

local refreshPending = false
function ns.RefreshSoon()
    if refreshPending then return end
    refreshPending = true
    if C_Timer and C_Timer.After then
        C_Timer.After(0.25, function()
            refreshPending = false
            ns.Refresh()
        end)
    else
        refreshPending = false
        ns.Refresh()
    end
end

local lastNpcQuest

local function showNpcPanel()
    if ns.char.npcPanel == false then
        ns.NpcPanel:Hide()
        return
    end
    local qid = ns.Collector.CurrentQuestID() or lastNpcQuest
    if qid then
        lastNpcQuest = qid
        ns.NpcPanel:Show(qid)
    else
        ns.NpcPanel:Hide()
    end
end

local function initialize()
    if ns.ready then return end
    if ns.depFailed then return end

    -- QuestieDB is a declared .toc dependency, so it has loaded before us, but
    -- verify the contract so a version skew fails with a clear message instead
    -- of a cryptic nil index three files later.
    if not _G.QuestDB or not _G.LibQuestieDB or not _G.LibQuestieDB.RequireContract then
        ns.depFailed = true
        ns.Print("QuestieDB not found. Install the QuestieDB library and reload.")
        return
    end
    -- pcall returns (callOk, contractOk, message); RequireContract itself
    -- reports a version skew as (false, message), not as an error.
    local called, satisfied, why = pcall(_G.LibQuestieDB.RequireContract, 4)
    if not called or not satisfied then
        ns.depFailed = true
        ns.Print(tostring(why or called) .. " Install a compatible QuestieDB and reload.")
        return
    end

    ns.ready = true

    applyDefaults()
    ns.selectedEntry = ns.char.selectedEntry

    ns.Main.Create()
    ns.Minimap.Create()
    ns.NpcPanel.Create()
    ns.Share.Create()

    if _G.QuestFrame and QuestFrame.HookScript then
        pcall(QuestFrame.HookScript, QuestFrame, "OnHide", function()
            ns.NpcPanel:Hide()
        end)
    end
    if _G.WorldMapFrame and WorldMapFrame.HookScript then
        pcall(WorldMapFrame.HookScript, WorldMapFrame, "OnShow", function()
            ns.Map.OnMapChanged()
        end)
    end

    -- Warm the quest index up a few seconds after login, then never let go of it. Doing
    -- it here instead of on the first open is what removes the one hitch the handbook used
    -- to have: the window, every page switch and every reopen after that are instant.
    if C_Timer and C_Timer.After then
        C_Timer.After(3, function()
            if ns.ready and not ns.Source.IsBuilt() then pcall(ns.EnsureData) end
        end)
        -- Title cache for whatever the default page shows, only when the window is up.
        C_Timer.After(4, function()
            if ns.Main:IsShown() then ns.Main:Refresh() end
        end)
    end
end

SLASH_OURIXSQUESTHANDBOOK1 = "/oqh"
SLASH_OURIXSQUESTHANDBOOK2 = "/ourixsquesthandbook"
-- One command, one action: open or close the handbook. Everything else (faction scope,
-- filters, minimap button, NPC panel) lives in the options panel, so there is nothing
-- to memorise and no argument parsing to keep in sync with the UI.
SlashCmdList["OURIXSQUESTHANDBOOK"] = function()
    if not ns.ready then initialize() end
    if not ns.ready then return end
    ns.Main:Toggle()
end

local ev = CreateFrame("Frame")
local EVENTS = {
    "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_LEVEL_UP",
    "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN", "QUEST_LOG_UPDATE",
    "QUEST_DATA_LOAD_RESULT",
    "QUEST_DETAIL", "QUEST_PROGRESS", "QUEST_COMPLETE",
    "QUEST_FINISHED", "QUEST_GREETING", "GOSSIP_CLOSED", "WORLD_MAP_UPDATE",
}
for _, name in ipairs(EVENTS) do pcall(ev.RegisterEvent, ev, name) end

ev:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON then initialize() end
        return
    end
    if event == "PLAYER_LOGIN" then
        initialize()
        return
    end
    if not ns.ready then return end

    if event == "QUEST_DATA_LOAD_RESULT" then
        if arg1 then
            ns.Q.OnLoaded(arg1, arg2)
            -- Repaint that one row instead of refreshing the page: every row asks the
            -- client to load its own quest, so a full refresh here would rebuild the
            -- whole list once per loaded quest and start the requests all over again.
            local main = ns.Main and ns.Main.frame
            if main and main:IsShown() and main.view then
                ns.ChainView.Patch(main.view, arg1)
            end
        end
    elseif event == "QUEST_ACCEPTED" then
        ns.Collector.OnAccepted(arg1)
        if ns.Collector.lastQuestID then lastNpcQuest = ns.Collector.lastQuestID end
        ns.Q.Bump()
        ns.RefreshSoon()
    elseif event == "QUEST_LOG_UPDATE" or event == "QUEST_TURNED_IN" or
           event == "QUEST_REMOVED" or event == "PLAYER_LEVEL_UP" then
        -- The log can have changed, so the memoised status of every quest is stale.
        ns.Q.Bump()
        ns.RefreshSoon()
    elseif event == "QUEST_DETAIL" or event == "QUEST_PROGRESS" or
           event == "QUEST_COMPLETE" then
        if C_Timer and C_Timer.After then
            C_Timer.After(0.05, showNpcPanel)
        else
            showNpcPanel()
        end
    elseif event == "QUEST_FINISHED" or event == "GOSSIP_CLOSED" or
           event == "QUEST_GREETING" then
        ns.NpcPanel:Hide()
    elseif event == "WORLD_MAP_UPDATE" then
        ns.Map.OnMapChanged()
    elseif event == "PLAYER_ENTERING_WORLD" then
        ns.Q.Invalidate()
        ns.RefreshSoon()
    else
        ns.RefreshSoon()
    end
end)
