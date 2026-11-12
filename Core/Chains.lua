local _, ns = ...

-- Runtime view over QuestieDB (read once into ns.Source by DataSource.lua).
-- No other addon's globals are ever read.
local C = {}
ns.Chains = C

local continentCache = {}
local playerClass, playerRace, playerFaction

-- UnitRace() returns a locale-independent token, not the numeric race ID used
-- by the reference data. Custom Forever races are resolved through the client.
local RACE_TOKEN = {
    Human = 1, Orc = 2, Dwarf = 3, NightElf = 4, Undead = 5, Tauren = 6,
    Gnome = 7, Troll = 8, Goblin = 9, BloodElf = 10, Draenei = 11,
    Worgen = 22, Gilnean = 23, Pandaren = 24, Nightborne = 27,
    HighmountainTauren = 28, VoidElf = 29, LightforgedDraenei = 30,
    ZandalariTroll = 31, KulTiran = 32,
}

function C.PlayerClass()
    if playerClass == nil then
        local ok, token = pcall(function() return select(2, UnitClass("player")) end)
        playerClass = (ok and token) or false
    end
    return playerClass or nil
end

function C.PlayerRaceID()
    if playerRace == nil then
        -- UnitRace returns (localized name, file token, numeric race id). The numeric
        -- id is the only value that matches requiredRaces bits directly, so it is
        -- tried first; the token table and the name scan are last-resort fallbacks for
        -- clients that omit the third return.
        local ok, name, token, numId = pcall(UnitRace, "player")
        if not ok then name, token, numId = nil, nil, nil end
        if type(numId) == "number" and numId > 0 then
            playerRace = numId
        else
            playerRace = (token and RACE_TOKEN[token]) or false
            if name and C_CreatureInfo and C_CreatureInfo.GetRaceInfo then
                for id = 90, 120 do
                    local okInfo, info = pcall(C_CreatureInfo.GetRaceInfo, id)
                    if okInfo and type(info) == "table" then
                        if info.raceName == name or info.name == name then
                            playerRace = id
                            break
                        end
                    end
                end
            end
        end
    end
    return playerRace or nil
end

function C.Continent(mapID)
    if not mapID then return ns.L["Other Regions"] end
    if continentCache[mapID] then return continentCache[mapID] end
    local name
    if C_Map and C_Map.GetMapInfo then
        local cur = mapID
        local continentType = (Enum and Enum.UIMapType and Enum.UIMapType.Continent) or 2
        for _ = 1, 8 do
            local ok, info = pcall(C_Map.GetMapInfo, cur)
            if not ok or type(info) ~= "table" then break end
            if info.mapType == continentType then name = info.name break end
            if not info.parentMapID or info.parentMapID == 0 or info.parentMapID == cur then break end
            cur = info.parentMapID
        end
    end
    if not name and C_Map and C_Map.GetMapInfo then
        local ok, info = pcall(C_Map.GetMapInfo, mapID)
        if ok and type(info) == "table" then name = info.name end
    end
    name = name or ns.L["Other Regions"]
    continentCache[mapID] = name
    return name
end

local function clientMapName(mapID)
    if not mapID or not (C_Map and C_Map.GetMapInfo) then return nil end
    local ok, info = pcall(C_Map.GetMapInfo, mapID)
    if ok and type(info) == "table" and info.name and info.name ~= "" then
        return info.name
    end
    return nil
end

-- AreaTable names: some clients resolve them natively (localized), otherwise
-- fall back to the static QuestieDB-derived name table in Core/AreaMap.lua.
function C.AreaDisplayName(areaId)
    if not areaId then return nil end
    if C_Map and C_Map.GetAreaInfo then
        local ok, name = pcall(C_Map.GetAreaInfo, areaId)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    return ns.AreaName and ns.AreaName(areaId) or nil
end

