local _, ns = ...

local M = {}
ns.Main = M

local W = ns.Widgets
local WHITE = "Interface\\Buttons\\WHITE8X8"

local function makeWindow()
    return W.Frame("OurixsQuestHandbookFrame", UIParent)
end

function M.Create()
    local TH = W.Theme
    local f = makeWindow()
    W.SkinWindow(f)
    f:SetSize(1000, 680)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("HIGH")
    -- Stay above the action bar and other addon frames (requirement 1).
    f:SetToplevel(true)
    -- Blizzard's own ESC handling closes frames listed in UISpecialFrames.
    -- Combined with the keyboard handler below this works even when the
    -- frame does not currently own keyboard focus (requirement 2).
    if UISpecialFrames and type(UISpecialFrames) == "table" then
        local listed = false
        for _, name in ipairs(UISpecialFrames) do
            if name == "OurixsQuestHandbookFrame" then listed = true break end
        end
        if not listed then table.insert(UISpecialFrames, "OurixsQuestHandbookFrame") end
    end
    f:EnableKeyboard(true)
    f:SetScript("OnKeyDown", function(self, key)
        if InCombatLockdown and InCombatLockdown() then return end
        if key == "ESCAPE" and self:IsShown() then
            self:SetPropagateKeyboardInput(false)
            self:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)
    f:SetScript("OnHide", function()
        ns.Tooltip.Hide()
        -- Release the row/card frames immediately so closing the window frees the memory
        -- the page held. The next open rebuilds from scratch (C_Timer driven).
        if ns.ChainView and ns.ChainView.OnHide and f.view then
            ns.ChainView.OnHide(f.view)
        end
    end)
    f:SetMovable(true)
    f:SetResizable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop", function() f:StopMovingOrSizing() M.Save() end)
    if ns.db and ns.db.frame then
        local s = ns.db.frame
        f:ClearAllPoints()
        -- Save/restore both the point and the point it is relative to: resizing
        -- re-anchors the window to TOPLEFT/BOTTOMLEFT, and restoring that as a
        -- TOPLEFT/TOPLEFT anchor would have put it off screen.
        local ok = pcall(f.SetPoint, f, s.point or "CENTER", UIParent,
            s.rel or s.point or "CENTER", s.x or 0, s.y or 0)
        if not ok then
            pcall(f.SetPoint, f, "CENTER", UIParent, "CENTER", 0, 0)
        end
        f:SetSize(s.w or 1000, s.h or 680)
    end
    f:Hide()

    -- Hard size clamp. SetMinResize/SetMaxResize are not honoured by StartSizing on
    -- every client, so guard the size here as well: a bad sizing calculation can then
    -- never blow the window past these bounds.
    do
        local MIN_W, MIN_H, MAX_W, MAX_H = 700, 420, 1500, 950
        local clamping = false
        f:HookScript("OnSizeChanged", function()
            if clamping then return end
            local w, h = f:GetWidth(), f:GetHeight()
            local nw = math.max(MIN_W, math.min(MAX_W, w))
            local nh = math.max(MIN_H, math.min(MAX_H, h))
            if nw ~= w or nh ~= h then
                clamping = true
                f:SetSize(nw, nh)
                clamping = false
            end
        end)
    end

    -- Top bar: flat surface separated from the content by a single hairline rule.
    local top = W.Panel(f, TH.top[1], TH.top[2], TH.top[3], 1)
    top:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -4)
    top:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    top:SetHeight(40)
    -- Title lockup: brand icon, then the addon's own name on top (not translated -- it
    -- is the name in the TOC and in the addon list), one small localized subtitle
    -- underneath. The subtitle is anchored to the title's bottom edge so a different
    -- client font cannot make the two lines collide.
    f.brandIcon = W.BrandIcon(top, 30, "ARTWORK", 0.03)
    f.brandIcon:SetPoint("TOPLEFT", top, "TOPLEFT", 12, -5)
    local title = W.Font(top, "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", top, "TOPLEFT", 50, -5)
    title:SetText("Ourix's Quest Handbook")
    title:SetTextColor(TH.text[1], TH.text[2], TH.text[3])
    title:SetWordWrap(false)
    f.title = title

    local subtitle = W.Font(top, "GameFontDisableSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 1, 1)
    subtitle:SetText(ns.L["Quest Chain Handbook"])
    subtitle:SetTextColor(TH.gold[1], TH.gold[2], TH.gold[3])
    subtitle:SetWordWrap(false)
    f.subtitle = subtitle

    f.closeBtn = W.Button(top, "X", 24, 22)
    f.closeBtn:SetPoint("RIGHT", top, "RIGHT", -8, 0)
    f.closeBtn:SetScript("OnClick", function() f:Hide() ns.Tooltip.Hide() end)
    f.shareBtn = W.Button(top, ns.L["Settings"], 76, 22)
    f.shareBtn:SetPoint("RIGHT", f.closeBtn, "LEFT", -6, 0)
    f.shareBtn:SetScript("OnClick", function() ns.Share:Open() end)

    f.factionBtn = W.Segment(top, ns.L["Alliance"], ns.L["Horde"], 112, 22)
    f.factionBtn:SetPoint("RIGHT", f.shareBtn, "LEFT", -8, 0)
    f.factionBtn.OnSelect = function(i)
        M:SetFaction(i == 1 and "Alliance" or "Horde")
    end

    -- Class / race / faction scope all live in Settings; the title bar only keeps the
    -- one switch that is used constantly while browsing.
    f.hideBtn = W.Toggle(top, ns.L["Hide completed"], 130, 24)
    f.hideBtn:SetPoint("RIGHT", f.factionBtn, "LEFT", -8, 0)
    f.hideBtn:SetScript("OnClick", function()
        ns.char.hideCompleted = not ns.char.hideCompleted
        ns.focusQuestId = nil
        M:Refresh()
        M:ResetScroll()
    end)

    -- Left edge after the title lockup, right edge clamped against the toggle cluster:
    -- two anchors let the field shrink instead of colliding when the window is narrowed.
    f.search = W.EditBox(top, 200, 22)
    f.search:SetPoint("LEFT", top, "LEFT", 296, 0)
    f.search:SetPoint("RIGHT", f.hideBtn, "LEFT", -10, 0)
    f.searchHint = W.Font(top, "GameFontDisableSmall")
    f.searchHint:SetPoint("LEFT", f.search, "LEFT", 7, 0)
    f.searchHint:SetText(ns.L["Search quests..."])
    -- Search is applied on a short delay instead of on every keystroke. Each refresh
    -- rebuilds the whole category tree and every chain row (thousands of quests), which
    -- is why typing felt laggy; the timer is restarted by the next keystroke so only the
    -- pause after the last character rebuilds. Enter and leaving the field apply at once.
    local searchSeq, searchText = 0, ""
    local function applySearch(text)
        text = text or ""
        if text == ns.search then return end
        ns.search = text
        -- A real search means the player is browsing again: drop the single-quest
        -- jump exemption and leave any pinned quick-find list. The programmatic clear
        -- below sets ns.search first, so its deferred applySearch("") returns at the
        -- guard above and keeps the exemption.
        ns.focusQuestId = nil
        ns.viewMode = "normal"
        M:Refresh()
        M:ResetScroll()
    end
    local function queueSearch(text)
        searchSeq = searchSeq + 1
        local token = searchSeq
        if C_Timer and C_Timer.After then
            C_Timer.After(0.30, function()
                if token == searchSeq then applySearch(text) end
            end)
        else
            applySearch(text)
        end
    end

    f.search:SetScript("OnTextChanged", function()
        searchText = f.search:GetText() or ""
        f.searchHint:SetShown(searchText == "")
        queueSearch(searchText)
    end)
    f.search:SetScript("OnEnterPressed", function()
        searchSeq = searchSeq + 1 -- cancel whatever is still pending
        applySearch(f.search:GetText() or "")
        f.search:ClearFocus()
    end)
    f.search:HookScript("OnEditFocusLost", function()
        searchSeq = searchSeq + 1
        applySearch(searchText)
    end)
    f.search:SetScript("OnEditFocusGained", function() f.searchHint:Hide() end)

    -- Clear the search field without firing the debounced apply chain: cancel any
    -- pending timer, reset the model and the widget together. Used by a chain jump so
    -- the target quest is not hidden behind a stale query.
    function M:ClearSearch()
        searchSeq = searchSeq + 1
        searchText = ""
        ns.search = ""
        if f.search then f.search:SetText("") end
        if f.searchHint then f.searchHint:SetShown(true) end
    end

    f.tree = ns.Tree.Create(f)
    f.tree:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -48)
    f.tree:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 4, 28)
    f.tree:SetWidth(220)
    W.HLine(f, 46, 4)

    f.view = ns.ChainView.Create(f)
    f.view:SetPoint("TOPLEFT", f, "TOPLEFT", 228, -48)
    f.view:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, 28)

    -- Footer: status only. The colour legend and the map-mark hint were intentionally
    -- removed; only the entry name + progress survives.
    local foot = W.Panel(f, TH.top[1], TH.top[2], TH.top[3], 1)
    foot:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 4, 4)
    foot:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, 4)
    foot:SetHeight(20)
    f.info = W.SmallFont(foot, 10)
    f.info:SetPoint("LEFT", foot, "LEFT", 8, 0)
    f.info:SetPoint("RIGHT", foot, "RIGHT", -24, 0)
    f.info:SetJustifyH("LEFT")

    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(18, 18)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
    grip:SetFrameLevel(f:GetFrameLevel() + 20)
    grip:EnableMouse(true)

    -- Resize is driven by hand instead of StartSizing(). The engine's sizing maths
    -- re-derives the frame from whatever anchors are present, and with this window's
    -- saved single-point anchor the very first drag frame stretched the width instead
    -- of following the cursor. Tracking the cursor delta ourselves and calling
    -- SetSize() leaves no room for that: width/height are simply
    --   start + (cursor now - cursor at press), clamped to the min/max box.
    local MIN_W, MIN_H, MAX_W, MAX_H = 700, 420, 1500, 950
    local rs = { active = false }
    local function cursorUI()
        local x, y = GetCursorPosition()
        local s = f:GetEffectiveScale()
        if not s or s == 0 then s = 1 end
        return x / s, y / s
    end
    grip:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        local left, top = f:GetLeft(), f:GetTop()
        if not left or not top then return end
        -- Pin the frame by its TOPLEFT at its current on-screen position so only the
        -- width/height can change while dragging.
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        f:SetClampedToScreen(false)
        local cx, cy = cursorUI()
        rs.active = true
        rs.x, rs.y = cx, cy
        rs.w, rs.h = f:GetWidth(), f:GetHeight()
    end)
    grip:SetScript("OnUpdate", function()
        if not rs.active then return end
        if not IsMouseButtonDown("LeftButton") then
            rs.active = false
            f:SetClampedToScreen(true)
            M.Save()
            return
        end
        local cx, cy = cursorUI()
        local w = rs.w + (cx - rs.x)
        local h = rs.h - (cy - rs.y)
        w = math.max(MIN_W, math.min(MAX_W, w))
        h = math.max(MIN_H, math.min(MAX_H, h))
        f:SetSize(w, h)
    end)
    grip:SetScript("OnHide", function()
        if rs.active then
            rs.active = false
            f:SetClampedToScreen(true)
        end
    end)
    -- Self-drawn diagonal resize grip (three rotated accent bars). Avoids depending
    -- on any external texture that may be missing in this client.
    for i = 0, 2 do
        local ln = grip:CreateTexture(nil, "ARTWORK")
        ln:SetTexture(WHITE)
        ln:SetVertexColor(TH.accent[1], TH.accent[2], TH.accent[3], 0.7)
        ln:SetSize(7, 2)
        pcall(ln.SetRotation, ln, math.pi / 4)
        ln:SetPoint("BOTTOMRIGHT", grip, "BOTTOMRIGHT", -2 - i * 4, 2 + i * 4)
    end
    if f.SetMinResize then pcall(f.SetMinResize, f, MIN_W, MIN_H) end
    if f.SetMaxResize then pcall(f.SetMaxResize, f, MAX_W, MAX_H) end

    M.frame = f
    return f
