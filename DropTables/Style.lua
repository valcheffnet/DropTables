local _, ns = ...

-- The look all Drop Tables windows share, a dark ledger with hairlines in an accent colour, Morpheus headings and
-- Friz Quadrata text. Window backgrounds follow the opacity setting, while text and icons stay solid.
local Style = {}
ns.Style = Style

local WHITE = "Interface\\Buttons\\WHITE8x8"
local MAX_WIDTH, MAX_HEIGHT = 1400, 1100  -- the largest a window can be dragged to

-- Colour themes. Each one sets the background (ink), raised panels, the accent with its hairlines (line, faint), text,
-- muted text and the chance bars. The accent is still called "gold" whatever colour it is, and lineRgb, when given,
-- tints the hairlines differently from the accent.
local function theme(key, name, ink, raised, accent, text, muted, bar, lineRgb)
    local hair = lineRgb or accent
    return {
        key = key, name = name, ink = ink, raised = raised, gold = accent, text = text, muted = muted, bar = bar,
        line = { hair[1], hair[2], hair[3], 0.45 }, faint = { hair[1], hair[2], hair[3], 0.18 },
    }
end
Style.THEMES = {
    theme("ledger", "Ledger", { 0.055, 0.047, 0.04 }, { 0.105, 0.09, 0.075 }, { 0.91, 0.77, 0.42 },
        { 0.94, 0.9, 0.82 }, { 0.62, 0.57, 0.48 }, { 0.78, 0.5, 0.16, 0.3 }, { 0.79, 0.64, 0.29 }),
    theme("frost", "Frost", { 0.035, 0.05, 0.065 }, { 0.07, 0.1, 0.13 }, { 0.6, 0.83, 0.98 },
        { 0.88, 0.93, 0.97 }, { 0.52, 0.6, 0.68 }, { 0.3, 0.6, 0.85, 0.32 }),
    theme("fel", "Fel", { 0.03, 0.05, 0.03 }, { 0.065, 0.1, 0.06 }, { 0.6, 0.95, 0.35 },
        { 0.88, 0.95, 0.84 }, { 0.5, 0.61, 0.46 }, { 0.38, 0.78, 0.2, 0.3 }),
    theme("blood", "Blood", { 0.06, 0.028, 0.028 }, { 0.11, 0.05, 0.05 }, { 0.95, 0.43, 0.37 },
        { 0.96, 0.88, 0.86 }, { 0.66, 0.5, 0.48 }, { 0.8, 0.2, 0.15, 0.32 }),
    theme("arcane", "Arcane", { 0.048, 0.038, 0.075 }, { 0.09, 0.07, 0.14 }, { 0.78, 0.62, 1 },
        { 0.92, 0.89, 0.98 }, { 0.6, 0.55, 0.7 }, { 0.55, 0.35, 0.9, 0.32 }),
    theme("stone", "Stone", { 0.05, 0.05, 0.05 }, { 0.1, 0.1, 0.1 }, { 0.86, 0.86, 0.86 },
        { 0.95, 0.95, 0.95 }, { 0.6, 0.6, 0.6 }, { 0.6, 0.6, 0.6, 0.25 }),
}
local themeByKey = {}
for _, entry in ipairs(Style.THEMES) do
    themeByKey[entry.key] = entry
end
local COLOR_KEYS = { "ink", "raised", "line", "faint", "gold", "text", "muted", "bar" }

-- The colours in use. Everything holds on to these very tables, so a theme change rewrites them in place.
local C = {}
for _, key in ipairs(COLOR_KEYS) do
    local source = Style.THEMES[1][key]
    C[key] = { source[1], source[2], source[3], source[4] }
end
Style.colors = C

-- Colouring that has to be redone when the theme changes. Each painter runs once right away and again on every
-- change. Text and textures the windows colour while drawing their lists pick up the new colours when they redraw.
local painters = {}
function Style.Paint(painter)
    table.insert(painters, painter)
    painter()
end