function C.EntryName(e)
    if not e then return "" end
    -- Class pages are named by the class, never by a map. Their first quest usually
    -- carries a real AreaTable id (the Warlock trainers sit in Stormwind), so letting
    -- the area name win made the 术士 page show up as 暴风城.
    if e.cat == "classes" and e.classKey then
        local n = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[e.classKey]
        if n then return n end
        return e.nameEn or e.classKey
    end
    -- Instance pages must keep their own dungeon name. Their UiMapID often
    -- resolves to the parent outdoor zone, which used to make dungeon quests
    -- look like they belonged to a different region.
    if e.isDungeon then
        -- Names resolved from the static table are English keys; ns.L returns the key
        -- itself when no translation exists, so this is safe for client-localized names
        -- as well.
        local n = C.AreaDisplayName(e.areaId)
        if not n and e.nameEn and e.nameEn ~= "" then n = e.nameEn end
        if n then return ns.L[n] end
    end
    -- Quest-log category pages (each profession, each holiday, legendary, ...) carry
    -- the DBC QuestSort name as their label.
    if e.sortLabel then
        return ns.L[e.sortLabel]
    end
    -- Try every available naming source before ever showing a raw entry id.
    if e.mapID then
        local n = clientMapName(e.mapID)
        if n then return n end
    end
    if e.areaId then
        local n = C.AreaDisplayName(e.areaId)
        if n then return n end
    end
    if e.cat == "others" then return e.nameEn or ns.L["Others"] end
    if e.cat == "professions" then return e.nameEn or ns.L["Professions"] end
    if ns.IsChineseClient() and e.nameZh and e.nameZh ~= "" then return e.nameZh end
    return e.nameEn or e.nameZh or ns.L["Other Regions"]
end

-- Entry matching the player's current map, walking up the map hierarchy.
function C.CurrentZoneEntry()
    if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok or type(mapID) ~= "number" or mapID <= 0 then return nil end
    local seen, cur = {}, mapID
    for _ = 1, 6 do
        if seen[cur] then break end
        seen[cur] = true
        for _, e in ipairs(ns.Source.entries or {}) do
            if e.mapID == cur and C.EntryAllowed(e) then return e.id end
        end
        if not (C_Map and C_Map.GetMapInfo) then break end
        local ok2, info = pcall(C_Map.GetMapInfo, cur)
        if not ok2 or type(info) ~= "table" or not info.parentMapID or
            info.parentMapID == 0 or info.parentMapID == cur then break end
        cur = info.parentMapID
    end
    return nil
end

-- Continent ordering. Map names come from the client, so they are localized: match a
-- short fragment per language instead of the English name only. Fragments deliberately
-- skip the leading letter of capitalized words, because string.lower only folds ASCII
-- -- "Östliche" stays "Östliche" on a German client, so "östlich" would never match.
local CONTINENT_HINTS = {
    -- Eastern Kingdoms. "kingdom" is unique to this continent in every language.
    { 1, { "东部", "東部", "eastern", "nigreiche", "royaumes", "reinos", "regni",
           "королевства", "왕국" } },
    { 2, { "卡利姆多", "卡林多", "kalimdor", "алимдор", "칼림도어" } },
    { 3, { "外域", "outland", "scherbenwelt", "outreterre", "terrallende",
           "terre esterne", "terral", "апределье", "아웃랜드" } },
    { 4, { "诺森德", "北裂境", "northrend", "nordend", "norfendre", "rasganorte",
           "nordania", "nort", "ордскол", "노스렌드" } },
}

local function continentWeight(name)
    if not name then return 9 end
    local low = name:lower()
    for _, row in ipairs(CONTINENT_HINTS) do
        for _, hint in ipairs(row[2]) do
            if name:find(hint, 1, true) or low:find(hint, 1, true) then return row[1] end
        end
    end
    return 9
end

local function matches(entry, filter)
    if not filter or filter == "" then return true end
    filter = filter:lower()
    if C.EntryName(entry):lower():find(filter, 1, true) then return true end
    -- FastTitle, because typing in the search box otherwise queues a load request for
    -- every quest in every page, and the row shows the same title anyway.
    for _, id in ipairs(entry.quests or {}) do
        local title = ns.Q.FastTitle(id, nil)
        if title and title:lower():find(filter, 1, true) then return true end
    end
    return false
end

function C.ShowAllClasses()
    return ns.char and ns.char.showAllClasses and true or false
end

-- Race inspection is a separate switch from "show the other faction": the two filters
-- used to be coupled, which meant looking at the enemy roster silently also pulled in
-- quests no character of the player's race can ever take.
function C.ShowAllRaces()
    return ns.char and ns.char.showAllRaces and true or false
end