end

function M.Save()
    local f = M.frame
    if not f or not ns.db then return end
    local point, _, rel, x, y = f:GetPoint(1)
    ns.db.frame = { w = f:GetWidth(), h = f:GetHeight(),
                    point = point or "CENTER", rel = rel or point or "CENTER",
                    x = x or 0, y = y or 0 }
end

-- Switching page or faction rebuilds both lists, so both scroll offsets go
-- back to the top (requirement 3).
function M:ResetScroll()
    local f = self.frame
    if not f then return end
    local function reset(sf)
        if sf then
            sf:SetVerticalScroll(0)
            if sf.UpdateThumb then sf:UpdateThumb() end
        end
    end
    reset(f.view and f.view.scroll)
    reset(f.tree and f.tree.scroll)
end

-- Footer summary (entry name + progress). Shared by the full and the light refresh.
-- The pinned flat lists pass their own title instead of an entry id.
function M:UpdateInfo(f, entryId, done, total, title)
    if not (f and f.info) then return end
    local name = title
    if not name then
        local entry = ns.Source.byId and ns.Source.byId[entryId]
        name = entry and ns.Chains.EntryName(entry) or ""
    end
    f.info:SetText("|cffd9ae5f" .. name .. "|r   |cff9E968A" ..
        ns.L["Progress: %d/%d"]:format(done or 0, total or 0) .. "|r")