-- A colour that follows the theme but has its own alpha, for backdrops that use a C colour at another opacity.
function Style.Tint(key, alpha)
    return function()
        local color = C[key]
        return color[1], color[2], color[3], alpha
    end
end

local function rgba(color)
    if type(color) == "function" then
        return color()
    end
    return unpack(color)
end

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
    Style.Paint(function()
        line:SetColorTexture(rgba(color or C.line))
    end)
    return line
end

-- color and border are C colours, plain tables or Style.Tint functions.
local function setBox(frame, color, border)
    frame:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    Style.Paint(function()
        frame:SetBackdropColor(rgba(color))
        frame:SetBackdropBorderColor(rgba(border or C.line))
    end)
end

local windows = {}
local active -- the window in front: the last one shown or clicked
local applyOpacity

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
    frame:SetResizeBounds(minWidth, minHeight, MAX_WIDTH, MAX_HEIGHT)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetFrameStrata("DIALOG")
    -- A click anywhere on the window, its rows and buttons included, brings all of it in front of the others.
    frame:SetToplevel(true)
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
    Style.Paint(function()
        close.icon:SetVertexColor(unpack(C.muted))
    end)
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
    -- The corner follows the mouse by hand rather than through StartSizing, which made the windows jump to their
    -- largest size. The top left corner stays put, and the window never grows past the edge of the screen, so the
    -- corner can always be reached again.
    grip:SetScript("OnMouseDown", function(self)
        local left, top = frame:GetLeft(), frame:GetTop()
        if not left or not top then
            return
        end
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        local scale = frame:GetEffectiveScale()
        local startX, startY = GetCursorPosition()
        local startWidth, startHeight = frame:GetWidth(), frame:GetHeight()
        local maxWidth = math.min(MAX_WIDTH, UIParent:GetRight() - left)
        local maxHeight = math.min(MAX_HEIGHT, top - UIParent:GetBottom())
        self:SetScript("OnUpdate", function()
            local x, y = GetCursorPosition()
            local newWidth = startWidth + (x - startX) / scale
            local newHeight = startHeight + (startY - y) / scale
            frame:SetSize(math.max(minWidth, math.min(newWidth, maxWidth)),
                math.max(minHeight, math.min(newHeight, maxHeight)))
        end)
    end)
    grip:SetScript("OnMouseUp", function(self)
        self:SetScript("OnUpdate", nil)
        savePlacement()
    end)

    -- Puts the window at its saved place and size, or at the defaults when nothing is saved yet, as on the first
    -- start or after Restore defaults. A saved size larger than the screen shrinks to fit it.
    function frame:RestorePlacement()
        local size, pos = ns.settings[sizeKey], ns.settings[positionKey]
        self:SetSize(math.min(size and size[1] or width, UIParent:GetWidth()),
            math.min(size and size[2] or height, UIParent:GetHeight()))
        self:ClearAllPoints()
        if pos then
            self:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
        else
            self:SetPoint("CENTER")
        end
    end

    frame:HookScript("OnShow", function(self)
        self:Raise()
        Style.SetActive(self)
    end)

    table.insert(windows, frame)
    return frame
end

-- The window in front gets a bright frame and title, and the ones behind it a faint frame and a dimmed title.
function Style.SetActive(frame)
    if not ns.settings then
        return
    end
    active = frame
    for _, window in ipairs(windows) do
        applyOpacity(window)
    end
end

-- Toplevel windows rise when clicked, but nothing tells the addon about it, so we take the highest shown window as
-- the one in front.
C_Timer.NewTicker(0.25, function()
    local top
    for _, window in ipairs(windows) do
        if window:IsShown() and (not top or window:GetFrameLevel() > top:GetFrameLevel()) then
            top = window
        end
    end
    if top and top ~= active then
        Style.SetActive(top)
    end
end)

