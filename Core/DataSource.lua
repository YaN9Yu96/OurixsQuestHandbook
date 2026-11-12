local _, ns = ...

-- Runtime data comes exclusively from the QuestieDB library (external
-- dependency declared in the .toc). QuestDB / NpcDB / ObjectDB are read-only
-- public tables; nothing here reads any other addon's globals. No local quest
-- corrections, observations or imported records are kept.
local S = {}
ns.Source = S

S.quests = {}
S.entries = {}
S.byId = {}

-- QuestieDB publishes the exact bit values for requiredRaces / requiredClasses
-- through LibQuestieDB.Enum (public API). Static copies of the Forever constants
-- are kept as a fallback so a renamed field never breaks the whole handbook.
local RACE_BIT_FALLBACK = {
    [1] = 1, [2] = 2, [3] = 4, [4] = 8, [5] = 16, [6] = 32, [7] = 64,
    [8] = 128, [9] = 256, [10] = 512, [11] = 1024, [22] = 2097152,
    [24] = 8388608, [25] = 16777216, [26] = 33554432,
    [95] = 4294967296, [96] = 8589934592,
}
-- Class bit value -> client token (select(2, UnitClass("player")) spelling).
local CLASS_BIT_FALLBACK = {
    [1] = "WARRIOR", [2] = "PALADIN", [4] = "HUNTER", [8] = "ROGUE",
    [16] = "PRIEST", [32] = "DEATHKNIGHT", [64] = "SHAMAN",
    [128] = "MAGE", [256] = "WARLOCK", [512] = "MONK", [1024] = "DRUID",
}

local function enumTable(name)
    local lib = _G.LibQuestieDB
    local e = lib and lib.Enum
    return e and e[name] or nil
end

-- Bit membership without a bit library: Forever uses bits 32/33 (values above
-- 2^31), but Lua doubles stay exact up to 2^53 so plain division is safe.
local function hasBit(mask, bitValue)
    if type(bitValue) ~= "number" or bitValue <= 0 then return false end
    return math.floor(mask / bitValue) % 2 == 1
end