end

local function isFlatMode()
    return ns.viewMode == "active" or ns.viewMode == "favorite"
end

local function flatQuestIds()
    if ns.viewMode == "active" then return ns.Chains.ActiveQuestIds() end
    if ns.viewMode == "favorite" then return ns.FavoriteQuestIds() end
    return nil
end

local function pinCounts()
    return {
        active = #ns.Chains.ActiveQuestIds(),
        favorite = #ns.FavoriteQuestIds(),
    }
end

-- Clicking a pinned button switches the right-hand pane to a flat, chain-free list.
-- It never touches selectedEntry, so returning to normal restores the previous page.
-- A stale filter is cleared first: the flat list is a quick query, not another page to
-- filter, and a leftover search box would be misleading over an unfiltered result.
function M:SelectViewMode(mode)
    if mode ~= "active" and mode ~= "favorite" then return end
    local f = self.frame
    if not f then return end
    ns.viewMode = mode
    ns.focusQuestId = nil
    ns.selectedQuest = nil
    if self.ClearSearch then self:ClearSearch() end
    self:Refresh()
    local sf = f.view and f.view.scroll
    if sf then
        sf:SetVerticalScroll(0)
        if sf.UpdateThumb then sf.UpdateThumb() end
    end
end

-- Clicking an entry only needs the right-hand pane to change, so do NOT run a full
-- Refresh here: the tree is recoloured in place and keeps its scroll position and its
-- expand/collapse state. Only the quest list scrolls back to the top.
function M:SelectEntry(id)
    if not id then return end
    -- Manual navigation ends the single-quest jump exemption and leaves any pinned
    -- quick-find list; selecting a category always returns to the normal chain view.
    ns.focusQuestId = nil
    ns.viewMode = "normal"
    local f = self.frame
    ns.selectedEntry = id
    ns.selectedQuest = nil
    ns.char.selectedEntry = id
    if not f then return end
    if f.tree then
        ns.Tree.SetViewMode(f.tree, ns.viewMode, pinCounts())
        ns.Tree.SetSelected(f.tree, id)
    end
    local rows, done, total = ns.Chains.BuildView(id, ns.faction, ns.search)
    ns.ChainView.Update(f.view, rows, nil)
    self:UpdateInfo(f, id, done, total)
    if f.view and f.view.scroll then
        f.view.scroll:SetVerticalScroll(0)
        if f.view.scroll.UpdateThumb then f.view.scroll:UpdateThumb() end
    end