-- Race gating. A quest's allowed-race mask is the game's own requiredRaces field, so
-- a mask that excludes the player's race means the quest can never be taken. Masks
-- that cover a whole faction (ALL_ALLIANCE / ALL_HORDE) decode to that faction's full
-- roster, so faction-bound quests are unaffected — only genuinely race-locked ones
-- (e.g. Undead-only, Dwarf+Gnome) drop out. "Show all races" (Settings) lifts this
-- check, and so does browsing the other faction's tab (every quest there is foreign).
function C.RaceAllowed(q)
    if not q or not q.races or #q.races == 0 then return true end
    local rid = C.PlayerRaceID()
    -- Unknown race (custom client race the API cannot resolve): never hide anything.
    if not rid then return true end
    for _, r in ipairs(q.races) do
        if r == rid then return true end
    end
    return false
end

-- Race ids per faction, used only when the client cannot answer UnitFactionGroup.
local ALLIANCE_RACES = { [1] = true, [3] = true, [4] = true, [7] = true, [95] = true }
local HORDE_RACES = { [2] = true, [5] = true, [6] = true, [8] = true, [96] = true }

-- The character's OWN faction. Deliberately independent from ns.faction, which is the
-- browsing tab and can be flipped to the other side; comparing the two is what tells
-- us whether the list is showing content the character could never take.
function C.PlayerFaction()
    if playerFaction == nil then
        local resolved
        local ok, v = pcall(function()
            return UnitFactionGroup and UnitFactionGroup("player")
        end)
        if ok and (v == "Alliance" or v == "Horde") then resolved = v end
        if not resolved then
            -- No usable UnitFactionGroup: derive the side from the race, which is the
            -- same source the quest race masks use.
            local rid = C.PlayerRaceID()
            if rid then
                if ALLIANCE_RACES[rid] then
                    resolved = "Alliance"
                elseif HORDE_RACES[rid] then
                    resolved = "Horde"
                end
            end
        end
        playerFaction = resolved or false
    end
    return playerFaction or nil
end

-- True when the tab being browsed is not the character's own faction. That view is an
-- inspection view: everything in it is by definition something this character cannot
-- take, so the race gate is lifted there and the "not yours" capsules say why.
function C.Inspecting(faction)
    local own = C.PlayerFaction()
    if not own then return false end
    return (faction or ns.faction) ~= own
end

-- "Not mine" markers. These never filter anything by themselves: they only answer
-- "would this quest be hidden if the inspection switches were off", which is what the
-- capsules in the chain list are for. Faction is compared against the character's own
-- side, not against the side currently being browsed, because the capsule means
-- "your character can never take this".
function C.ClassAllowed(q)
    if not q or not q.classOnly then return true end
    local list = q.classList
    if not list or #list == 0 then
        if not q.classKey then return true end
        list = { q.classKey }
    end
    local pc = C.PlayerClass()
    if not pc then return true end
    for _, key in ipairs(list) do
        if key == pc then return true end
    end
    return false
end

function C.FactionAllowed(q)
    if not q or not q.faction then return true end
    local own = C.PlayerFaction()
    if not own then return true end
    return q.faction == own
end

-- Race / class display names. The client's own answer wins (it is already localized);
-- ids it does not serve fall back to a small English table that Locale can translate.
local RACE_NAMES = {
    [1] = "Human", [2] = "Orc", [3] = "Dwarf", [4] = "Night Elf", [5] = "Undead",
    [6] = "Tauren", [7] = "Gnome", [8] = "Troll", [9] = "Goblin",
    [10] = "Blood Elf", [11] = "Draenei",
}
local CLASS_NAMES = {
    WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue",
    PRIEST = "Priest", SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock",
    DRUID = "Druid", DEATHKNIGHT = "Death Knight", MONK = "Monk",
}
local raceNameCache, classNameCache = {}, {}

function C.RaceName(id)
    if type(id) ~= "number" then return nil end
    local cached = raceNameCache[id]
    if cached ~= nil then return cached or nil end
    local name
    if C_CreatureInfo and C_CreatureInfo.GetRaceInfo then
        local ok, info = pcall(C_CreatureInfo.GetRaceInfo, id)
        if ok and type(info) == "table" then
            name = info.raceName or info.name
        end
    end
    if type(name) ~= "string" or name == "" then
        local en = RACE_NAMES[id]
        name = en and ns.L[en] or nil
    end
    raceNameCache[id] = name or false
    return name
end

