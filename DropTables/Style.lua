local _, ns = ...

-- The look shared by the Drop Tables windows: a dark ledger with gold hairlines, Morpheus headings and
-- Friz Quadrata text. Window backgrounds follow the opacity setting; text and icons stay solid.
local Style = {}
ns.Style = Style

local WHITE = "Interface\\Buttons\\WHITE8x8"

local C = {
    ink = { 0.055, 0.047, 0.04 },
    raised = { 0.105, 0.09, 0.075 },
    line = { 0.79, 0.64, 0.29, 0.45 },
    faint = { 0.79, 0.64, 0.29, 0.18 },
    gold = { 0.91, 0.77, 0.42 },
    text = { 0.94, 0.9, 0.82 },
    muted = { 0.62, 0.57, 0.48 },
    bar = { 0.78, 0.5, 0.16, 0.3 },
}
Style.colors = C

local function makeFont(name, path, size, color)
    local font = CreateFont(name)
    font:SetFont(path, size, "")
    font:SetTextColor(color[1], color[2], color[3])
    font:SetShadowOffset(1, -1)
    font:SetShadowColor(0, 0, 0, 0.85)
    return font
end

Style.fonts = {
    title = makeFont("DropTablesFontTitle", "Fonts\\MORPHEUS.TTF", 22, C.gold),
    heading = makeFont("DropTablesFontHeading", "Fonts\\MORPHEUS.TTF", 18, C.text),
    body = makeFont("DropTablesFontBody", "Fonts\\FRIZQT__.TTF", 11, C.text),
    muted = makeFont("DropTablesFontMuted", "Fonts\\FRIZQT__.TTF", 10, C.muted),
    label = makeFont("DropTablesFontLabel", "Fonts\\FRIZQT__.TTF", 9, C.gold),
}

function Style.Text(parent, font, layer)
    local text = parent:CreateFontString(nil, layer or "OVERLAY")
    text:SetFontObject(Style.fonts[font])
    text:SetWordWrap(false)
    return text
end

function Style.Line(parent, color)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(unpack(color or C.line))
    return line
end

local function setBox(frame, color, border)
    frame:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    frame:SetBackdropColor(unpack(color))
    frame:SetBackdropBorderColor(unpack(border or C.line))
end

local windows = {}

-- A movable, resizable window with a title, a subtitle, a close button and a hairline under the title bar.
-- Content starts at y = -Style.HEADER.
Style.HEADER = 58

function Style.Window(name, width, height, minWidth, minHeight, positionKey, sizeKey, alphaKey)
    local frame = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    frame:Hide()
    frame.alphaKey = alphaKey
    frame:SetSize(width, height)
    frame:SetPoint("CENTER")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:SetResizable(true)
    frame:SetResizeBounds(minWidth, minHeight, 1400, 1100)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetFrameStrata("DIALOG")
    setBox(frame, C.ink)

    frame.band = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
    frame.band:SetTexture(WHITE)
    frame.band:SetPoint("TOPLEFT", 1, -1)
    frame.band:SetPoint("TOPRIGHT", -1, -1)
    frame.band:SetHeight(Style.HEADER - 2)

    frame.title = Style.Text(frame, "title")
    frame.title:SetPoint("TOPLEFT", 16, -10)
    frame.subtitle = Style.Text(frame, "muted")
    frame.subtitle:SetPoint("TOPLEFT", frame.title, "BOTTOMLEFT", 1, -3)

    local rule = Style.Line(frame)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", 1, -Style.HEADER)
    rule:SetPoint("TOPRIGHT", -1, -Style.HEADER)

    local close = CreateFrame("Button", nil, frame)
    close:SetSize(14, 14)
    close:SetPoint("TOPRIGHT", -12, -12)
    close.icon = close:CreateTexture(nil, "ARTWORK")
    close.icon:SetAllPoints()
    close.icon:SetTexture("Interface\\Buttons\\UI-StopButton")
    close.icon:SetVertexColor(unpack(C.muted))
    close:SetScript("OnEnter", function(self)
        self.icon:SetVertexColor(unpack(C.gold))
    end)
    close:SetScript("OnLeave", function(self)
        self.icon:SetVertexColor(unpack(C.muted))
    end)
    close:SetScript("OnClick", function()
        frame:Hide()
    end)

    local function savePlacement()
        frame:StopMovingOrSizing()
        local point, _, relativePoint, x, y = frame:GetPoint(1)
        ns.settings[positionKey] = { point, relativePoint, x, y }
        ns.settings[sizeKey] = { frame:GetWidth(), frame:GetHeight() }
        frame:SetUserPlaced(false)
    end
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", savePlacement)

    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(14, 14)
    grip:SetPoint("BOTTOMRIGHT", -3, 3)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function()
        frame:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", savePlacement)

    -- Puts the window at its saved place and size, or at the default ones when none is saved (first start,
    -- Restore defaults).
    function frame:RestorePlacement()
        local size, pos = ns.settings[sizeKey], ns.settings[positionKey]
        self:SetSize(size and size[1] or width, size and size[2] or height)
        self:ClearAllPoints()
        if pos then
            self:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
        else
            self:SetPoint("CENTER")
        end
    end

    table.insert(windows, frame)
    return frame