end

local function entryHas(e, id)
    for _, q in ipairs(e.quests or {}) do if q == id then return true end end
    return false
end

-- Right-click on a quest jumps to its prerequisite, switching pages when the
-- prerequisite belongs to another entry.
--
-- The dependency triangle is drawn from the raw edge, so the target can be a quest the
-- current filters keep off every page (other faction tab, race or class gate, or a
-- completed quest while "hide completed" is on). That used to end in a silent no-op; name
-- the gate instead, so the row always answers the click.
local JUMP_REFUSED = {
    faction = "Cannot jump: other faction",
    race = "Cannot jump: other race",
    class = "Cannot jump: other class",
    done = "Cannot jump: completed",
}
function M:FocusQuest(id)
    if not id then return end
    -- A jump always lands on a real category page: the pinned "current/favorite" lists
    -- are query aids and can never be a jump target. Exiting flat mode here covers the
    -- case where the jump was triggered from one of those lists.
    ns.viewMode = "normal"
    -- A jump lands on the quest the player clicked, so clear any stale search and
    -- exempt this one quest from every filter. Neither changes a saved user setting.
    if self.ClearSearch then self:ClearSearch() end
    ns.focusQuestId = id
    local target = ns.Source.Get(id)
    if not target then
        ns.Print(ns.L["Cannot jump: target is filtered out"])
        return
    end
    local why = ns.Chains.HiddenReason(target)
    -- A cross-faction dependency is only unreachable because of the tab we are on: the
    -- other side is an inspection view, where the race gate no longer applies either. Flip
    -- the tab when that alone makes the quest visible, and put it back when it does not --
    -- moving the player to an empty page would be worse than saying no.
    if why == "faction" and target.faction then
        local was = ns.faction
        ns.faction = target.faction
        local still = ns.Chains.HiddenReason(target)
        if still then
            ns.faction = was
            why = still   -- the tab was not the real blocker; name the one that is
        else
            ns.char.faction = ns.faction
            why = nil
        end
    end
    if why then
        ns.Print(ns.L[JUMP_REFUSED[why] or "Cannot jump: target is filtered out"])
        return
    end
    local current = ns.Source.byId and ns.Source.byId[ns.selectedEntry]
    if not current or not entryHas(current, id) then
        -- A class page is only reachable when "show all classes" is on, but the quest may
        -- still sit on one: prefer an entry the tree actually lists, fall back to any that
        -- holds the quest so the jump still lands somewhere.
        local pick, fallback
        for _, e in ipairs(ns.Source.entries or {}) do
            if entryHas(e, id) then
                if ns.Chains.EntryAllowed(e) then
                    pick = e
                    break
                end
                fallback = fallback or e
            end
        end
        pick = pick or fallback
        if not pick then
            ns.Print(ns.L["Cannot jump: target is filtered out"])
            return
        end
        ns.selectedEntry = pick.id
        ns.char.selectedEntry = pick.id
    end
    ns.selectedQuest = id
    self:Refresh()
    self:RevealSelected()
    ns.ChainView.ScrollToQuest(self.frame.view, id)
