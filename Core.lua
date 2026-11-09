local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local PathfindingService = game:GetService("PathfindingService")
pcall(function() RunService:UnbindFromRenderStep("HackPanelCoverWallCamera") end)
pcall(function() RunService:UnbindFromRenderStep("HackPanelRushCoverWalk") end)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
-- Shared across repeated executions in the same executor session.
-- Stop the previous run's night vision BEFORE creating the replacement GUI.
local sharedEnvironment = _G
if type(getgenv) == "function" then
    local ok, env = pcall(getgenv)
    if ok and type(env) == "table" then sharedEnvironment = env end
end
local previousCleanup = sharedEnvironment.HackPanelNightVisionCleanup
if type(previousCleanup) == "function" then
    pcall(previousCleanup)
end
sharedEnvironment.HackPanelNightVisionCleanup = nil
-- Invalidate every background loop from a previous optimized run.
local runToken = {}
sharedEnvironment.HackPanelRunToken = runToken
local function isCurrentRun()
    return sharedEnvironment.HackPanelRunToken == runToken
end
-- Remove highlights from previous executions.
-- Old run is invalidated by HackPanelRunToken; entity visuals are owned by the GUI.
-- Clear any old visualizer markers from previous runs.
local oldPathPreview = workspace:FindFirstChild("HackPanelPathPreview")
if oldPathPreview then oldPathPreview:Destroy() end

-- Remove stale windows from previous executions.
for _, oldName in ipairs({"UtilityMenuGui", "EspLinesOverlay", "EspNotifyGui", "HackPanelEntityAlert", "HackPanelEntityHUD", "HackPanelStairwellDoorCounter"}) do
    local old = PlayerGui:FindFirstChild(oldName)
    if old then old:Destroy() end
end
local function getCurrentRooms()
    return workspace:FindFirstChild("CurrentRooms")
end

-- Configuration
local TOGGLE_KEY = Enum.KeyCode.LeftAlt
local CLUSTER_RADIUS_PIXELS = 60
local SCAN_INTERVAL_SECONDS = 0.25 -- room transition check only; item spawns are event-driven
-- Follow the LOCAL PLAYER, not the team's LatestRoom progress.
-- A teammate can advance LatestRoom while you remain in an older room.
local function latestRoomNumber()
    local replicated = game:GetService("ReplicatedStorage")
    local gameData = replicated:FindFirstChild("GameData")
    local latest = gameData and gameData:FindFirstChild("LatestRoom")
    if not latest then latest = replicated:FindFirstChild("LatestRoom") end
    if not latest then latest = workspace:FindFirstChild("LatestRoom") end
    return latest and tonumber(latest.Value) or nil
end

local function roomForPosition(position)
    local rooms = getCurrentRooms()
    if not rooms then return nil end
    local bestRoom, bestScore
    for _, room in ipairs(rooms:GetChildren()) do
        if room:IsA("Model") and tonumber(room.Name) then
            local ok, cf, size = pcall(function() return room:GetBoundingBox() end)
            if ok then
                local localPos = cf:PointToObjectSpace(position)
                if math.abs(localPos.X) <= size.X / 2 + 2
                    and math.abs(localPos.Y) <= size.Y / 2 + 8
                    and math.abs(localPos.Z) <= size.Z / 2 + 2 then
                    -- Prefer the room whose footprint is most centered on the player.
                    local score = (localPos.X / math.max(size.X, 1)) ^ 2
                        + (localPos.Z / math.max(size.Z, 1)) ^ 2
                    if not bestScore or score < bestScore then
                        bestRoom, bestScore = room, score
                    end
                end
            end
        end
    end
    return bestRoom
end

local cachedRoom, nextRoomCheck = nil, 0
local function getCurrentRoom()
    local rooms = getCurrentRooms()
    if not rooms then cachedRoom = nil; return nil, nil end
    if os.clock() >= nextRoomCheck then
        nextRoomCheck = os.clock() + 0.75
        local character = LocalPlayer.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        local found = root and roomForPosition(root.Position) or nil
        if found then
            cachedRoom = found
        elseif not cachedRoom or not cachedRoom:IsDescendantOf(rooms) then
            -- Fallback only if player position cannot be matched yet.
            local latest = latestRoomNumber()
            cachedRoom = latest and rooms:FindFirstChild(tostring(latest)) or nil
        end
    end
    return cachedRoom, cachedRoom and tonumber(cachedRoom.Name) or nil
end

local function belongsToCurrentRoom(item, part)
    local room = getCurrentRoom()
    if not room or not item or not part then return false end
    if item:IsDescendantOf(room) then return true end
    local drops = workspace:FindFirstChild("Drops")
    if not drops or not item:IsDescendantOf(drops) then return false end
    return roomForPosition(part.Position) == room
end

