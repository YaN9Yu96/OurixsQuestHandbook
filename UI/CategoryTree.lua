local _, ns = ...

local T = {}
ns.Tree = T

local W = ns.Widgets
local WHITE = "Interface\\Buttons\\WHITE8X8"

local ROW_H, HEADER_H = 25, 26
-- Three distinct type sizes: group header > entry name > level/progress meta.
local FONT_HDR, FONT_ROW, FONT_META = 12, 10, 9

-- Pinned quick-find buttons sit ABOVE the scroll child, so they never scroll away.
-- PIN_AREA is how far the scroll region is pushed down to make room for the two rows.
local PIN_H, PIN_GAP = 24, 2
local PIN_AREA = PIN_H * 2 + PIN_GAP + 4

-- Rows are pooled and reused for BOTH group headers and entry rows. Every visual
-- property therefore has to be re-applied on each pass -- a font size set for a child
-- row would otherwise leak into the header that recycles the same frame next refresh
-- (that leak is what made big and small sections render at the same size).
local function setSize(fs, size)
    if not fs or not fs.GetFont then return end
    local ok, path, _, flags = pcall(fs.GetFont, fs)
    if ok and path then pcall(fs.SetFont, fs, path, size, flags or "") end
end

-- Entry name colour. A page that has a quest in the log is tinted with the "in progress"
-- colour and a page that merely has something to accept gets the "available" colour,
-- matching the node dots in the chain list. State outranks selection for the name
-- (the selected page is still obvious from its bar and row background), otherwise the
-- selected page keeps the accent colour.
local function paintLabel(row, selected, state)
    local TH = W.Theme
    local c = TH.text
    if state == "active" then
        c = ns.Q.STATUS_COLOR.active
    elseif state == "available" then
        c = ns.Q.STATUS_COLOR.available
    elseif state == "done" then
        c = ns.Q.STATUS_COLOR.done
    elseif selected then
        c = TH.accent
    end
    row.label:SetTextColor(c[1], c[2], c[3])
end

-- Build one pinned quick-find button. It is a child of the panel (not the scroll child)
-- so it stays put while the category list scrolls underneath it.
local function makePin(f, mode, labelKey, y)
    local TH = W.Theme
    local btn = CreateFrame("Button", nil, f)
    btn:SetHeight(PIN_H)
    btn:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -y)
    btn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -y)

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(btn)
    bg:SetTexture(WHITE)
    bg:SetVertexColor(TH.top[1], TH.top[2], TH.top[3], TH.top[4] or 1)
    btn.bg = bg

    local bar = btn:CreateTexture(nil, "OVERLAY")
    bar:SetTexture(WHITE)
    bar:SetVertexColor(TH.accent[1], TH.accent[2], TH.accent[3], 1)
    bar:SetWidth(3)
    bar:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
    bar:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0)
    bar:Hide()
    btn.bar = bar

    btn.label = W.Font(btn, "GameFontNormalSmall")
    -- These two are top-level "collection" tabs, not child pages: match the size of
    -- the collapsible group headers (FONT_HDR), not the smaller entry rows (FONT_ROW).
    setSize(btn.label, FONT_HDR)
    btn.label:SetJustifyH("LEFT")
    btn.label:SetWordWrap(false)
    btn.label:SetPoint("LEFT", btn, "LEFT", 18, 0)
    btn.label:SetPoint("RIGHT", btn, "RIGHT", -46, 0)
    btn.label:SetText(ns.L[labelKey])
    btn.label:SetTextColor(TH.accent[1], TH.accent[2], TH.accent[3])

    btn.meta = W.Font(btn, "GameFontHighlightSmall")
    setSize(btn.meta, FONT_META)
    btn.meta:SetJustifyH("RIGHT")
    btn.meta:SetWordWrap(false)
    btn.meta:SetPoint("RIGHT", btn, "RIGHT", -8, 0)
    btn.meta:SetTextColor(TH.muted[1], TH.muted[2], TH.muted[3])

    btn.mode = mode
    btn.base = TH.top
    btn:SetScript("OnClick", function()
        if ns.Main and ns.Main.SelectViewMode then ns.Main:SelectViewMode(mode) end
    end)
    btn:SetScript("OnEnter", function()
        if btn.selected then return end
        bg:SetVertexColor(TH.rowHover[1], TH.rowHover[2], TH.rowHover[3], TH.rowHover[4] or 1)
    end)
    btn:SetScript("OnLeave", function()
        if btn.selected then return end
        local c = btn.base or TH.top
        bg:SetVertexColor(c[1], c[2], c[3], c[4] or 1)
    end)
    return btn