end

function M:SetFaction(faction)
    if faction ~= "Alliance" and faction ~= "Horde" then return end
    -- Also reachable from the options panel while the window is closed, after the index
    -- may have been released; rebuild before touching byId / entries.
    if ns.EnsureData then ns.EnsureData() end
    ns.focusQuestId = nil
    ns.viewMode = "normal"
    ns.faction = faction
    ns.char.faction = faction
    local entry = ns.Source.byId and ns.Source.byId[ns.selectedEntry]
    if entry and ns.PickDefaultEntry then
        local any = false
        for _, id in ipairs(entry.quests or {}) do
            if ns.Chains.Visible(ns.Source.Get(id), faction) then any = true break end
        end
        if not any then
            ns.selectedEntry = ns.PickDefaultEntry()
            ns.char.selectedEntry = ns.selectedEntry
            ns.selectedQuest = nil
        end
    end
    self:Refresh()
    self:ResetScroll()
end

function M:Refresh()
    local f = self.frame
    if not f then return end
    f.factionBtn:SetIndex(ns.faction == "Horde" and 2 or 1)
    f.hideBtn:SetSelected(ns.char.hideCompleted and true or false)

    local groups = ns.Chains.Categories(ns.faction, ns.search)
    local flat = isFlatMode()
    -- Deliberately NO force-expand and NO auto-scroll on ordinary refreshes (typing,
    -- toggling a filter, a background log event). Forcing the selected group open on
    -- every refresh made the tree reflow under the cursor and overrode the player's own
    -- collapse state. Reveal on open/jump is done explicitly by RevealSelected below.
    local found = false
    for _, g in ipairs(groups) do
        for _, item in ipairs(g.entries) do
            if item.entry.id == ns.selectedEntry then found = true break end
        end
        if found then break end
    end
    if not found and ns.PickDefaultEntry then
        ns.selectedEntry = ns.PickDefaultEntry()
        ns.char.selectedEntry = ns.selectedEntry
        ns.selectedQuest = nil
    end

    -- Pin highlight + counts are refreshed on every path (including the light
    -- SelectEntry path, which calls this same setter directly). In flat mode pass an
    -- explicit nil as the selected id: `flat and nil or id` is a classic Lua trap --
    -- nil is falsy, so it falls through to id and leaves the old page highlighted.
    local treeSelected = nil
    if not flat then treeSelected = ns.selectedEntry end
    ns.Tree.Update(f.tree, groups, treeSelected)
    ns.Tree.SetViewMode(f.tree, ns.viewMode, pinCounts())

    local rows, done, total, infoTitle
    if flat then
        rows, done, total = ns.Chains.BuildFlatView(flatQuestIds())
        infoTitle = ns.L[ns.viewMode == "active" and "Current Quests" or "Favorite Quests"]
    else
        rows, done, total = ns.Chains.BuildView(ns.selectedEntry, ns.faction, ns.search)
    end
    local viewSelected = nil
    if not flat then viewSelected = ns.selectedQuest end
    ns.ChainView.Update(f.view, rows, viewSelected)
    self:UpdateInfo(f, ns.selectedEntry, done, total, infoTitle)