-- State
local isEspActive = false
local hotelEspMode = false
local hotelKeyEspEnabled = false
local mainRenderConnection = nil
local backgroundScanTask = nil
local disconnectItemWatchers
local screenGui = nil

local trackedTargets = {}
local trackedInstances = {}
local activeLines = {}
local activeLabels = {}

-- ==========================================================
-- NOTIFICATIONS
-- ==========================================================

local clearOldESP
local setEspEnabled

-- ==========================================================
-- MENU
-- ==========================================================

local menuGui
local menuFrame
local menuBody
local espButton
local menuMinimized = false
local scriptRunning = true
local inputConnection
local oldMouseIconEnabled = UserInputService.MouseIconEnabled
local cursorHeartbeat
local function updateCursor()
    pcall(function() RunService:UnbindFromRenderStep("HackPanelFreeCursor") end)
    if cursorHeartbeat then cursorHeartbeat:Disconnect(); cursorHeartbeat = nil end
    local function releaseMouse()
        if menuGui and menuGui.Parent and menuGui.Enabled then
            UserInputService.MouseBehavior = Enum.MouseBehavior.Default
            UserInputService.MouseIconEnabled = true
        end
    end
    if menuGui and menuGui.Parent and menuGui.Enabled then
        releaseMouse()
        -- Some first-person camera controllers lock the mouse every frame.
        RunService:BindToRenderStep("HackPanelFreeCursor", Enum.RenderPriority.Last.Value + 1000, releaseMouse)
        cursorHeartbeat = RunService.Heartbeat:Connect(releaseMouse)
    else
        UserInputService.MouseIconEnabled = oldMouseIconEnabled
    end
end

-- ==========================================================
-- MENU TOGGLE
-- ==========================================================

inputConnection = UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
    if not scriptRunning then
        return
    end

    -- Ignore menu shortcuts while the player is typing in a search/text box.
    if UserInputService:GetFocusedTextBox() then
        return
    end

    if input.KeyCode == TOGGLE_KEY and menuGui then
        menuGui.Enabled = not menuGui.Enabled
        updateCursor()
    elseif input.KeyCode == Enum.KeyCode.Minus and menuGui then
        local debugPanel = menuGui:FindFirstChild("ImageTestStatus", true)
        if debugPanel then
            debugPanel.Visible = not debugPanel.Visible
        end
    end
end)

local function updateEspButton()
    if espButton then
        espButton.Text = isEspActive and "ESP: ON" or "ESP: OFF"
        espButton.BackgroundColor3 = isEspActive
            and Color3.fromRGB(40, 125, 75)
            or Color3.fromRGB(65, 65, 75)
    end
end

local function makeButton(parent, text, position, size)
    local button = Instance.new("TextButton")
    button.Size = size
    button.Position = position
    button.BackgroundColor3 = Color3.fromRGB(92, 70, 55)
    button.BorderSizePixel = 0
    button.Font = Enum.Font.Code
    button.TextSize = 15
    button.TextColor3 = Color3.fromRGB(245, 225, 197)
    button.Text = text
    button.AutoButtonColor = true
    button.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = button
    return button
end