end

function T.Create(parent)
    local f = W.Panel(parent)
    f.pins = {
        makePin(f, "active",   "Current Quests",  2),
        makePin(f, "favorite", "Favorite Quests", 2 + PIN_H + PIN_GAP),
    }
    -- Hairline separating the pinned block from the scrolling category tree.
    local rule = f:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(W.Theme.line[1], W.Theme.line[2], W.Theme.line[3], 0.7)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -PIN_AREA + 2)
    rule:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -PIN_AREA + 2)

    local sf = W.Scroll(f)
    sf:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -PIN_AREA)
    sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    sf.child:SetWidth(200)
    f.scroll = sf
    f.rows = {}
    f:SetScript("OnSizeChanged", function()
        sf.child:SetWidth(math.max(160, f:GetWidth() - 10))
    end)
    return f
end

-- Reflect the active quick view on the pinned buttons. `counts` maps "active" and
-- "favorite" to the number of quests each list currently holds, shown as small meta.
function T:SetViewMode(mode, counts)
    local TH = W.Theme
    counts = counts or {}
    for _, btn in ipairs(self.pins or {}) do
        local on = btn.mode == mode
        btn.selected = on
        btn.base = on and TH.rowSel or TH.top
        btn.bg:SetVertexColor(btn.base[1], btn.base[2], btn.base[3], btn.base[4] or 1)
        btn.bar:SetShown(on)
        btn.meta:SetText(tostring(counts[btn.mode] or 0))
    end
end

local function acquire(f, i)
    local row = f.rows[i]
    if row then return row end
    local TH = W.Theme

    row = CreateFrame("Button", nil, f.scroll.child)
    row:SetHeight(ROW_H)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(row)
    bg:SetTexture(WHITE)
    bg:SetVertexColor(TH.panel[1], TH.panel[2], TH.panel[3], 1)
    row.bg = bg

    -- Selected marker: a 3px warm bar on the left edge (no arrow glyph, which used to
    -- be anchored straight on top of the progress column).
    local bar = row:CreateTexture(nil, "OVERLAY")
    bar:SetTexture(WHITE)
    bar:SetVertexColor(TH.accent[1], TH.accent[2], TH.accent[3], 1)
    bar:SetWidth(3)
    bar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    bar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    bar:Hide()
    row.bar = bar

    -- Bottom rule, used only by group headers to close the section band.
    local div = row:CreateTexture(nil, "ARTWORK")
    div:SetColorTexture(TH.line[1], TH.line[2], TH.line[3], 0.7)
    div:SetHeight(1)
    div:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    div:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
    div:Hide()
    row.div = div

    -- "new in Forever" marker as a 4px gold dot: in a 220px column a pill badge cannot
    -- sit anywhere without colliding with the level/progress text.
    local dot = row:CreateTexture(nil, "OVERLAY")
    dot:SetTexture(WHITE)
    dot:SetVertexColor(TH.accent[1], TH.accent[2], TH.accent[3], 1)
    dot:SetSize(4, 4)
    dot:SetPoint("LEFT", row, "LEFT", 10, 0)
    dot:Hide()
    row.dot = dot

    row.label = W.Font(row, "GameFontNormalSmall")
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)
    row.label:SetPoint("LEFT", row, "LEFT", 18, 0)
    row.label:SetPoint("RIGHT", row, "RIGHT", -76, 0)

    -- Level range and progress: small, muted, right aligned. Sized every pass with
    -- FONT_META so it stays secondary to the entry name.
    row.meta = W.Font(row, "GameFontHighlightSmall")
    row.meta:SetJustifyH("RIGHT")
    row.meta:SetWordWrap(false)
    row.meta:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.meta:SetTextColor(TH.muted[1], TH.muted[2], TH.muted[3])

    row.base = TH.panel
    -- Hover lightens the row's own base colour (never forces TH.panel), so hovering a
    -- group header no longer drops it to the entry-row colour.
    row:SetScript("OnEnter", function()
        if row.selected then return end
        bg:SetVertexColor(TH.rowHover[1], TH.rowHover[2], TH.rowHover[3], TH.rowHover[4] or 1)
    end)
    row:SetScript("OnLeave", function()
        if row.selected then return end
        local c = row.base or TH.panel
        bg:SetVertexColor(c[1], c[2], c[3], c[4] or 1)
    end)
    f.rows[i] = row
    return row
end

