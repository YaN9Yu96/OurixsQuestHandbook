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

    -- Where and when the quest can be picked up. The header only appears when there is
    -- something under it: a bare "接取条件：" hanging over the data-origin line would be a
    -- title with no block.
    if q.minLevel or q.loc then
        sectionHeader(tt, ns.L["Accept conditions"])
        if q.minLevel then
            tt:AddLine(ns.L["Accept at Lv.%d"]:format(q.minLevel), 0.62, 0.68, 0.76)
        end
        if q.loc then
            local where = mapName(q.loc[1]) or tostring(q.loc[1])
            tt:AddLine(ns.L["Start"] .. ": " .. where ..
                (" %.1f, %.1f"):format(q.loc[2] or 0, q.loc[3] or 0), 0.62, 0.68, 0.76, true)
        end
    end
    -- Footer split: the "new in Forever" badge and the data-origin line are the addon's own
    -- metadata, not part of the quest's conditions, so they get their own paragraph under
    -- the blocks above.
    tt:AddLine(" ")
    if q.isNew then tt:AddLine(ns.L["NEW IN FOREVER"], 0.275, 0.749, 0.447) end

    tt:AddLine(ns.L["Data origin"] .. ": " .. ns.L["QuestieDB"], 0.55, 0.62, 0.70)
    if not readOnly then
        tt:AddLine(ns.L["Left-click: mark start on map"], 0.55, 0.62, 0.70)
        -- Only offer the jump when there is actually somewhere to jump to: a raw
        -- prerequisite id whose quest is filtered out, missing or hidden is not a place
        -- the player can be taken to, so the hint stays away.
        if ns.Chains.PreJumpTarget(q) then
            tt:AddLine(ns.L["Right-click: jump to previous"], 0.55, 0.62, 0.70)
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