end

-- Each window takes the background opacity stored under its own setting key.
local function applyOpacity(frame)
    local alpha = ns.settings[frame.alphaKey]
    frame:SetBackdropColor(C.ink[1], C.ink[2], C.ink[3], alpha)
    frame:SetBackdropBorderColor(C.line[1], C.line[2], C.line[3], C.line[4] * math.max(alpha, 0.4))
    frame.band:SetGradient("VERTICAL", CreateColor(C.ink[1], C.ink[2], C.ink[3], alpha),
        CreateColor(C.raised[1], C.raised[2], C.raised[3], alpha))
end

function Style.ApplyOpacity()
    for _, frame in ipairs(windows) do
        applyOpacity(frame)
    end
end

-- A small slider in the title bar, left of the close button, for the window's background opacity.
function Style.OpacitySlider(frame)
    local slider = CreateFrame("Slider", nil, frame)
    slider:SetOrientation("HORIZONTAL")
    slider:SetSize(80, 12)
    slider:SetPoint("TOPRIGHT", -40, -14)
    slider:SetMinMaxValues(0, 1)
    slider:SetValueStep(0.05)
    slider:SetObeyStepOnDrag(true)
    slider:SetHitRectInsets(0, 0, -4, -4)
    local track = Style.Line(slider, C.faint)
    track:SetHeight(2)
    track:SetPoint("LEFT")
    track:SetPoint("RIGHT")
    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(6, 12)
    thumb:SetColorTexture(unpack(C.gold))
    slider:SetThumbTexture(thumb)
    local label = Style.Text(slider, "label")
    label:SetPoint("RIGHT", slider, "LEFT", -8, 0)
    label:SetText("OPACITY")
    slider.label = label
    slider:SetScript("OnValueChanged", function(_, value, userInput)
        if userInput then
            ns.settings[frame.alphaKey] = value
            applyOpacity(frame)
        end
    end)
    slider:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText(("Background %d%%"):format(ns.settings[frame.alphaKey] * 100 + 0.5))
        GameTooltip:AddLine("Text and icons stay solid.", 1, 1, 1)
        GameTooltip:Show()
    end)
    slider:SetScript("OnLeave", GameTooltip_Hide)
    frame.opacitySlider = slider
    return slider
end