function T:Update(groups, selectedId)
    local TH = W.Theme
    local child = self.scroll.child
    for _, row in ipairs(self.rows) do row:Hide() end
    ns.char.collapsed = ns.char.collapsed or {}
    local y, index = 0, 0

    for _, g in ipairs(groups or {}) do
        if #g.entries > 0 then
            index = index + 1
            local collapsed = ns.char.collapsed[g.id] and true or false
            local header = acquire(self, index)
            header:SetHeight(HEADER_H)
            header:ClearAllPoints()
            header:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
            header:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -y)
            header.y = y
            header.entryId = nil
            header.selected = false
            header.base = TH.top
            header.bg:SetVertexColor(TH.top[1], TH.top[2], TH.top[3], TH.top[4] or 1)
            header.bar:Hide()
            header.dot:Hide()
            header.div:Show()
            setSize(header.label, FONT_HDR)
            header.label:ClearAllPoints()
            header.label:SetPoint("LEFT", header, "LEFT", 8, 0)
            header.label:SetPoint("RIGHT", header, "RIGHT", -6, 0)
            header.label:SetText((collapsed and "+  " or "-  ") .. g.title)
            header.label:SetTextColor(TH.accent[1], TH.accent[2], TH.accent[3])
            header.meta:SetText("")
            header:SetScript("OnClick", function()
                ns.char.collapsed[g.id] = not ns.char.collapsed[g.id]
                ns.Refresh()
            end)
            header:Show()
            y = y + HEADER_H

            if not collapsed then
                for _, item in ipairs(g.entries) do
                    index = index + 1
                    local row = acquire(self, index)
                    local entry = item.entry
                    row:SetHeight(ROW_H)
                    row:ClearAllPoints()
                    row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
                    row:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -y)
                    row.y = y
                    row.entryId = entry.id
                    row.selected = entry.id == selectedId
                    row.div:Hide()
                    row.base = row.selected and TH.rowSel or TH.panel
                    row.bg:SetVertexColor(row.base[1], row.base[2], row.base[3], row.base[4] or 1)
                    row.bar:SetShown(row.selected)
                    row.dot:SetShown(entry.isNew and true or false)

                    -- Children sit one step in from the header and use the small size.
                    setSize(row.label, FONT_ROW)
                    row.label:ClearAllPoints()
                    row.label:SetPoint("LEFT", row, "LEFT", 18, 0)
                    row.label:SetPoint("RIGHT", row, "RIGHT", -76, 0)
                    row.label:SetText(item.name)
                    row.state = item.state
                    paintLabel(row, row.selected, item.state)

                    setSize(row.meta, FONT_META)
                    local range = ""
                    if entry.minLevel and entry.maxLevel then
                        range = entry.minLevel .. "-" .. entry.maxLevel .. "  "
                    elseif entry.minLevel then
                        range = entry.minLevel .. "+  "
                    end
                    row.meta:SetText(range .. item.done .. "/" .. item.total)
                    row.meta:SetTextColor(TH.muted[1], TH.muted[2], TH.muted[3])

                    row:SetScript("OnClick", function()
                        ns.Main:SelectEntry(entry.id)
                    end)
                    row:Show()
                    y = y + ROW_H
                end
            end
        end
    end
    child:SetHeight(math.max(1, y))
    if self.scroll.UpdateThumb then self.scroll:UpdateThumb() end
end

-- Bring a category row into view after a jump or on window open. The row must already
-- exist (its group expanded by the caller); this only moves the scrollbar.
function T:ScrollToEntry(id)
    if not id then return false end
    local sf = self.scroll
    if not sf then return false end
    for _, row in ipairs(self.rows) do
        if row:IsShown() and row.entryId == id then
            local vh = sf:GetHeight() or 0
            local max = math.max(0, (sf.child:GetHeight() or 0) - vh)
            local target = (row.y or 0) - vh / 2 + (row:GetHeight() or ROW_H) / 2
            sf:SetVerticalScroll(math.max(0, math.min(max, target)))
            if sf.UpdateThumb then sf.UpdateThumb() end
            return true
        end
    end
    return false
end

-- Light-weight selection change: recolour the pooled rows in place instead of running
-- a full Update. Clicking an entry therefore keeps the scroll offset and the expand /
-- collapse state exactly where the player left them.
function T:SetSelected(id)
    local TH = W.Theme
    for _, row in ipairs(self.rows) do
        if row:IsShown() and row.entryId then
            local sel = row.entryId == id
            if row.selected ~= sel then
                row.selected = sel
                row.base = sel and TH.rowSel or TH.panel
                row.bg:SetVertexColor(row.base[1], row.base[2], row.base[3], row.base[4] or 1)
                row.bar:SetShown(sel)
                paintLabel(row, sel, row.state)
            end
        end
    end
end