-- Each window takes the background opacity stored under its own setting key.
function applyOpacity(frame)
    local alpha = ns.settings[frame.alphaKey]
    local front = frame == active
    frame:SetBackdropColor(C.ink[1], C.ink[2], C.ink[3], alpha)
    if front then
        frame:SetBackdropBorderColor(C.gold[1], C.gold[2], C.gold[3], 0.85)
    else
        frame:SetBackdropBorderColor(C.line[1], C.line[2], C.line[3], C.line[4] * math.max(alpha, 0.4))
    end
    frame.title:SetAlpha(front and 1 or 0.6)
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
    Style.Paint(function()
        thumb:SetColorTexture(unpack(C.gold))
    end)
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

-- A card that asks the player to share. It has a square seal with the number of the player's mobs the shared database
-- lacks, and two lines of text, and the seal glows slowly while there's something to share. The whole card is the
-- button. Callers place it, and Refresh() updates the number.
Style.SHARE_CARD = 46
local SEAL = 34
local SEAL_ICON = "Interface\\Icons\\Achievement_Reputation_01"

function Style.ShareCard(parent)
    local card = CreateFrame("Button", nil, parent, "BackdropTemplate")
    card:SetHeight(Style.SHARE_CARD)
    setBox(card, Style.Tint("raised", 0.92), C.line)

    local seal = CreateFrame("Frame", nil, card, "BackdropTemplate")
    seal:SetSize(SEAL + 4, SEAL + 4)
    seal:SetPoint("LEFT", 5, 0)
    setBox(seal, { 0, 0, 0, 0.7 }, C.gold)
    seal.icon = seal:CreateTexture(nil, "ARTWORK")
    seal.icon:SetPoint("TOPLEFT", 2, -2)
    seal.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    seal.icon:SetTexture(SEAL_ICON)
    seal.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    seal.glow = seal:CreateTexture(nil, "OVERLAY")
    seal.glow:SetAllPoints(seal.icon)
    Style.Paint(function()
        seal.glow:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 1)
    end)
    seal.glow:SetBlendMode("ADD")
    seal.glow:SetAlpha(0)
    local pulse = seal.glow:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(0)
    fade:SetToAlpha(0.28)
    fade:SetDuration(1.4)
    fade:SetSmoothing("IN_OUT")

    local badge = CreateFrame("Frame", nil, seal, "BackdropTemplate")
    badge:SetHeight(14)
    badge:SetPoint("BOTTOMRIGHT", 6, -3)
    badge:SetFrameLevel(seal:GetFrameLevel() + 2)
    setBox(badge, Style.Tint("ink", 0.95), C.gold)
    badge.text = Style.Text(badge, "label")
    badge.text:SetPoint("CENTER", 0, 0)

    local heading = Style.Text(card, "body")
    heading:SetPoint("TOPLEFT", seal, "TOPRIGHT", 10, -3)
    heading:SetPoint("RIGHT", -8, 0)
    heading:SetJustifyH("LEFT")
    Style.Paint(function()
        heading:SetTextColor(unpack(C.gold))
    end)
    local line = Style.Text(card, "muted")
    line:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -4)
    line:SetPoint("RIGHT", -8, 0)
    line:SetJustifyH("LEFT")

    function card:Refresh()
        local count = ns.NewCount()
        if count > 0 then
            heading:SetText("Share your tables")
            line:SetText(("%d %s the community lacks"):format(count, count == 1 and "mob" or "mobs"))
            badge.text:SetText(count > 99 and "99+" or tostring(count))
            badge:SetWidth(badge.text:GetStringWidth() + 8)
            badge:Show()
            seal.icon:SetDesaturated(false)
            if not pulse:IsPlaying() then
                pulse:Play()
            end
        else
            heading:SetText("Your tables are shared")
            line:SetText("Thank you! New kills will show here.")
            badge:Hide()
            seal.icon:SetDesaturated(true)
            pulse:Stop()
            seal.glow:SetAlpha(0)
        end
    end

    card:SetScript("OnClick", function()
        ns.ToggleExport()
    end)
    ns.On("DT_SHARE_COPIED", function()
        if card:IsVisible() then
            card:Refresh()
        end
    end)
    card:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(unpack(C.gold))
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Share with the community")
        GameTooltip:AddLine("Every table players send goes into the shared database that comes with Drop Tables, "
            .. "so everyone's chances get better, yours too.", 1, 1, 1, true)
        GameTooltip:AddLine("Click, copy the text and paste it on the share page. No account needed.", 0.62, 0.57,
            0.48, true)
        GameTooltip:Show()
    end)
    card:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(unpack(C.line))
        GameTooltip:Hide()
    end)
    return card
