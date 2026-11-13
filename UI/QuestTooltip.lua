local _, ns = ...

local T = {}
ns.Tooltip = T

local function mapName(mapID)
    if not mapID or not (C_Map and C_Map.GetMapInfo) then return nil end
    local ok, info = pcall(C_Map.GetMapInfo, mapID)
    if ok and type(info) == "table" then return info.name end
    return nil
end

-- The native quest hyperlink is the only source for the quest's description and
-- objectives; re-printing them here produced two identical "Requirements" blocks, so
-- those are still never repeated. Prerequisites ARE enumerated, though: the list column
-- only has room for a short "needs prerequisite" reason, which tells the player nothing
-- about *which* quest to go and do. Each prerequisite is printed with its own live state
-- (completed / in progress / available / locked + short reason) so a blocked quest is
-- actionable straight from the tooltip.
-- readOnly suppresses the click hints: the NPC companion panel is a read-only view, so
-- advertising "left-click marks the map" there would describe something that no longer
-- happens.

-- Keep the list short enough that the tooltip never grows past the screen; a quest with
-- a dozen prerequisites reports the remainder instead of wrapping into a wall of text.
local MAX_PRE_LINES = 6

-- Blizzard's objective block in the native quest tooltip is headed "要求：" / "Requirements:"
-- in the standard tooltip gold at the normal left margin. Our own section headers copy that
-- exact look -- same gold, same colon -- so the tooltip reads as several blocks of the same
-- kind instead of one gold title glued onto grey detail lines.
local COLON = ns.IsChineseClient() and "：" or ":"

-- Gold matches the native "要求：" line (NORMAL_FONT_COLOR, 1.00 / 0.82 / 0.00). Keep the
-- hex in sync with ns.Q.ColorEscape if that ever changes.
local HEADER_R, HEADER_G, HEADER_B = 1.00, 0.82, 0.00