-- The SHARE link of a title bar: opens the window with the export text. The caller places it.
function Style.ShareButton(frame)
    local share = CreateFrame("Button", nil, frame)
    share.label = Style.Text(share, "label")
    share.label:SetPoint("RIGHT")
    share.label:SetText("SHARE")
    share:SetSize(share.label:GetStringWidth() + 4, 16)
    share:SetScript("OnClick", function()
        ns.ToggleExport()
    end)
    share:SetScript("OnEnter", function(self)
        self.label:SetTextColor(unpack(C.text))
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Share my tables")
        GameTooltip:AddLine("Copy your drop counts into the shared database, for every player's tables.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    share:SetScript("OnLeave", function(self)
        self.label:SetTextColor(unpack(C.gold))
        GameTooltip:Hide()
    end)
    return share
end

local function syncSliders()
    for _, frame in ipairs(windows) do
        if frame.opacitySlider then
            frame.opacitySlider:SetValue(ns.settings[frame.alphaKey])
        end
    end
end

-- An edit box in a dark inset with a placeholder; icon is an optional texture shown at the left.
function Style.Input(parent, width, placeholder, icon)
    local box = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    box:SetSize(width, 22)
    setBox(box, { C.raised[1], C.raised[2], C.raised[3], 0.9 }, C.faint)
    local edit = CreateFrame("EditBox", nil, box)
    edit:SetFontObject(Style.fonts.body)
    edit:SetAutoFocus(false)
    edit:SetPoint("TOPLEFT", icon and 22 or 6, 0)
    edit:SetPoint("BOTTOMRIGHT", -6, 0)
    if icon then
        local glyph = box:CreateTexture(nil, "ARTWORK")
        glyph:SetSize(13, 13)
        glyph:SetPoint("LEFT", 6, 0)
        glyph:SetTexture(icon)
        glyph:SetVertexColor(unpack(C.muted))
    end
    local hint = Style.Text(edit, "muted")
    hint:SetPoint("LEFT", 1, 0)
    hint:SetText(placeholder or "")
    edit:HookScript("OnTextChanged", function(self)
        hint:SetShown(self:GetText() == "")
    end)
    edit:SetScript("OnEditFocusGained", function()
        box:SetBackdropBorderColor(unpack(C.line))
    end)
    edit:SetScript("OnEditFocusLost", function()
        box:SetBackdropBorderColor(unpack(C.faint))
    end)
    edit:SetScript("OnEscapePressed", edit.ClearFocus)
    edit:SetScript("OnEnterPressed", edit.ClearFocus)
    edit.box = box
    return edit
end

-- A vertical scroll list whose content follows the scroll frame's width; the caller anchors the scroll frame.
function Style.ScrollList(parent)
    local scroll = CreateFrame("ScrollFrame", nil, parent, "ScrollFrameTemplate")
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(100, 1)
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function(_, width)
        content:SetWidth(width)
    end)
    return scroll, content
end

-- The index-th row of a list, as wide as the list.
function Style.ListRow(content, index, height)
    local row = Style.Row(content, height)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * height)
    row:SetPoint("RIGHT", content, "RIGHT")
    return row
end

-- A list row: zebra stripe, hover tint, and a selected state with a gold bar on the left edge.
function Style.Row(parent, height)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(height)
    row.stripe = row:CreateTexture(nil, "BACKGROUND")
    row.stripe:SetAllPoints()
    row.stripe:SetColorTexture(1, 1, 1, 0.025)
    row.hover = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    row.hover:SetAllPoints()
    row.hover:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.09)
    row.hover:Hide()
    row.selected = row:CreateTexture(nil, "BACKGROUND", nil, 2)
    row.selected:SetAllPoints()
    row.selected:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.14)
    row.selected:Hide()
    row.accent = row:CreateTexture(nil, "ARTWORK")
    row.accent:SetPoint("TOPLEFT")
    row.accent:SetPoint("BOTTOMLEFT")
    row.accent:SetWidth(2)
    row.accent:SetColorTexture(unpack(C.gold))
    row.accent:Hide()
    row:HookScript("OnEnter", function(self)
        self.hover:Show()
    end)
    row:HookScript("OnLeave", function(self)
        self.hover:Hide()
    end)
    return row
end

function Style.SetRowState(row, index, selected)
    row.stripe:SetShown(index % 2 == 0)
    row.selected:SetShown(selected == true)
    row.accent:SetShown(selected == true)
