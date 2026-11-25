local _, ns = ...

-- A test helper kept out of the Drop Tables download. /dtdebug turns it on, and Drop Tables then hands it a line for
-- every sharing message in and out and for every loot window, which helps when testing with another player. The lines
-- go only to a chat tab called "DT Debug" that /dtdebug opens and closes again, or to the main window when there's no
-- free tab. The last lines are kept over a /reload and put back in the tab, and a new login starts with none.
local TAB = "DT Debug"
local KEEP = 500

local db  -- DropTablesDebugDB: on, and log, the kept lines
local shareState  -- Drop Tables' sharing state, for the first line after turning on

local function print(msg)
    _G.print("|cff66ccffForever Drop Tables Debug|r " .. msg)
end

-- A docked tab that isn't the selected one is hidden, and the client then calls it not shown, so a tab counts while it
-- is shown or docked. A tab closed by hand is neither.
local function findFrame()
    for i = 1, NUM_CHAT_WINDOWS or 0 do
        local name, _, _, _, _, _, shown, _, docked = GetChatWindowInfo(i)
        if name and name:lower() == TAB:lower() and (shown ~= false or docked) and _G["ChatFrame" .. i] then
            return _G["ChatFrame" .. i]
        end
    end
end

-- Opens the DT Debug tab with no other messages in it. If the client lacks Blizzard's chat functions, the lines just
-- stay in the main window.
local function openTab()
    if findFrame() or not FCF_OpenNewWindow then
        return
    end
    local frame = FCF_OpenNewWindow(TAB, true)
    if frame and ChatFrame_RemoveAllMessageGroups then
        ChatFrame_RemoveAllMessageGroups(frame)
    end
    if frame and ChatFrame_RemoveAllChannels then
        ChatFrame_RemoveAllChannels(frame)
    end
end

-- The DT Debug tab, opened again when it was closed by hand while debug is on.
local function lineFrame()
    if not findFrame() then
        openTab()
    end
    return findFrame() or DEFAULT_CHAT_FRAME
end

-- How many lines came while the DT Debug tab wasn't in front, as a number in a red circle on its tab, the way Chat+
-- marks other tabs. Bringing the tab to the front clears it.
local unread, badgeFrame = 0, nil
local hookedFrames = {}

local function updateBadge()
    local badge = ns.badge
    if not badge then
        return
    end
    local tab = badgeFrame and _G[badgeFrame:GetName() .. "Tab"]
    if unread > 0 and tab and tab:IsShown() then
        badge:ClearAllPoints()
        badge:SetPoint("CENTER", tab, "TOPRIGHT", -6, -6)
        badge.text:SetText(unread > 99 and "99+" or tostring(unread))
        badge:SetWidth(math.max(16, badge.text:GetStringWidth() + 8))
        badge:Show()
    else
        badge:Hide()
    end
end

local function createBadge()
    local badge = CreateFrame("Frame", nil, UIParent)
    badge:SetSize(16, 16)
    badge:SetFrameStrata("MEDIUM")
    local circle = badge:CreateTexture(nil, "BACKGROUND")
    circle:SetAllPoints()
    circle:SetColorTexture(0.85, 0.12, 0.12, 1)
    local mask = badge:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(circle)
    circle:AddMaskTexture(mask)
    badge.text = badge:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    badge.text:SetPoint("CENTER", 0, 0)
    badge:Hide()
    ns.badge = badge
end

-- Counts a line written to the tab while it is hidden. A frame without a tab, the main window, counts nothing.
local function countUnread(frame)
    local tab = frame.GetName and frame ~= DEFAULT_CHAT_FRAME and _G[frame:GetName() .. "Tab"]
    if not tab then
        return
    end
    if not ns.badge then
        createBadge()
    end
    if not hookedFrames[frame] then
        hookedFrames[frame] = true
        frame:HookScript("OnShow", function(self)
            if self == badgeFrame then
                unread = 0
                updateBadge()
            end
        end)
        tab:HookScript("OnShow", updateBadge)
        tab:HookScript("OnHide", updateBadge)
    end
    if badgeFrame ~= frame then
        badgeFrame, unread = frame, 0
    end
    if not frame:IsShown() then
        unread = unread + 1
    end
    updateBadge()
end

local function closeTab()
    unread = 0
    updateBadge()
    local frame = findFrame()
    if frame and frame ~= DEFAULT_CHAT_FRAME and FCF_Close then
        FCF_Close(frame)
    end
end

local function write(text)
    local line = ("|cff888888%s DT|r %s"):format(date("%H:%M:%S"), text)
    local frame = lineFrame()
    frame:AddMessage(line)
    countUnread(frame)
    local log = db.log
    log[#log + 1] = line
    if #log > KEEP then
        table.remove(log, 1)
    end
end

-- Drop Tables writes through this addon only while it is on.
local function apply()
    if db.on then
        openTab()
        shareState = DropTables_SetDebugWriter(write)
    else
        DropTables_SetDebugWriter(nil)
        closeTab()
        wipe(db.log)
    end
end

function ns.OnEvent(event, ...)
    if event == "ADDON_LOADED" and ... == "DropTablesDebug" then
        DropTablesDebugDB = DropTablesDebugDB or {}
        db = DropTablesDebugDB
        db.log = db.log or {}
        if db.on then
            apply()
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- A /reload empties the chat tabs, so the kept lines go back into the DT Debug tab.
        local isInitialLogin, isReloadingUi = ...
        if isInitialLogin then
            wipe(db.log)
        elseif isReloadingUi and db.on then
            local frame = lineFrame()
            for _, line in ipairs(db.log) do
                frame:AddMessage(line)
            end
        end
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function(_, event, ...)
    ns.OnEvent(event, ...)
end)

SLASH_DROPTABLESDEBUG1 = "/dtdebug"
SlashCmdList.DROPTABLESDEBUG = function()
    db.on = not db.on
    apply()
    if db.on then
        print("debug messages on, in the DT Debug chat tab. /dtdebug again turns them off.")
        write(shareState())
    else
        print("debug messages off.")
    end
end