function C.ClassName(key)
    if type(key) ~= "string" or key == "" then return nil end
    local cached = classNameCache[key]
    if cached ~= nil then return cached or nil end
    local name
    if LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[key] then
        name = LOCALIZED_CLASS_NAMES_MALE[key]
    end
    if not name then
        local en = CLASS_NAMES[key]
        name = en and ns.L[en] or nil
    end
    classNameCache[key] = name or false
    return name
end

-- A quest's allowed races normally spell out its faction's whole roster. In that case
-- the race lock says nothing the faction capsule does not already say, so it is left
-- off instead of listing four names. Genuine race locks list one or two races.
local function raceSetIsFactionRoster(q)
    if not q.faction then return false end
    local roster = (q.faction == "Alliance") and ALLIANCE_RACES
        or (q.faction == "Horde") and HORDE_RACES or nil
    if not roster then return false end
    local races = q.races
    if not races or #races < 3 then return false end
    for _, r in ipairs(races) do
        if not roster[r] then return false end
    end
    return true
end

-- Capsule contents for one row: a list of { kind = "class"|"race"|"faction", text = ... }
-- naming the actual requirement ("Undead", "Warlock", "Horde") whenever the data says
-- which it is. Generic wording is used only when nothing specific can be resolved.
function C.NotMineTags(q)
    local out = {}
    if not q then return out end

    if not C.ClassAllowed(q) then
        local list = q.classList
        if not list or #list == 0 then
            list = q.classKey and { q.classKey } or nil
        end
        local names = {}
        for _, key in ipairs(list or {}) do
            local n = C.ClassName(key)
            if n then names[#names + 1] = n end
        end
        if #names > 0 and #names <= 2 then
            out[#out + 1] = { kind = "class", text = table.concat(names, " / ") }
        else
            out[#out + 1] = { kind = "class", text = ns.L["Not your class"] }
        end
    end

    if not C.RaceAllowed(q) and not raceSetIsFactionRoster(q) then
        local names = {}
        for _, r in ipairs(q.races or {}) do
            local n = C.RaceName(r)
            if n then names[#names + 1] = n end
        end
        if #names > 0 and #names <= 3 then
            out[#out + 1] = { kind = "race", text = table.concat(names, " / ") }
        else
            out[#out + 1] = { kind = "race", text = ns.L["Not your race"] }
        end
    end

    if not C.FactionAllowed(q) and q.faction then
        out[#out + 1] = { kind = "faction", text = q.faction and ns.L[q.faction] or ns.L["Not your faction"] }
    end

    return out
end

-- Faction, class and race gating. Class-only quests of other classes never show, and
-- neither do race-locked quests the player's race cannot take -- except in the other
-- faction's tab, which is an inspection view (see C.Inspecting): every quest listed
-- there is race-locked to that side, so keeping the gate would leave nothing but the
-- faction-neutral quests on screen and the "not yours" capsules would never appear.
function C.Visible(q, faction)
    if not q then return false end
    if q.faction and q.faction ~= faction then
        return false
    end
    if not C.Inspecting(faction) and not C.ShowAllRaces() and not C.RaceAllowed(q) then
        return false
    end
    if not C.ShowAllClasses() and not C.ClassAllowed(q) then
        return false
    end
    return true
end

function C.EntryAllowed(e)
    if e.cat == "classes" and e.classKey and not C.ShowAllClasses() then
        local pc = C.PlayerClass()
        if pc and e.classKey ~= pc then return false end
    end
    return true
end

-- Quests currently tracked in the player's log, collected in a single pass. On this
-- client IsOnQuest falls back to a full log scan per quest, so querying it for every
-- visible quest (thousands) on each refresh would be quadratic; the log itself is
-- read once instead.
local function activeSet()
    local set = {}
    if GetNumQuestLogEntries and GetQuestLogTitle then
        local n = GetNumQuestLogEntries() or 0
        for i = 1, n do
            local _, _, _, isHeader, _, _, _, questID = GetQuestLogTitle(i)
            if not isHeader and type(questID) == "number" and questID > 0 then
                set[questID] = true
            end
        end
    else
        for _, q in pairs(ns.Source.quests or {}) do
            if q and q.id and ns.Q.Active(q.id) then set[q.id] = true end
        end
    end
    return set
end

-- "Could be accepted right now": same rules as Q.Status, without building the
-- localized reason strings, because this runs for every visible quest of every page.
function C.CanAccept(q)
    if not q or not q.id or q.sparse then return false end
    -- Whatever the level or prerequisite situation, a quest whose faction, race or
    -- class excludes this character is never "available" to it. Without this the left
    -- tree would paint the other faction's pages as acceptable the moment the race gate
    -- is lifted for inspection.
    if not C.FactionAllowed(q) or not C.RaceAllowed(q) or not C.ClassAllowed(q) then
        return false
    end
    local mine = ns.Q.PlayerLevel()
    if q.minLevel and mine < q.minLevel then return false end
    for _, p in ipairs(q.pre or {}) do
        if type(p) == "number" and not ns.Q.Done(p) then return false end
    end
    return true
end

-- done/total for the page badge, plus the page's own state: "active" when a quest of
-- this page is in the log, otherwise "available" when at least one quest can be taken,
-- otherwise "done" when the whole page is finished. A page that is being worked on wins
-- over one that merely has something to offer.
--
-- This walks every quest of every page, so its answer is cached per (log generation,
-- faction). Switching pages or toggling a filter reuses the cache; only a real log
-- change repays the pass.
local progressCache = {}

function C.Progress(entry, faction, actives)
    local stamp = ns.Q.Stamp()
    -- The two inspection switches change what counts as acceptable, and they are not
    -- log events, so they belong in the key as well.
    local relax = (C.ShowAllClasses() and 1 or 0) + (ns.char and ns.char.showAllRaces and 2 or 0)
    local hit = entry.id and progressCache[entry.id]
    if hit and hit.stamp == stamp and hit.faction == faction and hit.relax == relax then
        return hit.done, hit.total, hit.state
    end
    local done, total = 0, 0
    local hasActive, hasAvail = false, false
    actives = actives or {}
    for _, id in ipairs(entry.quests or {}) do
        local q = ns.Source.Get(id)
        if C.Visible(q, faction) then
            total = total + 1
            if ns.Q.Done(id) then
                done = done + 1
            elseif actives[id] then
                hasActive = true
            elseif not hasActive and not hasAvail and C.CanAccept(q) then
                hasAvail = true
            end
        end
    end
    local state
    if hasActive then
        state = "active"
    elseif hasAvail then
        state = "available"
    elseif total > 0 and done == total then
        state = "done"
    end
    if entry.id then
        progressCache[entry.id] = {
            stamp = stamp, faction = faction, relax = relax,
            done = done, total = total, state = state,
        }
    end
    return done, total, state
end

-- Empty pages and empty groups are dropped for the current view (requirement 1).
function C.Categories(faction, filter)
    local groups = {}
    local function group(id, title, weight)
        if not groups[id] then
            groups[id] = { id = id, title = title, weight = weight, entries = {} }
        end
        return groups[id]
    end
    local actives = activeSet()
    for _, e in ipairs(ns.Source.entries or {}) do
        if C.EntryAllowed(e) and matches(e, filter) then
            local done, total, state = C.Progress(e, faction, actives)
            if total > 0 then
                local g
                if e.isDungeon or e.cat == "dungeons" then
                    g = group("dungeons", ns.L["Dungeons"], 20)
                elseif e.cat == "zones" then
                    local name = C.Continent(e.mapID)
                    g = group("continent:" .. name, name, continentWeight(name))
                elseif e.cat == "classes" then
                    g = group("classes", ns.L["Class Quests"], 21)
                elseif e.cat == "professions" then
                    g = group("professions", ns.L["Professions"], 22)
                elseif e.cat == "events" then
                    g = group("events", ns.L["Events"], 23)
                elseif e.cat == "legendary" then
                    g = group("legendary", ns.L["Legendary Quests"], 24)
                elseif e.cat == "reputation" then
                    g = group("reputation", ns.L["Reputation Quests"], 25)
                elseif e.cat == "special" then
                    g = group("special", ns.L["Special Quests"], 26)
                elseif e.cat == "forever" then
                    g = group("forever", ns.L["Forever Content"], 27)
                elseif e.cat == "raids" then
                    g = group("raids", ns.L["Raids"], 28)
                elseif e.cat == "races" then
                    g = group("races", ns.L["Races"], 29)
                elseif e.cat == "battlegrounds" then
                    g = group("battlegrounds", ns.L["Battlegrounds"], 30)
                else
                    g = group("others", ns.L["Others"], 40)
                end
                g.entries[#g.entries + 1] = {
                    entry = e, name = C.EntryName(e), done = done, total = total,
                    state = state,
                }
            end
        end
    end
    local list = {}
    for _, g in pairs(groups) do
        if #g.entries > 0 then
            table.sort(g.entries, function(a, b)
                local al = a.entry.minLevel or 999
                local bl = b.entry.minLevel or 999
                if al ~= bl then return al < bl end
                return a.name < b.name
            end)
            list[#list + 1] = g
        end
    end
    table.sort(list, function(a, b)
        if a.weight ~= b.weight then return a.weight < b.weight end
        return a.title < b.title
    end)
    return list
end

local function questSorter(a, b)
    local al = a.minLevel or a.level or 999
    local bl = b.minLevel or b.level or 999
    if al ~= bl then return al < bl end
    return a.id < b.id
end

-- The predecessor the "jump to previous quest" action can actually reach. A raw
-- prerequisite id is not enough: the quest behind it may be missing from the
-- database, belong to the other faction or another class (and therefore be filtered
-- out of the list right now), or be hidden by "hide completed". In all of those
-- cases the jump has nowhere to land, so the row behaves as if it had no previous
-- quest at all -- no hint in the tooltip and no action on right click.
function C.PreJumpTarget(q)
    if not q or not q.pre then return nil end
    local faction = ns.faction
    local hideDone = ns.char and ns.char.hideCompleted
    for _, p in ipairs(q.pre) do
        if type(p) == "number" and p ~= q.id then
            local pq = ns.Source.Get(p)
            if pq and C.Visible(pq, faction) and not (hideDone and ns.Q.Done(p)) then
                return pq
            end
        end
    end
    return nil
end

-- A "chain" is one root plus everything reachable from it. Only the root is
-- flush left; every following quest is indented by one fixed step. Chain-internal
-- prerequisites are expressed by the guide line, so no "Requires: ..." text is
-- emitted for them; prerequisites from another chain still are.
function C.BuildView(entryId, faction, filter)
    local entry = ns.Source.byId and ns.Source.byId[entryId]
    if not entry then return {}, 0, 0, 0 end
    local visible = {}
    for _, id in ipairs(entry.quests or {}) do
        local q = ns.Source.Get(id)
        if q and C.Visible(q, faction) then visible[#visible + 1] = q end
    end
    -- Progress always reflects the whole page; the list itself can optionally
    -- drop completed quests (Settings -> Hide completed).
    local done, total = 0, #visible
    for _, q in ipairs(visible) do if ns.Q.Done(q.id) then done = done + 1 end end
    local quests, byId = {}, {}
    local hideDone = ns.char and ns.char.hideCompleted
    for _, q in ipairs(visible) do
        if not (hideDone and ns.Q.Done(q.id)) then
            quests[#quests + 1] = q
            byId[q.id] = q
        end
    end

    if filter and filter ~= "" then
        local low = filter:lower()
        local flat = {}
        for _, q in ipairs(quests) do
            local title = ns.Q.FastTitle(q.id, q.titleFallback)
            if title and title:lower():find(low, 1, true) then
                flat[#flat + 1] = {
                    q = q, chain = #flat + 1, chainKey = q.id, chainSet = {},
                    chainCount = 1, chainIndex = #flat + 1,
                    isStart = true, isEnd = true, single = true,
                    indent = false, collapsed = nil, search = true,
                    lineTop = false, lineBottom = false,
                }
            end
        end
        table.sort(flat, function(a, b) return questSorter(a.q, b.q) end)
        return flat, done, total, #flat
    end

    local children = {}
    for _, q in ipairs(quests) do
        for _, p in ipairs(q.pre or {}) do
            if byId[p] then
                local list = children[p] or {}
                list[#list + 1] = q
                children[p] = list
            end
        end
    end
    local roots = {}
    for _, q in ipairs(quests) do
        local hasParent = false
        for _, p in ipairs(q.pre or {}) do
            if byId[p] then hasParent = true break end
        end
        if not hasParent then roots[#roots + 1] = q end
    end
    table.sort(roots, questSorter)

    local collapsedMap = (ns.char and ns.char.chainCollapsed) or {}
    local rows, seen, chainIndex = {}, {}, 0

    local function walk(q, out)
        if seen[q.id] then return end
        seen[q.id] = true
        out[#out + 1] = q
        local kids = children[q.id]
        if kids then
            table.sort(kids, questSorter)
            for _, kid in ipairs(kids) do walk(kid, out) end
        end
    end

    local function emit(out)
        chainIndex = chainIndex + 1
        local key = out[1].id
        local chainSet = {}
        for _, q in ipairs(out) do chainSet[q.id] = true end
        local isCollapsed = collapsedMap[key] and true or false
        local visible = isCollapsed and { out[1] } or out
        local n = #visible
        for i, q in ipairs(visible) do
            rows[#rows + 1] = {
                q = q,
                chain = chainIndex, chainIndex = chainIndex, chainKey = key,
                chainSet = chainSet, chainCount = #out,
                isStart = i == 1, isEnd = i == n, single = n == 1,
                collapsed = (i == 1 and isCollapsed) or nil,
                indent = i > 1,
                lineTop = n > 1 and i > 1,
                lineBottom = n > 1 and i < n,
            }
        end
    end

    for _, root in ipairs(roots) do
        if not seen[root.id] then
            local out = {}
            walk(root, out)
            emit(out)
        end
    end
    for _, q in ipairs(quests) do
        if not seen[q.id] then
            local out = {}
            walk(q, out)
            emit(out)
        end
    end
    return rows, done, total, chainIndex
end

-- chainSet suppresses only the "Requires: ..." reasons for quests inside the
-- same chain. Cross-chain and level requirements remain visible.
function C.Status(q, item)
    local opts = item and item.chainSet and { skipPre = item.chainSet } or nil
    local status, reasons, flags = ns.Q.Status(q, opts)
    -- A quest of the other faction is never takeable, whatever the level or the
    -- prerequisites say: it only shows up when the other side is being browsed.
    if status == "available" and not C.FactionAllowed(q) then
        status = "locked"
        reasons, flags = {}, { faction = true }
    end
    if status == "locked" and q and q.faction and q.faction ~= (ns.faction or "Alliance") then
        reasons = reasons or {}
        reasons[#reasons + 1] = ns.L["Faction"] .. ": " .. ns.L[q.faction]
        flags = flags or {}
        flags.faction = true
    end
    return status, reasons, flags
end

-- Compact one-line status for the list: level / prerequisite requirements are
-- stated in the status column instead of a second, wrapping reason line.
function C.StatusLabel(q, item)
    local status, _, flags = C.Status(q, item)
    if status == "locked" and flags then
        -- "Harmless name of the other side" reads better than a bare "cannot accept"
        -- and matches the capsule sitting at the other end of the same row.
        if flags.faction then
            return (q and q.faction and ns.L[q.faction]) or ns.L["Locked"]
        end
        if flags.level then
            return ns.L["Requires level %d"]:format(flags.level)
        end
        if flags.pre then return ns.L["Requires prerequisite"] end
    end
    return ns.Q.StatusLabel(status)
end

-- Previous / next quests for the NPC companion panel, followed through the
-- whole runtime model rather than only the entry the quest is listed under.
function C.Relatives(qid)
    if not qid then return {}, {} end
    local all = ns.Source.quests or {}
    local entry
    for _, e in ipairs(ns.Source.entries or {}) do
        for _, id in ipairs(e.quests or {}) do
            if id == qid then entry = e break end
        end
        if entry then break end
    end

    local prev, nextList, seen = {}, {}, {}
    local function back(id, depth)
        if depth > 4 or #prev >= 10 then return end
        local q = all[id]
        if not q then return end
        for _, p in ipairs(q.pre or {}) do
            if type(p) == "number" and p ~= id and not seen[p] then
                seen[p] = true
                prev[#prev + 1] = all[p] or { id = p, pre = {} }
                back(p, depth + 1)
            end
        end
    end
    back(qid, 0)

    wipe(seen)
    seen[qid] = true
    local function forward(id, depth)
        if depth > 4 or #nextList >= 10 then return end
        for other, q in pairs(all) do
            if not seen[other] then
                for _, p in ipairs(q.pre or {}) do
                    if p == id then
                        seen[other] = true
                        nextList[#nextList + 1] = q
                        forward(other, depth + 1)
                        break
                    end
                end
            end
        end
    end
    forward(qid, 0)
    table.sort(nextList, questSorter)
    return prev, nextList, entry
end

function C.Build()
    ns.Source.Build()
    wipe(continentCache)
    playerClass, playerRace, playerFaction = nil, nil, nil
end
