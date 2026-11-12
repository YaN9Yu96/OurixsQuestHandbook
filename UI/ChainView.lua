local _, ns = ...

local V = {}
ns.ChainView = V

local W = ns.Widgets
local WHITE = "Interface\\Buttons\\WHITE8X8"
-- Our own generated circle (a white disk that fills the texture edge to edge). The chain
-- nodes are drawn with it so they read as round dots rather than squares.
local ROUND = "Interface/AddOns/OurixsQuestHandbook/Media/Round.png"
local ROW_H, PAD, GAP = 30, 9, 12
-- The spine sits 5px further right than before, so the stub that reaches left of it (an
-- external prerequisite) has more room and is easier to see.
local TRUNK_X, INDENT = 21, 18
local NODE_X = TRUNK_X + INDENT
local CENTER = ROW_H / 2
-- A row costs about a dozen frames, and a chain page can be sixty of them, so a large page
-- is created over several frames -- a few rows per frame -- and the player can watch it fill
-- in. Nothing is pre-built behind the player's back: a row frame only exists once a page has
-- actually shown it, so the addon's frame memory tracks what the player really looks at
-- rather than a guessed worst case. Small pages are built in one go because spreading them
-- would only cost frames for nothing; the first slice of a big page is larger so the top of
-- the page lands immediately.
local BATCH_ROWS = 3
local BATCH_MS = 4
local FIRST_BATCH_ROWS = 14
-- Pages this small are cheaper to build in one go than to spread over frames.
local SYNC_LIMIT = 12
-- One capsule frame per "not yours" kind, so each keeps its own colour while the text
-- inside is whatever the quest data actually requires. The capsules are created the first
-- time a row needs one instead of for every row up front: most rows never show a badge,
-- and four unused pills per row was the bulk of the creation cost.
local TAG_RGB = {
    class   = { 0.72, 0.62, 0.94 },
    race    = { 0.45, 0.80, 0.72 },
    faction = { 0.92, 0.56, 0.50 },
}
local TAG_LABEL = {
    class   = "Not your class",
    race    = "Not your race",
    faction = "Not your faction",
}

local function hex(r, g, b)
    return ("|cff%02x%02x%02x"):format(math.floor(r * 255 + 0.5),
        math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

function V.Create(parent)
    local f = W.Panel(parent)
    local sf = W.Scroll(f)
    sf:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -4)
    sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 4)
    sf.child:SetWidth(400)
    f.scroll = sf
    f.rows, f.cards = {}, {}
    f.empty = W.Font(f, "GameFontDisable")
    f.empty:SetPoint("CENTER", f, "CENTER", 0, 0)
    f.empty:SetText(ns.L["No quest chain here"])
    f:SetScript("OnSizeChanged", function()
        sf.child:SetWidth(math.max(260, f:GetWidth() - 14))
    end)
    return f
end

-- ---- Lazily created row pieces ----------------------------------------------

local function ensureTag(row, key)
    local pill = row.tags[key]
    if pill then return pill end
    local TH = W.Theme
    local rgb = TAG_RGB[key] or TH.accent
    local text = ns.L[TAG_LABEL[key] or "NEW IN FOREVER"]
    pill = W.Badge(row, text, rgb, 13)
    row.tags[key] = pill
    return pill
end

-- ---- Reward item icons ----------------------------------------------
-- QuestieDB carries no reward-item field on quests, so rewards come from the inverted
-- ItemDB.questRewards index (DataSource). The data cannot tell a "choose one of N" reward
-- from a guaranteed one, so every reward shows as a bare game icon in one strip. Hovering
-- an icon shows the native item tooltip (GameTooltip) -- no text in the row itself.

local ICON, RGAP = 16, 3

-- This client exposes item data ONLY through the tooltip: GetItemIcon, GetItemInfoInstant
-- and GetItemInfo are all absent, while GameTooltip:SetItemByID works (the hover tooltip
-- proves the client knows the item). So the icon texture is pulled from a hidden
-- GameTooltip after SetItemByID. Resolution is asynchronous: an uncached item first
-- returns the question-mark fallback, then a short re-probe after the load lands caches
-- the real texture and a page repaint swaps it in.
local probeTT
local function getProbeTT()
    if probeTT then return probeTT end
    probeTT = CreateFrame("GameTooltip", "OQHItemProbeTT", nil, "GameTooltipTemplate")
    probeTT:Hide()
    return probeTT
end

local iconCache = {}   -- itemId -> resolved texture path
local pending = {}     -- itemId -> true while awaiting the load
local repaintQueued

