local _, ns = ...

-- Options panel. All quest data comes from QuestieDB: there is nothing to
-- export, import, observe or correct, so this is a pure view-options surface.
local S = {}
ns.Share = S
ns.Options = S

local W = ns.Widgets

local function toggle(char, key, refresh)
    return function()
        char[key] = not char[key]
        S:Refresh()
        if refresh and ns.Refresh then ns.Refresh() end
    end
end

function S.Create()
    local TH = W.Theme
    local f = W.Frame("OurixsQuestHandbookOptionsFrame", UIParent)
    f:SetSize(420, 380)
    f:SetPoint("CENTER", UIParent, "CENTER", 40, 0)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    f:EnableKeyboard(true)
    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" and self:IsShown() then
            self:SetPropagateKeyboardInput(false)
            self:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)
    if UISpecialFrames and type(UISpecialFrames) == "table" then
        local listed = false
        for _, name in ipairs(UISpecialFrames) do
            if name == "OurixsQuestHandbookOptionsFrame" then listed = true break end
        end
        if not listed then table.insert(UISpecialFrames, "OurixsQuestHandbookOptionsFrame") end
    end
    W.SkinWindow(f)

    local top = W.Panel(f, TH.top[1], TH.top[2], TH.top[3], 1)
    top:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -4)
    top:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    top:SetHeight(34)
    local title = W.Font(top, "GameFontNormalLarge")
    f.brandIcon = W.BrandIcon(top, 20, "ARTWORK", 0.05)
    f.brandIcon:SetPoint("LEFT", top, "LEFT", 8, 0)
    title:SetPoint("LEFT", top, "LEFT", 36, 0)
    title:SetText("|cffd9ae5f" .. ns.L["Settings"] .. "|r")
    local close = W.Button(top, "X", 24, 22)
    close:SetPoint("RIGHT", top, "RIGHT", -6, 0)
    close:SetScript("OnClick", function() f:Hide() end)

    local head = W.Font(f, "GameFontNormal")
    head:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -48)
    head:SetTextColor(TH.accent[1], TH.accent[2], TH.accent[3])
    head:SetText(ns.L["Display options"])

    -- y is measured DOWN from the panel's top edge, like every other offset in this file
    -- (W.HLine / the reset button use the same convention). The rows used to be given
    -- already-negated values here and were then negated again, which pushed all five
    -- toggles above the panel instead of inside it.
    local function check(key, y, label, charTable, refresh)
        local b = W.Toggle(f, label, 360, 26)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -y)
        b:SetScript("OnClick", toggle(charTable, key, refresh))
        return b
    end

    f.hideBtn = check("hideCompleted", 72, ns.L["Hide completed"], ns.char, true)
    f.classBtn = check("showAllClasses", 104, ns.L["Show all classes"], ns.char, true)
    f.raceBtn = check("showAllRaces", 136, ns.L["Show all races"], ns.char, true)

    -- Same two choices, same words, same state as the Alliance/Horde switch in the
    -- title bar: picking a side here flips the title bar and the list with it, so the
    -- two controls can never disagree.
    f.factionSeg = W.Segment(f, ns.L["Alliance"], ns.L["Horde"], 360, 26)
    f.factionSeg:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -168)
    f.factionSeg.OnSelect = function(i)
        local want = (i == 2) and "Horde" or "Alliance"
        if ns.Main and ns.Main.SetFaction then
            ns.Main:SetFaction(want)
        else
            ns.faction, ns.char.faction = want, want
        end
        S:Refresh()
        if ns.Refresh then ns.Refresh() end
    end

    f.followBtn = check("followZone", 200, ns.L["Open at current zone"], ns.char, false)
    f.npcBtn = check("npcPanel", 232, ns.L["NPC chain panel"], ns.char, false)

    f.minimapBtn = W.Toggle(f, ns.L["Minimap button"], 360, 26)
    f.minimapBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -264)
    f.minimapBtn:SetScript("OnClick", function()
        ns.Minimap:Toggle()
        S:Refresh()
    end)

    W.HLine(f, 304, 16)

    f.resetBtn = W.Button(f, ns.L["Reset window"], 180, 24)
    f.resetBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -314)
    f.resetBtn:SetScript("OnClick", function()
        ns.db.frame = nil
        if ns.Main.frame then
            ns.Main.frame:ClearAllPoints()
            ns.Main.frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
            ns.Main.frame:SetSize(1000, 680)
        end
        ns.Print(ns.L["Window position reset"])
    end)

    f.foot = W.Font(f, "GameFontDisableSmall")
    f.foot:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 10)
    f.foot:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 10)
    f.foot:SetJustifyH("LEFT")
    f.foot:SetText(ns.L["Data source"] .. ": " .. ns.L["QuestieDB"])

    f:Hide()
    S.frame = f
    return f
end

function S:Refresh()
    local f = self.frame
    if not f then return end
    f.hideBtn:SetSelected(ns.char.hideCompleted and true or false)
    f.classBtn:SetSelected(ns.char.showAllClasses and true or false)
    f.raceBtn:SetSelected(ns.char.showAllRaces and true or false)
    f.factionSeg:SetIndex(ns.faction == "Horde" and 2 or 1)
    f.followBtn:SetSelected(ns.char.followZone ~= false)
    f.npcBtn:SetSelected(ns.char.npcPanel ~= false)
    f.minimapBtn:SetSelected(ns.db.minimap.show ~= false)
end

function S:Open()
    if not self.frame then self.Create() end
    self:Refresh()
    self.frame:Show()
end

function S:Toggle()
    if self.frame and self.frame:IsShown() then
        self.frame:Hide()
    else
        self:Open()
    end
end
