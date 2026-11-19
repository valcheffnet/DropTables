local _, ns = ...

-- Shows the address of the share page and, under it, the export string to paste there. The page comes first because
-- the player has to open it before the text has anywhere to go.
local Style = ns.Style
local C = Style.colors
local TOP = Style.HEADER
local PAGE_URL = "https://droptables-relay.valcheffnet.workers.dev"

local frame = Style.Window("DropTablesExport", 520, 440, 420, 360, "exportPos", "exportSize", "detailsAlpha")
frame.title:SetText("Share my tables")
table.insert(UISpecialFrames, "DropTablesExport")

local result, part, copied

local intro = Style.Text(frame, "body")
intro:SetPoint("TOPLEFT", 16, -(TOP + 12))
intro:SetPoint("RIGHT", -16, 0)
intro:SetJustifyH("LEFT")
intro:SetWordWrap(true)
intro:SetText("Drop Tables gets better with every table players share, and you don't need an account for it. Open "
    .. "the share page below in your browser, then copy the text under it, paste it there and press Send. Your kills "
    .. "then help other players' tables, the way theirs help yours.")

local linkLabel = Style.Text(frame, "label")
linkLabel:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -14)
linkLabel:SetText("SHARE PAGE")
local link = Style.Input(frame, 300, "")
link.box:SetPoint("TOPLEFT", linkLabel, "BOTTOMLEFT", 0, -6)
link.box:SetPoint("RIGHT", -16, 0)
link:SetText(PAGE_URL)

local textLabel = Style.Text(frame, "label")
textLabel:SetPoint("TOPLEFT", link.box, "BOTTOMLEFT", 0, -16)
textLabel:SetText("TEXT TO SEND")

local box = CreateFrame("Frame", nil, frame, "BackdropTemplate")
box:SetPoint("TOPLEFT", textLabel, "BOTTOMLEFT", 0, -6)
box:SetPoint("RIGHT", -16, 0)
box:SetPoint("BOTTOM", 0, 78)
box:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
Style.Paint(function()
    box:SetBackdropColor(C.raised[1], C.raised[2], C.raised[3], 0.9)
    box:SetBackdropBorderColor(unpack(C.faint))
end)

local scroll = CreateFrame("ScrollFrame", nil, box, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 6, -6)
scroll:SetPoint("BOTTOMRIGHT", -26, 6)

local text = CreateFrame("EditBox", nil, scroll)
text:SetMultiLine(true)
text:SetMaxLetters(0)
text:SetAutoFocus(false)
text:SetFontObject(Style.fonts.muted)
text:SetWidth(400)
scroll:SetScrollChild(text)
scroll:SetScript("OnSizeChanged", function(self, width)
    text:SetWidth(width)
end)

local status = Style.Text(frame, "body")
status:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -8)
status:SetPoint("RIGHT", -16, 0)
status:SetJustifyH("LEFT")
status:SetWordWrap(true)

local nextPart = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
nextPart:SetSize(110, 22)
nextPart:SetPoint("BOTTOMRIGHT", -16, 12)
nextPart:SetText("Next part")

-- Addons cannot write to the clipboard, so these buttons only select the whole box for Ctrl+C.
local function copyButton(anchor, edit, hint)
    local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    button:SetSize(64, 22)
    button:SetPoint("BOTTOMRIGHT", anchor, "TOPRIGHT", 0, 4)
    button:SetText("Select")
    button:SetScript("OnClick", function()
        edit:SetFocus()
        edit:HighlightText()
        status:SetText(hint)
        status:SetTextColor(unpack(C.gold))
    end)
    return button
end

-- Both boxes are only for copying, so typing puts the text back and selects it again.
local function readOnly(edit, value)
    edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            self:SetText(value())
            self:HighlightText()
        end
    end)
    edit:HookScript("OnEditFocusGained", function(self)
        self:HighlightText()
    end)
    -- The click that focuses the box also places the cursor and drops the selection.
    edit:HookScript("OnMouseUp", function(self)
        self:HighlightText()
    end)
    edit:SetScript("OnEscapePressed", function()
        frame:Hide()
    end)
end
readOnly(link, function()
    return PAGE_URL
end)
readOnly(text, function()
    return result and result.strings[part] or ""
end)
local copyText = copyButton(box, text, "Selected. Press Ctrl+C now.")
copyButton(link.box, link, "Link selected. Press Ctrl+C, then paste it into your browser.")

local function showPart()
    local count = #result.strings
    text:SetText(result.strings[part])
    text:SetCursorPosition(0)
    text:SetFocus()
    text:HighlightText()
    copyText:Show()
    nextPart:SetShown(count > 1)
    nextPart:SetEnabled(part < count)
    if count > 1 then
        status:SetText(("Part %d of %d. Press Select above the text, then Ctrl+C, and send this part on the page by "
            .. "itself."):format(part, count))
    else
        status:SetText("Press Select above the text, then Ctrl+C, and paste it on the page.")
    end
    status:SetTextColor(unpack(C.text))
end

-- On opening, the address is the first thing to copy, so it starts selected.
local function showLink()
    link:SetFocus()
    link:HighlightText()
    local count = #result.strings
    status:SetText("The page address is selected. Press Ctrl+C, open it in your browser, and come back for the text."
        .. (count > 1 and (" It comes in %d parts."):format(count) or ""))
    status:SetTextColor(unpack(C.text))
end

local function build()
    if not ns.CanExport() then
        frame.subtitle:SetText("")
        text:SetText("")
        copyText:Hide()
        nextPart:Hide()
        status:SetText("This game client cannot pack the export string.")
        status:SetTextColor(unpack(C.muted))
        return
    end
    result = ns.BuildExport()
    part, copied = 1, {}
    local summary = ("%d of your mobs, %d kills"):format(result.mobs, result.kills)
    if result.sources > 0 then
        summary = summary .. (", counts of %d other %s"):format(result.sources,
            result.sources == 1 and "player" or "players")
    end
    frame.subtitle:SetText(summary)
    if #result.strings == 0 then
        text:SetText("")
        copyText:Hide()
        nextPart:Hide()
        status:SetText("Nothing to share: the shared database that came with the addon already has all your counts.")
        status:SetTextColor(unpack(C.muted))
        return
    end
    showPart()
    showLink()
end

text:SetScript("OnKeyDown", function(self, key)
    local copyKey = IsControlKeyDown() or (IsMetaKeyDown and IsMetaKeyDown())
    if key ~= "C" or not copyKey or not result or not result.strings[part] then
        return
    end
    copied[part] = true
    local count = #result.strings
    for i = 1, count do
        if not copied[i] then
            status:SetText(("Part %d copied. Send it on the page, then copy part %d."):format(part, i))
            status:SetTextColor(unpack(C.gold))
            return
        end
    end
    ns.MarkCopied(result)
    status:SetText("Copied. Paste it on the page and press Send. Thank you!")
    status:SetTextColor(unpack(C.gold))
end)

nextPart:SetScript("OnClick", function()
    part = part + 1
    showPart()
end)

frame:HookScript("OnShow", build)

function ns.ToggleExport()
    if frame:IsShown() then
        frame:Hide()
    else
        frame:RestorePlacement()
        frame:Show()
    end
end