local function probeIconNow(itemId)
    local tt = getProbeTT()
    tt:SetOwner(UIParent, "ANCHOR_NONE")
    tt:ClearLines()
    local ok = pcall(tt.SetItemByID, tt, itemId)
    if not ok then return nil end
    -- The item icon lives in the tooltip's embedded texture, conventionally named
    -- <frameName>Texture. Fall back to scanning the tooltip's children if a custom
    -- client names it differently.
    local name = tt:GetName()
    local texFrame = name and _G[name .. "Texture"]
    if texFrame and texFrame.GetTexture then
        local t = texFrame:GetTexture()
        if type(t) == "string" and t ~= "" and t:find("\\") then return t end
    end
    for _, child in ipairs({ tt:GetChildren() }) do
        if child.GetTexture and child ~= texFrame then
            local t = child:GetTexture()
            if type(t) == "string" and t ~= "" and t:find("\\") and not t:lower():find("tooltip") then
                return t
            end
        end
    end
    return nil
end

local function queueRepaint()
    if repaintQueued then return end
    repaintQueued = true
    if C_Timer and C_Timer.After then
        C_Timer.After(0.1, function()
            repaintQueued = nil
            ns.Refresh()
        end)
    else
        ns.RefreshSoon()
    end
end

local function cacheAndRepaint(itemId, tex)
    iconCache[itemId] = tex
    pending[itemId] = nil
    queueRepaint()
end

local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- An icon is either a texture path string or a numeric fileID; both are accepted by
-- Texture:SetTexture. 0 / "" / a non-path string means "no icon".
local function isIcon(v)
    if type(v) == "number" then return v ~= 0 end
    if type(v) == "string" then return v ~= "" and v:find("\\") ~= nil end
    return false
end

-- Resolve an item's icon synchronously. This client (Interface 16001) exposes the icon
-- through C_Item.GetItemIconByID(itemID), which returns a numeric fileID -- that is the
-- accessor other addons on this client use. Legacy clients expose GetItemIcon globally.
-- Returns a texture path / fileID, or nil when nothing resolves synchronously.
local function resolveIconSync(itemId)
    local C_Item = _G.C_Item
    if C_Item then
        -- Purpose-built, takes a plain itemID, returns a fileID (number). Primary path.
        if type(C_Item.GetItemIconByID) == "function" then
            local ok, ic = pcall(C_Item.GetItemIconByID, itemId)
            if ok and isIcon(ic) then return ic end
        end
        -- Fallback: instant info; the icon may sit in a table's .icon or a positional slot.
        if type(C_Item.GetItemInfoInstant) == "function" then
            local ok, r1 = pcall(C_Item.GetItemInfoInstant, itemId)
            if ok and type(r1) == "table" then
                if isIcon(r1.icon) then return r1.icon end
            end
        end
    end
    if type(GetItemIcon) == "function" then
        local ok, ic = pcall(GetItemIcon, itemId)
        if ok and isIcon(ic) then return ic end
    end
    if type(GetItemInfoInstant) == "function" then
        local ok, _, _, _, _, ic = pcall(GetItemInfoInstant, itemId)
        if ok and isIcon(ic) then return ic end
    end
    if type(GetItemInfo) == "function" then
        local ok, n, l, _, _, _, _, _, _, _, ic = pcall(GetItemInfo, "item:"..itemId..":0:0:0:0:0:0:0")
        if ok and isIcon(ic) then return ic end
    end
    return nil
end

local function retryResolve(itemId)
    if iconCache[itemId] then return end
    local ic = resolveIconSync(itemId) or probeIconNow(itemId)
    if ic then cacheAndRepaint(itemId, ic) end
end