local function decodeRaces(mask)
    if not mask or mask == 0 then return nil end
    local bits = enumTable("raceMaskById") or RACE_BIT_FALLBACK
    local out = {}
    for raceId, bitValue in pairs(bits) do
        if type(raceId) == "number" and hasBit(mask, bitValue) then
            out[#out + 1] = raceId
        end
    end
    if #out == 0 then return nil end
    table.sort(out)
    return out
end

-- Client class tokens for a class-restricted quest, plus a flag saying whether the
-- quest is class-restricted at all. The whole list is kept because a handful of quests
-- are open to two classes (warrior + shaman, mage + priest, ...); the first token is
-- still exposed as `classKey` for callers that only need one name.
local function classInfo(mask)
    if not mask or mask == 0 then return nil, false, nil end
    local names = enumTable("classKeys")
    if names and mask == names.ALL_CLASSES then return nil, false, nil end
    local found, count, list = nil, 0, {}
    if names then
        for key, bitValue in pairs(names) do
            if key ~= "NONE" and key ~= "ALL_CLASSES" and hasBit(mask, bitValue) then
                count = count + 1
                local token = key:gsub("_", "") -- DEATH_KNIGHT -> DEATHKNIGHT
                list[#list + 1] = token
                found = token
            end
        end
    end
    if count == 0 then
        for token, bitValue in pairs(CLASS_BIT_FALLBACK) do
            if hasBit(mask, bitValue) then
                count = count + 1
                list[#list + 1] = token
                found = token
            end
        end
    end
    table.sort(list)
    return (count == 1 and found or nil), (count > 0), (count > 0 and list or nil)
end

-- Negative zoneOrSort values are QuestSort ids: the client's own quest-log
-- categories (QuestSort.db2). Only a handful ever appear in this data set, but
-- guessing the ids was what filed Warlock quests under "Raids" and Warrior quests
-- under "Events" — every id below is the DBC value, verified against the 5,682
-- baked quests. Third element, when present, makes the page class-exclusive.
local QUESTSORT = {
    -- Classes
    [61]  = { "classes", "Warlock", "WARLOCK" },
    [81]  = { "classes", "Warrior", "WARRIOR" },
    [82]  = { "classes", "Shaman", "SHAMAN" },
    [141] = { "classes", "Paladin", "PALADIN" },
    [161] = { "classes", "Mage", "MAGE" },
    [162] = { "classes", "Rogue", "ROGUE" },
    [261] = { "classes", "Hunter", "HUNTER" },
    [262] = { "classes", "Priest", "PRIEST" },
    [263] = { "classes", "Druid", "DRUID" },
    [372] = { "classes", "Death Knight", "DEATHKNIGHT" },
    -- Professions
    [24]  = { "professions", "Herbalism" },
    [101] = { "professions", "Fishing" },
    [121] = { "professions", "Blacksmithing" },
    [181] = { "professions", "Alchemy" },
    [182] = { "professions", "Leatherworking" },
    [201] = { "professions", "Engineering" },
    [264] = { "professions", "Tailoring" },
    [304] = { "professions", "Cooking" },
    [324] = { "professions", "First Aid" },
    [371] = { "professions", "Inscription" },
    [373] = { "professions", "Jewelcrafting" },
    [762] = { "professions", "Riding" },
    -- Holidays and world events
    [21]  = { "events", "Hallow's End" },
    [22]  = { "events", "Seasonal" },
    [41]  = { "events", "Day of the Dead" },
    [364] = { "events", "Darkmoon Faire" },
    [365] = { "events", "Ahn'Qiraj War" },
    [366] = { "events", "Lunar Festival" },
    [368] = { "events", "Invasion" },
    [369] = { "events", "Midsummer" },
    [370] = { "events", "Brewfest" },
    [374] = { "events", "Noblegarden" },
    [375] = { "events", "Pilgrim's Bounty" },
    [376] = { "events", "Love is in the Air" },
    [378] = { "events", "Children's Week" },
    [379] = { "events", "Firelands Invasion" },
    -- Misc sorts. 666/676 do not exist in the DBC; they are Forever's own
    -- quest-log categories for its added content.
    [1]   = { "legendary", "Epic" },
    [344] = { "legendary", "Legendary" },
    [367] = { "reputation", "Reputation" },
    [284] = { "special", "Special" },
    [25]  = { "battlegrounds", "Battlegrounds" },
    [221] = { "treasure", "Treasure Map" },
    [241] = { "tournament", "Tournament" },
    [666] = { "professions", "Outdoor Survival" },
    [676] = { "forever", "Forever Additions" },
}
local function categorizeQuestSort(qs)
    local known = QUESTSORT[qs]
    if known then return known[1], known[2], known[3] end
    return "others", nil, nil
end

-- Four AreaTable ids in this data set have neither a UiMapID nor a dungeon flag, so
-- they used to stand as orphan pages named after a zone that is not really a zone.
-- They are filed by content instead. Every other AreaTable id falls through to the
-- normal zone / instance rules.
local AREA_OVERRIDE = {
    -- 150 "Craftsman's Writ: ..." turn-ins. AreaTable calls it "Crafting"; it is a
    -- profession activity, not a place.
    [16941] = { cat = "professions", label = "Craftsman's Writ" },
    -- The pre-Cataclysm Sunken Temple id; the live one is 1477 -> UiMapID 220.
    [1417]  = { cat = "dungeons", ui = 220 },
    -- Two Forever pockets with no map of their own: keep them, but under "Others"
    -- rather than pretending they are regions. Their generated AreaTable names carry
    -- a numeric suffix, so a clean label replaces it.
    [16560] = { cat = "others", label = "City of Dalaran" },
    [16169] = { cat = "others", label = "Ashenvale Instance" },
}

-- Faction implied by the allowed-race mask. requiredRaces is the game's own field and
-- is authoritative, so it wins over the NPC-standing heuristic (3,415 quests carry a
-- faction mask; 1,765 carry none and fall back to the quest giver's standing).
-- Returns "Alliance"/"Horde", false when both factions may take it, nil when unknown.
local function factionFromRaces(mask)
    if not mask or mask == 0 then return nil end
    local bits = enumTable("raceMaskById") or RACE_BIT_FALLBACK
    local function on(raceId)
        local bitValue = bits[raceId]
        return (bitValue and hasBit(mask, bitValue)) and true or false
    end
    local hasA = on(1) or on(3) or on(4) or on(7) or on(95)
    local hasH = on(2) or on(5) or on(6) or on(8) or on(96)
    if hasA and not hasH then return "Alliance" end
    if hasH and not hasA then return "Horde" end
    if hasA and hasH then return false end
    return nil
end

-- Spawn coordinates are percentages (0..100); { -1, -1 } marks an unknown
-- position. MapLink expects the very same 0..100 scale, so no rescaling here.
local function validCoord(x, y)
    return type(x) == "number" and type(y) == "number"
        and x >= 0 and x <= 100 and y >= 0 and y <= 100
end

-- startedBy / finishedBy are positional tables: { npcIds, objectIds, itemIds }.
-- They can be sparse (an item-only quest has just slot 3, slot 1 is nil).
-- Returns starter NPCs, starter objects and finisher NPCs in one pass.
-- Every slot is type-checked before ipairs: if a future QuestieDB flattens the positional
-- table into a plain id list (or returns a bare number), ipairs() on a number would raise
-- and take the whole index build down with it.
local function idList(v)
    local out = {}
    if type(v) == "table" then
        for _, n in ipairs(v) do
            if type(n) == "number" and n > 0 then out[#out + 1] = n end
        end
    elseif type(v) == "number" and v > 0 then
        out[1] = v
    end
    return out
end

local function questGivers(id)
    local QuestDB = _G.QuestDB
    local npcs, objects, fnpcs = {}, {}, {}
    local function collect(t, a, b)
        if type(t) ~= "table" then return end
        for _, n in ipairs(idList(t[1])) do a[#a + 1] = n end
        if b then
            for _, o in ipairs(idList(t[2])) do b[#b + 1] = o end
        end
    end
    if QuestDB then
        local ok, s = pcall(QuestDB.startedBy, id)
        if ok then collect(s, npcs, objects) end
        local ok2, f = pcall(QuestDB.finishedBy, id)
        if ok2 then collect(f, fnpcs, {}) end
    end
    return npcs, objects, fnpcs
end

-- Derive the quest's faction from the starter / finisher NPCs' standing.
local function factionOf(npcs, fnpcs)
    local NpcDB = _G.NpcDB
    if not NpcDB then return nil end
    local hasA, hasH = false, false
    local function scan(list)
        for _, npc in ipairs(list) do
            local ok, fr = pcall(NpcDB.friendlyToFaction, npc)
            if ok then
                if fr == "A" then hasA = true
                elseif fr == "H" then hasH = true
                elseif fr == "AH" then hasA, hasH = true, true end
            end
        end
    end
    scan(npcs)
    scan(fnpcs)
    if hasA and not hasH then return "Alliance" end
    if hasH and not hasA then return "Horde" end
    return nil
end

-- First usable spawn of one entity, translated to a UiMapID.
local function pickSpawn(spawns)
    if type(spawns) ~= "table" then return nil end
    local areas = {}
    for areaId in pairs(spawns) do
        if type(areaId) == "number" then areas[#areas + 1] = areaId end
    end
    table.sort(areas) -- deterministic result regardless of pairs() order
    for _, areaId in ipairs(areas) do
        local ui = ns.AreaToUiMap and ns.AreaToUiMap(areaId)
        local coords = spawns[areaId]
        if ui and type(coords) == "table" then
            for _, c in ipairs(coords) do
                local x, y = c and c[1], c and c[2]
                if validCoord(x, y) then return { ui, x, y } end
            end
        end
    end
    return nil
end

-- First quest-giver spawn: NPC starters first, then object starters.
local function locOfGivers(npcs, objects)
    local NpcDB, ObjectDB = _G.NpcDB, _G.ObjectDB
    for _, npc in ipairs(npcs) do
        if NpcDB then
            local ok, spawns = pcall(NpcDB.spawns, npc)
            if ok then
                local loc = pickSpawn(spawns)
                if loc then return loc end
            end
        end
    end
    for _, obj in ipairs(objects) do
        if ObjectDB and ObjectDB.spawns then
            local ok, spawns = pcall(ObjectDB.spawns, obj)
            if ok then
                local loc = pickSpawn(spawns)
                if loc then return loc end
            end
        end
    end
    return nil
end

-- Forever's "Friend of the Library" series: 41 book-collection quests plus the hand-in
-- steps, all run by Owen Thadd in Undercity.
--
-- The DBC files them under QuestSort 284 ("Special"), but the data we actually read is
-- post-correction: QuestieDB's Forever correction layer rewrites their zoneOrSort to
-- Undercity AND gives them a starter NPC + a book object. Both of the markers this used
-- to rely on (sort 284, "nobody hands it out") are gone at load time, so the giver NPC
-- is what decides now.
local LIBRARY_NPC = 211022
local LIBRARY_KEY = "special:library"

local function containsId(list, target)
    for _, v in ipairs(list or {}) do
        if v == target then return true end
    end
    return false
end

-- Build the raw prerequisite set for every quest, then invert the forward
-- "next in chain" / "child quests" edges so chains connect in both directions.
-- Breadcrumbs are deliberately NOT treated as hard prerequisites: Questie
-- marks them as optional lead-ins, and doing so would wrongly lock quests.
local function buildPreMap(ids)
    local raw, follow = {}, {}
    local q = _G.QuestDB
    for _, id in ipairs(ids) do
        local pre = {}
        raw[id] = pre
        local function addList(list)
            -- A bare number is accepted as a one-element list, so a schema change from
            -- "array of prerequisites" to "single prerequisite" degrades instead of
            -- silently dropping every edge.
            if type(list) == "number" then
                if list > 0 and list ~= id then pre[list] = true end
            elseif type(list) == "table" then
                for _, p in ipairs(list) do
                    if type(p) == "number" and p > 0 and p ~= id then
                        pre[p] = true
                    end
                end
            end
        end
        -- Wrap the accessor call itself inside pcall so a throwing getter
        -- cannot escape (passing a pre-evaluated value to pcall would not).
        pcall(function() addList(q.preQuestGroup(id)) end)
        pcall(function() addList(q.preQuestSingle(id)) end)
        local okP, parent = pcall(q.parentQuest, id)
        if okP and type(parent) == "number" and parent > 0 and parent ~= id then
            pre[parent] = true
        end
        -- nextQuestInChain is a single QuestId; childQuests is an id array.
        local okN, nxt = pcall(q.nextQuestInChain, id)
        if okN and type(nxt) == "number" and nxt > 0 and nxt ~= id then
            follow[id] = follow[id] or {}
            follow[id][nxt] = true
        end
        local okC, kids = pcall(q.childQuests, id)
        if okC and type(kids) == "table" then
            for _, c in ipairs(kids) do
                if type(c) == "number" and c > 0 and c ~= id then
                    follow[id] = follow[id] or {}
                    follow[id][c] = true
                end
            end
        end
    end
    for src, fs in pairs(follow) do
        for f in pairs(fs) do
            if raw[f] then raw[f][src] = true end
        end
    end
    return raw
end

local function buildBase()
    local QuestDB = _G.QuestDB
    local quests, entries = {}, {}
    if not QuestDB then return quests, entries end

    local ids = QuestDB.GetAllIds()
    if not ids then return quests, entries end
    local preMap = buildPreMap(ids)

    for _, id in ipairs(ids) do
        local q = QuestDB
        local level = nil
        local ok, lv = pcall(q.questLevel, id)
        if ok and type(lv) == "number" and lv > 0 then level = lv end
        local minLevel = nil
        local ok2, rl = pcall(q.requiredLevel, id)
        if ok2 and type(rl) == "number" and rl > 0 then minLevel = rl end

        local classKey, classOnly, classList = nil, false, nil
        local okc, rc = pcall(q.requiredClasses, id)
        if okc and type(rc) == "number" then
            classKey, classOnly, classList = classInfo(rc)
        end
        local races = nil
        local okr, rm = pcall(q.requiredRaces, id)
        if okr and type(rm) == "number" then
            races = decodeRaces(rm)
        end

        local name
        local okn, nm = pcall(q.name, id)
        if okn and type(nm) == "string" then name = nm end

        local pre = {}
        local set = preMap[id]
        if set then
            for p in pairs(set) do pre[#pre + 1] = p end
            table.sort(pre)
        end

        -- One giver read per quest feeds faction, start pin and the NPC panel.
        local npcs, objects, fnpcs = questGivers(id)
        -- The race mask is the authoritative faction source. `false` means both
        -- factions may take the quest, so the page must appear in both tabs.
        -- (Written as two statements: `a and false or nil` would collapse to nil and
        -- silently fall through to the NPC heuristic.)
        local maskFaction
        if okr and type(rm) == "number" then maskFaction = factionFromRaces(rm) end
        local faction
        if maskFaction ~= nil then
            faction = maskFaction or nil
        else
            faction = factionOf(npcs, fnpcs)
        end
        quests[id] = {
            id = id,
            pre = pre,
            level = level,
            minLevel = minLevel,
            faction = faction,
            loc = locOfGivers(npcs, objects),
            npcID = npcs[1],
            -- Somebody (NPC or object) actually hands this quest out.
            hasGiver = (#npcs + #objects) > 0,
            -- Handed out by the Undercity librarian: the book-collection series.
            library = containsId(npcs, LIBRARY_NPC) or containsId(fnpcs, LIBRARY_NPC),
            classKey = classKey,
            classList = classList,
            profKey = nil,
            races = races,
            classOnly = classOnly,
            sparse = false,
            -- Forever-only quests occupy the 90xxx..99xxx custom id range.
            isNew = (id >= 90000),
            titleFallback = name, -- localized name from QuestieDB, client title wins
            source = "questiedb",
        }
    end

    -- Group quests into entries by zone (AreaTable) or QuestSort category.
    local groups = {}
    local function ensure(eid, init)
        local e = groups[eid]
        if not e then
            e = init()
            e.id = eid
            e.quests = {}
            e._set = {}
            groups[eid] = e
        end
        return e
    end

    for _, id in ipairs(ids) do
        local qq = quests[id]
        if qq then
            local okz, zs = pcall(QuestDB.zoneOrSort, id)
            local areaId = (okz and type(zs) == "number" and zs > 0) and zs or nil
            local qs = (okz and type(zs) == "number" and zs < 0) and -zs or 0
            local cat, label, sortClass = categorizeQuestSort(qs)
            -- A class QuestSort is class-exclusive even when the quest carries no
            -- requiredClasses mask, so the sort id decides before the mask does.
            local classKey = qq.classKey or sortClass
            local ui = areaId and ns.AreaToUiMap and ns.AreaToUiMap(areaId) or nil
            -- No usable AreaTable id (or none at all): the first starter spawn
            -- is the best hint for which map this quest belongs to.
            local spawnMap = qq.loc and qq.loc[1] or nil
            local eid, init
            local areaName = areaId and ns.AreaName and ns.AreaName(areaId) or nil
            local isDungeon = (areaId and ns.IsDungeonArea and ns.IsDungeonArea(areaId)) and true or false
            -- Content-based overrides for the few areas the client cannot place.
            local over = areaId and AREA_OVERRIDE[areaId] or nil
            if over then
                if over.cat == "dungeons" then isDungeon = true end
                if over.ui then ui = over.ui end
                if over.cat then cat = over.cat end
                if over.label then label = over.label end
            end
            local areaCat = (over and over.cat) or (isDungeon and "dungeons" or "zones")
            local function page(catName, mapID)
                return { cat = catName, mapID = mapID, areaId = areaId,
                         isDungeon = isDungeon, minLevel = nil, maxLevel = nil,
                         nameEn = areaName, nameZh = nil, classKey = nil,
                         sortLabel = nil, isNew = false, source = "questiedb" }
            end
            if classKey then
                -- Class-exclusive quests keep their own page, which the tree
                -- hides for other classes (C.EntryAllowed).
                eid = "class:" .. classKey
                init = function()
                    local e = page("classes", nil)
                    e.classKey, e.nameEn, e.isDungeon = classKey, nil, false
                    return e
                end
            elseif qq.library then
                -- One page of their own: 40+ books would otherwise bury the Undercity
                -- list. Checked before the area branch, because the corrected
                -- zoneOrSort points at Undercity and would win otherwise.
                eid = LIBRARY_KEY
                init = function()
                    local e = page("special", nil)
                    e.nameEn = "Book Collection"
                    e.sortLabel = "Book Collection"
                    return e
                end
            elseif ui then
                -- Instance areas are explicitly categorised as dungeons, so they
                -- never land in the generic "other regions" continent group.
                -- A dungeon whose AreaTable has no DBC UiMapID of its own borrows the
                -- entrance zone's map (Ruins of Lordaeron -> Undercity, Deeprun Tram ->
                -- Stormwind). Sharing "zone:<ui>" with the outdoor page silently merged
                -- the instance quests into that city list and swallowed the instance
                -- name, so those areas always keep a page of their own.
                local dbcUI = ns.AreaMap and ns.AreaMap[areaId]
                if isDungeon and not dbcUI and not (over and over.ui) then
                    eid = "area:" .. areaId
                    init = function()
                        local e = page("dungeons", nil)
                        e.nameEn = areaName or label
                        return e
                    end
                else
                    eid = "zone:" .. ui
                    init = function() return page(areaCat, ui) end
                end
            elseif areaId and (isDungeon or areaName) then
                -- No UiMapID for this AreaTable id. Keep the page under its own
                -- name instead of falling back to the starter's map, which used
                -- to file dungeon quests under an unrelated outdoor zone.
                eid = "area:" .. areaId
                init = function()
                    local e = page(areaCat, nil)
                    e.nameEn = areaName or label
                    e.sortLabel = over and over.label or nil
                    return e
                end
            elseif cat ~= "others" then
                -- Identifiable QuestSort: one page per sort id, so each profession
                -- or holiday keeps its own list. The DBC label is translated at
                -- display time through C.EntryName.
                eid = "sort:" .. qs
                init = function()
                    local e = page(cat, nil)
                    e.nameEn = label
                    e.sortLabel = label
                    return e
                end
            elseif spawnMap then
                eid = "zone:" .. spawnMap
                init = function() return page("zones", spawnMap) end
            else
                eid = "sort:" .. qs
                init = function()
                    local e = page("others", nil)
                    -- `label` is nil for unknown sorts, so it can never be concatenated
                    -- blindly; fall back to the area name, then to the raw sort id.
                    local fallback = label or areaName or (ns.L["Others"] .. " " .. qs)
                    e.nameEn = fallback
                    e.sortLabel = label
                    return e
                end
            end
            local e = ensure(eid, init)
            if not e._set[id] then
                e._set[id] = true
                e.quests[#e.quests + 1] = id
                local lvl = qq.level
                if lvl then
                    if e.minLevel == nil or lvl < e.minLevel then e.minLevel = lvl end
                    if e.maxLevel == nil or lvl > e.maxLevel then e.maxLevel = lvl end
                end
            end
        end
    end

    for _, e in pairs(groups) do
        e._set = nil
        entries[#entries + 1] = e
    end
    return quests, entries
end

local baseQuests, baseEntries = nil, nil
local built = false

-- Inverted reward index: questId -> { itemId, ... }. QuestieDB's Quest entity carries
-- no reward-item field, but its Item entity records which quests reward each item
-- (ItemDB.questRewards). We reverse that so a quest can list its reward items. The
-- split between "choose one of N" and "guaranteed" is NOT in this data, so the UI can
-- only separate the two when the live client answers for a quest in the player's log.
local rewardsIndex = {}
local rewardsBuilt = false

-- QuestieDB is the single source of truth. No local corrections, no share strings, no
-- SavedVariables overlay. The index is built once per session (warmed up a few seconds
-- after login) and kept, so opening the window never waits for it.
--
-- This deliberately hands out the baseline tables themselves instead of cloning them:
-- nothing in the addon ever writes to a quest record (writing to a hash table here used
-- to cost ~5.7k extra tables -- roughly half the addon's whole memory footprint -- for a
-- guarantee nobody needed).
-- `force` re-reads QuestieDB instead of reusing the baseline built earlier. Nothing in the
-- addon needs it at runtime (the baseline never changes under a live session); it exists
-- so a rebuild after a data-layer change can be verified.
-- Reverse ItemDB.questRewards ("which quests reward this item") into a per-quest list of
-- reward item ids. Iterates every item once; cheap relative to buildBase and runs at the
-- same warm-up. Each list is naturally free of duplicate item ids (one item contributes
-- itself to a quest at most once).
local function buildRewards()
    rewardsIndex = {}
    local ItemDB = _G.ItemDB
    if not ItemDB or type(ItemDB.GetAllIds) ~= "function" then return end
    local ids = ItemDB.GetAllIds()
    if not ids then return end
    -- ItemDB exposes only Get(id, key) / GetByIndex(id, fieldIndex); there is no per-field
    -- accessor named after the field, so read questRewards through Get (field 6 by name).
    for _, itemId in ipairs(ids) do
        if type(itemId) == "number" and itemId > 0 then
            -- Get(id, key) is a plain function (no self): the entity table is captured in a
            -- closure, so passing ItemDB as the first arg would shift arguments and read the
            -- wrong field. Call it as ItemDB.Get(itemId, "questRewards").
            local ok, qids = pcall(ItemDB.Get, itemId, "questRewards")
            if ok and type(qids) == "table" then
                for _, qid in ipairs(qids) do
                    if type(qid) == "number" and qid > 0 then
                        local list = rewardsIndex[qid]
                        if not list then
                            list = {}
                            rewardsIndex[qid] = list
                        end
                        list[#list + 1] = itemId
                    end
                end
            end
        end
    end
end

function S.Build(force)
    if force then
        baseQuests, baseEntries = nil, nil
        rewardsIndex = {}
        rewardsBuilt = false
    end
    if not baseQuests then
        baseQuests, baseEntries = buildBase()
    end
    if not rewardsBuilt then
        buildRewards()
        rewardsBuilt = true
    end
    S.quests, S.entries = baseQuests, baseEntries
    S.byId = {}
    for _, e in ipairs(baseEntries) do S.byId[e.id] = e end
    built = true
    return S.quests, S.entries
end

function S.IsBuilt()
    return built
end

function S.Get(id)
    return id and S.quests[id] or nil
end

-- Reward item ids for a quest, if any (from the inverted ItemDB.questRewards index).
-- Undifferentiated: the reverse map does not record whether an item is a guaranteed or a
-- "choose one" reward.
function S.Rewards(id)
    return id and rewardsIndex[id] or nil
end
