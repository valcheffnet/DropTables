local _, ns = ...

-- A round button on the minimap edge. Left click opens the Loot Finder, right click a menu, and dragging moves it.
local EDGE_OFFSET = 5

local button = CreateFrame("Button", "DropTablesMinimapButton", Minimap)
button:SetSize(31, 31)
button:SetFrameStrata("MEDIUM")
button:SetFrameLevel(8)
button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
button:RegisterForDrag("LeftButton")
button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local background = button:CreateTexture(nil, "BACKGROUND")
background:SetSize(20, 20)
background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
background:SetPoint("TOPLEFT", 7, -5)
local icon = button:CreateTexture(nil, "ARTWORK")
icon:SetSize(17, 17)
icon:SetTexture("Interface\\Icons\\INV_Misc_Bag_10")
icon:SetPoint("TOPLEFT", 7, -6)
local border = button:CreateTexture(nil, "OVERLAY")
border:SetSize(53, 53)
border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
border:SetPoint("TOPLEFT")

local function place()
    local angle = math.rad(ns.settings.minimapAngle)
    local radius = Minimap:GetWidth() / 2 + EDGE_OFFSET
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function followCursor()
    local centerX, centerY = Minimap:GetCenter()
    local x, y = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    ns.settings.minimapAngle = math.deg(math.atan2(y / scale - centerY, x / scale - centerX))
    place()
end

button:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", followCursor)
end)
button:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
end)

local function apply()
    button:SetShown(ns.settings.showMinimap)
    place()
end

local function openMenu(owner)
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle("Forever Drop Tables")
        root:CreateButton("Loot Finder", function()
            ns.OpenFinder()
        end)
        root:CreateButton("Drop table of the target", function()
            ns.ShowDetails(ns.UnitMob("target"))
        end)
        root:CreateButton("Share my tables", ns.ToggleExport)
        root:CreateButton("Move the target icons", function()
            ns.UnlockStrip(true)
        end)
        root:CreateButton("Options", ns.OpenOptions)
    end)
end

button:SetScript("OnClick", function(self, mouseButton)
    if mouseButton == "RightButton" then
        openMenu(self)
    else
        ns.ToggleFinder()
    end
end)

button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Forever Drop Tables")
    GameTooltip:AddLine("Left click: Loot Finder", 1, 1, 1)
    GameTooltip:AddLine("Right click: menu", 1, 1, 1)
    GameTooltip:AddLine("Drag: move around the minimap", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end)
button:SetScript("OnLeave", GameTooltip_Hide)

ns.On("DT_READY", apply)
ns.On("DT_SETTINGS_CHANGED", apply)
