local _, ns = ...

-- Pure native map: Blizzard's user waypoint (the same marker Ctrl+LeftClick
-- places on a modern client) plus our own golden "!" start pin.
local M = {}
ns.Map = M

local pin, last
local WHITE = "Interface\\Buttons\\WHITE8X8"

local function canvasOf(wmf)
    if wmf.GetCanvas then
        local ok, c = pcall(wmf.GetCanvas, wmf)
        if ok and c then return c end
    end
    if wmf.ScrollContainer and wmf.ScrollContainer.Child then
        return wmf.ScrollContainer.Child
    end
    return nil
end

local function ensurePin()
    if pin then return pin end
    local wmf = _G.WorldMapFrame
    if not wmf then return nil end
    local parent = canvasOf(wmf) or wmf
    pin = CreateFrame("Frame", "OurixsQuestHandbookMapPin", parent)
    pin:SetSize(26, 26)
    local base = (parent.GetFrameLevel and parent:GetFrameLevel() or 1) + 40
    if pin.SetFrameLevel then pcall(pin.SetFrameLevel, pin, base) end
    pin:EnableMouse(true)

    local ring = pin:CreateTexture(nil, "BACKGROUND")
    ring:SetAllPoints(pin)
    ring:SetTexture(WHITE)
    ring:SetVertexColor(0.12, 0.09, 0.02, 0.9)
    local bg = pin:CreateTexture(nil, "ARTWORK")
    bg:SetPoint("TOPLEFT", pin, "TOPLEFT", 2, -2)
    bg:SetPoint("BOTTOMRIGHT", pin, "BOTTOMRIGHT", -2, 2)
    bg:SetTexture(WHITE)
    bg:SetVertexColor(0.96, 0.77, 0.16, 1)
    local text = pin:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    text:SetPoint("CENTER", pin, "CENTER", 0, 0)
    text:SetText("!")
    text:SetTextColor(0.15, 0.11, 0.03)
    pin.text = text
    pin:SetScript("OnEnter", function()
        if not (last and last.label) then return end
        if not GameTooltip then return end
        GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
        GameTooltip:SetText(last.label, 1, 0.82, 0)
        GameTooltip:AddLine(ns.L["Left-click: mark start on map"], 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    pin:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    return pin
end

-- Native waypoint + super-track arrow. Exists on Interface 16001; all calls
-- are guarded so older / partial clients simply keep the drawn pin.
function M.SetWaypoint(mapID, x, y)
    if not (C_Map and C_Map.SetUserWaypoint and UiMapPoint
        and UiMapPoint.CreateFromCoordinates) then return false end
    if C_Map.CanSetUserWaypointOnMap then
        local ok, can = pcall(C_Map.CanSetUserWaypointOnMap, mapID)
        if ok and not can then return false end
    end
    local ok1, point = pcall(UiMapPoint.CreateFromCoordinates, mapID, x / 100, y / 100)
    if not ok1 or not point then return false end
    local ok2 = pcall(C_Map.SetUserWaypoint, point)
    if not ok2 then return false end
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
        pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
    end
    return true
end

function M.Place(reassert)
    if not last then return end
    local wmf = _G.WorldMapFrame
    if not wmf then return end
    -- The client sometimes resets the map right after ShowUIPanel. Re-assert
    -- our target map during the initial retries, but never fight a player who
    -- deliberately switches maps later on.
    if wmf.GetMapID then
        local ok, cur = pcall(wmf.GetMapID, wmf)
        if ok and type(cur) == "number" and cur > 0 and cur ~= last.mapID then
            if reassert and wmf.SetMapID then
                pcall(wmf.SetMapID, wmf, last.mapID)
            else
                if pin then pin:Hide() end
                return
            end
        end
    end
    local p = ensurePin()
    if not p then return end
    local canvas = p:GetParent() or wmf
    local w, h
    if canvas.GetSize then w, h = canvas:GetSize() end
    if (not w or w == 0 or not h or h == 0) and wmf.GetWidth then
        w, h = wmf:GetWidth(), wmf:GetHeight()
    end
    if not w or w == 0 or not h or h == 0 then return end
    p:ClearAllPoints()
    p:SetPoint("CENTER", canvas, "TOPLEFT", last.x / 100 * w, -last.y / 100 * h)
    p:Show()
end

-- x, y are percentages (0..100), exactly as QuestieDB stores spawn coords.
function M.Show(mapID, x, y, label)
    if not mapID or not x or not y then return false, ns.L["No start location"] end
    local wmf = _G.WorldMapFrame
    if not wmf then return false, ns.L["No start location"] end
    if ShowUIPanel then pcall(ShowUIPanel, wmf) else wmf:Show() end
    if wmf.SetMapID then pcall(wmf.SetMapID, wmf, mapID) end

    last = { mapID = mapID, x = x, y = y, label = label }
    M.SetWaypoint(mapID, x, y)
    M.Place(true)
    if C_Timer and C_Timer.After then
        for _, delay in ipairs({ 0.05, 0.20, 0.60, 1.20 }) do
            C_Timer.After(delay, function() M.Place(true) end)
        end
    end
    return true
end

function M.OnMapChanged()
    if last then M.Place() end
end
