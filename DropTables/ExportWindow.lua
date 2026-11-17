local _, ns = ...

-- Shows the export string to copy and the link of the form to paste it into.
local Style = ns.Style
local C = Style.colors
local TOP = Style.HEADER
local FORM_URL = "https://github.com/valcheffnet/DropTables/issues/new?template=share-tables.yml"

local frame = Style.Window("DropTablesExport", 520, 440, 420, 360, "exportPos", "exportSize", "detailsAlpha")
frame.title:SetText("Share my tables")
table.insert(UISpecialFrames, "DropTablesExport")

local result, part, copied

-- The form link carries a title, so the issue says what is in it without the player typing one.
local function formUrl()
    if not result or #result.strings == 0 then
        return FORM_URL
    end
    local title = ("Drop tables: %d mobs, %d kills"):format(result.mobs, result.kills)
    if #result.strings > 1 then
        title = title .. (", part %d of %d"):format(part, #result.strings)
    end
    local encoded = title:gsub("[^%w%-%.]", function(char)
        return ("%%%02X"):format(char:byte())
    end)
    return FORM_URL .. "&title=" .. encoded
end

local intro = Style.Text(frame, "body")
intro:SetPoint("TOPLEFT", 16, -(TOP + 12))
intro:SetPoint("RIGHT", -16, 0)
intro:SetJustifyH("LEFT")
intro:SetText("Drop Tables gets better with every table players share. Press Select and then Ctrl+C, open the link "
    .. "under the text in your browser and paste the text into the form. Your kills then help other players' tables, "
    .. "the way theirs help yours.")

local everything = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
everything:SetSize(20, 20)
everything:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", -4, -8)
everything.label = Style.Text(everything, "muted")
everything.label:SetPoint("LEFT", everything, "RIGHT", 1, 0)
everything.label:SetText("Everything, not only what is new since the last time")
everything:SetHitRectInsets(0, -everything.label:GetStringWidth() - 4, 0, 0)

local box = CreateFrame("Frame", nil, frame, "BackdropTemplate")
box:SetPoint("TOPLEFT", everything, "BOTTOMLEFT", 4, -8)
box:SetPoint("RIGHT", -16, 0)
box:SetPoint("BOTTOM", 0, 118)
box:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
box:SetBackdropColor(C.raised[1], C.raised[2], C.raised[3], 0.9)
box:SetBackdropBorderColor(unpack(C.faint))

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

local linkLabel = Style.Text(frame, "label")
linkLabel:SetPoint("TOPLEFT", status, "BOTTOMLEFT", 0, -12)
linkLabel:SetText("FORM")
local link = Style.Input(frame, 300, "")
link.box:SetPoint("TOPLEFT", linkLabel, "BOTTOMLEFT", 0, -4)
link.box:SetPoint("RIGHT", -16, 0)
link:SetText(FORM_URL)

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

-- Both boxes are for copying only: typing puts the text back and selects it again.
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
readOnly(link, formUrl)
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
    link:SetText(formUrl())
    nextPart:SetShown(count > 1)
    nextPart:SetEnabled(part < count)
    if count > 1 then
        status:SetText(("Part %d of %d. Press Select, then Ctrl+C, and paste each part into its own form."):format(part, count))
    else
        status:SetText("Press Select, then Ctrl+C, and paste it into the form.")
    end
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
    result = ns.BuildExport(everything:GetChecked())
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
        link:SetText(formUrl())
        nextPart:Hide()
        status:SetText("Nothing new since your last export. Tick Everything to export all of it again.")
        status:SetTextColor(unpack(C.muted))
        return
    end
    showPart()
end

text:SetScript("OnKeyUp", function(self, key)
    if key ~= "C" or not IsControlKeyDown() or not result or not result.strings[part] then
        return
    end
    copied[part] = true
    local count = #result.strings
    for i = 1, count do
        if not copied[i] then
            status:SetText(("Part %d copied. Paste it into the form, then copy part %d."):format(part, i))
            status:SetTextColor(unpack(C.gold))
            return
        end
    end
    ns.MarkExported(result)
    status:SetText("Copied. Paste it into the form at the link below. Thank you!")
    status:SetTextColor(unpack(C.gold))
end)

nextPart:SetScript("OnClick", function()
    part = part + 1
    showPart()
end)

everything:SetScript("OnClick", build)
frame:SetScript("OnShow", build)

function ns.ToggleExport()
    if frame:IsShown() then
        frame:Hide()
    else
        frame:RestorePlacement()
        frame:Show()
    end
end