local function itemIcon(itemId)
    if type(itemId) ~= "number" or itemId <= 0 then return FALLBACK_ICON end
    local cached = iconCache[itemId]
    if cached then return cached end
    local ic = resolveIconSync(itemId)
    if ic then iconCache[itemId] = ic; return ic end
    -- Not available synchronously: kick off the load through every available channel and
    -- repaint once the data lands.
    if not pending[itemId] then
        pending[itemId] = true
        -- Canonical retail async loader: the Item mixin calls us back after load.
        local Item = _G.Item
        if Item and type(Item.CreateFromItemID) == "function" then
            local okItem, item = pcall(function() return Item:CreateFromItemID(itemId) end)
            if okItem and item and type(item.ContinueOnItemLoad) == "function" then
                pcall(item.ContinueOnItemLoad, item, function()
                    local ic = (type(item.GetItemIcon) == "function" and item:GetItemIcon())
                        or resolveIconSync(itemId) or probeIconNow(itemId)
                    if ic then cacheAndRepaint(itemId, ic) end
                end)
            end
        end
        -- Independent safety net: request + tooltip probe + timer retries.
        local C_Item = _G.C_Item
        if C_Item and type(C_Item.RequestLoadItemDataByID) == "function" then
            pcall(C_Item.RequestLoadItemDataByID, itemId)
        end
        local t = probeIconNow(itemId)
        if t then
            cacheAndRepaint(itemId, t)
        elseif C_Timer and C_Timer.After then
            C_Timer.After(0.3, function() retryResolve(itemId) end)
            C_Timer.After(1.2, function() retryResolve(itemId) end)
            C_Timer.After(3.0, function() retryResolve(itemId) end)
        end
    end
    return FALLBACK_ICON
end

-- Item data arrives asynchronously. When it does, resolve any icon still showing the
-- fallback and repaint. Covers ITEM_DATA_LOAD_RESULT (retail) and GET_ITEM_INFO_RECEIVED.
local loadWatcher = CreateFrame("Frame")
pcall(loadWatcher.RegisterEvent, loadWatcher, "ITEM_DATA_LOAD_RESULT")
pcall(loadWatcher.RegisterEvent, loadWatcher, "GET_ITEM_INFO_RECEIVED")
loadWatcher:SetScript("OnEvent", function(_, event, a, b)
    local itemId = (type(a) == "number" and a) or (type(b) == "number" and b) or nil
    if itemId and iconCache[itemId] == nil then retryResolve(itemId) end
end)

local function showItemTooltip(owner, itemId)
    local tt = GameTooltip
    tt:SetOwner(owner, "ANCHOR_RIGHT")
    tt:ClearLines()
    local shown = false
    if type(tt.SetItemByID) == "function" then
        shown = pcall(tt.SetItemByID, tt, itemId)
    end
    if not shown and type(tt.SetHyperlink) == "function" then
        pcall(tt.SetHyperlink, tt, "item:" .. itemId .. ":0:0:0:0:0:0:0")
    end
    tt:Show()
end

local function ensureRewardIcon(row, i)
    local icons = row.rewardIcons
    if icons[i] then return icons[i] end
    local btn = CreateFrame("Button", nil, row)
    btn:SetSize(ICON, ICON)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function() end)   -- swallow clicks; tooltip is hover-only
    btn:SetFrameLevel((row:GetFrameLevel() or 1) + 2)
    local tex = btn:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints(btn)
    tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)    -- trim the icon's built-in padding
    btn.tex = tex
    btn:SetScript("OnEnter", function()
        local TH = W.Theme
        if row.bg then
            row.bg:SetVertexColor(TH.rowHover[1], TH.rowHover[2], TH.rowHover[3], 0.85)
        end
        if btn.itemId then showItemTooltip(btn, btn.itemId) end
    end)
    btn:SetScript("OnLeave", function()
        local TH = W.Theme
        if row.bg then
            row.bg:SetVertexColor(TH.rowSel[1], TH.rowSel[2], TH.rowSel[3],
                row.selected and 0.9 or 0)
        end
        GameTooltip:Hide()
    end)
    icons[i] = btn
    return btn
end

-- Width in px of a reward strip for `n` items (0 when none). No positioning here; the
-- strip is placed by paintRow to the LEFT of the badge strip (per request).
local function rewardWidth(n)
    if not n or n <= 0 then return 0 end
    return n * ICON + (n - 1) * RGAP
end

-- Place the reward icon strip with its RIGHT edge at `rightEdge` (x offset from the row's
-- right edge), marching LEFTWARD so it grows away from the badge anchor. Hides any surplus
-- icons from a previously wider row.
local function paintRewardStrip(row, list, n, rightEdge)
    local icons = row.rewardIcons or {}
    row.rewardIcons = icons
    for i = 1, #icons do icons[i]:Hide() end
    local cursor = 0
    for i = 1, n do
        local btn = ensureRewardIcon(row, i)
        btn.tex:SetTexture(itemIcon(list[i]))
        btn.itemId = list[i]
        btn:ClearAllPoints()
        btn:SetSize(ICON, ICON)
        btn:SetPoint("RIGHT", row, "RIGHT", rightEdge - cursor, 0)
        btn:Show()
        cursor = cursor + ICON + RGAP
    end