local function createMenu()
    menuGui = Instance.new("ScreenGui")
    menuGui.Name = "UtilityMenuGui"
    menuGui.ResetOnSpawn = false
    menuGui.DisplayOrder = 10000
    menuGui.IgnoreGuiInset = true
    menuGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    menuGui.Enabled = true
    menuGui.Parent = PlayerGui
    -- Visible custom cursor fallback for first-person games that hide the
    -- native cursor despite MouseBehavior being Default.
    local cursorDot = Instance.new("Frame")
    cursorDot.Name = "HackPanelVisibleCursor"
    cursorDot.Size = UDim2.fromOffset(10, 10)
    cursorDot.AnchorPoint = Vector2.new(0.5, 0.5)
    cursorDot.BackgroundColor3 = Color3.fromRGB(255, 241, 210)
    cursorDot.BorderSizePixel = 0
    cursorDot.ZIndex = 100000
    cursorDot.Parent = menuGui
    Instance.new("UICorner", cursorDot).CornerRadius = UDim.new(1, 0)
    local cursorOutline = Instance.new("UIStroke")
    cursorOutline.Color = Color3.fromRGB(24, 18, 16)
    cursorOutline.Thickness = 2
    cursorOutline.Parent = cursorDot
    local cursorConnection
    cursorConnection = RunService.RenderStepped:Connect(function()
        if not isCurrentRun() or not cursorDot.Parent then
            cursorConnection:Disconnect()
            return
        end
        if cursorDot.Parent then
            cursorDot.Visible = menuGui.Enabled
            local pos = UserInputService:GetMouseLocation()
            cursorDot.Position = UDim2.fromOffset(pos.X, pos.Y)
        end
    end)

    menuFrame = Instance.new("Frame")
    menuFrame.Name = "MainMenu"
    menuFrame.Size = UDim2.new(0.92, 0, 0.88, 0)
    menuFrame.Position = UDim2.new(0.04, 0, 0.06, 0)
    menuFrame.BackgroundColor3 = Color3.fromRGB(58, 43, 34)
    menuFrame.BackgroundTransparency = 0.12
    menuFrame.BorderSizePixel = 0
    menuFrame.Parent = menuGui

    -- A visible, modal GuiButton tells Roblox to release the first-person mouse lock.
    -- Transparent and behind other controls, so it does not cover menu buttons.
    local mouseRelease = Instance.new("TextButton")
    mouseRelease.Name = "FirstPersonMouseRelease"
    mouseRelease.Text = ""
    mouseRelease.Size = UDim2.fromScale(1, 1)
    mouseRelease.BackgroundTransparency = 1
    mouseRelease.TextTransparency = 1
    mouseRelease.AutoButtonColor = false
    mouseRelease.Active = false
    mouseRelease.Selectable = false
    mouseRelease.Modal = true
    mouseRelease.ZIndex = 0
    mouseRelease.Parent = menuFrame

    local frameCorner = Instance.new("UICorner")
    frameCorner.CornerRadius = UDim.new(0, 7)
    frameCorner.Parent = menuFrame
    local frameStroke = Instance.new("UIStroke")
    frameStroke.Color = Color3.fromRGB(230, 202, 164)
    frameStroke.Thickness = 1.5
    frameStroke.Parent = menuFrame

    local titleBar = Instance.new("Frame")
    titleBar.Size = UDim2.new(1, 0, 0, 36)
    titleBar.BackgroundColor3 = Color3.fromRGB(43, 31, 25)
    titleBar.BorderSizePixel = 0
    titleBar.Parent = menuFrame

    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.Position = UDim2.fromOffset(10, 0)
    title.Size = UDim2.new(1, -20, 1, 0)
    title.Font = Enum.Font.Code
    title.TextSize = 16
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextColor3 = Color3.fromRGB(245, 222, 190)
    title.Text = "HACK PANEL"
    title.Parent = titleBar

    -- Central version label; change this once per released panel build.
    local panelVersion = Instance.new("TextLabel")
    panelVersion.Name = "HackPanelVersion"
    panelVersion.BackgroundTransparency = 1
    panelVersion.AnchorPoint = Vector2.new(1, 0)
    panelVersion.Position = UDim2.new(1, -12, 0, 0)
    panelVersion.Size = UDim2.fromOffset(145, 36)
    panelVersion.Font = Enum.Font.Code
    panelVersion.TextSize = 14
    panelVersion.TextXAlignment = Enum.TextXAlignment.Right
    panelVersion.TextColor3 = Color3.fromRGB(210, 184, 158)
    panelVersion.Text = "v0.1.12"
    panelVersion.ZIndex = 3
    panelVersion.Parent = titleBar

    menuBody = Instance.new("Frame")
    menuBody.BackgroundTransparency = 1
    menuBody.Position = UDim2.fromOffset(12, 48)
    menuBody.Size = UDim2.new(1, -24, 1, -60)
    menuBody.Parent = menuFrame

    local nav = Instance.new("Frame")
    nav.BackgroundTransparency = 1
    nav.Position = UDim2.fromOffset(0, 0)
    nav.Size = UDim2.new(1, 0, 0, 36)
    nav.Parent = menuBody

    local floorsButton = makeButton(nav, "Floors", UDim2.new(0, 0, 0, 0), UDim2.new(1/3, -6, 1, 0))
    local subfloorsButton = makeButton(nav, "Subfloors", UDim2.new(1/3, 3, 0, 0), UDim2.new(1/3, -6, 1, 0))
    local visionsButton = makeButton(nav, "Visions", UDim2.new(2/3, 6, 0, 0), UDim2.new(1/3, -6, 1, 0))

    -- Back to the top-level HACK PANEL list.
    local backButton = makeButton(nav, "< BACK", UDim2.new(0, 0, 0, 0), UDim2.new(0, 100, 1, 0))
    backButton.BackgroundColor3 = Color3.fromRGB(67, 52, 44)
    floorsButton.Position = UDim2.new(0, 106, 0, 0)
    floorsButton.Size = UDim2.new(1/3, -110/3, 1, 0)
    subfloorsButton.Position = UDim2.new(1/3, 106*2/3, 0, 0)
    subfloorsButton.Size = UDim2.new(1/3, -110/3, 1, 0)
    visionsButton.Position = UDim2.new(2/3, 106/3, 0, 0)
    visionsButton.Size = UDim2.new(1/3, -110/3, 1, 0)

    local tabPanel = Instance.new("Frame")
    tabPanel.Name = "ContentPanel"
    tabPanel.Position = UDim2.fromOffset(0, 46)
    tabPanel.Size = UDim2.new(1, 0, 1, -46)
    tabPanel.BackgroundColor3 = Color3.fromRGB(43, 31, 25)
    tabPanel.BackgroundTransparency = 0.12
    tabPanel.BorderSizePixel = 0
    tabPanel.Parent = menuBody

    local panelCorner = Instance.new("UICorner")
    panelCorner.CornerRadius = UDim.new(0, 5)
    panelCorner.Parent = tabPanel
    local panelStroke = Instance.new("UIStroke")
    panelStroke.Color = Color3.fromRGB(180, 145, 105)
    panelStroke.Thickness = 1
    panelStroke.Parent = tabPanel

    local cards = Instance.new("ScrollingFrame")
    cards.Name = "LevelCards"
    cards.BackgroundTransparency = 1
    cards.BorderSizePixel = 0
    cards.Position = UDim2.fromOffset(0, 12)
    cards.Size = UDim2.new(1, 0, 1, -12)
    cards.ScrollBarThickness = 7
    cards.ScrollBarImageColor3 = Color3.fromRGB(210, 177, 139)
    cards.CanvasSize = UDim2.new(0, 0, 0, 0)
    cards.AutomaticCanvasSize = Enum.AutomaticSize.Y
    cards.Parent = tabPanel

    local cardsPadding = Instance.new("UIPadding")
    cardsPadding.PaddingTop = UDim.new(0, 8)
    cardsPadding.PaddingBottom = UDim.new(0, 8)
    cardsPadding.Parent = cards

    local cardLayout = Instance.new("UIListLayout")
    cardLayout.Padding = UDim.new(0, 6)
    cardLayout.SortOrder = Enum.SortOrder.LayoutOrder
    cardLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center -- Center all compact cards horizontally
    cardLayout.Parent = cards

    -- On-screen HTTP diagnostics (no executor console required).
    local diagnostic = Instance.new("TextLabel")
    diagnostic.Name = "ImageTestStatus"
    diagnostic.AnchorPoint = Vector2.new(0.5, 1)
    diagnostic.Position = UDim2.new(0.5, 0, 1, -6)
    diagnostic.Size = UDim2.new(0.96, 0, 0, 160)
    diagnostic.BackgroundColor3 = Color3.fromRGB(16, 17, 21)
    diagnostic.BackgroundTransparency = 0.04
    diagnostic.TextColor3 = Color3.fromRGB(255, 230, 175)
    diagnostic.TextWrapped = true
    diagnostic.TextXAlignment = Enum.TextXAlignment.Left
    diagnostic.TextYAlignment = Enum.TextYAlignment.Top
    diagnostic.TextSize = 12
    diagnostic.Font = Enum.Font.Code
    diagnostic.ZIndex = 100
    diagnostic.Text = "HTTP diagnostic starting..."
    diagnostic.Parent = menuFrame
    diagnostic.Visible = false -- Press minus to show/hide debug output.

    -- GitHub Assets branch: filenames match the repository exactly.
    local RAW_ROOT = "https://raw.githubusercontent.com/JrakeM-TheSigma/Hackpanel/Assets/"
    local assetFiles = {
        ["THE HOTEL"] = {"HotelBackground.png", "HotelTitle.png"},
        ["THE MINES"] = {"MinesBackground.png", "MinesTitle.png"},
        ["THE OUTDOORS"] = {"OutdoorsBackground.png", "OutdoorsTitle.png"},
        ["THE BACKDOOR"] = {"BackdoorBackground.png", "BackdoorTitle.png"},
        ["THE ROOMS"] = {"RoomsBackground.png", nil},
        ["RUSH MODE"] = {"RushmodeBackground.png", "RushmodeTitle.png"},
        ["THE STAIRWELL"] = {"StairwellBackground.png", "StairwellTitle.png"},
        ["THE ARCHIVES"] = {"ArchivesBackground.png", "ArchivesTitle.png"},
        ["THE CANDY VAULT"] = {"CandyvaultBackground.png", "CandyvaultLogo.png"},
    }
    local loadedImages = {}
    local imageStatus = {}
    local function refreshStatus()
        local lines = {"GITHUB IMAGE STATUS (press - to hide)"}
        for _, name in ipairs({"THE HOTEL", "THE MINES", "THE OUTDOORS", "THE BACKDOOR", "THE STAIRWELL", "THE ARCHIVES", "THE ROOMS", "RUSH MODE", "THE CANDY VAULT"}) do
            table.insert(lines, name .. ": " .. (imageStatus[name] or "Waiting"))
        end
        diagnostic.Text = table.concat(lines, "\n")
    end
    local function hexPrefix(value)
        if type(value) ~= "string" then return "not-string" end
        local pieces = {}
        for i = 1, math.min(12, #value) do
            pieces[#pieces + 1] = string.format("%02X", string.byte(value, i))
        end
        return table.concat(pieces, " ")
    end
    local function loadGithubImage(url, filename)
        local env = _G
        if type(getgenv) == "function" then
            local ok, value = pcall(getgenv)
            if ok and type(value) == "table" then env = value end
        end
        local assetFn = (type(getcustomasset) == "function" and getcustomasset)
            or (type(getsynasset) == "function" and getsynasset)
            or (env and (env.getcustomasset or env.getsynasset))
        local saveFn = (type(writefile) == "function" and writefile) or (env and env.writefile)
        local requestFn = (type(request) == "function" and request)
            or (type(http_request) == "function" and http_request)
            or (env and (env.request or env.http_request))
        if type(saveFn) ~= "function" then return nil, "writefile unavailable" end
        if type(assetFn) ~= "function" then return nil, "getcustomasset unavailable" end
        local ok, body, code = pcall(function()
            if type(requestFn) == "function" then
                local response = requestFn({Url = url, Method = "GET"})
                if type(response) ~= "table" then return nil, "no response" end
                return response.Body or response.body, tostring(response.StatusCode or response.Status or "?")
            end
            return game:HttpGet(url), "?"
        end)
        if not ok then return nil, "HTTP error: " .. tostring(body):sub(1, 75) end
        if type(body) ~= "string" then return nil, "empty response (" .. tostring(code) .. ")" end
        local format
        if body:sub(1, 8) == "\137PNG\r\n\26\n" then
            format = "png"
        elseif body:sub(1, 4) == "RIFF" and body:sub(9, 12) == "WEBP" then
            format = "webp"
        elseif body:sub(1, 3) == "\255\216\255" then
            format = "jpg"
        else
            return nil, "invalid " .. #body .. " bytes HTTP " .. tostring(code) .. " [" .. hexPrefix(body) .. "]"
        end
        filename = filename:gsub("%.png$", "." .. format)
        local saved, result = pcall(function()
            saveFn(filename, body)
            return assetFn(filename)
        end)
        if saved and type(result) == "string" and #result > 0 then
            return result, "OK (" .. format .. ", " .. #body .. " bytes)"
        end
        return nil, "asset error: " .. tostring(result):sub(1, 60)
    end
    refreshStatus()
    -- Fetch in a task so the panel appears promptly; cards refresh when ready.
    local buildCards
    local currentSection = "Floors"
    local refreshHomeCard
    local function fetchAllImages()
        for _, name in ipairs({"THE HOTEL", "THE MINES", "THE OUTDOORS", "THE BACKDOOR", "THE STAIRWELL", "THE ARCHIVES", "THE ROOMS", "RUSH MODE", "THE CANDY VAULT"}) do
            local files = assetFiles[name]
            loadedImages[name] = {}
            local outcomes = {}
            for i, file in ipairs(files) do
                if file then
                    local asset, result = loadGithubImage(RAW_ROOT .. file, "HackPanel_" .. file)
                    loadedImages[name][i] = asset
                    table.insert(outcomes, (i == 1 and "BG " or "TITLE ") .. result)
                end
            end
            imageStatus[name] = table.concat(outcomes, " | ")
            refreshStatus()
            if name == "THE HOTEL" and refreshHomeCard then refreshHomeCard() end
            if buildCards and menuGui and menuGui.Parent then
                buildCards(currentSection)
            end
            task.wait()
        end
    end

    -- Detail screen shared by every floor/subfloor/vision card.
    local detailPanel = Instance.new("Frame")
    detailPanel.Name = "FloorDetailPanel"
    detailPanel.Size = UDim2.fromScale(1, 1)
    detailPanel.BackgroundColor3 = Color3.fromRGB(43, 31, 25)
    detailPanel.BorderSizePixel = 0
    detailPanel.Visible = false
    detailPanel.ZIndex = 30
    detailPanel.Parent = tabPanel

    local detailTitle = Instance.new("TextLabel")
    detailTitle.Name = "SelectedFloorTitle"
    detailTitle.Size = UDim2.new(1, -160, 0, 48)
    detailTitle.Position = UDim2.fromOffset(16, 10)
    detailTitle.BackgroundTransparency = 1
    detailTitle.Font = Enum.Font.GothamBold
    detailTitle.TextSize = 24
    detailTitle.TextColor3 = Color3.fromRGB(255, 231, 206)
    detailTitle.TextXAlignment = Enum.TextXAlignment.Left
    detailTitle.ZIndex = 32
    detailTitle.Parent = detailPanel

    local detailBack = makeButton(detailPanel, "< BACK", UDim2.new(1, -132, 0, 12), UDim2.fromOffset(116, 38))
    detailBack.ZIndex = 32

    local detailMessage = Instance.new("TextLabel")
    detailMessage.Name = "ToBeContinued"
    detailMessage.AnchorPoint = Vector2.new(0.5, 0.5)
    detailMessage.Position = UDim2.fromScale(0.5, 0.46)
    detailMessage.Size = UDim2.new(0.95, 0, 0, 70)
    detailMessage.BackgroundTransparency = 1
    detailMessage.Font = Enum.Font.GothamBlack
    detailMessage.TextSize = 35
    detailMessage.TextColor3 = Color3.fromRGB(245, 222, 190)
    detailMessage.Text = "TO BE CONTINUED"
    detailMessage.ZIndex = 32
    detailMessage.Parent = detailPanel

    espButton = makeButton(detailPanel, "ESP: OFF", UDim2.new(0.5, -115, 0.65, 0), UDim2.fromOffset(230, 50))
    espButton.ZIndex = 32
    espButton.Visible = false
    espButton.MouseButton1Click:Connect(function()
        if not isEspActive then hotelEspMode = false end
        setEspEnabled(not isEspActive)
    end)
    updateEspButton()

    -- Hotel door selector. Uses locally replicated room geometry; server checks
    -- may reject or reverse movement. No anti-cheat bypass is attempted.
    local doorPanel = Instance.new("Frame")
    doorPanel.Name = "HotelDoorSelector"
    doorPanel.Size = UDim2.new(0.9, 0, 0, 178)
    doorPanel.AnchorPoint = Vector2.new(0.5, 0.5)
    doorPanel.Position = UDim2.fromScale(0.5, 0.49)
    doorPanel.BackgroundColor3 = Color3.fromRGB(62, 46, 36)
    doorPanel.BorderSizePixel = 0
    doorPanel.ZIndex = 33
    doorPanel.Visible = false
    doorPanel.Parent = detailPanel
    Instance.new("UICorner", doorPanel).CornerRadius = UDim.new(0, 14)

    local doorCaption = Instance.new("TextLabel")
    doorCaption.Name = "DoorCaption"
    doorCaption.BackgroundTransparency = 1
    doorCaption.Size = UDim2.new(1, 0, 0, 35)
    doorCaption.Position = UDim2.fromOffset(0, 8)
    doorCaption.Font = Enum.Font.GothamBold
    doorCaption.TextSize = 22
    doorCaption.TextColor3 = Color3.fromRGB(255, 218, 183)
    doorCaption.Text = "SELECT HOTEL DOOR"
    doorCaption.ZIndex = 34
    doorCaption.Parent = doorPanel

    local selectedDoor = 1
    local previousDoor = makeButton(doorPanel, "<", UDim2.new(0.5, -185, 0, 53), UDim2.fromOffset(62, 45))
    local nextDoor = makeButton(doorPanel, ">", UDim2.new(0.5, 123, 0, 53), UDim2.fromOffset(62, 45))
    previousDoor.ZIndex = 35
    nextDoor.ZIndex = 35

    local doorInput = Instance.new("TextBox")
    doorInput.Name = "DoorNumberInput"
    doorInput.Position = UDim2.new(0.5, -113, 0, 53)
    doorInput.Size = UDim2.fromOffset(226, 45)
    doorInput.BackgroundColor3 = Color3.fromRGB(35, 28, 25)
    doorInput.TextColor3 = Color3.fromRGB(255, 231, 206)
    doorInput.PlaceholderText = "Door number"
    doorInput.Font = Enum.Font.GothamBold
    doorInput.TextSize = 22
    doorInput.Text = "1"
    doorInput.ClearTextOnFocus = false
    doorInput.ZIndex = 35
    doorInput.Parent = doorPanel
    Instance.new("UICorner", doorInput).CornerRadius = UDim.new(0, 8)

    local doorGo = makeButton(doorPanel, "WALK TO DOOR", UDim2.new(0.5, -110, 0, 111), UDim2.fromOffset(220, 45))
    doorGo.ZIndex = 35

    local function setDoor(number)
        selectedDoor = math.clamp(math.floor(tonumber(number) or selectedDoor), 0, 10000)
        doorInput.Text = tostring(selectedDoor)
    end
    previousDoor.MouseButton1Click:Connect(function() setDoor(selectedDoor - 1) end)
    nextDoor.MouseButton1Click:Connect(function() setDoor(selectedDoor + 1) end)
    doorInput.FocusLost:Connect(function() setDoor(doorInput.Text) end)
    doorGo.MouseButton1Click:Connect(function()
        setDoor(doorInput.Text)
        local rooms = getCurrentRooms()
        local room = rooms and rooms:FindFirstChild(tostring(selectedDoor))
        if not room or not room:IsA("Model") then
            doorCaption.Text = "DOOR " .. selectedDoor .. " NOT LOADED"
            return
        end
        local character = LocalPlayer.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if not root then
            doorCaption.Text = "CHARACTER NOT READY"
            return
        end
        local target = room:FindFirstChild("Door", true) or room:FindFirstChild("DoorEntrance", true)
        local targetPart
        if target then
            if target:IsA("BasePart") then targetPart = target
            elseif target:IsA("Model") then targetPart = target.PrimaryPart or target:FindFirstChildWhichIsA("BasePart", true) end
        end
        if not targetPart then
            doorCaption.Text = "DOOR PART NOT FOUND"
            return
        end
        local destination = targetPart.Position - targetPart.CFrame.LookVector * 5
        doorCaption.Text = "WALKING TO DOOR " .. selectedDoor
        task.spawn(function()
            local characterNow = LocalPlayer.Character
            local humanoid = characterNow and characterNow:FindFirstChildOfClass("Humanoid")
            local rootNow = characterNow and characterNow:FindFirstChild("HumanoidRootPart")
            if not humanoid or not rootNow then return end
            local path = PathfindingService:CreatePath({AgentCanJump = true})
            local ok = pcall(function() path:ComputeAsync(rootNow.Position, destination) end)
            if not ok or path.Status ~= Enum.PathStatus.Success then
                doorCaption.Text = "NO WALKABLE PATH"
                return
            end
            for _, waypoint in ipairs(path:GetWaypoints()) do
                if waypoint.Action == Enum.PathWaypointAction.Jump then humanoid.Jump = true end
                humanoid:MoveTo(waypoint.Position)
                if not humanoid.MoveToFinished:Wait() then
                    doorCaption.Text = "PATH BLOCKED"
                    return
                end
            end
            doorCaption.Text = "ARRIVED NEAR DOOR " .. selectedDoor
        end)
    end)

    -- Rush auto-hide: normal humanoid movement, no character teleporting.
    local rushAutoEnabled = false
    local rushBusy = false
    local rushGeneration = 0
    local rushStatus = Instance.new("TextLabel")
    rushStatus.Name = "RushAutoStatus"
    rushStatus.BackgroundTransparency = 1
    rushStatus.Position = UDim2.new(0, 10, 1, -24)
    rushStatus.Size = UDim2.new(1, -20, 0, 22)
    rushStatus.Font = Enum.Font.Gotham
    rushStatus.TextSize = 13
    rushStatus.TextColor3 = Color3.fromRGB(255, 231, 206)
    rushStatus.Text = "Entity auto-hide is off"
    rushStatus.ZIndex = 36
    rushStatus.Parent = doorPanel

    doorPanel.Size = UDim2.new(0.9, 0, 0, 250)
    local rushButton = makeButton(doorPanel, "ENTITY AUTO-HIDE: OFF", UDim2.new(0.5, -130, 0, 165), UDim2.fromOffset(260, 45))
    rushButton.ZIndex = 35
    rushStatus.Position = UDim2.new(0, 10, 0, 215)

    -- Optional lightweight path visualization. Parts are local-only and non-colliding.
    local pathVisualEnabled = false
    local pathVisualFolder
    local function clearPathVisual()
        if pathVisualFolder then pathVisualFolder:Destroy(); pathVisualFolder = nil end
    end
    local function showPathVisual(waypoints, kind)
        clearPathVisual()
        if not pathVisualEnabled or not waypoints then return end
        local folder = Instance.new("Folder")
        folder.Name = "HackPanelPathPreview"
        folder.Parent = workspace
        pathVisualFolder = folder
        local previous
        for i, wp in ipairs(waypoints) do
            local point = Instance.new("Part")
            point.Name = "Waypoint_" .. i
            point.Shape = Enum.PartType.Ball
            point.Size = Vector3.new(0.75, 0.75, 0.75)
            point.Material = Enum.Material.Neon
            point.Color = kind == "COVER" and Color3.fromRGB(80, 210, 255) or Color3.fromRGB(90, 255, 120)
            point.Anchored = true
            point.CanCollide = false
            point.CanTouch = false
            point.CanQuery = false
            point.Position = wp.Position + Vector3.new(0, 0.55, 0)
            point.Parent = folder
            if previous then
                local displacement = point.Position - previous
                local segment = Instance.new("Part")
                segment.Name = "Segment_" .. i
                segment.Anchored = true
                segment.CanCollide = false
                segment.CanTouch = false
                segment.CanQuery = false
                segment.Material = Enum.Material.Neon
                segment.Color = point.Color
                segment.Transparency = 0.3
                segment.Size = Vector3.new(0.13, 0.13, displacement.Magnitude)
                segment.CFrame = CFrame.lookAt((point.Position + previous) / 2, point.Position)
                segment.Parent = folder
            end
            previous = point.Position
        end
    end

    -- Hotel feature tabs: Auto / ESP / Essentials.
    -- Expand the entire Hotel tab panel into the unused vertical space.
    -- The warning grid uses proportional cell heights, so this makes its
    -- checkbox tiles large instead of tiny strips.
    doorPanel.Size = UDim2.new(0.9, 0, 0.84, 0)
    doorPanel.Position = UDim2.fromScale(0.5, 0.54)
    local hotelPages = {}
    local hotelTabButtons = {}
    for i, name in ipairs({"Auto", "ESP", "Essentials", "Warnings"}) do
        local tab = makeButton(doorPanel, name, UDim2.new((i-1)/4, 4, 0, 8), UDim2.new(1/4, -8, 0, 36))
        tab.Name = name .. "Tab"
        tab.ZIndex = 40
        hotelTabButtons[name] = tab
        local page = Instance.new("Frame")
        page.Name = name .. "Page"
        page.Position = UDim2.fromOffset(0, 46)
        page.Size = UDim2.new(1, 0, 1, -50)
        page.BackgroundTransparency = 1
        page.ZIndex = 34
        page.Visible = false
        page.Parent = doorPanel
        hotelPages[name] = page
    end
    local function showHotelTab(name)
        for tabName, page in pairs(hotelPages) do
            page.Visible = tabName == name
            hotelTabButtons[tabName].BackgroundColor3 = tabName == name
                and Color3.fromRGB(135, 96, 68) or Color3.fromRGB(75, 55, 44)
        end
    end
    for name, button in pairs(hotelTabButtons) do
        button.MouseButton1Click:Connect(function() showHotelTab(name) end)
    end

    -- Move existing controls without replacing their connected callbacks.
    doorCaption.Parent = hotelPages.Auto
    previousDoor.Parent = hotelPages.Auto
    nextDoor.Parent = hotelPages.Auto
    doorInput.Parent = hotelPages.Auto
    doorGo.Parent = hotelPages.Auto
    doorCaption.Position = UDim2.fromOffset(0, 102)
    previousDoor.Position = UDim2.new(0.5, -185, 0, 140)
    nextDoor.Position = UDim2.new(0.5, 123, 0, 140)
    doorInput.Position = UDim2.new(0.5, -113, 0, 140)
    doorGo.Position = UDim2.new(0.5, -110, 0, 192)
    rushButton.Parent = hotelPages.Auto
    rushButton.Position = UDim2.new(0.5, -130, 0, 35)
    rushStatus.Parent = hotelPages.Auto
    rushStatus.Position = UDim2.new(0, 10, 0, 83)
    rushStatus.Size = UDim2.new(1, -20, 0, 22)
    rushStatus.TextWrapped = true

    local pathVisualButton = makeButton(hotelPages.Auto, "SHOW PATH: OFF", UDim2.new(0.5, -130, 0, 248), UDim2.fromOffset(260, 38))
    pathVisualButton.ZIndex = 36
    pathVisualButton.MouseButton1Click:Connect(function()
        pathVisualEnabled = not pathVisualEnabled
        pathVisualButton.Text = pathVisualEnabled and "SHOW PATH: ON" or "SHOW PATH: OFF"
        if not pathVisualEnabled then clearPathVisual() end
    end)


    local autoDescription = Instance.new("TextLabel")
    autoDescription.Name = "AutoDescription"
    autoDescription.Size = UDim2.new(1, -24, 0, 28)
    autoDescription.Position = UDim2.fromOffset(12, 8)
    autoDescription.BackgroundTransparency = 1
    autoDescription.Text = "Entity assistance and door controls"
    autoDescription.TextColor3 = Color3.fromRGB(245, 225, 197)
    autoDescription.Font = Enum.Font.Gotham
    autoDescription.TextSize = 14
    autoDescription.ZIndex = 36
    autoDescription.Parent = hotelPages.Auto

    -- Hotel key ESP: independent control, using the existing cursor-tracer renderer.
    local keyEspButton = makeButton(hotelPages.ESP, "KEY ESP: OFF", UDim2.new(0.5, -130, 0, 42), UDim2.fromOffset(260, 40))
    keyEspButton.ZIndex = 36
    keyEspButton.MouseButton1Click:Connect(function()
        if hotelKeyEspEnabled then
            setEspEnabled(false)
            hotelKeyEspEnabled = false
        else
            if isEspActive then setEspEnabled(false) end
            hotelKeyEspEnabled = true
            setEspEnabled(true)
        end
        keyEspButton.Text = hotelKeyEspEnabled and "KEY ESP: ON" or "KEY ESP: OFF"
        keyEspButton.BackgroundColor3 = Color3.fromRGB(92, 70, 55)
    end)

    -- Item ESP is intentionally available only in THE CANDY VAULT.
    -- Other floors retain Entity Wall ESP and floor-specific ESP tools.