-- Name of the item that opens a quest. The client's own item table is the first choice
-- (it is localised in the player's language); QuestieDB's composed item name is the
-- fallback. Both are synchronous: a tooltip must never depend on an item load callback.
local function itemName(itemId)
    local CItem = _G.C_Item
    if CItem and type(CItem.GetItemNameByID) == "function" then
        local ok, name = pcall(CItem.GetItemNameByID, itemId)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    if CItem and type(CItem.GetItemInfo) == "function" then
        local ok, name = pcall(CItem.GetItemInfo, itemId)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    local ItemDB = _G.ItemDB
    if ItemDB and type(ItemDB.name) == "function" then
        local ok2, name2 = pcall(ItemDB.name, itemId)
        if ok2 and type(name2) == "string" and name2 ~= "" then return name2 end
    end
    return "#" .. tostring(itemId)
end

-- One blank line above every header: without it the previous block's last line runs
-- straight into the header and the two read as one stammering sentence.
local function sectionHeader(tt, label)
    tt:AddLine(" ")
    tt:AddLine(label .. COLON, HEADER_R, HEADER_G, HEADER_B)
end

-- One prerequisite per line: quest name on the left, its state on the right, both in the
-- state colour (the right column slightly darker so the name stays dominant).
local function addPrerequisites(tt, q)
    local pre = q.pre
    if type(pre) ~= "table" or #pre == 0 then return end
    local rows = {}
    for _, pid in ipairs(pre) do
        if type(pid) == "number" and pid ~= q.id then
            rows[#rows + 1] = { id = pid, q = ns.Source.Get(pid) }
        end
    end
    if #rows == 0 then return end

    -- Same order as the chain in the list: lowest level first, id as the tie-break. The
    -- prerequisite order is the story order, not the raw id order, so the block can be
    -- read top-down as "do these in this order".
    table.sort(rows, function(a, b)
        local al = (a.q and (a.q.minLevel or a.q.level)) or 999
        local bl = (b.q and (b.q.minLevel or b.q.level)) or 999
        if al ~= bl then return al < bl end
        return a.id < b.id
    end)

    sectionHeader(tt, ns.L["Prerequisites"])
    for i, row in ipairs(rows) do
        if i > MAX_PRE_LINES then
            tt:AddLine(ns.L["%d more prerequisites"]:format(#rows - MAX_PRE_LINES), 0.55, 0.62, 0.70)
            break
        end
        local pid, pq = row.id, row.q
        if pq then
            local status = ns.Chains.Status(pq, nil)
            local r, g, b = ns.Q.StatusColor(status)
            -- Resolve the name without kicking off an async load: hovering a row must
            -- not fire one RequestLoadQuestByID per prerequisite (the tooltip is drawn
            -- once and would not repaint when those answers arrive).
            local name = ns.Q.CachedTitle(pid) or pq.titleFallback
                or (ns.L["Quest #%d"]:format(pid))
            local state = ns.Chains.StatusLabel(pq, nil)
            if tt.AddDoubleLine then
                tt:AddDoubleLine(name, state, r, g, b, r * 0.8, g * 0.8, b * 0.8)
            else
                tt:AddLine(name .. "  " .. state, r, g, b)
            end
        else
            -- Prerequisite recorded in the chain data but absent from the database:
            -- say so instead of silently dropping it.
            tt:AddLine(ns.L["Quest #%d"]:format(pid) .. "  " .. ns.L["Details unavailable"],
                0.48, 0.46, 0.44)
        end
    end
end

-- One follower per line: quest name on the left, its state on the right. Only followers
-- OUTSIDE the quest's own chain are listed -- an in-chain child is already on the spine, so
-- repeating it here would just duplicate the list the player is looking at.
local function addFollowUps(tt, q, chainSet)
    local post = ns.Source.post
    if type(post) ~= "table" then return end
    local rows = {}
    for _, fid in ipairs(post[q.id] or {}) do
        if type(fid) == "number" and fid ~= q.id then
            if chainSet and chainSet[fid] then
                -- in-chain child: drawn on the spine already; skip
            else
                rows[#rows + 1] = { id = fid, q = ns.Source.Get(fid) }
            end
        end
    end
    if #rows == 0 then return end
    table.sort(rows, function(a, b)
        local al = (a.q and (a.q.minLevel or a.q.level)) or 999
        local bl = (b.q and (b.q.minLevel or b.q.level)) or 999
        if al ~= bl then return al < bl end
        return a.id < b.id
    end)
    sectionHeader(tt, ns.L["Follow-ups"])
    for i, row in ipairs(rows) do
        if i > MAX_PRE_LINES then
            tt:AddLine(ns.L["%d more follow-ups"]:format(#rows - MAX_PRE_LINES), 0.55, 0.62, 0.70)
            break
        end
        local fid, fq = row.id, row.q
        if fq then
            local status = ns.Chains.Status(fq, nil)
            local r, g, b = ns.Q.StatusColor(status)
            local name = ns.Q.CachedTitle(fid) or fq.titleFallback
                or (ns.L["Quest #%d"]:format(fid))
            local state = ns.Chains.StatusLabel(fq, nil)
            if tt.AddDoubleLine then
                tt:AddDoubleLine(name, state, r, g, b, r * 0.8, g * 0.8, b * 0.8)
            else
                tt:AddLine(name .. "  " .. state, r, g, b)
            end
        else
            tt:AddLine(ns.L["Quest #%d"]:format(fid) .. "  " .. ns.L["Details unavailable"],
                0.48, 0.46, 0.44)
        end
    end
end

function T.Show(owner, q, item, readOnly)
    if not owner or not q then return end
    local tt = GameTooltip
    tt:SetOwner(owner, "ANCHOR_RIGHT")
    tt:ClearLines()

    -- Prefer the client's own quest hyperlink tooltip when it has the data.
    local native = false
    local link = ns.Q.NativeLink(q.id)
    if link and tt.SetHyperlink then
        local ok = pcall(tt.SetHyperlink, tt, link)
        if ok and tt.NumLines then
            local n = tt:NumLines()
            native = type(n) == "number" and n > 1
        end
    end
    if not native then
        local level = ns.Q.Level(q.id, q.level)
        local prefix = level and (ns.Q.ColorEscape(level) .. "[" .. level .. "]|r ") or ""
        tt:AddLine(prefix .. ns.Q.Title(q.id, nil), 1, 0.82, 0, true)
    end

    -- One compact line: status, or the short reason why it is locked.
    local status = ns.Chains.Status(q, item)
    local r, g, b = ns.Q.StatusColor(status)
    tt:AddLine(ns.Chains.StatusLabel(q, item), r, g, b)

    -- Which quests have to be done first, and where each one stands right now.
    addPrerequisites(tt, q)
    -- What this quest unlocks elsewhere (follow-ups outside its own chain).
    addFollowUps(tt, q, item and item.chainSet)

    -- Where and when the quest can be picked up. The header only appears when there is
    -- something under it: a bare "接取条件：" hanging over the data-origin line would be a
    -- title with no block. For a quest opened by an item, the item (not the NPC giver)
    -- is the real starting point, so its coordinates win over the giver's spawn.
    local startItems = q.startItems
    local hasStartItems = type(startItems) == "table" and #startItems > 0
    local markLoc = q.startLoc or q.loc
    if q.minLevel or markLoc or hasStartItems then
        sectionHeader(tt, ns.L["Accept conditions"])
        if q.minLevel then
            tt:AddLine(ns.L["Accept at Lv.%d"]:format(q.minLevel), 0.62, 0.68, 0.76)
        end
        if hasStartItems then
            for _, itemId in ipairs(startItems) do
                tt:AddLine(ns.L["Started by item %s"]:format(itemName(itemId)),
                    0.62, 0.68, 0.76, true)
            end
        end
        if markLoc then
            local where = mapName(markLoc[1]) or tostring(markLoc[1])
            tt:AddLine(ns.L["Start"] .. ": " .. where ..
                (" %.1f, %.1f"):format(markLoc[2] or 0, markLoc[3] or 0), 0.62, 0.68, 0.76, true)
        end
    end
    -- Footer split: the "new in Forever" badge and the data-origin line are the addon's own
    -- metadata, not part of the quest's conditions, so they get their own paragraph under
    -- the blocks above.
    tt:AddLine(" ")
    if q.isNew then tt:AddLine(ns.L["NEW IN FOREVER"], 0.275, 0.749, 0.447) end

    tt:AddLine(ns.L["Data origin"] .. ": " .. ns.L["QuestieDB"], 0.55, 0.62, 0.70)
    if not readOnly then
        -- Only offer the pin when there is somewhere to pin: an item-started quest with
        -- a known drop spot qualifies, a quest with no coordinates at all does not.
        if markLoc then
            tt:AddLine(ns.L["Left-click: mark start on map"], 0.55, 0.62, 0.70)
        end
        -- Offer the jump whenever the edge exists AND it is outside the current chain (an
        -- in-chain parent is already on the spine, so it needs neither hint nor action).
        -- A target the filters currently hide still gets the hint: the click answers with
        -- the gate name, which is more useful than a row that visibly marks a dependency
        -- and then swallows the click.
        if ns.Chains.PreJumpTarget(q, item and item.chainSet) then
            tt:AddLine(ns.L["Right-click: jump to previous"], 0.55, 0.62, 0.70)
        end
        if ns.Chains.PostJumpTarget(q, item and item.chainSet) then
            tt:AddLine(ns.L["Shift+right-click: jump to follow-up"], 0.55, 0.62, 0.70)
        end
        if ns.Q.Active(q.id) then
            tt:AddLine(ns.L["Shift+Click: open quest log"], 0.55, 0.62, 0.70)
        end
    end
    tt:Show()
end

function T.Hide()
    GameTooltip:Hide()
end