end

local function acquire(f, i)
    local row = f.rows[i]
    if row then return row end
    local TH = W.Theme
    local child = f.scroll.child
    row = CreateFrame("Button", nil, child)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    if row.SetFrameLevel then pcall(row.SetFrameLevel, row, 2) end
    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(row)
    bg:SetTexture(WHITE)
    bg:SetVertexColor(TH.row[1], TH.row[2], TH.row[3], 0)
    row.bg = bg

    -- Trunk starts at the root node and stops at the last node of the chain.
    row.trunk = row:CreateTexture(nil, "ARTWORK")
    row.trunk:SetTexture(WHITE)
    row.trunk:SetVertexColor(TH.accentDim[1], TH.accentDim[2], TH.accentDim[3], 0.9)
    row.arm = row:CreateTexture(nil, "ARTWORK")
    row.arm:SetTexture(WHITE)
    row.arm:SetVertexColor(TH.accentDim[1], TH.accentDim[2], TH.accentDim[3], 0.9)
    row.dotRing = row:CreateTexture(nil, "OVERLAY")
    row.dotRing:SetTexture(ROUND)
    row.dotRing:SetSize(12, 12)
    row.dotRing:SetVertexColor(0.08, 0.10, 0.13, 1)
    row.dot = row:CreateTexture(nil, "OVERLAY")
    row.dot:SetTexture(ROUND)
    row.dot:SetSize(8, 8)

    -- Stub reaching left of the chain spine: marks a quest whose prerequisite lives
    -- outside this chain (another chain, another page, or a quest not in the list).
    -- Hidden unless the row actually has such a prerequisite.
    row.leftArm = row:CreateTexture(nil, "ARTWORK")
    row.leftArm:SetTexture(WHITE)
    row.leftArm:SetVertexColor(TH.accentDim[1], TH.accentDim[2], TH.accentDim[3], 0.9)
    row.leftArm:Hide()

    row.title = W.Font(row, "GameFontNormal")
    row.title:SetJustifyH("LEFT")
    if row.title.SetWordWrap then pcall(row.title.SetWordWrap, row.title, false) end
    row.status = W.Font(row, "GameFontHighlightSmall")
    row.status:SetJustifyH("RIGHT")
    row.status:SetWidth(112)

    row.tags = {}
    row.rewardIcons = {}

    if row.SetHighlightTexture then pcall(row.SetHighlightTexture, row, W.QuestHighlight, "ADD") end
    row:SetScript("OnEnter", function()
        bg:SetVertexColor(TH.rowHover[1], TH.rowHover[2], TH.rowHover[3], 0.85)
        ns.Tooltip.Show(row, row.quest, row.item)
    end)
    row:SetScript("OnLeave", function()
        bg:SetVertexColor(TH.rowSel[1], TH.rowSel[2], TH.rowSel[3], row.selected and 0.9 or 0)
        ns.Tooltip.Hide()
    end)
    f.rows[i] = row
    return row
end

local function acquireCard(f, i)
    local card = f.cards[i]
    if card then return card end
    local child = f.scroll.child
    card = W.Card(child)
    if card.SetFrameLevel then pcall(card.SetFrameLevel, card, 1) end
    card.fold = W.Button(card, "-", 20, 18)
    card.fold:SetPoint("TOPRIGHT", card, "TOPRIGHT", -8, -PAD - 1)
    card.fold:Hide()
    f.cards[i] = card
    return card
end

-- Handing the player over to another view (world map pin / native quest log) always
-- takes our own window out of the way. It is closed BEFORE the handover runs: if the
-- handover bails out half way on a client quirk, the panel would otherwise sit on top
-- of whatever opened behind it. A deferred second pass covers clients that re-show
-- the window from their own panel code.
local function closeMain()
    ns.Tooltip.Hide()
    local f = ns.Main and ns.Main.frame
    if not f then return end
    f:Hide()
    if C_Timer and C_Timer.After then
        C_Timer.After(0.1, function()
            if f.IsShown and f:IsShown() then f:Hide() end
        end)
    end
end

