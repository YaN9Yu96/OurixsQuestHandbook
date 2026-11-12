local _, ns = ...

-- Companion panel: deliberately Blizzard-native (same DialogBox textures as
-- QuestFrame / GossipFrame), so it reads as part of the conversation UI.
--
-- Scope: the NPC dialog only. A quest-log variant was tried and dropped -- this client
-- exposes no way to ask which log row is selected (no C_QuestLog.GetSelectedQuest, no
-- quest id in GetQuestLogTitle, no QuestLogQuestTitle detail region), so the panel could
-- never tell which chain to draw.
local P = {}
ns.NpcPanel = P

local W = ns.Widgets
local WHITE = "Interface\\Buttons\\WHITE8X8"
local ROW_H = 24

local function acquire(f, i)
    local row = f.rows[i]
    if row then return row end
    row = CreateFrame("Button", nil, f)
    row:SetHeight(ROW_H)
    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(row)
    bg:SetTexture(WHITE)
    bg:SetVertexColor(0.85, 0.70, 0.32, 0)
    row.bg = bg
    local div = row:CreateTexture(nil, "ARTWORK")
    div:SetTexture(WHITE)
    div:SetVertexColor(0.55, 0.45, 0.25, 0.28)
    div:SetHeight(1)
    div:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 10, 0)
    div:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -10, 0)
    row.dot = row:CreateTexture(nil, "ARTWORK")
    row.dot:SetTexture(WHITE)
    row.dot:SetSize(6, 6)
    row.dot:SetPoint("LEFT", row, "LEFT", 12, 0)
    row.tag = W.SmallFont(row, 9)
    row.tag:SetPoint("LEFT", row, "LEFT", 24, 6)
    row.tag:SetTextColor(0.65, 0.58, 0.42)
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", row, "LEFT", 24, -5)
    row.text:SetPoint("RIGHT", row, "RIGHT", -10, -5)
    row.text:SetJustifyH("LEFT")
    if row.SetHighlightTexture then pcall(row.SetHighlightTexture, row, W.QuestHighlight, "ADD") end
    row:SetScript("OnEnter", function()
        if not row.current then bg:SetVertexColor(0.85, 0.70, 0.32, 0.16) end
        ns.Tooltip.Show(row, row.quest, nil, true)
    end)
    row:SetScript("OnLeave", function()
        bg:SetVertexColor(0.85, 0.70, 0.32, row.current and 0.22 or 0)
        ns.Tooltip.Hide()
    end)
    -- Display only: the companion panel never reacts to clicks. No OnClick handler and
    -- no click registration, so a stray click cannot open the map, move the waypoint or
    -- touch the quest log while the player is talking to an NPC.
    if row.RegisterForClicks then pcall(row.RegisterForClicks, row) end
    row:SetScript("OnClick", nil)
    if row.EnableMouseWheel then pcall(row.EnableMouseWheel, row, false) end
    f.rows[i] = row
    return row
end

function P.Create()
    local f = W.Frame("OurixsQuestHandbookNpcPanel", UIParent)
    W.SkinDialog(f)
    f:SetSize(262, 300)
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    -- Native gold title bar, same texture / height / offset as QuestFrame.
    f.title = W.DialogHeader(f, ns.L["Quest Chains"], 240)
    f.rows = {}
    f:Hide()
    P.frame = f
    return f
end

local function attach(f)
    f:ClearAllPoints()
    if _G.QuestFrame then
        -- Align the tops so both DialogBox header bars sit on the same line.
        f:SetPoint("TOPLEFT", QuestFrame, "TOPRIGHT", 4, 0)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 330, 0)
    end
end

local function hex(r, g, b)
    return ("|cff%02x%02x%02x"):format(math.floor(r * 255 + 0.5),
        math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

function P:Show(qid)
    if not qid or not self.frame then return end
    -- The companion panel walks the whole quest model (previous / next), so it needs the
    -- index as well; build it here when the handbook has never been opened.
    if ns.EnsureData then ns.EnsureData() end
    local f = self.frame
    attach(f)
    for _, row in ipairs(f.rows) do row:Hide() end
    local prev, nextList = ns.Chains.Relatives(qid)
    local current = ns.Source.Get(qid)
    local list = {}
    for i = #prev, 1, -1 do list[#list + 1] = { quest = prev[i], tag = ns.L["Previous"] } end
    if current or _G.QuestDB then
        list[#list + 1] = { quest = current or { id = qid, pre = {} },
                            tag = ns.L["Current quest"], current = true }
    end
    for _, q in ipairs(nextList) do
        list[#list + 1] = { quest = q, tag = ns.L["Next"] }
    end
    if #list == 0 then self:Hide() return end

    -- The panel is capped at 440px, and Relatives can return up to 10 previous plus 10
    -- next quests: without a cap the last rows are laid out below the bottom edge and
    -- simply never seen. Keep the current quest centred and drop the farthest neighbours.
    do
        local TOP, MAX_H = 34, 440
        local maxRows = math.max(1, math.floor((MAX_H - TOP - 10) / ROW_H))
        if #list > maxRows then
            local curPos = 0
            for i, item in ipairs(list) do
                if item.current then curPos = i break end
            end
            curPos = curPos > 0 and curPos or 1
            local half = math.floor((maxRows - 1) / 2)
            local from = math.max(1, curPos - half)
            local to = math.min(#list, from + maxRows - 1)
            from = math.max(1, to - maxRows + 1)
            local kept = {}
            for i = from, to do kept[#kept + 1] = list[i] end
            list = kept
        end
    end

    local y = 34
    for i, item in ipairs(list) do
        local row = acquire(f, i)
        local q = item.quest
        row.quest = q
        row.current = item.current and true or false
        row:SetHeight(ROW_H)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -y)
        row:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -y)
        row.bg:SetVertexColor(0.85, 0.70, 0.32, row.current and 0.22 or 0)
        local status = ns.Chains.Status(q)
        local r, g, b = ns.Q.StatusColor(status)
        row.dot:SetVertexColor(r, g, b, 1)
        row.tag:SetText(item.tag)
        local level = ns.Q.Level(q.id, q.level)
        local head = level and ("[" .. level .. "] ") or ""
        row.text:SetText(hex(r, g, b) .. head .. ns.Q.Title(q.id, nil) .. "|r")
        row:Show()
        y = y + ROW_H
    end
    f:SetHeight(math.min(440, math.max(100, y + 10)))
    f:Show()
end

function P:Hide()
    if self.frame then self.frame:Hide() end
end