end

-- A bar behind a cell that fills with the drop chance.
function Style.ChanceBar(row, cell)
    local bar = row:CreateTexture(nil, "BORDER")
    bar:SetColorTexture(unpack(C.bar))
    bar:SetPoint("TOPRIGHT", cell, "TOPRIGHT", 2, 2)
    bar:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", 2, -2)
    function bar:SetChance(chance, cellWidth)
        self:SetWidth(math.max(1, math.min(1, chance) * (cellWidth + 4)))
    end
    return bar
end

-- An icon with a thin border in its quality colour.
function Style.ItemIcon(parent, size)
    local holder = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    holder:SetSize(size + 2, size + 2)
    setBox(holder, { 0, 0, 0, 0.6 }, C.faint)
    holder.icon = holder:CreateTexture(nil, "ARTWORK")
    holder.icon:SetPoint("TOPLEFT", 1, -1)
    holder.icon:SetPoint("BOTTOMRIGHT", -1, 1)
    holder.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    function holder:SetItem(texture, quality)
        self.icon:SetTexture(texture)
        local r, g, b = ns.QualityRGB(quality)
        if r and quality >= 2 then
            self:SetBackdropBorderColor(r, g, b, 0.9)
        else
            self:SetBackdropBorderColor(unpack(C.faint))
        end
    end
    return holder
end

-- A column header: small gold capitals, brighter with an arrow when it is the sort column.
function Style.Header(parent, label, justify)
    local header = CreateFrame("Button", nil, parent)
    header:SetHeight(16)
    header.text = Style.Text(header, "label")
    header.text:SetAllPoints()
    header.text:SetJustifyH(justify or "LEFT")
    header.text:SetText(label:upper())
    header.arrow = header:CreateTexture(nil, "ARTWORK")
    header.arrow:SetSize(9, 9)
    header.arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
    header.arrow:Hide()
    function header:SetSorted(active, descending)
        self.text:SetAlpha(active and 1 or 0.65)
        self.arrow:SetShown(active)
        self.arrow:SetTexture(descending and "Interface\\Buttons\\Arrow-Down-Up" or "Interface\\Buttons\\Arrow-Up-Up")
        self.arrow:ClearAllPoints()
        local justify = self.text:GetJustifyH()
        if justify == "RIGHT" then
            self.arrow:SetPoint("RIGHT", self.text, "RIGHT", -self.text:GetStringWidth() - 2, 1)
        elseif justify == "CENTER" then
            self.arrow:SetPoint("LEFT", self.text, "CENTER", self.text:GetStringWidth() / 2 + 2, 1)
        else
            self.arrow:SetPoint("LEFT", self.text, "LEFT", self.text:GetStringWidth() + 2, 1)
        end
    end
    return header
end

-- Text tabs with a gold underline on the chosen one, for switching views.
function Style.Tab(parent, label)
    local tab = CreateFrame("Button", nil, parent)
    tab:SetHeight(20)
    tab.text = Style.Text(tab, "body")
    tab.text:SetPoint("CENTER")
    tab.text:SetText(label)
    tab:SetWidth(tab.text:GetStringWidth() + 16)
    tab.underline = Style.Line(tab, C.gold)
    tab.underline:SetHeight(2)
    tab.underline:SetPoint("BOTTOMLEFT", 6, 0)
    tab.underline:SetPoint("BOTTOMRIGHT", -6, 0)
    function tab:SetChosen(chosen)
        self.underline:SetShown(chosen)
        self.text:SetTextColor(unpack(chosen and C.gold or C.muted))
    end
    return tab
end

local function applyAll()
    Style.ApplyOpacity()
    syncSliders()
end

-- After Restore defaults the saved places are gone; open windows move back at once.
ns.On("DT_SETTINGS_CHANGED", function()
    for _, frame in ipairs(windows) do
        frame:RestorePlacement()
    end
end)

ns.On("DT_READY", applyAll)
ns.On("DT_SETTINGS_CHANGED", applyAll)