end

-- Expand and reveal the selected category after opening the window or jumping to a
-- quest. Only these two moments move the tree: normal refreshes leave it untouched.
function M:RevealSelected()
    local f = self.frame
    if not f or not f.tree or isFlatMode() then return end
    local groups = ns.Chains.Categories(ns.faction, ns.search)
    for _, g in ipairs(groups) do
        for _, item in ipairs(g.entries) do
            if item.entry.id == ns.selectedEntry then
                ns.char.collapsed[g.id] = false
                break
            end
        end
    end
    ns.Tree.Update(f.tree, groups, ns.selectedEntry)
    ns.Tree.SetViewMode(f.tree, ns.viewMode, pinCounts())
    ns.Tree.ScrollToEntry(f.tree, ns.selectedEntry)
end

-- Default view on open: the player's own faction and the map they are on.
function M:FollowCurrentZone()
    local faction = UnitFactionGroup and UnitFactionGroup("player") or nil
    if faction == "Alliance" or faction == "Horde" then
        ns.faction = faction
        ns.char.faction = faction
    end
    if ns.char.followZone == false then return end
    local eid = ns.Chains.CurrentZoneEntry and ns.Chains.CurrentZoneEntry() or nil
    if eid and ns.Source.byId and ns.Source.byId[eid] then
        ns.selectedEntry = eid
        ns.char.selectedEntry = eid
        ns.selectedQuest = nil
    end
end

function M:Toggle()
    if not self.frame then self.Create() end
    if self.frame:IsShown() then
        self.frame:Hide()
        ns.Tooltip.Hide()
    else
        -- Already warm in the normal case (see the login timer in Init.lua); this only
        -- pays for the index if the player opens the window before that timer fires.
        if ns.EnsureData then ns.EnsureData() end
        self:FollowCurrentZone()
        -- Quick-find mode is transient: reopening always lands on the normal tree.
        ns.viewMode = "normal"
        self.frame:Show()
        self:Refresh()
        self:ResetScroll()
        self:RevealSelected()
    end
end

function M:IsShown()
    return self.frame and self.frame:IsShown()
end