-- Everything that has to be written on one row. Split out of the layout pass so a single
-- quest can be repainted in place when its title arrives asynchronously.
local function paintRow(view, row, item, selectedId, rightReserve)
    local TH = W.Theme
    local q = item.q
    row.quest, row.item = q, item
    row.rightReserve = rightReserve
    row.selected = q.id == selectedId
    local status = ns.Chains.Status(q, item)
    local h = ROW_H
    local nodeX = item.indent and NODE_X or TRUNK_X
    local titleX = nodeX + 12

    row:SetHeight(h)
    row.bg:SetVertexColor(TH.rowSel[1], TH.rowSel[2], TH.rowSel[3], row.selected and 0.9 or 0)

    local top = item.lineTop and 0 or CENTER
    local bottom = item.lineBottom and h or CENTER
    if bottom > top then
        row.trunk:ClearAllPoints()
        row.trunk:SetPoint("TOPLEFT", row, "TOPLEFT", TRUNK_X, -top)
        row.trunk:SetSize(1, bottom - top)
        row.trunk:Show()
    else
        row.trunk:Hide()
    end
    if item.indent then
        row.arm:ClearAllPoints()
        row.arm:SetPoint("TOPLEFT", row, "TOPLEFT", TRUNK_X, -CENTER)
        row.arm:SetSize(INDENT, 1)
        row.arm:Show()
    else
        row.arm:Hide()
    end
    -- Node fill: only "done" / "ready" / "active" are solid. "available" (可接取) and
    -- "locked" (不可接取) -- plus the rare "unknown" -- are hollow: the ring keeps the
    -- status colour but the centre is punched out with the card fill so the outline alone
    -- shows. The ring colour still distinguishes available (blue) from locked (grey).
    local sr, sg, sb = ns.Q.StatusColor(status)
    local solid = status == "done" or status == "ready" or status == "active"
    local CARD = W.Theme.card
    row.dotRing:ClearAllPoints()
    row.dotRing:SetPoint("CENTER", row, "TOPLEFT", nodeX + 0.5, -CENTER)
    row.dotRing:SetVertexColor(sr, sg, sb, 1)
    row.dot:ClearAllPoints()
    row.dot:SetPoint("CENTER", row, "TOPLEFT", nodeX + 0.5, -CENTER)
    if solid then
        row.dot:SetVertexColor(sr, sg, sb, 1)
    else
        row.dot:SetVertexColor(CARD[1], CARD[2], CARD[3], 1)
    end

    -- External prerequisite stub: a prerequisite not part of this quest's own chain is
    -- drawn as a short line reaching left of the chain spine (the in-chain arm reaches
    -- right, so the two directions never read the same). Search hits each sit in their
    -- own one-quest "chain", so the flag is suppressed there to avoid a stub on every row.
    if q.pre and item.chainSet and not item.search then
        local external = false
        for _, p in ipairs(q.pre) do
            if type(p) == "number" and not item.chainSet[p] then
                external = true
                break
            end
        end
        if external then
            row.leftArm:ClearAllPoints()
            row.leftArm:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -CENTER)
            row.leftArm:SetSize(TRUNK_X - 0.5 - 6, 1)
            row.leftArm:Show()
        else
            row.leftArm:Hide()
        end
    else
        row.leftArm:Hide()
    end

    local level = ns.Q.Level(q.id, q.level)
    local head = level and (ns.Q.ColorEscape(level) .. "[" .. level .. "]|r ") or ""
    local name = ns.Q.FastTitle(q.id, q.titleFallback)
    -- Badge follows the title on the SAME line; no second reason line,
    -- no "you are Lv.x", no multi-prerequisite text in the list.
    local meta = q.minLevel and ("  |cff9E968A" ..
        ns.L["Accept at Lv.%d"]:format(q.minLevel) .. "|r") or ""
    for _, pill in pairs(row.tags) do pill:Hide() end
    -- Reward icon strip is computed first (width only); it is painted LEFT of the badge
    -- strip after the badges are laid out, so the order right-to-left is: status,
    -- badges, then reward icons. The title truncates left of the reward strip.
    local rewardList = ns.Rewards.ForQuest(q.id)
    local nRew = rewardList and #rewardList or 0
    local stripW = rewardWidth(nRew)
    -- Right-aligned capsule strip: NEW first, then every "your character can
    -- never take this" marker. Laid out right-to-left so the status column keeps
    -- its fixed slot; the title simply truncates earlier when capsules are up.
    -- The text comes from the data ("Undead", "Warlock", "Horde"), so the row
    -- states the actual requirement instead of a generic "not yours".
    local tags = {}
    if q.isNew then tags[#tags + 1] = ensureTag(row, "badge") end
    for _, info in ipairs(ns.Chains.NotMineTags(q)) do
        if TAG_RGB[info.kind] then
            local pill = ensureTag(row, info.kind)
            pill:SetText(info.text)
            tags[#tags + 1] = pill
        end
    end
    local badgeX = -(124 + rightReserve)
    for _, b in ipairs(tags) do
        b:ClearAllPoints()
        b:SetPoint("RIGHT", row, "RIGHT", badgeX, 0)
        b:Show()
        badgeX = badgeX - (b:GetWidth() or 40) - 4
    end
    local tagsW = (-badgeX - 4) - (124 + rightReserve)
    if tagsW < 0 then tagsW = 0 end

    -- Reward icons: to the LEFT of the badge strip (right edge sits 4px left of the
    -- leftmost badge). Painted after badges so we know where they end. Always invoked so a
    -- row recycled from a quest with rewards to one without clears its leftover icons.
    paintRewardStrip(row, rewardList, nRew, badgeX - 4)

    row.title:ClearAllPoints()
    row.title:SetPoint("LEFT", row, "LEFT", titleX, 0)
    -- Title truncates left of the reward strip. Clamp keeps it from collapsing when a
    -- quest carries many rewards and badges at once.
    local titleRight = badgeX - 4
    if nRew > 0 then titleRight = titleRight - stripW - 4 end
    local rw = row:GetWidth() or 360
    local limit = -(rw - titleX - 24)
    if titleRight < limit then titleRight = limit end
    row.title:SetPoint("RIGHT", row, "RIGHT", titleRight, 0)
    row.title:SetText(head .. hex(sr, sg, sb) .. name .. "|r" .. meta)
    row.status:ClearAllPoints()
    row.status:SetPoint("RIGHT", row, "RIGHT", -(8 + rightReserve), 0)
    row.status:SetText(hex(sr, sg, sb) .. ns.Chains.StatusLabel(q, item) .. "|r")

    row:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            -- Silent when there is nothing to jump to: the tooltip does not
            -- advertise the action in that case either, so a message here would
            -- be the only feedback for something the player was never offered.
            local pre = ns.Chains.PreJumpTarget(q)
            if pre then ns.Main:FocusQuest(pre.id) end
            return
        end
        -- Shift+click is the "hand this quest to the native log" shortcut, and it
        -- only makes sense for a quest the player is actually on. Done, merely
        -- acceptable and locked quests have nothing to select in the log, so the
        -- click is swallowed silently instead of popping a "not in log" warning.
        if IsShiftKeyDown and IsShiftKeyDown() then
            if not ns.Q.Active(q.id) then return end
            closeMain()
            if not ns.Q.OpenInLog(q.id) then
                ns.Print(ns.L["Quest not in log"])
            end
            ns.selectedQuest = q.id
            ns.ChainView.Update(view, view.lastRows, q.id)
            return
        end
        if not q.loc then
            ns.Print(ns.L["No start location"])
            return
        end
        -- The world map is the destination: close our own window first so the pin
        -- and waypoint are immediately visible, whatever the map call returns.
        closeMain()
        local ok, err = ns.Map.Show(q.loc[1], q.loc[2], q.loc[3], name)
        if not ok then
            ns.Print(err or ns.L["No start location"])
            return
        end
        ns.selectedQuest = q.id
        ns.ChainView.Update(view, view.lastRows, q.id)
    end)
end

-- Geometry is computed for the whole page up front (it is only arithmetic), so the
-- scrollbar length and the card frames are right even while rows are still being
-- created frame by frame.
local function buildPlan(view, rows, selectedId)
    local plan, groups = {}, {}
    for _, item in ipairs(rows) do
        local g = groups[#groups]
        if not g or g.chain ~= item.chain then
            g = { chain = item.chain, items = {} }
            groups[#groups + 1] = g
        end
        g.items[#g.items + 1] = item
    end
    local y = 0
    for gi, g in ipairs(groups) do
        if gi > 1 then y = y + GAP end
        local cardY = y
        local cardH = #g.items * ROW_H + PAD * 2
        local first = g.items[1]
        -- The fold button sits on the card's top-right corner, i.e. 20px wide ending
        -- 6px inside the row's right edge. Every right-aligned column (status, badge,
        -- title) must therefore reserve that strip, otherwise the status text runs
        -- straight underneath the button.
        local foldShown = first.isStart and not first.search and (first.chainCount or 0) > 1
        plan[#plan + 1] = {
            kind = "card", gi = gi, cardY = cardY, cardH = cardH,
            foldShown = foldShown, first = first,
            rightReserve = foldShown and 30 or 0,
        }
        for ci, item in ipairs(g.items) do
            plan[#plan + 1] = {
                kind = "row", item = item, rowY = cardY + PAD + (ci - 1) * ROW_H,
                rightReserve = foldShown and 30 or 0,
            }
        end
        y = cardY + cardH
    end
    return plan, y
end

local function buildOne(view, e, selectedId)
    local child = view.scroll.child
    if e.kind == "card" then
        local card = acquireCard(view, e.gi)
        card:ClearAllPoints()
        card:SetPoint("TOPLEFT", child, "TOPLEFT", 6, -e.cardY)
        card:SetPoint("TOPRIGHT", child, "TOPRIGHT", -12, -e.cardY)
        card:SetHeight(e.cardH)
        card:Show()
        card.fold:ClearAllPoints()
        card.fold:SetPoint("TOPRIGHT", card, "TOPRIGHT", -8, -PAD - 1)
        if e.foldShown then
            local first = e.first
            card.fold:SetLabel(first.collapsed and "+" or "-")
            card.fold:SetSelected(first.collapsed and true or false)
            card.fold:Show()
            card.fold:SetScript("OnClick", function()
                ns.char.chainCollapsed = ns.char.chainCollapsed or {}
                ns.char.chainCollapsed[first.chainKey] =
                    not ns.char.chainCollapsed[first.chainKey]
                ns.Refresh()
            end)
        else
            card.fold:Hide()
        end
        return
    end
    view.rowCount = (view.rowCount or 0) + 1
    local row = acquire(view, view.rowCount)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", child, "TOPLEFT", 8, -e.rowY)
    row:SetPoint("TOPRIGHT", child, "TOPRIGHT", -14, -e.rowY)
    row.y = e.rowY
    paintRow(view, row, e.item, selectedId, e.rightReserve)
    row:Show()
    view.ids[#view.ids + 1] = e.item.q.id
    view.rowPlan[view.rowCount] = e
end

local function finishBuild(view, totalH)
    local child = view.scroll.child
    for i = view.rowCount + 1, #view.rows do view.rows[i]:Hide() end
    for i = view.cardCount + 1, #view.cards do view.cards[i]:Hide() end
    child:SetHeight(math.max(1, totalH + 8))
    if view.scroll.UpdateThumb then view.scroll:UpdateThumb() end
    view.building = false
    view.empty:SetShown(#view.lastRows == 0)
    if view.pendingScroll then
        local id = view.pendingScroll
        view.pendingScroll = nil
        V.ScrollToQuest(view, id)
    end
end

local function stepBuild(view)
    -- The first slice is bigger so one screenful lands in a single frame; after that the
    -- budget is small enough that nothing is felt.
    local limit = view.batchRows or BATCH_ROWS
    view.batchRows = BATCH_ROWS
    local deadline
    if type(debugprofilestop) == "function" then
        deadline = debugprofilestop() + BATCH_MS
    end
    local done = 0
    local plan = view.plan
    while view.planIndex <= #plan do
        local e = plan[view.planIndex]
        view.planIndex = view.planIndex + 1
        if e.kind == "card" then view.cardCount = (view.cardCount or 0) + 1 end
        buildOne(view, e, view.selectedId)
        done = done + 1
        if done >= limit then break end
        if deadline and debugprofilestop() > deadline then break end
    end
    if view.planIndex > #plan then
        view:SetScript("OnUpdate", nil)
        finishBuild(view, view.planHeight)
    end
end

-- A page is "the same" when every row position holds the same quest and the fold state
-- of each card is unchanged. Only the text can then differ, so the existing frames are
-- repainted instead of rebuilt: that is the selection-click path.
local function planSignature(plan)
    local parts = {}
    for i = 1, #plan do
        local e = plan[i]
        if e.kind == "card" then
            parts[i] = e.foldShown and "c1" or "c0"
        else
            parts[i] = "r" .. tostring(e.item.q and e.item.q.id or 0)
        end
    end
    return table.concat(parts, "|")
end

function V:Update(rows, selectedId)
    local child = self.scroll.child
    self.lastRows = rows or {}
    self.selectedId = selectedId
    self.generation = (self.generation or 0) + 1
    self.empty:SetShown(#self.lastRows == 0)

    local plan, totalH = buildPlan(self, self.lastRows, selectedId)
    local sig = planSignature(plan)

    if not self.building and self.rowPlan and sig == self.signature then
        for i = 1, self.rowCount do
            local e = self.rowPlan[i]
            -- The frame pool can be shorter than the plan after V:Trim; the signature is
            -- dropped there too, so this is a belt-and-braces guard on the shortcut.
            if e and self.rows[i] then
                paintRow(self, self.rows[i], e.item, selectedId, e.rightReserve)
            end
        end
        return
    end

    self:SetScript("OnUpdate", nil)
    for _, row in ipairs(self.rows) do row:Hide() end
    for _, card in ipairs(self.cards) do card:Hide() end

    self.plan, self.planHeight, self.signature = plan, totalH, sig
    self.planIndex, self.rowCount, self.cardCount = 1, 0, 0
    self.ids, self.rowPlan = {}, {}
    child:SetHeight(math.max(1, totalH + 8))

    -- Small pages are cheaper to build in one go than to spread over frames.
    if #plan <= SYNC_LIMIT then
        while self.planIndex <= #plan do
            local e = plan[self.planIndex]
            self.planIndex = self.planIndex + 1
            if e.kind == "card" then self.cardCount = self.cardCount + 1 end
            buildOne(self, e, selectedId)
        end
        self.building = false
        finishBuild(self, totalH)
        return
    end

    self.building = true
    self.batchRows = FIRST_BATCH_ROWS
    self:SetScript("OnUpdate", stepBuild)
    stepBuild(self)
end

-- Repaint the rows of one quest in place, without touching the rest of the page. Used
-- when a quest's title arrives from the client mid-session.
function V:Patch(id, selectedId)
    if not id or self.building then return end
    local sel = selectedId or self.selectedId
    for i = 1, self.rowCount or 0 do
        local row = self.rows[i]
        if row and row:IsShown() and row.quest and row.quest.id == id then
            local item = row.item
            if item then paintRow(self, row, item, sel, row.rightReserve or 0) end
        end
    end
end

-- Release row/card frames the player is no longer looking at. A frame pool only ever grows
-- in this design (a visited page leaves its rows behind), so a long session that browses a
-- hundred-row page would otherwise keep all of those frames alive forever. When the window
-- has been hidden for a while and nothing is mid-build, drop the surplus down to a small
-- floor: reopening will rebuild the rows a few per frame, which the player has chosen to
-- accept over keeping the memory. Anonymous frames whose last reference is dropped here are
-- collected by the Lua GC afterwards.
local TRIM_KEEP_ROWS, TRIM_KEEP_CARDS = 40, 6
local trimTimer

local function dropFrames(list, keep)
    if #list <= keep then return end
    for i = #list, keep + 1, -1 do
        local fr = list[i]
        list[i] = nil
        if fr then
            fr:Hide()
            if fr.ClearAllPoints then pcall(fr.ClearAllPoints, fr) end
            fr:SetScript("OnUpdate", nil)
            fr:SetScript("OnEnter", nil)
            fr:SetScript("OnLeave", nil)
            fr:SetScript("OnClick", nil)
        end
    end
end

function V:Trim()
    if self.building then return end
    local before = #self.rows
    dropFrames(self.rows, TRIM_KEEP_ROWS)
    dropFrames(self.cards, TRIM_KEEP_CARDS)
    -- The cached plan describes a frame pool that no longer exists, so the "same page,
    -- just repaint" shortcut must not be taken for the next open: the page is rebuilt
    -- (a few rows per frame) against the shortened pool instead.
    if #self.rows ~= before then self.signature = nil end
    if self.scroll and self.scroll.UpdateThumb then self.scroll:UpdateThumb() end
end

-- Called by the main window once it has been hidden for a while.
function V:ScheduleTrim(seconds)
    if trimTimer then return end
    if not (C_Timer and C_Timer.After) then return end
    trimTimer = C_Timer.After(seconds, function()
        trimTimer = nil
        local f = ns.Main and ns.Main.frame
        if f and not f:IsShown() and not self.building then V.Trim(self) end
    end)
end

function V.ScrollToQuest(f, id)
    if not f or not f.scroll then return false end
    if f.building then
        f.pendingScroll = id
        return true
    end
    for _, row in ipairs(f.rows or {}) do
        if row:IsShown() and row.quest and row.quest.id == id then
            local sf = f.scroll
            local vh = sf:GetHeight() or 0
            local max = math.max(0, (sf.child:GetHeight() or 0) - vh)
            local target = (row.y or 0) - vh / 2 + (row:GetHeight() or ROW_H) / 2
            sf:SetVerticalScroll(math.max(0, math.min(max, target)))
            if sf.UpdateThumb then sf:UpdateThumb() end
            return true
        end
    end
    return false
end