end

local function syncSliders()
    for _, frame in ipairs(windows) do
        if frame.opacitySlider then
            frame.opacitySlider:SetValue(ns.settings[frame.alphaKey])
        end
    end
end

-- An edit box in a dark inset with a placeholder, and icon is an optional texture shown on the left.
function Style.Input(parent, width, placeholder, icon)
    local box = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    box:SetSize(width, 22)
    setBox(box, Style.Tint("raised", 0.9), C.faint)
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
        Style.Paint(function()
            glyph:SetVertexColor(unpack(C.muted))
        end)
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

-- A vertical scroll list whose content follows the scroll frame's width. The caller anchors the scroll frame.
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

-- A list row with a zebra stripe, a hover tint and a selected state that shows a bar on the left edge.
function Style.Row(parent, height)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(height)
    row.stripe = row:CreateTexture(nil, "BACKGROUND")
    row.stripe:SetAllPoints()
    row.stripe:SetColorTexture(1, 1, 1, 0.025)
    row.hover = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    row.hover:SetAllPoints()
    row.hover:Hide()
    row.selected = row:CreateTexture(nil, "BACKGROUND", nil, 2)
    row.selected:SetAllPoints()
    row.selected:Hide()
    row.accent = row:CreateTexture(nil, "ARTWORK")
    row.accent:SetPoint("TOPLEFT")
    row.accent:SetPoint("BOTTOMLEFT")
    row.accent:SetWidth(2)
    row.accent:Hide()
    Style.Paint(function()
        row.hover:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.09)
        row.selected:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.14)
        row.accent:SetColorTexture(unpack(C.gold))
    end)
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
    Style.Paint(function()
        bar:SetColorTexture(unpack(C.bar))
    end)
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

-- A column header in small capitals, brighter and with an arrow when it's the sort column.
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

-- Text tabs for switching views, with an underline on the chosen one.
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

local FONT_COLORS = { title = "gold", heading = "text", body = "text", muted = "muted", label = "gold" }
local currentTheme = Style.THEMES[1]

-- Puts a theme on every window at once by rewriting the shared colours and the fonts and running the painters. The
-- window backgrounds follow in ApplyOpacity, and the windows redraw their lists on the settings change that comes
-- with it.
function Style.SetTheme(key)
    local chosen = themeByKey[key] or Style.THEMES[1]
    if chosen == currentTheme then
        return
    end
    currentTheme = chosen
    for _, colorKey in ipairs(COLOR_KEYS) do
        local source, color = chosen[colorKey], C[colorKey]
        color[1], color[2], color[3], color[4] = source[1], source[2], source[3], source[4]
    end
    for fontKey, colorKey in pairs(FONT_COLORS) do
        local color = C[colorKey]
        Style.fonts[fontKey]:SetTextColor(color[1], color[2], color[3])
    end
    for _, painter in ipairs(painters) do
        painter()
    end
end

function Style.CurrentTheme()
    return currentTheme.key
end

local function applyAll()
    Style.SetTheme(ns.settings.theme)
    Style.ApplyOpacity()
    syncSliders()
end

-- After Restore defaults the saved places are gone, so open windows move back right away.
ns.On("DT_SETTINGS_CHANGED", function()
    for _, frame in ipairs(windows) do
        frame:RestorePlacement()
    end
end)

ns.On("DT_READY", applyAll)
ns.On("DT_SETTINGS_CHANGED", applyAll)
