local _, ns = ...

local M = {}
ns.Minimap = M

-- Icon centre sits on the minimap's circular edge; the radius is derived from
-- the actual minimap size instead of a hardcoded guess.
local function position(b)
    local angle = math.rad((ns.db and ns.db.minimap and ns.db.minimap.angle) or 215)
    local radius = 5
    local w = ((Minimap.GetWidth and Minimap:GetWidth()) or 140) / 2 + radius
    local h = ((Minimap.GetHeight and Minimap:GetHeight()) or 140) / 2 + radius
    local ux, uy = math.cos(angle), math.sin(angle)
    local x, y
    local shape = (GetMinimapShape and GetMinimapShape()) or "ROUND"
    if shape == "ROUND" then
        x, y = ux * w, uy * h
    else
        local dw = math.sqrt(2 * w * w) - 10
        local dh = math.sqrt(2 * h * h) - 10
        x = math.max(-w, math.min(ux * dw, w))
        y = math.max(-h, math.min(uy * dh, h))
    end
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

function M.Create()
    if not Minimap then return end
    local b = CreateFrame("Button", "OurixsQuestHandbookMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    -- Left click only: the button opens / closes the handbook and does nothing else. The
    -- faction view lives in the window's own top bar and in the options panel, where it
    -- is discoverable; an invisible right-click toggle on a 31px button was a trap.
    b:RegisterForClicks("LeftButtonUp")
    b:RegisterForDrag("LeftButton")

    local back = b:CreateTexture(nil, "BACKGROUND")
    back:SetSize(20, 20)
    back:SetPoint("CENTER", b, "CENTER", 0, 0)
    back:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    -- Same brand icon as the addon list and the title bars. Its own artwork is a dark
    -- plate, so it sits inside Blizzard's minimap button ring without a visible seam.
    local icon = ns.Widgets.BrandIcon(b, 17, "ARTWORK", 0.06)
    icon:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.icon = icon
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("CENTER", b, "CENTER", 11, -11)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    b:SetScript("OnClick", function(_, button)
        -- Guard as well as unregister: some UI packs re-register clicks on every button
        -- they skin, and a stray right click must stay inert.
        if button and button ~= "LeftButton" then return end
        ns.Main:Toggle()
    end)
    b:SetScript("OnEnter", function()
        if not GameTooltip then return end
        GameTooltip:SetOwner(b, "ANCHOR_LEFT")
        GameTooltip:SetText("Ourix's Quest Handbook", 1, 0.82, 0)
        GameTooltip:AddLine(ns.L["Quest Chain Handbook"], 0.851, 0.682, 0.373)
        GameTooltip:AddLine(ns.L["Left-click: open the handbook"], 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine(ns.L["Data source"] .. ": " .. ns.L["QuestieDB"], 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    b:SetScript("OnDragStart", function() b.dragging = true end)
    b:SetScript("OnDragStop", function() b.dragging = false end)
    b:SetScript("OnUpdate", function()
        if not b.dragging then return end
        local mx, my = Minimap:GetCenter()
        if not mx or not my then return end
        local cx, cy = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale() or 1
        cx, cy = cx / scale, cy / scale
        local angle = math.deg(math.atan2(cy - my, cx - mx)) % 360
        ns.db.minimap.angle = angle
        position(b)
    end)

    M.button = b
    position(b)
    M:SetShown(ns.db.minimap.show ~= false)
    return b
end

function M:SetShown(on)
    if not self.button then return end
    ns.db.minimap.show = on and true or false
    if on then self.button:Show() else self.button:Hide() end
end

function M:Toggle()
    self:SetShown(not (ns.db.minimap.show ~= false))
end
