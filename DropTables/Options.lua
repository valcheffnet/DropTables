local _, ns = ...

local category, layout
local registered = {}

local function onChange()
    ns.Fire("DT_SETTINGS_CHANGED")
end

local function register(key, name, varType)
    local variable = "DropTables_" .. key
    local setting = Settings.RegisterAddOnSetting(category, variable, key, ns.settings, varType, name, ns.DEFAULTS[key])
    Settings.SetOnValueChangedCallback(variable, onChange)
    registered[key] = setting
    return setting
end

local function checkbox(key, name, tooltip)
    Settings.CreateCheckbox(category, register(key, name, Settings.VarType.Boolean), tooltip)
end

local function slider(key, name, tooltip, min, max, step, format)
    local options = Settings.CreateSliderOptions(min, max, step)
    options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, format)
    Settings.CreateSlider(category, register(key, name, Settings.VarType.Number), options, tooltip)
end

local function whole(value)
    return tostring(math.floor(value + 0.5))
end

local function percent(value)
    return ("%d%%"):format(value * 100 + 0.5)
end

local QUALITY_NAMES = { [0] = "Poor", "Common", "Uncommon", "Rare", "Epic" }

-- Shows the quality in its own colour, using the client's localized name when it has one.
local function qualityName(value)
    local quality = math.floor(value + 0.5)
    local name = _G["ITEM_QUALITY" .. quality .. "_DESC"] or QUALITY_NAMES[quality]
    return ns.QualityColor(quality) .. name .. "|r"
end

StaticPopupDialogs.DROPTABLES_RESTORE_DEFAULTS = {
    text = "Put all Drop Tables settings and window places back to their defaults? Your recorded drops stay.",
    button1 = YES,
    button2 = NO,
    OnAccept = function()
        ns.RestoreDefaults()
        -- The controls in the open panel show the new values only through their settings.
        for key, setting in pairs(registered) do
            setting:SetValue(ns.DEFAULTS[key])
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

ns.On("DT_READY", function()
    category, layout = Settings.RegisterVerticalLayoutCategory("Drop Tables")
    checkbox("showStrip", "Icons under the target", "Show the most likely drops of your target under its frame.")
    slider("stripIcons", "Number of icons", "How many icons the strip shows at most, money included.", 3, 10, 1, whole)
    slider("stripScale", "Icon size", "Scale of the icon strip.", 0.6, 2, 0.1, percent)
    checkbox("showTooltip", "Drops in the mob tooltip", "Add the most likely drops to the tooltip of a mob.")
    slider("tooltipLines", "Tooltip lines", "How many lines the tooltip lists, money included.", 1, 15, 1, whole)
    slider("minQuality", "Minimum item quality",
        "Items below this quality stay out of the icons and the tooltip. The /dt table still lists everything.",
        0, 4, 1, qualityName)
    checkbox("collapseWorldDrops", "World drops only in the table",
        "Keep random gear and recipe drops out of the icons and the tooltip; the /dt table lists them in their own section.")
    checkbox("showMinimap", "Minimap button", "Show the Drop Tables button on the minimap edge.")
    checkbox("exportReminder", "Remind me to share my tables",
        "Once a session, when 25 or more mobs have new counts, a chat line points to /dt export.")
    slider("detailsAlpha", "Table window background", "Opacity of the /dt window's background; text and icons stay solid.",
        0, 1, 0.05, percent)
    slider("finderAlpha", "Loot Finder background",
        "Opacity of the Loot Finder's background; also on the slider in its title bar.", 0, 1, 0.05, percent)
    checkbox("debug", "Debug messages",
        "A chat line for every sharing message in and out, for testing with other players. Same as /dt debug.")
    if CreateSettingsButtonInitializer and layout then
        layout:AddInitializer(CreateSettingsButtonInitializer("Default settings", "Restore defaults", function()
            StaticPopup_Show("DROPTABLES_RESTORE_DEFAULTS")
        end, "Put every setting and window place back to how it was on first install.", true))
    end
    Settings.RegisterAddOnCategory(category)
end)

function ns.OpenOptions()
    Settings.OpenToCategory(category:GetID())
end
