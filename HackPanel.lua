local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local PathfindingService = game:GetService("PathfindingService")
pcall(function() RunService:UnbindFromRenderStep("HackPanelCoverWallCamera") end)
pcall(function() RunService:UnbindFromRenderStep("HackPanelLOSDebugWalk") end)
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
-- Remove highlights from previous executions.
for _, descendant in ipairs(workspace:GetDescendants()) do
    if (descendant:IsA("Highlight") and descendant.Name == "HackPanelEntityOutline")
        or (descendant:IsA("BoxHandleAdornment") and descendant.Name == "HackPanelEntityBox") then
        descendant:Destroy()
    end
end
-- Clear any old visualizer markers from previous runs.
local oldLOSDiagnostics = workspace:FindFirstChild("HackPanelLOSRayDiagnostics")
if oldLOSDiagnostics then oldLOSDiagnostics:Destroy() end
local oldPathPreview = workspace:FindFirstChild("HackPanelPathPreview")
if oldPathPreview then oldPathPreview:Destroy() end

-- Remove stale windows from previous executions.
for _, oldName in ipairs({"UtilityMenuGui", "EspLinesOverlay", "EspNotifyGui", "HackPanelEntityAlert", "HackPanelEntityHUD"}) do
    local old = PlayerGui:FindFirstChild(oldName)
    if old then old:Destroy() end
end
local function getCurrentRooms()
    return workspace:FindFirstChild("CurrentRooms")
end

-- Configuration
local TOGGLE_KEY = Enum.KeyCode.LeftAlt
local CLUSTER_RADIUS_PIXELS = 60
local SCAN_INTERVAL_SECONDS = 1.5
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
        nextRoomCheck = os.clock() + 0.2
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
local mainRenderConnection = nil
local backgroundScanTask = nil
local screenGui = nil

local trackedTargets = {}
local trackedInstances = {}
local activeLines = {}
local activeLabels = {}

-- ==========================================================
-- NOTIFICATIONS
-- ==========================================================

local function showToggleMessage(text, color)
    local oldGui = PlayerGui:FindFirstChild("EspNotifyGui")
    if oldGui then
        oldGui:Destroy()
    end

    local notifyGui = Instance.new("ScreenGui")
    notifyGui.Name = "EspNotifyGui"
    notifyGui.ResetOnSpawn = false
    notifyGui.IgnoreGuiInset = true
    notifyGui.Parent = PlayerGui

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromOffset(360, 50)
    label.Position = UDim2.new(0.5, -180, 0.35, 0)
    label.Font = Enum.Font.Code
    label.TextSize = 18
    label.TextColor3 = color
    label.Text = text
    label.TextStrokeTransparency = 0
    label.TextStrokeColor3 = Color3.new(0, 0, 0)
    label.Parent = notifyGui

    task.delay(1, function()
        if not label.Parent then
            return
        end

        local tween = TweenService:Create(
            label,
            TweenInfo.new(0.5),
            {
                TextTransparency = 1,
                TextStrokeTransparency = 1
            }
        )

        tween:Play()
        tween.Completed:Once(function()
            if notifyGui.Parent then
                notifyGui:Destroy()
            end
        end)
    end)
end

-- ==========================================================
-- CLEANUP
-- ==========================================================

local function clearOldESP()
    if mainRenderConnection then
        mainRenderConnection:Disconnect()
        mainRenderConnection = nil
    end

    if backgroundScanTask then
        task.cancel(backgroundScanTask)
        backgroundScanTask = nil
    end

    if screenGui then
        screenGui:Destroy()
        screenGui = nil
    end

    for _, target in ipairs(trackedTargets) do
        local highlight = target.Highlight
        if highlight and highlight.Parent then
            highlight:Destroy()
        end
    end

    -- Also remove any remaining target-owned highlights.
    for _, line in pairs(activeLines) do
        if line then
            line:Destroy()
        end
    end

    for _, label in pairs(activeLabels) do
        if label then
            label:Destroy()
        end
    end

    activeLines = {}
    activeLabels = {}
    trackedTargets = {}
    trackedInstances = {}
end

-- ==========================================================
-- FIND A PHYSICAL PART
-- ==========================================================

local function getPhysicalPart(object)
    if object:IsA("BasePart") then
        return object
    end

    local root = object:FindFirstChild("CandyRoot", true)
        or object:FindFirstChild("Handle", true)

    if root and root:IsA("BasePart") then
        return root
    end

    for _, descendant in ipairs(object:GetDescendants()) do
        if descendant:IsA("BasePart") then
            return descendant
        end
    end

    return nil
end

-- ==========================================================
-- TRACK TARGETS
-- ==========================================================

local function trackItemInstance(item, defaultName, highlightPartOnly, category)
    if not isEspActive or not item or not item.Parent then
        return
    end

    -- Use the Instance itself as the key instead of GetDebugId().
    if trackedInstances[item] then
        return
    end

    local part = getPhysicalPart(item)
    if not part then
        return
    end

    if not belongsToCurrentRoom(item, part) then return end

    local categoryColors = {
        CANDY = Color3.fromRGB(255, 145, 210),
        ITEMS = Color3.fromRGB(100, 215, 255),
        KEYS = Color3.fromRGB(255, 225, 80),
    }
    category = category or "ITEMS"
    local color = categoryColors[category] or categoryColors.ITEMS

    local highlight = Instance.new("Highlight")
    highlight.Name = "FakeESPHighlight"
    highlight.FillColor = color
    highlight.FillTransparency = 0.2
    highlight.OutlineColor = Color3.new(1, 1, 1)
    highlight.OutlineTransparency = 0
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.Adornee = highlightPartOnly and part or item
    highlight.Parent = screenGui

    local target = {
        Instance = item,
        Part = part,
        Highlight = highlight,
        Color = color,
        Name = string.upper(defaultName or item.Name),
        Category = category,
        
    }

    trackedInstances[item] = target
    table.insert(trackedTargets, target)
end

-- ==========================================================
-- DISCOVERY
-- ==========================================================

local function scanAllLocations()
    if not isEspActive then
        return
    end

    local function inspect(container)
        if not container then return end
        for _, descendant in ipairs(container:GetDescendants()) do
            -- Keys can appear in Drops, FloorLootItem, DrawerContainer,
            -- and other room loot containers. Highlight only KeyJewelry itself.
            if descendant.Name == "KeyJewelry" and (descendant:IsA("Model") or descendant:IsA("BasePart") or descendant:IsA("Tool")) then
                trackItemInstance(descendant, "KEY JEWELRY", false, "KEYS")
            end

            -- Keep the existing Candy and SalvageItems ESP discovery.
            if descendant.Name == "Candy" and not hotelEspMode then
                trackItemInstance(descendant, "CANDY", false, "CANDY")
            elseif descendant.Parent
                and descendant.Parent.Name == "SalvageItems"
                and descendant.Name ~= "JewelryCase" then
                trackItemInstance(descendant, nil, false, "ITEMS")
            end

            -- Additional discovery: every physical item directly inside a
            -- JewelryCase, regardless of its name (not just ShakeLight).
            if descendant.Name == "JewelryCase" then
                for _, item in ipairs(descendant:GetChildren()) do
                    if item:IsA("Model") or item:IsA("Tool") then
                        trackItemInstance(item, item.Name, false, "ITEMS")
                    end
                end
            end
        end
    end

    local currentRoom = getCurrentRoom()
    inspect(currentRoom)

    local dropsFolder = workspace:FindFirstChild("Drops")
    if dropsFolder then
        inspect(dropsFolder)
    end
end

local function startBackgroundLiveScanner()
    if backgroundScanTask then
        task.cancel(backgroundScanTask)
    end

    backgroundScanTask = task.spawn(function()
        while isEspActive do
            scanAllLocations()
            task.wait(SCAN_INTERVAL_SECONDS)
        end

        backgroundScanTask = nil
    end)
end

-- ==========================================================
-- CREATE HUD ELEMENTS
-- ==========================================================

local function createLine()
    local line = Instance.new("Frame")
    line.Name = "TracerLine"
    line.BorderSizePixel = 0
    line.AnchorPoint = Vector2.new(0.5, 0.5)
    line.Size = UDim2.fromOffset(0, 1.5)
    line.Visible = false
    line.Parent = screenGui
    return line
end

local function createLabel()
    local label = Instance.new("TextLabel")
    label.Name = "ClusterLabel"
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromOffset(200, 42)
    label.AnchorPoint = Vector2.new(0.5, 0)
    label.Font = Enum.Font.Code
    label.TextSize = 13
    label.TextStrokeTransparency = 0
    label.TextStrokeColor3 = Color3.new(0, 0, 0)
    label.TextWrapped = true
    label.Visible = false
    label.Parent = screenGui
    return label
end

-- ==========================================================
-- RENDER LOOP
-- ==========================================================

local function startEspLoop()
    if mainRenderConnection then
        mainRenderConnection:Disconnect()
    end

    mainRenderConnection = RunService.RenderStepped:Connect(function()
        if not isEspActive or not screenGui or not screenGui.Parent then
            return
        end

        local camera = workspace.CurrentCamera
        if not camera then
            return
        end

        local viewport = camera.ViewportSize
        -- All tracers originate from the actual cursor (Candy ESP style).
        local mouseOrigin = UserInputService:GetMouseLocation()
        local centerX = mouseOrigin.X
        local centerY = mouseOrigin.Y

        local character = LocalPlayer.Character
        local rootPart = character
            and character:FindFirstChild("HumanoidRootPart")

            local visiblePoints = {}

        for _, line in pairs(activeLines) do
            line.Visible = false
        end

        -- Draw tracers and remove deleted targets.
        for i = #trackedTargets, 1, -1 do
            local target = trackedTargets[i]
            local item = target.Instance
            local part = target.Part

            local isPast = item and part and not belongsToCurrentRoom(item, part)
            if not item or not item.Parent or not part or not part.Parent or isPast then
                if target.Highlight and target.Highlight.Parent then
                    target.Highlight:Destroy()
                end

                activeLines[target] = nil
                trackedInstances[item] = nil
                table.remove(trackedTargets, i)
            else
                local screenPos, onScreen =
                    camera:WorldToViewportPoint(part.Position)

                if onScreen and screenPos.Z > 0 then
                    local distance = 0

                    if rootPart then
                        distance = math.floor(
                            (rootPart.Position - part.Position).Magnitude / 3.5
                        )
                    end

                    table.insert(visiblePoints, {
                        X = screenPos.X,
                        Y = screenPos.Y,
                        Distance = distance,
                        Color = target.Color,
                        Name = target.Name,
                        Category = target.Category,
                    })

                    local line = activeLines[target]
                    if not line then
                        line = createLine()
                        activeLines[target] = line
                    end

                    line.BackgroundColor3 = target.Color

                    local dx = screenPos.X - centerX
                    local dy = screenPos.Y - centerY
                    local length = math.sqrt(dx * dx + dy * dy)

                    line.Size = UDim2.fromOffset(length, 1.5)
                    line.Position = UDim2.fromOffset(
                        centerX + dx / 2,
                        centerY + dy / 2
                    )
                    line.Rotation = math.deg(math.atan2(dy, dx))
                    line.Visible = true
                end
            end
        end

        -- Group nearby on-screen items.
        local groups = {}

        for _, point in ipairs(visiblePoints) do
            local nearestGroup = nil
            local nearestDistance = CLUSTER_RADIUS_PIXELS

            for _, group in ipairs(groups) do
                local dx = point.X - group.X
                local dy = point.Y - group.Y
                local distance = math.sqrt(dx * dx + dy * dy)

                if group.Category == point.Category and distance <= nearestDistance then
                    nearestDistance = distance
                    nearestGroup = group
                end
            end

            if nearestGroup then
                table.insert(nearestGroup.Items, point)

                -- Keep the group position centered on its members.
                local count = #nearestGroup.Items
                nearestGroup.X =
                    nearestGroup.X + (point.X - nearestGroup.X) / count
                nearestGroup.Y =
                    nearestGroup.Y + (point.Y - nearestGroup.Y) / count
            else
                table.insert(groups, {
                    X = point.X,
                    Y = point.Y,
                    Items = {point},
                    Category = point.Category,
                })
            end
        end

        for _, label in pairs(activeLabels) do
            label.Visible = false
        end

        -- Display labels.
        for index, group in ipairs(groups) do
            local label = activeLabels[index]

            if not label then
                label = createLabel()
                activeLabels[index] = label
            end

            local count = #group.Items

            if count == 1 then
                local item = group.Items[1]
                label.Text = string.format(
                    "%s\n[%dm]",
                    item.Name,
                    item.Distance
                )
                label.TextColor3 = item.Color
            else
                local totalDistance = 0

                for _, item in ipairs(group.Items) do
                    totalDistance = totalDistance + item.Distance
                end

                local averageDistance = math.floor(totalDistance / count)

                label.Text = string.format(
                    "%dx %s CLUSTERED\n[%dm]",
                    count, group.Category,
                    averageDistance
                )
                label.TextColor3 = Color3.new(1, 1, 1)
            end

            label.Position = UDim2.fromOffset(group.X, group.Y + 15)
            label.Visible = true
        end
    end)
end

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

local function updateEspButton()
    if espButton then
        espButton.Text = isEspActive and "ESP: ON" or "ESP: OFF"
        espButton.BackgroundColor3 = isEspActive
            and Color3.fromRGB(40, 125, 75)
            or Color3.fromRGB(65, 65, 75)
    end
end

local function setEspEnabled(enabled)
    if not scriptRunning or isEspActive == enabled then
        return
    end

    isEspActive = enabled
    clearOldESP()

    if enabled then
        screenGui = Instance.new("ScreenGui")
        screenGui.Name = "EspLinesOverlay"
        screenGui.IgnoreGuiInset = true
        screenGui.ResetOnSpawn = false
        screenGui.DisplayOrder = 10
        screenGui.Parent = PlayerGui

        scanAllLocations()
        startBackgroundLiveScanner()
        startEspLoop()
        showToggleMessage("CANDY / ITEMS / KEYS ESP: ENABLED", Color3.fromRGB(0, 255, 0))
    else
        showToggleMessage("CANDY / ITEMS / KEYS ESP: DISABLED", Color3.fromRGB(255, 0, 0))
    end

    updateEspButton()
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
    RunService.RenderStepped:Connect(function()
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
    rushStatus.Text = "Rush auto-hide is off"
    rushStatus.ZIndex = 36
    rushStatus.Parent = doorPanel

    doorPanel.Size = UDim2.new(0.9, 0, 0, 250)
    local rushButton = makeButton(doorPanel, "RUSH AUTO-HIDE: OFF", UDim2.new(0.5, -130, 0, 165), UDim2.fromOffset(260, 45))
    rushButton.ZIndex = 35
    rushStatus.Position = UDim2.new(0, 10, 0, 215)

    -- Optional lightweight path visualization. Parts are local-only and non-colliding.
    local pathVisualEnabled = false
    local searchVisualEnabled = false
    local rayLabelsEnabled = false
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

    -- Independent red preview: never clears the cyan player path.
    local rushRoutePreview
    local function clearRushRoutePreview()
        if rushRoutePreview then rushRoutePreview:Destroy(); rushRoutePreview = nil end
    end
    local function showRushRoutePreview(points)
        clearRushRoutePreview()
        if not pathVisualEnabled or not points or #points < 2 then return end
        local folder = Instance.new("Folder")
        folder.Name = "HackPanelSimulatedRushRoute"
        folder.Parent = workspace
        rushRoutePreview = folder
        local previous
        for i, position in ipairs(points) do
            local dot = Instance.new("Part")
            dot.Name = "RushRoute_" .. i
            dot.Shape = Enum.PartType.Ball
            dot.Size = Vector3.new(0.5, 0.5, 0.5)
            dot.Material = Enum.Material.Neon
            dot.Color = Color3.fromRGB(255, 65, 65)
            dot.Transparency = 0.15
            dot.Anchored = true
            dot.CanCollide = false
            dot.CanTouch = false
            dot.CanQuery = false
            dot.Position = position + Vector3.new(0, 0.65, 0)
            dot.Parent = folder
            if previous then
                local delta = dot.Position - previous
                if delta.Magnitude > 0.05 then
                    local line = Instance.new("Part")
                    line.Name = "RushSegment_" .. i
                    line.Anchored = true
                    line.CanCollide = false
                    line.CanTouch = false
                    line.CanQuery = false
                    line.Material = Enum.Material.Neon
                    line.Color = dot.Color
                    line.Transparency = 0.25
                    line.Size = Vector3.new(0.12, 0.12, delta.Magnitude)
                    line.CFrame = CFrame.lookAt((dot.Position + previous) * 0.5, dot.Position)
                    line.Parent = folder
                end
            end
            previous = dot.Position
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
        if not pathVisualEnabled then clearPathVisual(); clearRushRoutePreview() end
    end)


    local searchVisualButton = makeButton(hotelPages.Auto, "SHOW SEARCH: OFF", UDim2.new(0.5, -130, 0, 344), UDim2.fromOffset(260, 34))
    searchVisualButton.ZIndex = 36
    searchVisualButton.MouseButton1Click:Connect(function()
        searchVisualEnabled = not searchVisualEnabled
        searchVisualButton.Text = searchVisualEnabled and "SHOW SEARCH: ON" or "SHOW SEARCH: OFF"
        if not searchVisualEnabled then
            local folder = workspace:FindFirstChild("HackPanelLOSWholeRoomCandidates")
            if folder then folder:Destroy() end
        end
    end)

    local rayLabelsButton = makeButton(hotelPages.Auto, "RAY LABELS: OFF", UDim2.new(0.5, -130, 0, 384), UDim2.fromOffset(260, 32))
    rayLabelsButton.ZIndex = 36
    rayLabelsButton.MouseButton1Click:Connect(function()
        rayLabelsEnabled = not rayLabelsEnabled
        rayLabelsButton.Text = rayLabelsEnabled and "RAY LABELS: ON" or "RAY LABELS: OFF"
        if not rayLabelsEnabled then
            local old = workspace:FindFirstChild("HackPanelLOSRayDiagnostics")
            if old then old:Destroy() end
        end
    end)

    local autoDescription = Instance.new("TextLabel")
    autoDescription.Name = "AutoDescription"
    autoDescription.Size = UDim2.new(1, -24, 0, 28)
    autoDescription.Position = UDim2.fromOffset(12, 8)
    autoDescription.BackgroundTransparency = 1
    autoDescription.Text = "Rush assistance and door controls"
    autoDescription.TextColor3 = Color3.fromRGB(245, 225, 197)
    autoDescription.Font = Enum.Font.Gotham
    autoDescription.TextSize = 14
    autoDescription.ZIndex = 36
    autoDescription.Parent = hotelPages.Auto

    local espTabButton = makeButton(hotelPages.ESP, "ITEMS / KEYS ESP: OFF",
        UDim2.new(0.5, -155, 0, 38), UDim2.fromOffset(310, 48))
    espTabButton.ZIndex = 36
    local function refreshHotelEsp()
        espTabButton.Text = isEspActive
            and "ITEMS / KEYS ESP: ON"
            or "ITEMS / KEYS ESP: OFF"
    end
    espTabButton.MouseButton1Click:Connect(function()
        if not isEspActive then hotelEspMode = true end
        setEspEnabled(not isEspActive)
        refreshHotelEsp()
    end)

    -- Adaptive fixture night vision. A single heartbeat handles both already-dark
    -- rooms and lights that fade out while the player remains in a room.
    local nightVisionEnabled = false
    local nvGeneration = 0
    local nvRecords = {}
    local nvVisualRecords = {}
    local nvLabel = Instance.new("TextLabel")
    nvLabel.Name = "NightVisionDiagnostics"
    nvLabel.Parent = hotelPages.Essentials
    nvLabel.Position = UDim2.new(0, 12, 0, 218)
    nvLabel.Size = UDim2.new(1, -24, 0, 42)
    nvLabel.BackgroundTransparency = 1
    nvLabel.TextColor3 = Color3.fromRGB(235, 221, 195)
    nvLabel.Font = Enum.Font.Gotham
    nvLabel.TextSize = 12
    nvLabel.TextWrapped = true
    nvLabel.ZIndex = 37
    nvLabel.Text = "Night Vision: OFF"

    local function nvIsLight(obj)
        return obj:IsA("PointLight") or obj:IsA("SpotLight") or obj:IsA("SurfaceLight")
    end
    local function nvFixture(light)
        local node = light
        while node and node ~= workspace do
            if node.Name == "Window" or node.Name == "LightPanel" then return false end
            if node.Name == "Light_Fixtures" or node.Name == "Chandelier" then return true end
            node = node.Parent
        end
        return false
    end
    local function nvFallback(light)
        local parent = light.Parent
        if not parent then return nil end
        if parent.Name == "LightFixture" and light:IsA("PointLight") then return 0.3 end
        if parent.Name == "CenterAttach" then
            if light:IsA("SpotLight") then return 0.3 end
            if light:IsA("PointLight") then return 0.1 end
        end
        if parent.Name == "LightFixture" and light:IsA("SpotLight") then return 1.16 end
        return nil
    end
    local function nvRegister(light)
        if not nvIsLight(light) or not nvFixture(light) or nvRecords[light] then return end
        if not light.Enabled or light.Range <= 0 then return end
        local brightness = light.Brightness
        local fallback = nvFallback(light)
        if brightness <= 0.025 and not fallback then return end
        local fixture = light:FindFirstAncestor("LightFixture")
        local rec = {
            baseline = brightness > 0.025 and brightness or fallback,
            initialBrightness = brightness,
            lastObserved = brightness,
            lastChange = os.clock(),
            restored = false,
            broken = brightness <= 0.025,
            fixture = fixture,
        }
        nvRecords[light] = rec
    end
    local function nvVisual(fixture)
        if not fixture then return end
        for _, part in ipairs(fixture:GetDescendants()) do
            if part:IsA("BasePart") and (part.Name == "Neon" or part.Name == "Bulb") then
                local rec = nvVisualRecords[part]
                if not rec then
                    rec = {initialTransparency = part.Transparency, restored = false}
                    nvVisualRecords[part] = rec
                end
                if part.Transparency > 0.75 then
                    rec.restored = true
                    pcall(function() part.Transparency = 0.1 end)
                end
            end
        end
    end
    local function nvTick(rooms)
        local now = os.clock()
        local restoredCount = 0
        local trackedCount = 0
        -- Re-scan: existing lights may become visible after the room streams in,
        -- and already-broken fixtures may have been loaded before enabling NV.
        for _, light in ipairs(rooms:GetDescendants()) do
            if nvIsLight(light) then nvRegister(light) end
        end
        local brokenFixtures = {}
        for light, rec in pairs(nvRecords) do
            if not light.Parent or not light:IsDescendantOf(rooms) then
                nvRecords[light] = nil
            else
                trackedCount += 1
                local current = light.Brightness
                -- Treat a change from the script itself as distinct from the
                -- game's fade, so it doesn't reset the settling timer.
                if math.abs(current - rec.lastObserved) > 0.004 then
                    rec.lastObserved = current
                    rec.lastChange = now
                end
                if light.Enabled and current <= 0.025 then
                    rec.broken = true
                end
                if rec.broken and rec.fixture then brokenFixtures[rec.fixture] = true end
                -- Wait for the game's fade to settle before applying NV.
                if rec.broken and light.Enabled and rec.baseline and current <= 0.025
                    and now - rec.lastChange >= 0.8 then
                    pcall(function() light.Brightness = rec.baseline end)
                    rec.lastObserved = rec.baseline
                    rec.restored = true
                end
                if rec.restored then restoredCount += 1 end
            end
        end
        -- Keep bulbs visible even if the game hides them after restoring
        -- light brightness. Do not touch fixtures that haven't gone dark.
        for fixture in pairs(brokenFixtures) do
            if fixture.Parent then nvVisual(fixture) end
        end
        nvLabel.Text = string.format("Fixture lights: %d | restored: %d", trackedCount, restoredCount)
    end
    local function disableNightVision()
        nightVisionEnabled = false
        nvGeneration += 1
        -- Undo *only* NV modifications, returning broken lights to darkness.
        for light, rec in pairs(nvRecords) do
            if light.Parent and rec.restored then
                pcall(function()
                    light.Brightness = rec.broken and 0 or rec.initialBrightness
                end)
            end
        end
        for part, rec in pairs(nvVisualRecords) do
            if part.Parent and rec.restored then
                local fixture = part:FindFirstAncestor("LightFixture")
                local isBroken = false
                for _, lightRec in pairs(nvRecords) do
                    if lightRec.fixture == fixture and lightRec.broken then
                        isBroken = true
                        break
                    end
                end
                pcall(function()
                    part.Transparency = isBroken and 1 or rec.initialTransparency
                end)
            end
        end
        table.clear(nvRecords)
        table.clear(nvVisualRecords)
        nvLabel.Text = "Night Vision: OFF"
    end
    local function enableNightVision()
        if nightVisionEnabled then return end
        local rooms = getCurrentRooms()
        if not rooms then nvLabel.Text = "CurrentRooms not found"; return end
        nightVisionEnabled = true
        nvGeneration += 1
        local generation = nvGeneration
        task.spawn(function()
            while nightVisionEnabled and generation == nvGeneration do
                pcall(nvTick, rooms)
                task.wait(0.4)
            end
        end)
    end
    sharedEnvironment.HackPanelNightVisionCleanup = disableNightVision
    local nightButton = makeButton(hotelPages.Essentials, "NIGHT VISION: OFF",
        UDim2.new(0.5, -120, 0, 172), UDim2.fromOffset(240, 42))
    nightButton.ZIndex = 36
    nightButton.MouseButton1Click:Connect(function()
        if nightVisionEnabled then disableNightVision() else enableNightVision() end
        nightButton.Text = nightVisionEnabled and "NIGHT VISION: ON" or "NIGHT VISION: OFF"
    end)
    -- Entity ESP and independently configurable entity warnings.
    local entityList = {"Rush","Ambush","Seek","Figure","Eyes","Screech","Halt","A-60","A-90","A-120","Blitz","Haste","Vacuum","Giggle","Grumble","Dread","Lookman"}
    local aliases = {
        rush="Rush", rushmoving="Rush", rushnew="Rush", rushrig="Rush",
        ambush="Ambush", ambushmoving="Ambush", ambushrig="Ambush",
        seek="Seek", seekmoving="Seek", seekrig="Seek",
        figure="Figure", figuremoving="Figure", figurerig="Figure",
        eyes="Eyes", eyesmoving="Eyes", screech="Screech",
        halt="Halt", haltmoving="Halt", a60="A-60", a90="A-90",
        a120="A-120", blitz="Blitz", haste="Haste", vacuum="Vacuum",
        giggle="Giggle", grumble="Grumble", dread="Dread", lookman="Lookman"
    }
    local entityColors = {
        Rush=Color3.fromRGB(255,90,90), Ambush=Color3.fromRGB(80,255,130),
        Seek=Color3.fromRGB(255,180,70), Figure=Color3.fromRGB(255,80,80)
    }
    local entityEspEnabled = false
    local updateWarningMonitor -- forward declaration for UI callbacks
    local pendingWarnings, activeWarnings = {}, {}
    local entityHighlights = {}
    for _, name in ipairs(entityList) do
        pendingWarnings[name] = false
        activeWarnings[name] = false
    end

    local entityEspButton = makeButton(hotelPages.ESP, "ENTITY WALL ESP: OFF",
        UDim2.new(0.5,-155,0,103), UDim2.fromOffset(310,48))
    entityEspButton.ZIndex = 36
    local espInfo = Instance.new("TextLabel")
    espInfo.Parent = hotelPages.ESP
    espInfo.Position = UDim2.new(0,10,0,158)
    espInfo.Size = UDim2.new(1,-20,0,56)
    espInfo.BackgroundTransparency = 1
    espInfo.TextColor3 = Color3.fromRGB(230,210,190)
    espInfo.Font = Enum.Font.Gotham
    espInfo.TextSize = 12
    espInfo.TextWrapped = true
    espInfo.Text = "Entity outlines are OFF. Turn on to highlight detected live entity models through walls."
    espInfo.ZIndex = 36

    local warningStatus = Instance.new("TextLabel")
    warningStatus.Parent = hotelPages.Warnings
    warningStatus.Position = UDim2.new(0,8,1,-36)
    warningStatus.Size = UDim2.new(1,-16,0,32)
    warningStatus.BackgroundTransparency = 1
    warningStatus.TextColor3 = Color3.fromRGB(255,205,155)
    warningStatus.Font = Enum.Font.Gotham
    warningStatus.TextSize = 12
    warningStatus.TextWrapped = true
    warningStatus.Text = "Select entities to enable their warnings"
    warningStatus.ZIndex = 38

    local warningScroll = Instance.new("Frame")
    warningScroll.Name = "EntityWarningChecklist"
    warningScroll.Parent = hotelPages.Warnings
    warningScroll.Position = UDim2.new(0,8,0,46)
    warningScroll.Size = UDim2.new(1,-16,1,-94)
    warningScroll.BackgroundColor3 = Color3.fromRGB(34,29,28)
    warningScroll.BackgroundTransparency = 0.15
    warningScroll.BorderSizePixel = 0
    warningScroll.ZIndex = 37
    local warningLayout = Instance.new("UIGridLayout")
    warningLayout.Parent = warningScroll
    warningLayout.SortOrder = Enum.SortOrder.LayoutOrder
    warningLayout.CellPadding = UDim2.fromOffset(10,10)
    warningLayout.CellSize = UDim2.new(1/3,-8,1/6,-9)

    local checkButtons = {}
    local function makeCheckButton(label, order)
        local button = Instance.new("TextButton")
        button.Name = label .. "Check"
        button.Parent = warningScroll
        button.BackgroundColor3 = Color3.fromRGB(65,48,43)
        button.BorderSizePixel = 0
        button.Text = ""
        button.LayoutOrder = order
        button.ZIndex = 38
        local square = Instance.new("Frame")
        square.Name = "Checkbox"
        square.Parent = button
        square.Size = UDim2.fromOffset(19,19)
        square.Position = UDim2.new(0,7,0.5,-10)
        square.BackgroundColor3 = Color3.fromRGB(35,30,29)
        square.BorderSizePixel = 1
        square.BorderColor3 = Color3.fromRGB(190,165,145)
        square.ZIndex = 39
        local tick = Instance.new("TextLabel")
        tick.Name = "Tick"
        tick.Parent = square
        tick.Size = UDim2.fromScale(1,1)
        tick.BackgroundTransparency = 1
        tick.Font = Enum.Font.GothamBold
        tick.TextSize = 16
        tick.TextColor3 = Color3.fromRGB(120,255,160)
        tick.Text = "✓"
        tick.ZIndex = 40
        local nameLabel = Instance.new("TextLabel")
        nameLabel.Parent = button
        nameLabel.Position = UDim2.fromOffset(32,0)
        nameLabel.Size = UDim2.new(1,-35,1,0)
        nameLabel.BackgroundTransparency = 1
        nameLabel.TextXAlignment = Enum.TextXAlignment.Left
        nameLabel.Font = Enum.Font.Gotham
        nameLabel.TextSize = 16
        nameLabel.TextColor3 = Color3.fromRGB(245,232,215)
        nameLabel.Text = label
        nameLabel.ZIndex = 39
        return button
    end
    local allCheck = makeCheckButton("Select / Deselect All",0)
    allCheck.Parent = hotelPages.Warnings
    allCheck.Position = UDim2.new(0,8,0,6)
    allCheck.Size = UDim2.new(0.5,-12,0,34)
    local searchBox = Instance.new("TextBox")
    searchBox.Name = "WarningEntitySearch"
    searchBox.Parent = hotelPages.Warnings
    searchBox.Position = UDim2.new(0.5,4,0,6)
    searchBox.Size = UDim2.new(0.5,-12,0,34)
    searchBox.BackgroundColor3 = Color3.fromRGB(65,48,43)
    searchBox.BorderSizePixel = 0
    searchBox.ClearTextOnFocus = false
    searchBox.PlaceholderText = "Search entities..."
    searchBox.PlaceholderColor3 = Color3.fromRGB(175,155,140)
    searchBox.Text = ""
    searchBox.TextColor3 = Color3.fromRGB(245,232,215)
    searchBox.Font = Enum.Font.Gotham
    searchBox.TextSize = 15
    searchBox.TextXAlignment = Enum.TextXAlignment.Left
    searchBox.ZIndex = 39
    local searchPadding = Instance.new("UIPadding")
    searchPadding.PaddingLeft = UDim.new(0,10)
    searchPadding.PaddingRight = UDim.new(0,10)
    searchPadding.Parent = searchBox
    local function applyWarningSelection()
        for _, name in ipairs(entityList) do
            activeWarnings[name] = pendingWarnings[name]
        end
        warningStatus.Text = "Selections updated"
    end
    local function updateChecks()
        local allSelected = true
        for _, name in ipairs(entityList) do
            checkButtons[name].Checkbox.Tick.Visible = pendingWarnings[name]
            if not pendingWarnings[name] then allSelected = false end
        end
        allCheck.Checkbox.Tick.Visible = allSelected
    end
    for i, name in ipairs(entityList) do
        local button = makeCheckButton(name,i)
        checkButtons[name] = button
        button.MouseButton1Click:Connect(function()
            pendingWarnings[name] = not pendingWarnings[name]
            updateChecks()
            applyWarningSelection()
        end)
    end
    allCheck.MouseButton1Click:Connect(function()
        local allSelected = true
        for _, name in ipairs(entityList) do
            if not pendingWarnings[name] then allSelected = false break end
        end
        for _, name in ipairs(entityList) do pendingWarnings[name] = not allSelected end
        updateChecks()
        applyWarningSelection()
    end)
    updateChecks()

    -- Search filters visible choices without changing any checked states.
    -- Reflow the matching choices so the grid stays compact.
    local function filterWarnings()
        local query = searchBox.Text:lower():gsub("^%s+", ""):gsub("%s+$", "")
        local visibleIndex = 0
        for _, name in ipairs(entityList) do
            local button = checkButtons[name]
            local matches = query == "" or name:lower():find(query,1,true) ~= nil
            button.Visible = matches
            if matches then
                visibleIndex += 1
                button.LayoutOrder = visibleIndex
            end
        end
        -- A fixed six-row grid can leave hidden cells occupying layout space
        -- in some clients; resize rows based on visible matches.
        local rows = math.max(1, math.ceil(visibleIndex/3))
        warningLayout.CellSize = UDim2.new(1/3,-8,1/rows,-9)
    end
    searchBox:GetPropertyChangedSignal("Text"):Connect(filterWarnings)
    filterWarnings()

    -- Warnings must be visible during gameplay, not only while this tab is open.
    local alertBanner = Instance.new("TextLabel")
    alertBanner.Name = "HackPanelEntityWarningBanner"
    local playerGuiForAlerts = Players.LocalPlayer:WaitForChild("PlayerGui")
    local oldAlert = playerGuiForAlerts:FindFirstChild("HackPanelWarningsOverlay")
    if oldAlert then oldAlert:Destroy() end
    local alertGui = Instance.new("ScreenGui")
    alertGui.Name = "HackPanelWarningsOverlay"
    alertGui.ResetOnSpawn = false
    alertGui.IgnoreGuiInset = true
    alertGui.DisplayOrder = 10000
    alertGui.Enabled = true
    alertGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
    alertBanner.Parent = alertGui
    alertBanner.AnchorPoint = Vector2.new(0.5,0)
    alertBanner.Position = UDim2.new(0.5,0,0,14)
    alertBanner.Size = UDim2.new(0,440,0,36)
    -- Warnings are plain text. The bordered box belongs to the entity
    -- info panel (name / distance / movement), NOT to this message.
    alertBanner.BackgroundTransparency = 1
    alertBanner.TextColor3 = Color3.fromRGB(255,210,190)
    alertBanner.TextStrokeColor3 = Color3.fromRGB(15,10,10)
    alertBanner.TextStrokeTransparency = 0.15
    alertBanner.Font = Enum.Font.GothamBold
    alertBanner.TextSize = 19
    alertBanner.ZIndex = 100
    alertBanner.Visible = false
    local function getEntityName(obj)
        if not (obj:IsA("Model") or obj:IsA("BasePart")) then return nil end
        local normalized = obj.Name:lower():gsub("[^%w]","")
        if aliases[normalized] then return aliases[normalized] end
        -- Variants sometimes add a suffix (e.g. RushMoving, AmbushRig).
        for _, prefix in ipairs({"rush","ambush","seek","figure","eyes","screech","halt","giggle","grumble","blitz","haste","dread","lookman"}) do
            if normalized:sub(1,#prefix) == prefix then
                return prefix:sub(1,1):upper() .. prefix:sub(2)
            end
        end
        return nil
    end
    local function clearHighlight(obj)
        local h = entityHighlights[obj]
        if h then
            if type(h) == "table" then
                for _, box in ipairs(h) do pcall(function() box:Destroy() end) end
            else
                pcall(function() h:Destroy() end)
            end
        end
        entityHighlights[obj] = nil
    end
    -- Entity labels, distance meter and screen-space tracers.
    local entityHud = Instance.new("ScreenGui")
    entityHud.Name = "HackPanelEntityHUD"
    entityHud.IgnoreGuiInset = true
    entityHud.ResetOnSpawn = false
    entityHud.DisplayOrder = 950
    entityHud.Parent = PlayerGui
    local entityHudItems = {}
    -- Live warning state is shared with the ESP renderer. A checked box alone
    -- must not pin an absent entity to the top of the screen.
    local warningPresent = {}
    -- Rush motion tracking: spawn does not necessarily mean an attack is underway.
    local rushMotion = {}
    local function getEntityPart(obj)
        if obj:IsA("BasePart") then return obj end
        return obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart", true)
    end
    -- Both ESP labels have the same boxed styling. One tracks the entity;
    -- an additional top-screen copy only appears for a selected LIVE warning.
    local function createEntityInfoBox(parent, color, labelName)
        local label = Instance.new("TextLabel")
        label.Name = labelName
        label.BackgroundColor3 = Color3.fromRGB(30,20,20)
        label.BackgroundTransparency = 0.13
        label.BorderSizePixel = 0
        label.TextColor3 = color
        label.TextStrokeColor3 = Color3.fromRGB(5,5,5)
        label.TextStrokeTransparency = 1
        label.Font = Enum.Font.Gotham
        label.TextSize = 16
        label.TextScaled = false
        label.Size = UDim2.fromOffset(295,42)
        label.AnchorPoint = Vector2.new(0.5,1)
        label.ZIndex = 110
        label.Visible = false
        label.Parent = parent
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0,6)
        corner.Parent = label
        local stroke = Instance.new("UIStroke")
        stroke.Color = color
        stroke.Thickness = 1.5
        stroke.Transparency = 0.15
        -- Border-only stroke: do not outline/glow the label's text.
        stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        stroke.Parent = label
        return label
    end
    local function newEntityHud(obj, name)
        local color = entityColors[name] or Color3.fromRGB(195,115,255)
        local label = createEntityInfoBox(entityHud,color,"EntityNameDistance")
        local topLabel = createEntityInfoBox(alertGui,color,"TopEntityNameDistance")
        local tracer = Instance.new("Frame")
        tracer.Name = "EntityTracer"
        tracer.BorderSizePixel = 0
        tracer.BackgroundColor3 = color
        tracer.AnchorPoint = Vector2.new(0.5,0.5)
        tracer.ZIndex = 98
        tracer.Parent = entityHud
        entityHudItems[obj] = {label=label, topLabel=topLabel, tracer=tracer, name=name}
    end
    local function removeEntityHud(obj)
        local hud = entityHudItems[obj]
        if not hud then return end
        for _, gui in ipairs({hud.label,hud.topLabel,hud.tracer}) do gui:Destroy() end
        rushMotion[obj] = nil
        entityHudItems[obj] = nil
    end
    local lastAmbushSample = 0
    local entityHudConnection = RunService.RenderStepped:Connect(function()
        local sampleAmbush = os.clock() - lastAmbushSample >= 0.08
        if sampleAmbush then lastAmbushSample = os.clock() end
        local camera = workspace.CurrentCamera
        if not camera then return end
        local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        local vp = camera.ViewportSize
        local topLabelIndex = 0
        for obj,hud in pairs(entityHudItems) do
            local part = obj.Parent and getEntityPart(obj)
            -- Sample Ambush at most ~12 times per second, using the already
            -- resolved part; avoid costly GetPivot calls every rendered frame.
            if sampleAmbush and hud.name == "Ambush" and part and part.Parent then
                local now = os.clock()
                local position = part.Position
                local state = rushMotion[obj]
                if not state then
                    rushMotion[obj] = {position=position, time=now, moving=false}
                else
                    if (position - state.position).Magnitude > 0.001 then
                        state.moving = true
                        state.lastMoved = now
                    else
                        -- Short hold so rebounds switch back to WAITING promptly.
                        state.moving = state.lastMoved ~= nil and (now - state.lastMoved < 0.18)
                    end
                    state.position = position
                    state.time = now
                end
            end
            if not entityEspEnabled or not part or not part.Parent then
                hud.label.Visible = false
                hud.topLabel.Visible = false
                hud.tracer.Visible = false
            else
                local worldPosition = part.Position
                if obj:IsA("Model") then
                    local ok, cf = pcall(function() return obj:GetBoundingBox() end)
                    if ok then worldPosition = cf.Position end
                end
                local projected, onScreen = camera:WorldToViewportPoint(worldPosition)
                local visible = onScreen and projected.Z > 0
                -- Independent warnings: both ESP and this entity's confirmed
                -- warning must be active. The entity must actually be present.
                local topLabel = activeWarnings[hud.name] == true
                    and warningPresent[hud.name] ~= nil
                    and alertBanner.Visible
                hud.label.Visible = visible
                hud.topLabel.Visible = topLabel
                hud.tracer.Visible = visible
                if visible or topLabel then
                    local distance = root and (root.Position-worldPosition).Magnitude or 0
                    local motionText = ""
                    if hud.name == "Rush" or hud.name == "Ambush" then
                        local state = rushMotion[obj]
                        motionText = (state and state.moving) and "  |  MOVING" or "  |  WAITING"
                    end
                    local infoText = string.format("%s  |  %d studs%s",hud.name,math.floor(distance+0.5),motionText)
                    hud.label.Text = infoText
                    hud.topLabel.Text = infoText
                    -- Keep the ESP box next to the entity ALWAYS when ESP is ON.
                    if visible then
                        hud.label.Position = UDim2.fromOffset(projected.X, projected.Y+46)
                    end
                    -- If both ESP and its warning are active, show a SECOND
                    -- copy below the plain-text warning at the top.
                    if topLabel then
                        topLabelIndex += 1
                        hud.topLabel.AnchorPoint = Vector2.new(0.5,0)
                        hud.topLabel.Position = UDim2.fromOffset(vp.X/2,64+(topLabelIndex-1)*47)
                    end
                    if visible then
                        local from = UserInputService:GetMouseLocation()
                        local to = Vector2.new(projected.X,projected.Y)
                        local diff = to-from
                        hud.tracer.Position = UDim2.fromOffset((from.X+to.X)/2,(from.Y+to.Y)/2)
                        hud.tracer.Size = UDim2.fromOffset(diff.Magnitude,2)
                        hud.tracer.Rotation = math.deg(math.atan2(diff.Y,diff.X))
                    end
                end
            end
        end
    end)
    local lastSeen = {}
    local function refreshEntities()
        local found, present = {}, {}
        local function inspect(obj)
            local name = getEntityName(obj)
            if not name or obj:IsDescendantOf(Players) then return end
            if obj:IsA("Model") and not obj:FindFirstChildWhichIsA("BasePart",true) then return end
            -- Ignore prefabs in common storage/template folders.
            local ancestor = obj.Parent
            while ancestor and ancestor ~= workspace do
                if ancestor.Name == "EntityInfo" or ancestor.Name == "EntityTemplates"
                    or ancestor.Name == "EntityStorage" then return end
                if getEntityName(ancestor) then return end
                ancestor = ancestor.Parent
            end
            if name == "Rush" then
                local rushPart = getEntityPart(obj)
                if rushPart then
                    for _, candidate in ipairs(workspace:GetDescendants()) do
                        if candidate ~= obj and getEntityName(candidate) == "Ambush" then
                            local ambushPart = getEntityPart(candidate)
                            if ambushPart and (rushPart.Position - ambushPart.Position).Magnitude < 5 then
                                return
                            end
                        end
                    end
                end
            end
            found[obj] = true
            present[name] = true
            -- Track Rush continuously, including with ESP on, and while offscreen.
            -- Any measurable movement counts: no speed threshold or delay.
            if name == "Rush" then
                local part = getEntityPart(obj)
                if part then
                    local now = os.clock()
                    local position = part.Position
                    if obj:IsA("Model") then
                        local ok, pivot = pcall(function() return obj:GetPivot() end)
                        if ok then position = pivot.Position end
                    end
                    local state = rushMotion[obj]
                    if not state then
                        rushMotion[obj] = {position=position, time=now, moving=false}
                    else
                        local displacement = (position-state.position).Magnitude
                        -- Tiny epsilon filters floating-point jitter, not gameplay movement.
                        if displacement > 0.001 then
                            state.moving = true
                            state.lastMoved = now
                        else
                            state.moving = state.lastMoved ~= nil and (now - state.lastMoved < 1.5)
                        end
                        state.position = position
                        state.time = now
                    end
                end
            end
            if entityEspEnabled and not entityHighlights[obj] then
                -- Keep the proven 3D red entity boxes with ESP regardless of
                -- Warnings selection. The top INFO box is a separate overlay.
                -- Rushmoving and other DOORS entities can use invisible parts,
                -- so a Highlight alone may never draw. Adorn the actual parts
                -- with always-on-top 3D boxes instead.
                local boxes = {}
                local function adorn(part)
                    if not part:IsA("BasePart") or #boxes >= 32 then return end
                    local box = Instance.new("BoxHandleAdornment")
                    box.Name = "HackPanelEntityBox"
                    box.Adornee = part
                    box.Size = part.Size + Vector3.new(0.18, 0.18, 0.18)
                    box.CFrame = CFrame.new()
                    box.AlwaysOnTop = true
                    box.ZIndex = 10
                    box.Transparency = 0.35
                    box.Color3 = entityColors[name] or Color3.fromRGB(195,115,255)
                    box.Parent = workspace.CurrentCamera or workspace
                    table.insert(boxes, box)
                end
                if obj:IsA("BasePart") then
                    adorn(obj)
                else
                    for _, part in ipairs(obj:GetDescendants()) do
                        adorn(part)
                    end
                end
                if #boxes > 0 then entityHighlights[obj] = boxes end
            end
        end
        if entityEspEnabled then
            for _, obj in ipairs(workspace:GetDescendants()) do
                if getEntityName(obj) then inspect(obj) end
            end
        end
        for obj in pairs(entityHighlights) do
            if not entityEspEnabled or not found[obj] then clearHighlight(obj) end
        end
        for obj in pairs(entityHudItems) do
            if not entityEspEnabled or not found[obj] then removeEntityHud(obj) end
        end
        for obj in pairs(rushMotion) do
            if not found[obj] then rushMotion[obj] = nil end
        end
        if entityEspEnabled then
            for obj in pairs(found) do
                if entityHighlights[obj] and not entityHudItems[obj] then
                    newEntityHud(obj, getEntityName(obj) or obj.Name)
                end
            end
        end
        local count = 0
        for _ in pairs(found) do count += 1 end
        local namesFound = {}
        for obj in pairs(found) do
            table.insert(namesFound, obj.Name)
            if #namesFound >= 4 then break end
        end
        espInfo.Text = entityEspEnabled
            and ("Entity Wall ESP ON | detected: " .. count
                .. " | " .. table.concat(namesFound, ", "))
            or "Entity Wall ESP is OFF."
        -- Warning detection runs in its own loop below, never through ESP.

    end
    -- Independent warnings monitor. No ESP toggle, box, HUD, or motion
    -- state is required for an entity to generate an alert.
    -- One workspace traversal per warning refresh (previously up to THREE).
    -- A modest refresh interval avoids costly full-world scans on every tick.
    local warningRushPositions = {}
    local lastWarningScan = 0
    updateWarningMonitor = function()
        local anySelected = false
        for _, name in ipairs(entityList) do
            if activeWarnings[name] then anySelected = true break end
        end
        if not anySelected then
            alertBanner.Visible = false
            warningStatus.Text = "No warnings selected — check entities above"
            table.clear(warningPresent)
            table.clear(warningRushPositions)
            return
        end
        local detected, rushPositions, ambushPositions = {}, {}, {}
        local seen = {}
        local objects = workspace:GetDescendants()
        for _, obj in ipairs(objects) do
            local name = getEntityName(obj)
            if name and activeWarnings[name] and not obj:IsDescendantOf(Players) then
                local isLive = true
                local parent = obj.Parent
                while parent and parent ~= workspace do
                    if parent.Name == "EntityInfo" or parent.Name == "EntityTemplates"
                        or parent.Name == "EntityStorage" or getEntityName(parent) then
                        isLive = false
                        break
                    end
                    parent = parent.Parent
                end
                if isLive and (obj:IsA("BasePart") or obj:FindFirstChildWhichIsA("BasePart",true)) then
                    seen[obj] = true
                    local moving = false
                    if name == "Rush" or name == "Ambush" then
                        local part = getEntityPart(obj)
                        if part then
                            local pos = part.Position
                            local previous = warningRushPositions[obj]
                            moving = previous ~= nil and (pos-previous).Magnitude > 0.001
                            warningRushPositions[obj] = pos
                            if name == "Rush" then
                                table.insert(rushPositions,pos)
                            else
                                table.insert(ambushPositions,pos)
                            end
                        end
                    end
                    local status = (name == "Rush" or name == "Ambush")
                        and (moving and "MOVING" or "WAITING") or "DETECTED"
                    if not detected[name] or status == "MOVING" then detected[name] = status end
                end
            end
        end
        for obj in pairs(warningRushPositions) do
            if not seen[obj] then warningRushPositions[obj] = nil end
        end
        -- Ignore Rush when it shares Ambush's location; no extra world scan.
        if detected.Rush and #ambushPositions > 0 and #rushPositions > 0 then
            local independentRush = false
            for _, rushPos in ipairs(rushPositions) do
                local overlaps = false
                for _, ambushPos in ipairs(ambushPositions) do
                    if (rushPos-ambushPos).Magnitude < 5 then overlaps = true break end
                end
                if not overlaps then independentRush = true break end
            end
            if not independentRush then detected.Rush = nil end
        end
        local messages = {}
        for _, name in ipairs(entityList) do
            if activeWarnings[name] and detected[name] then
                table.insert(messages, name .. " Is Coming")
            end
        end
        alertBanner.Visible = #messages > 0
        if #messages > 0 then
            alertBanner.Text = "⚠ " .. table.concat(messages," | ")
            warningStatus.Text = "WARNING: " .. table.concat(messages," | ")
        else
            warningStatus.Text = "Monitoring selected entities — none detected"
        end
        warningPresent = detected
    end
    task.spawn(function()
        while menuGui and menuGui.Parent do
            local ok, err = pcall(updateWarningMonitor)
            if not ok then
                warningStatus.Text = "Warning monitor error: " .. tostring(err):sub(1,110)
            end
            task.wait(0.65)
        end
        alertBanner.Visible = false
        if alertGui.Parent then alertGui:Destroy() end
    end)
    entityEspButton.MouseButton1Click:Connect(function()
        entityEspEnabled = not entityEspEnabled
        entityEspButton.Text = entityEspEnabled and "ENTITY WALL ESP: ON" or "ENTITY WALL ESP: OFF"
        refreshEntities()
    end)
    task.spawn(function()
        while menuGui and menuGui.Parent do
            local ok, err = pcall(refreshEntities)
            if not ok then
                espInfo.Text = "ESP error: " .. tostring(err):sub(1,140)
                -- ESP errors must not overwrite the independent warning status.
                espInfo.Text = "ESP detection error: " .. tostring(err):sub(1,140)
            end
            task.wait(0.6)
        end
        for obj in pairs(entityHighlights) do clearHighlight(obj) end
        for obj in pairs(entityHudItems) do removeEntityHud(obj) end
        entityHudConnection:Disconnect()
        entityHud:Destroy()
        alertGui:Destroy()
    end)
    showHotelTab("Auto")

    -- Manual navigation diagnostics. These do not spawn a real Rush.
    local debugMode = nil
    local debugRushOrigin = nil
    local function navigationActive(generation)
        return (rushAutoEnabled or debugMode ~= nil) and rushGeneration == generation
    end

    local function rushModel()
        -- Rush typically spawns in workspace, but variants can be named RushMoving.
        for _, child in ipairs(workspace:GetChildren()) do
            local n = child.Name:lower()
            if (n == "rushmoving" or n == "rush" or n == "rushnew")
                and (child:IsA("Model") or child:IsA("BasePart")) then
                return child
            end
        end
        return nil
    end

    local function closetCandidates(origin)
        -- Search the current room and the two numerically adjacent loaded rooms.
        -- This avoids scanning the whole workspace or all loaded rooms.
        local current, number = getCurrentRoom()
        local rooms = getCurrentRooms()
        if not rooms or not current then return {} end
        local searchRooms = {current}
        if number then
            for _, offset in ipairs({-1, 1}) do
                local adjacent = rooms:FindFirstChild(tostring(number + offset))
                if adjacent and adjacent:IsA("Model") then
                    table.insert(searchRooms, adjacent)
                end
            end
        end
        local candidates, seen = {}, {}
        for _, room in ipairs(searchRooms) do
            for _, obj in ipairs(room:GetDescendants()) do
                if obj:IsA("Model") then
                    local name = obj.Name:lower()
                    if name:find("wardrobe", 1, true) or name:find("closet", 1, true) then
                        local prompt = obj:FindFirstChildWhichIsA("ProximityPrompt", true)
                        if prompt and prompt.Enabled and not seen[prompt] then
                            seen[prompt] = true
                            local holder = prompt.Parent
                            local pos = holder:IsA("Attachment") and holder.WorldPosition
                                or (holder:IsA("BasePart") and holder.Position)
                                or obj:GetPivot().Position
                            local distance = (pos - origin).Magnitude
                            if distance <= 110 then
                                table.insert(candidates, {model=obj, prompt=prompt, position=pos, distance=distance, room=room, currentRoom=(room == current)})
                            end
                        end
                    end
                end
            end
        end
        table.sort(candidates, function(x,y) return x.distance < y.distance end)
        return candidates
    end

    -- Movement through the local PlayerModule, with Player:Move fallback.
    -- Applied after Roblox's ordinary control update each frame.
    local function getPlayerControls()
        local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
        local module = playerScripts and playerScripts:FindFirstChild("PlayerModule")
        if not module then return nil end
        local ok, result = pcall(function() return require(module):GetControls() end)
        return ok and result or nil
    end

    local function walkToCloset(candidate, generation)
        local character = LocalPlayer.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if not humanoid or not root then return false, "Character not ready" end
        if humanoid.Health <= 0 or humanoid.PlatformStand or humanoid.Sit then
            return false, "Movement disabled (seated / downed)"
        end

        local position = candidate.position
        local range = candidate.prompt.MaxActivationDistance
        local acceptable = math.max(2, range - 0.25)
        local function closeEnough()
            -- ProximityPrompt distance is measured from the prompt's actual
            -- world position, not from the wardrobe model's center.
            local parent = candidate.prompt.Parent
            local promptPosition = parent and parent:IsA("Attachment") and parent.WorldPosition
                or (parent and parent:IsA("BasePart") and parent.Position)
                or position
            return (root.Position - promptPosition).Magnitude <= acceptable
        end
        if closeEnough() then return true end

        -- Lightweight pathfinding: at most two path calculations per approach.
        -- Never use a straight-line fallback through walls or furniture.
        local delta = root.Position - position
        local direction = Vector3.new(delta.X, 0, delta.Z)
        if direction.Magnitude < 0.1 then direction = Vector3.new(0, 0, 1) end
        direction = direction.Unit
        local radius = math.max(1.5, math.min(3, acceptable - 0.6))
        local approaches = {
            position + direction * radius,
            position - direction * radius,
        }
        local waypoints
        for _, target in ipairs(approaches) do
            if not navigationActive(generation) then
                return false, "Cancelled"
            end
            local ok, path = pcall(function()
                local result = PathfindingService:CreatePath({
                    AgentRadius = 1.5, AgentHeight = 5,
                    AgentCanJump = true, WaypointSpacing = 3
                })
                result:ComputeAsync(root.Position, target)
                return result
            end)
            if ok and path and path.Status == Enum.PathStatus.Success then
                waypoints = path:GetWaypoints()
                break
            end
            task.wait(0.1)
        end
        if not waypoints then
            return false, "No safe path to closet (not walking through walls)"
        end

        showPathVisual(waypoints, "CLOSET")

        local renderName = "HackPanelRushWalk"
        local moveDirection = Vector3.zero
        local movementActive = true
        pcall(function() RunService:UnbindFromRenderStep(renderName) end)
        RunService:BindToRenderStep(renderName, Enum.RenderPriority.Input.Value + 2, function()
            if movementActive and humanoid.Parent and humanoid.Health > 0 then
                humanoid:Move(moveDirection, false) -- WORLD space; independent of camera direction
            end
        end)
        local function stopMoving()
            movementActive = false
            moveDirection = Vector3.zero
            pcall(function() RunService:UnbindFromRenderStep(renderName) end)
            pcall(function() humanoid:Move(Vector3.zero, false) end)
        end

        local function runPath()
            local initialPosition = root.Position
            for _, waypoint in ipairs(waypoints) do
                if not navigationActive(generation) then return false, "Cancelled" end
                if closeEnough() then return true end
                if waypoint.Action == Enum.PathWaypointAction.Jump then humanoid.Jump = true end
                local started = os.clock()
                local lastPosition = root.Position
                local stuckSince = started
                while os.clock() - started < 6 do
                    if closeEnough() then return true end
                    if not navigationActive(generation) then return false, "Cancelled" end
                    if humanoid.Health <= 0 then return false, "Character died" end
                    local displacement = waypoint.Position - root.Position
                    local flat = Vector3.new(displacement.X, 0, displacement.Z)
                    if flat.Magnitude < 2.5 then break end
                    moveDirection = flat.Unit
                    if (root.Position - lastPosition).Magnitude > 0.5 then
                        lastPosition = root.Position
                        stuckSince = os.clock()
                    elseif os.clock() - stuckSince > 2 then
                        local reason = (root.Position - initialPosition).Magnitude < 0.5
                            and "PlayerModule movement blocked" or "Path blocked near closet"
                        return false, reason
                    end
                    task.wait(0.06)
                end
            end
            return closeEnough(), "Could not get within prompt range"
        end

        local succeeded, reached, reason = pcall(runPath)
        stopMoving() -- always release automatic movement, including errors/cancellation
        if not succeeded then return false, "Movement error: " .. tostring(reached):sub(1, 80) end
        return reached, reason
    end

    local function isActuallyHiding()
        local character = LocalPlayer.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        if not character or not humanoid then return false end
        -- DOORS versions can expose different replicated hiding flags.
        for _, obj in ipairs({character, humanoid}) do
            for _, attribute in ipairs({"Hiding", "IsHiding", "InCloset", "IsInCloset"}) do
                if obj:GetAttribute(attribute) == true then return true end
            end
        end
        local hidden = character:FindFirstChild("Hiding", true)
        if hidden and hidden:IsA("BoolValue") and hidden.Value then return true end
        return humanoid.Sit -- some hiding interactions seat the player
    end

    local function tryHide(candidate, generation)
        local prompt = candidate.prompt
        if not prompt or not prompt.Parent or not prompt.Enabled then
            return false, "Closet prompt unavailable"
        end
        local character = LocalPlayer.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        local camera = workspace.CurrentCamera
        if not root or not camera then return false, "Character/camera not ready" end

        local holder = prompt.Parent
        local targetPosition = holder:IsA("Attachment") and holder.WorldPosition
            or (holder:IsA("BasePart") and holder.Position) or candidate.position
        if (root.Position - targetPosition).Magnitude > prompt.MaxActivationDistance + 0.5 then
            return false, "Not within closet interaction range"
        end

        -- Camera controllers may overwrite a one-time CFrame assignment every frame.
        -- Lock the camera aim AFTER the standard camera update while interacting.
        local cameraBinding = "HackPanelRushAim"
        local oldCameraType = camera.CameraType
        local oldCameraSubject = camera.CameraSubject
        local oldCameraCFrame = camera.CFrame
        local function aimAtCloset()
            local current = workspace.CurrentCamera
            if not current then return end
            local eye = current.CFrame.Position
            if (eye - targetPosition).Magnitude < 0.5 then
                eye = root.Position + Vector3.new(0, 1.5, 0)
            end
            current.CameraType = Enum.CameraType.Scriptable
            current.CFrame = CFrame.lookAt(eye, targetPosition)
        end
        local function restoreCamera()
            pcall(function() RunService:UnbindFromRenderStep(cameraBinding) end)
            local current = workspace.CurrentCamera
            if current then
                current.CameraType = oldCameraType
                current.CameraSubject = oldCameraSubject
                if oldCameraType == Enum.CameraType.Scriptable then
                    current.CFrame = oldCameraCFrame
                end
            end
        end
        pcall(function() RunService:UnbindFromRenderStep(cameraBinding) end)
        RunService:BindToRenderStep(cameraBinding, Enum.RenderPriority.Camera.Value + 10, aimAtCloset)
        aimAtCloset()
        rushStatus.Text = "At closet - aiming at E prompt..."
        task.wait(0.05)

        local function sendE(down)
            local keyFunction = down and keypress or keyrelease
            if type(keyFunction) == "function" then
                local ok = pcall(keyFunction, 0x45)
                if ok then return true end
            end
            return pcall(function()
                game:GetService("VirtualInputManager"):SendKeyEvent(down, Enum.KeyCode.E, false, game)
            end)
        end

        local succeeded = false
        local attempted = false
        for attempt = 1, 2 do
            if not rushAutoEnabled or rushGeneration ~= generation then
                restoreCamera()
                return false, "Cancelled"
            end
            if not prompt.Parent or not prompt.Enabled then break end
            rushStatus.Text = "At closet - holding E (attempt " .. attempt .. ")"
            -- Native ProximityPrompt input methods, plus E as an alternative.
            -- InputHoldBegin/End may work even when executor key injection doesn't.
            local holdOk = pcall(function() prompt:InputHoldBegin() end)
            local keyOk = sendE(true)
            attempted = attempted or holdOk or keyOk
            local holdTime = math.max(0.1, prompt.HoldDuration + 0.05)
            local deadline = os.clock() + holdTime
            while os.clock() < deadline do
                if isActuallyHiding() then succeeded = true; break end
                if not rushAutoEnabled or rushGeneration ~= generation then break end
                task.wait(0.05)
            end
            pcall(function() prompt:InputHoldEnd() end)
            if keyOk then sendE(false) end
            if succeeded then break end
            -- If the normal prompt methods didn't work, try the executor's
            -- optional proximity prompt helper on the second attempt.
            if attempt == 2 and type(fireproximityprompt) == "function" then
                pcall(function() fireproximityprompt(prompt) end)
                attempted = true
            end
            local waitUntil = os.clock() + 0.15
            while os.clock() < waitUntil do
                if isActuallyHiding() then succeeded = true; break end
                task.wait(0.05)
            end
            if succeeded then break end
        end
        restoreCamera()
        if succeeded then return true end
        return false, attempted and "E attempted; closet did not confirm hiding" or "No supported E input method"
    end

    -- Tune these distances for the particular DOORS Rush variant.
    -- Distances are studs from Rush's physical model to the local player.
    local RUSH_ENTER_DISTANCE = 95 -- start interaction sooner to account for camera aim and E hold
    local RUSH_SAFE_DISTANCE = 110
    local RUSH_SAFE_SECONDS = 2.0
    local RUSH_MISSING_SECONDS = 2.5
    local rushHiddenByAutomation = false
    local rushHidingCandidate = nil

    local function rushDistance()
        local rush = rushModel()
        if not rush then return nil end
        local character = LocalPlayer.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if not root then return nil end
        local position
        if rush:IsA("BasePart") then
            position = rush.Position
        elseif rush:IsA("Model") then
            local ok, pivot = pcall(function() return rush:GetPivot() end)
            if ok then position = pivot.Position end
        end
        return position and (position - root.Position).Magnitude or nil
    end

    local function leaveCloset(candidate)
        rushStatus.Text = "Rush passed - holding W to leave closet..."
        -- In DOORS the closet exit is triggered by forward INPUT, not by
        -- setting a world-space Humanoid movement vector. Keep issuing W
        -- until hiding clears, with a bounded retry window.
        local vim = game:GetService("VirtualInputManager")
        local function sendW(down)
            local keyFn = down and keypress or keyrelease
            if type(keyFn) == "function" then
                local ok = pcall(keyFn, 0x57)
                if ok then return true end
            end
            return pcall(function()
                vim:SendKeyEvent(down, Enum.KeyCode.W, false, game)
            end)
        end
        local controls = getPlayerControls()
        local start = os.clock()
        local exited = false
        local initialHiding = isActuallyHiding()
        -- Some versions don't expose a hiding flag; retry a few times even
        -- when the state cannot be confirmed.
        for attempt = 1, 5 do
            if not rushAutoEnabled then break end
            sendW(true)
            local untilTime = os.clock() + 0.45
            while os.clock() < untilTime do
                if controls then
                    pcall(function() controls:move(Vector3.new(0, 0, -1), true) end)
                end
                task.wait(0.05)
                if initialHiding and not isActuallyHiding() then
                    exited = true
                    break
                end
            end
            sendW(false)
            if controls then pcall(function() controls:move(Vector3.zero, true) end) end
            if exited then break end
            task.wait(0.12)
        end
        sendW(false)
        if controls then pcall(function() controls:move(Vector3.zero, true) end) end
        task.wait(0.2)
        if exited or (initialHiding and not isActuallyHiding()) then
            rushStatus.Text = "Rush passed - exited closet"
        elseif isActuallyHiding() then
            rushStatus.Text = "Rush passed - still hiding; press W manually"
        else
            rushStatus.Text = "Rush passed - forward exit attempted (unconfirmed)"
        end
    end

    local coverCrouchActive = false
    -- Emergency line-of-sight cover when no reachable closet is available.
    -- This is a best-effort fallback: DOORS may use additional hit checks.
    local function rushPosition()
        if debugMode == "LOS" then return debugRushOrigin end
        local rush = rushModel()
        if not rush then return nil end
        if rush:IsA("BasePart") then return rush.Position end
        local ok, cf = pcall(function() return rush:GetPivot() end)
        return ok and cf.Position or nil
    end

    -- LOS tests must reject the floor, ceilings, trim, plants and tiny props.
    -- A ray hitting the ground before a low target is NOT proof of safe cover.
    -- Decorative models can contain opaque, collidable parts with generic names.
    -- Reject the entire ancestry, not only the individual raycast hit.
    local function isDecorativeCover(part)
        local node = part
        while node and node ~= workspace do
            local name = node.Name:lower()
            for _, word in ipairs({"plant", "leaf", "leaves", "foliage", "bush", "tree", "shrub", "pot", "vase", "flower", "carpet", "rug", "glass", "window", "luggage", "cart", "suitcase", "decoration", "ornament", "bookshelf", "bookcase", "shelf", "books", "picture", "painting", "wardrobe", "cabinet", "dresser", "drawer", "desk", "table", "chair", "sofa", "couch", "bedframe", "closet", "locker"}) do
                if name:find(word, 1, true) then return true end
            end
            node = node.Parent
        end
        return false
    end

    -- Physically-based LOS obstruction checking. The old version needed a
    -- raycast to hit a large collidable, named wall. That failed on DOORS
    -- modular wall geometry (including non-queryable collision panels) and
    -- rejected virtually every room as "no structural occlusion".
    -- Decorative objects, door leaves and thin props never count as cover.
    local losStructuralParts = {}
    local losStructuralRoom = nil
    local losRayDiagnostics = {hits = 0, boxed = 0, unblocked = 0}

    -- Accept ACTUAL room-shell geometry on a sightline, not just a part whose
    -- name happens to contain "Wall". DOORS commonly calls wall meshes "Main"
    -- and "Darker". A successful raycast intersects actual triangles, so a
    -- solid room mesh can safely count even if its bounding box is thick.
    -- A bounding box alone must NEVER count for a queryable MeshPart or Union:
    -- its bounding box may span an open doorway.
    local function isStructuralCover(part)
        if not part or not part:IsA("BasePart") or isDecorativeCover(part) then
            return false
        end
        -- Physically real or visible geometry only; unanchored objects are
        -- typically furniture, movable props, or entities, not room walls.
        if not part.Anchored then return false end
        local visible = part.Transparency < 0.82
        local solidPanel = part:IsA("Part") and part.Shape == Enum.PartType.Block
            and part.CanCollide
        if not visible and not solidPanel then return false end

        local node = part
        local namedWall = false
        local roomShell = false
        while node and node ~= workspace do
            local n = node.Name:lower()
            -- Prevent cover from floors, roof edges, doors or decor, even if
            -- these have broad bounds. A doorframe does not imply a safe room.
            if n:find("ceiling", 1, true) or n:find("roof", 1, true)
                or n:find("floor", 1, true) or n:find("carpet", 1, true)
                or n:find("stair", 1, true) or n:find("railing", 1, true)
                or n:find("curtain", 1, true) or n:find("trim", 1, true)
                or n:find("doorleaf", 1, true) or n:find("furniture", 1, true)
                or n:find("decoration", 1, true) or n == "door"
                or n == "gate" then
                return false
            end
            if n:find("wall", 1, true) or n:find("pillar", 1, true)
                or n:find("column", 1, true) or n:find("partition", 1, true)
                or n:find("chimney", 1, true) then
                namedWall = true
            end
            if n == "main" or n == "darker" or n == "walls" or n == "wallmain" then
                roomShell = true
            end
            node = node.Parent
        end

        local sx, sy, sz = part.Size.X, part.Size.Y, part.Size.Z
        local horizontalSpan = math.max(sx, sz)
        local thickness = math.min(sx, sz)
        -- Stacked wall boards need not be character-height individually.
        -- All six body rays and neighboring candidate tests must still find
        -- real obstructions; one board does not guarantee a safe spot.
        if namedWall then
            return sy >= 0.65 and horizontalSpan >= 1.6
        end
        -- The old rule rejected "Main" / "Darker" wall panels even after
        -- a horizontal RAYCAST actually HIT them. Don't equate unknown names
        -- with open air. Still require panel-like dimensions.
        if roomShell then
            return (visible or solidPanel) and sy >= 0.6 and horizontalSpan >= 2.0
        end
        -- Real ray-hit meshes/unions can have thick bounding boxes because
        -- their geometry contains wall corners or surrounds room openings.
        -- The raycast, not the bounding box, decides whether sight is blocked.
        if (part:IsA("MeshPart") or part:IsA("UnionOperation")) and visible then
            return sy >= 2.4 and horizontalSpan >= 3.5
        end
        -- Anonymous ordinary Parts: restrict to tall, thin wall panels.
        if sy >= 3.2 and horizontalSpan >= 4.0 and thickness <= 3.25 then
            return visible or solidPanel
        end
        return false
    end

    local function refreshLOSStructuralParts(room)
        if losStructuralRoom == room then return end
        losStructuralRoom = room
        table.clear(losStructuralParts)
        losRayDiagnostics = {hits = 0, boxed = 0, unblocked = 0}
        if not room then return end
        for _, part in ipairs(room:GetDescendants()) do
            if isStructuralCover(part) then
                table.insert(losStructuralParts, part)
            end
        end
    end

    -- Line-segment intersection with an oriented rectangular wall panel.
    -- This is a LIMITED fallback for non-queryable ordinary Roblox Parts.
    -- Never use mesh/union bounding boxes: a mesh can have a doorway hole
    -- despite a bounding box covering that hole.
    local function segmentHitsWallPanel(startPos, endPos, part)
        local p0 = part.CFrame:PointToObjectSpace(startPos)
        local p1 = part.CFrame:PointToObjectSpace(endPos)
        local delta = p1 - p0
        local half = part.Size * 0.5
        local t0, t1 = 0, 1
        for _, axis in ipairs({"X", "Y", "Z"}) do
            local position = p0[axis]
            local velocity = delta[axis]
            local bound = half[axis]
            if math.abs(velocity) < 0.0001 then
                if math.abs(position) > bound then return nil end
            else
                local a, b = (-bound - position) / velocity, (bound - position) / velocity
                if a > b then a, b = b, a end
                t0 = math.max(t0, a)
                t1 = math.min(t1, b)
                if t0 > t1 then return nil end
            end
        end
        -- Require material BETWEEN source and target. A point embedded in
        -- a wall, or a Rush origin inside a panel, is not protected cover.
        if t0 <= 0.015 or t0 >= 0.94 or t1 >= 0.985 then return nil end
        return startPos:Lerp(endPos, t0)
    end

    local function horizontalCoverRay(fromPosition, targetPosition, diagnostic)
        local character = LocalPlayer.Character
        local exclusions = {}
        if character then table.insert(exclusions, character) end
        local rush = debugMode == "LOS" and nil or rushModel()
        if rush then table.insert(exclusions, rush) end
        for _, name in ipairs({"HackPanelLOSRayDiagnostics", "HackPanelLOSWholeRoomCandidates",
            "HackPanelPathPreview", "HackPanelSimulatedRushRoute"}) do
            local folder = workspace:FindFirstChild(name)
            if folder then table.insert(exclusions, folder) end
        end
        local planar = Vector3.new(targetPosition.X-fromPosition.X, 0, targetPosition.Z-fromPosition.Z)
        if planar.Magnitude < 0.5 then return false, nil, nil, "Too close" end
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.IgnoreWater = true
        -- IMPORTANT: fromPosition is already the chosen eye point. The old
        -- code raised the source twice, sending rays over room walls.
        local startPos = fromPosition
        local direction = targetPosition - startPos
        local firstHit = nil
        -- Run BOTH query-based and collision-based raycasts. Visible DOORS
        -- wall meshes can be CanCollide=false but CanQuery=true, whereas
        -- physical wall panels may be CanQuery=false but CanCollide=true.
        for _, collisionMode in ipairs({false, true}) do
            pcall(function() params.RespectCanCollide = collisionMode end)
            local ignored = table.clone(exclusions)
            for _ = 1, 14 do
                params.FilterDescendantsInstances = ignored
                local hit = workspace:Raycast(startPos, direction, params)
                if not hit then break end
                firstHit = firstHit or hit
                local part = hit.Instance
                -- Mesh and union wall triangles may have slanted normals.
                -- An actual intersection with vetted room-shell geometry
                -- counts even when its triangle normal is not horizontal.
                if isStructuralCover(part)
                    and (hit.Position-startPos).Magnitude > 0.5
                    and (hit.Position-targetPosition).Magnitude > 1.1 then
                    losRayDiagnostics.hits += 1
                    return true, part, hit, "Wall occludes body: " .. part.Name
                end
                -- Ignore details while checking for solid structural walls
                -- deeper along the same sightline.
                table.insert(ignored, part)
            end
        end
        -- Some visible, COLLIDABLE wall Parts are still non-queryable in
        -- custom DOORS room models. Test their actual oriented box segments.
        -- Restrict to rectangular Parts; no false cover across mesh openings.
        for _, part in ipairs(losStructuralParts) do
            if part.Parent and part:IsA("Part") and part.Shape == Enum.PartType.Block
                and not part.CanQuery and part.CanCollide then
                local point = segmentHitsWallPanel(startPos, targetPosition, part)
                if point then
                    losRayDiagnostics.boxed += 1
                    return true, part,
                        {Position = point, Instance = part, Normal = Vector3.zero},
                        "Solid nonqueryable wall: " .. part.Name
                end
            end
        end
        losRayDiagnostics.unblocked += 1
        local firstPart = firstHit and firstHit.Instance
        local firstName = firstPart and firstPart.Name or "open air"
        local geometry = firstPart and string.format(" %s %.1fx%.1fx%.1f",
            firstPart.ClassName, firstPart.Size.X, firstPart.Size.Y,
            firstPart.Size.Z) or ""
        return false, nil, firstHit, "Open LOS (first: " .. firstName .. geometry .. ")"
    end

    local function solidCoverBetween(fromPosition, targetPosition)
        local blocked, part = horizontalCoverRay(fromPosition, targetPosition)
        return blocked, part
    end

    local function coverProtected(rushPos, groundPos, crouched)
        -- GroundPos is the actual floor surface. Test body at real standing
        -- or crouched heights, plus the edges so half-exposed spots fail.
        local head = crouched and 2.25 or 4.45
        local torso = crouched and 1.45 or 3.0
        local points = {
            Vector3.new(0, head, 0),
            Vector3.new(0, torso, 0),
            -- Sample the character's body width without treating a 0.85-stud
            -- fringe beyond the body as an exposed character.
            Vector3.new(0.45, torso, 0),
            Vector3.new(-0.45, torso, 0),
            Vector3.new(0, torso, 0.45),
            Vector3.new(0, torso, -0.45),
        }
        -- Rush route positions are navigation points near player-root height.
        -- Use approximately eye level once, not a second rise in the raycast.
        local origins = {rushPos + Vector3.new(0, 1.35, 0)}
        local rush = debugMode == "LOS" and nil or rushModel()
        if rush then
            local part = rush:IsA("BasePart") and rush or rush:FindFirstChildWhichIsA("BasePart", true)
            if part then
                local velocity = part.AssemblyLinearVelocity
                if velocity.Magnitude > 5 then
                    table.insert(origins, rushPos + velocity.Unit * math.min(18, velocity.Magnitude * 0.3) + Vector3.new(0, 1.35, 0))
                end
            end
        end
        local commonBlocker = nil
        for _, origin in ipairs(origins) do
            for _, offset in ipairs(points) do
                local bodyPoint = groundPos + offset
                local blocked, blocker = solidCoverBetween(origin, bodyPoint)
                if not blocked then return false, origin, bodyPoint end
                -- Require at least the same physical structure to obstruct
                -- multiple body points, not unrelated pieces of decoration.
                if not commonBlocker then commonBlocker = blocker end
            end
        end
        return commonBlocker ~= nil
    end

    -- Approximate Rush's entrance-to-exit travel with navigation around obstacles.
    -- Unlike the previous multi-angle guess, only samples the actual computed route.
    local function rushApproachSamples(source, roomCF, roomSize)
        local room, number = getCurrentRoom()
        local rooms = getCurrentRooms()
        if not room or not rooms then return nil, "Room unavailable" end
        local function doorPosition(model)
            if not model then return nil end
            local door = model:FindFirstChild("Door", true)
            if not door then return nil end
            if door:IsA("BasePart") then return door.Position end
            local part = door:FindFirstChildWhichIsA("BasePart", true)
            return part and part.Position or nil
        end
        local previous = number and rooms:FindFirstChild(tostring(number - 1))
        local entrance = doorPosition(previous) or source
        local exit = doorPosition(room)
        if not exit then return nil, "Room exit door unavailable" end
        -- Lift positions to the navigable character/root plane; the source may
        -- be the top of a door assembly instead of a walkable point.
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        local rayParams = RaycastParams.new()
        rayParams.FilterType = Enum.RaycastFilterType.Exclude
        rayParams.IgnoreWater = true
        -- Include solid CanCollide floors even when a decorative visual part
        -- is non-queryable. DOORS sometimes separates render and collision.
        pcall(function() rayParams.RespectCanCollide = true end)
        local baseExclusions = char and {char} or {}
        -- CRITICAL: do NOT cast down from a door/room bounding-box center.
        -- That often hits the TOP of the ceiling and produces a perfectly
        -- successful PathfindingService route *above* the actual room.
        local humanoid = char and char:FindFirstChildOfClass("Humanoid")
        local baseFloorY = root and (root.Position.Y - (humanoid and humanoid.HipHeight or 2)
            - root.Size.Y * 0.5) or entrance.Y - 2.5
        local routeFloorMaxDifference = 3.0
        local routeRaySkipped = 0
        -- Floor support detection uses the waypoint itself, not only the
        -- player's starting floor level. DOORS rooms contain stairs, narrow
        -- floorboards and separate invisible collision parts; one straight
        -- downward ray from a fixed Y is not a reliable proof of missing floor.
        local supportOverlap = OverlapParams.new()
        supportOverlap.FilterType = Enum.RaycastFilterType.Exclude
        supportOverlap.FilterDescendantsInstances = baseExclusions
        supportOverlap.MaxParts = 100
        pcall(function() supportOverlap.RespectCanCollide = true end)
        local floorProbeOffsets = {
            Vector3.zero,
            Vector3.new(0.8, 0, 0), Vector3.new(-0.8, 0, 0),
            Vector3.new(0, 0, 0.8), Vector3.new(0, 0, -0.8),
            Vector3.new(1.5, 0, 0), Vector3.new(-1.5, 0, 0),
            Vector3.new(0, 0, 1.5), Vector3.new(0, 0, -1.5),
        }
        local function walkableFloorAt(point, onRoute)
            local bestFloor, bestScore = nil, math.huge
            local allowableLevelDelta = onRoute and 5.0 or 3.0
            local function acceptableSurface(part, surfaceY)
                if not part or not part:IsA("BasePart") or not part.CanCollide
                    or isDecorativeCover(part) then return false end
                local n = part.Name:lower()
                if n:find("ceiling", 1, true) or n:find("roof", 1, true)
                    or n:find("table", 1, true) or n:find("shelf", 1, true)
                    or n:find("mantle", 1, true) then return false end
                -- Keep every sample in the player's room-height band. A roof
                -- may be navigable, but it is not a valid simulated Rush route.
                if math.abs(surfaceY - baseFloorY) > allowableLevelDelta then
                    return false
                end
                if onRoute and math.min(math.abs(point.Y - surfaceY),
                    math.abs(point.Y - surfaceY - 2.5)) > 3.6 then
                    return false
                end
                return true
            end
            local function consider(position, part, surfaceY, offsetDistance)
                if not acceptableSurface(part, surfaceY) then return end
                local waypointDifference = math.min(
                    math.abs(point.Y - surfaceY),
                    math.abs(point.Y - surfaceY - 2.5))
                local score = waypointDifference * (onRoute and 1 or 0.12)
                    + offsetDistance * 0.42
                    + math.abs(surfaceY - baseFloorY) * 0.06
                if score < bestScore then
                    bestScore = score
                    bestFloor = Vector3.new(point.X, surfaceY, point.Z)
                end
            end
            -- Try the exact waypoint before nearby probes. This avoids
            -- snapping to an adjacent furniture top or through a thin wall.
            for offsetIndex, offset in ipairs(floorProbeOffsets) do
                if bestFloor and offsetIndex > 1 then break end
                local x, z = point.X + offset.X, point.Z + offset.Z
                local firstHeight = math.max(baseFloorY + 1.8,
                    onRoute and (point.Y + 1.3) or baseFloorY + 1.8)
                local upperHeight = math.max(baseFloorY + 4.8,
                    onRoute and (point.Y + 3.3) or baseFloorY + 4.8)
                for _, startHeight in ipairs({firstHeight, upperHeight}) do
                    for _, collisionMode in ipairs({true, false}) do
                        pcall(function() rayParams.RespectCanCollide = collisionMode end)
                        local ignored = table.clone(baseExclusions)
                        local probe = Vector3.new(x, startHeight, z)
                        for _ = 1, 8 do
                            rayParams.FilterDescendantsInstances = ignored
                            local hit = workspace:Raycast(probe, Vector3.new(0, -17, 0), rayParams)
                            if not hit then break end
                            if hit.Normal.Y >= 0.78 then
                                consider(hit.Position, hit.Instance, hit.Position.Y, offset.Magnitude)
                            end
                            if bestFloor then break end
                            table.insert(ignored, hit.Instance)
                            routeRaySkipped += 1
                        end
                        if bestFloor then break end
                    end
                    if bestFloor then break end
                end
            end
            if bestFloor then return bestFloor end
            -- Last resort: a nearby non-queryable, collidable rectangular
            -- floor can be present in the physics world but missed by rays.
            -- Bounding boxes are used only for floor SUPPORT corroboration,
            -- never as proof that a wall blocks Rush's sightline.
            local height = onRoute and point.Y or (baseFloorY + 2.5)
            local okParts, parts = pcall(function()
                return workspace:GetPartBoundsInBox(
                    CFrame.new(point.X, (height + baseFloorY) * 0.5, point.Z),
                    Vector3.new(2.2, 10, 2.2), supportOverlap)
            end)
            if okParts and parts then
                for _, part in ipairs(parts) do
                    if part:IsA("Part") and part.Shape == Enum.PartType.Block
                        and part.CFrame.UpVector.Y > 0.87 then
                        local top = part.CFrame:PointToWorldSpace(Vector3.new(0, part.Size.Y * 0.5, 0))
                        local projected = part.CFrame:PointToObjectSpace(
                            Vector3.new(point.X, top.Y, point.Z))
                        if math.abs(projected.X) <= part.Size.X * 0.5 + 0.45
                            and math.abs(projected.Z) <= part.Size.Z * 0.5 + 0.45
                            and part.Size.X >= 1.0 and part.Size.Z >= 1.0 then
                            consider(top, part, top.Y, 0)
                        end
                    end
                end
            end
            return bestFloor
        end
        local function grounded(point)
            local floor = walkableFloorAt(point)
            return floor and (floor + Vector3.new(0, 2.5, 0))
                or Vector3.new(point.X, baseFloorY + 2.5, point.Z)
        end
        entrance, exit = grounded(entrance), grounded(exit)
        -- Door parts are often embedded in non-walkable geometry. Find
        -- reachable ground points just inside the room before asking for a path.
        local function endpointOptions(point)
            local result = {}
            local seen = {}
            -- The door can belong to the adjacent room. Never require
            -- roomForPosition(candidate) == room here: that discarded all
            -- endpoints when the door was just outside the room bounding box.
            local offsets = {
                Vector3.zero,
                Vector3.new(0, 0, 3), Vector3.new(0, 0, -3),
                Vector3.new(3, 0, 0), Vector3.new(-3, 0, 0),
                Vector3.new(0, 0, 6), Vector3.new(0, 0, -6),
                Vector3.new(6, 0, 0), Vector3.new(-6, 0, 0),
                Vector3.new(0, 0, 10), Vector3.new(0, 0, -10),
                Vector3.new(10, 0, 0), Vector3.new(-10, 0, 0),
            }
            local function addCandidate(probe)
                -- Snap at the PLAYER'S floor elevation, never to an overhead
                -- ceiling that happens to be above a door or a furniture top.
                local floorPos = walkableFloorAt(probe)
                if not floorPos then return end
                local localPos = roomCF:PointToObjectSpace(floorPos)
                if math.abs(localPos.X) > roomSize.X / 2 + 14
                    or math.abs(localPos.Z) > roomSize.Z / 2 + 14 then return end
                local candidate = floorPos + Vector3.new(0, 2.5, 0)
                local key = math.floor(candidate.X * 2) .. ':' .. math.floor(candidate.Z * 2)
                if not seen[key] then
                    seen[key] = true
                    table.insert(result, candidate)
                end
            end
            for _, offset in ipairs(offsets) do addCandidate(point + offset) end
            -- Use the actual player position as a backup for the entrance.
            -- This is only used if the door-derived candidates fail.
            return result
        end
        local starts, goals = endpointOptions(entrance), endpointOptions(exit)
        if #starts == 0 and root then
            table.insert(starts, root.Position)
        end
        -- Last-resort endpoint samples around the room's center; do not
        -- confuse the absence of door-adjacent samples with a LOS failure.
        if #goals == 0 then
            local center = roomCF.Position
            for _, delta in ipairs({Vector3.zero, roomCF.RightVector * 6,
                -roomCF.RightVector * 6, roomCF.LookVector * 6,
                -roomCF.LookVector * 6}) do
                local probe = center + delta
                local floor = walkableFloorAt(probe)
                if floor then
                    table.insert(goals, floor + Vector3.new(0, 2.5, 0))
                end
            end
        end
        local path, status
        local attempts = 0
        -- Prefer a modest number of endpoint combinations to avoid the
        -- performance problems of the earlier pathfinder versions.
        for _, radius in ipairs({1.4, 1}) do
            if path then break end
            for si = 1, math.min(#starts, 7) do
                if path then break end
                for gi = 1, math.min(#goals, 7) do
                    attempts += 1
                    local candidate = PathfindingService:CreatePath({
                        AgentRadius = radius, AgentHeight = 3.5,
                        AgentCanJump = true, AgentCanClimb = false,
                        WaypointSpacing = 3,
                    })
                    local ok = pcall(function() candidate:ComputeAsync(starts[si], goals[gi]) end)
                    if ok and candidate.Status == Enum.PathStatus.Success then
                        path = candidate
                        break
                    end
                    status = ok and tostring(candidate.Status) or "ComputeAsync error"
                    if attempts % 5 == 0 then task.wait() end
                end
            end
        end
        -- When a long entrance-to-exit path fails, try a small graph of
        -- grounded room checkpoints. Every edge is independently validated by
        -- PathfindingService; never join points through walls with a straight line.
        local segmentedWaypoints = nil
        local segmentFailure = "no connected checkpoint chain"
        if not path and #starts > 0 and #goals > 0 then
            local checkpoints = {}
            local checkpointKeys = {}
            local function addCheckpoint(pos)
                local key = math.floor(pos.X / 3) .. ":" .. math.floor(pos.Z / 3)
                if checkpointKeys[key] then return end
                checkpointKeys[key] = true
                table.insert(checkpoints, pos)
            end
            -- One chosen door endpoint at either end, plus grounded interior
            -- positions. Keep the graph small to prevent game freezes.
            addCheckpoint(starts[1])
            local startIndex = 1
            local localGrid = {-0.32, 0, 0.32}
            for _, x in ipairs(localGrid) do
                for _, z in ipairs(localGrid) do
                    local probe = roomCF:PointToWorldSpace(Vector3.new(roomSize.X * x, 0, roomSize.Z * z))
                    local floor = walkableFloorAt(probe)
                    if floor then
                        addCheckpoint(floor + Vector3.new(0, 2.5, 0))
                    end
                end
            end
            addCheckpoint(goals[1])
            local goalIndex = #checkpoints
            local edges, totalCalls = {}, 0
            for i = 1, #checkpoints do edges[i] = {} end
            local pairsToTry = {}
            for i = 1, #checkpoints do
                for j = i + 1, #checkpoints do
                    local dist = (checkpoints[i] - checkpoints[j]).Magnitude
                    if dist <= 65 or i == startIndex or j == goalIndex then
                        table.insert(pairsToTry, {i, j, dist})
                    end
                end
            end
            table.sort(pairsToTry, function(a, b) return a[3] < b[3] end)
            -- Prioritize short edges, but give endpoints a chance to connect.
            for _, pair in ipairs(pairsToTry) do
                if totalCalls >= 42 then break end
                totalCalls += 1
                local segment = PathfindingService:CreatePath({
                    AgentRadius = 1, AgentHeight = 3.5,
                    AgentCanJump = true, AgentCanClimb = false, WaypointSpacing = 3,
                })
                local ok = pcall(function()
                    segment:ComputeAsync(checkpoints[pair[1]], checkpoints[pair[2]])
                end)
                if ok and segment.Status == Enum.PathStatus.Success then
                    local points = segment:GetWaypoints()
                    edges[pair[1]][pair[2]] = {points = points, cost = pair[3]}
                    edges[pair[2]][pair[1]] = {points = points, cost = pair[3], reverse = true}
                else
                    segmentFailure = ok and tostring(segment.Status) or "ComputeAsync error"
                end
                if totalCalls % 6 == 0 then task.wait() end
            end
            -- Dijkstra across successful segment edges.
            local dist, previous, visited = {[startIndex] = 0}, {}, {}
            for _ = 1, #checkpoints do
                local current, best = nil, math.huge
                for index, value in pairs(dist) do
                    if not visited[index] and value < best then current, best = index, value end
                end
                if not current then break end
                if current == goalIndex then break end
                visited[current] = true
                for neighbor, edge in pairs(edges[current]) do
                    local newCost = best + edge.cost
                    if not dist[neighbor] or newCost < dist[neighbor] then
                        dist[neighbor] = newCost
                        previous[neighbor] = current
                    end
                end
            end
            if dist[goalIndex] then
                local chain = {goalIndex}
                while chain[1] ~= startIndex do
                    local parent = previous[chain[1]]
                    if not parent then break end
                    table.insert(chain, 1, parent)
                end
                if chain[1] == startIndex then
                    segmentedWaypoints = {}
                    for i = 1, #chain - 1 do
                        local edge = edges[chain[i]][chain[i + 1]]
                        local points = edge.points
                        if edge.reverse then
                            for k = #points, 1, -1 do
                                if #segmentedWaypoints == 0 or k < #points then
                                    table.insert(segmentedWaypoints, points[k])
                                end
                            end
                        else
                            for k = 1, #points do
                                if #segmentedWaypoints == 0 or k > 1 then
                                    table.insert(segmentedWaypoints, points[k])
                                end
                            end
                        end
                    end
                end
            end
            if not segmentedWaypoints then
                segmentFailure = "checkpoint graph disconnected; last edge " .. segmentFailure
            end
        end
        if not path and not segmentedWaypoints then
            clearRushRoutePreview()
            if #starts == 0 or #goals == 0 then
                return nil, "Rush route: no walkable entrance/exit point"
            end
            return nil, "Rush route failed (direct: " .. tostring(status) .. "; segments: " .. segmentFailure .. ")"
        end
        local waypoints = segmentedWaypoints or path:GetWaypoints()
        local route = {}
        for i, waypoint in ipairs(waypoints) do
            if i == 1 then
                table.insert(route, waypoint.Position)
            else
                local a, b = waypoints[i - 1].Position, waypoint.Position
                local length = (b - a).Magnitude
                for step = 1, math.max(1, math.ceil(length / 5)) do
                    table.insert(route, a:Lerp(b, step / math.max(1, math.ceil(length / 5))))
                end
            end
        end
        -- Normalize the route onto the character's walking level. Roblox
        -- PathfindingService:GetWaypoints() returns navigation positions that
        -- can sit ON THE FLOOR rather than at HumanoidRootPart height. The old
        -- validator compared waypoint.Y only to floor.Y + 2.5 and rejected
        -- valid routes at waypoint 5, 10, etc. It also treated a single missed
        -- ray (at a doorway or floor seam) as proof of an invalid route.
        -- Keep the roof-height check. A completely unsupported route must
        -- still fail rather than claiming to be Rush-safe.
        local confirmedFloors = {}
        local confirmedCount, missedCount, missingStreak, longestMissing = 0, 0, 0, 0
        for i, point in ipairs(route) do
            local relativeToRoot = math.abs(point.Y - (baseFloorY + 2.5))
            local relativeToSurface = math.abs(point.Y - baseFloorY)
            if math.min(relativeToRoot, relativeToSurface) > routeFloorMaxDifference + 0.75 then
                clearRushRoutePreview()
                return nil, string.format(
                    "Invalid Rush route height at %d/%d (Y %.1f, player floor %.1f)",
                    i, #route, point.Y, baseFloorY)
            end
            local floor = walkableFloorAt(point, true)
            if floor then
                -- A waypoint Y can be either surface-height or root-height.
                -- Require it to be reasonably close to the floor it claims.
                if math.min(math.abs(point.Y - floor.Y),
                    math.abs(point.Y - (floor.Y + 2.5))) > 3.25 then
                    clearRushRoutePreview()
                    return nil, string.format(
                        "Rush route has wrong floor at %d/%d (waypoint %.1f floor %.1f)",
                        i, #route, point.Y, floor.Y)
                end
                confirmedFloors[i] = floor.Y
                confirmedCount += 1
                missingStreak = 0
            else
                missedCount += 1
                missingStreak += 1
                longestMissing = math.max(longestMissing, missingStreak)
            end
        end
        -- A successful pathfinder route with one missing support sample is
        -- not a failed route. But many unconfirmed points (or a long gap)
        -- remain untrustworthy and should not be used to verify LOS safety.
        local routeSupportUncertain = confirmedCount < math.max(2, math.ceil(#route * 0.45))
            or (longestMissing > 6 and confirmedCount < math.ceil(#route * 0.85))
        if confirmedCount < 2 or (routeSupportUncertain and debugMode ~= "LOS") then
            clearRushRoutePreview()
            return nil, string.format(
                "Rush route support uncertain: %d/%d confirmed (%d missing, gap %d)",
                confirmedCount, #route, missedCount, longestMissing)
        end
        -- A successful navigation-mesh route that is height-plausible can
        -- still have unqueryable floor sections. In LOS *debug only*, inspect
        -- cover against this estimated route rather than aborting the search.
        -- Never claim these estimates are verified or use them for AUTO-HIDE.
        local routeConfidenceMessage = routeSupportUncertain and string.format(
            "ESTIMATED Rush route (floor %d/%d); not survival-verified",
            confirmedCount, #route) or nil
        -- Convert every sample to the same root-height coordinate system.
        -- For a missed ray at a floor seam, interpolate between adjacent
        -- confirmed floor heights; don't drop that Rush path segment.
        local lastKnown = nil
        local nextKnown = 1
        for i, point in ipairs(route) do
            if confirmedFloors[i] then lastKnown = i end
            if not confirmedFloors[i] then
                nextKnown = math.max(nextKnown, i + 1)
                while nextKnown <= #route and not confirmedFloors[nextKnown] do
                    nextKnown += 1
                end
                local y = baseFloorY
                if lastKnown and nextKnown <= #route then
                    local factor = (i - lastKnown) / (nextKnown - lastKnown)
                    y = confirmedFloors[lastKnown] * (1 - factor)
                        + confirmedFloors[nextKnown] * factor
                elseif lastKnown then
                    y = confirmedFloors[lastKnown]
                elseif nextKnown <= #route then
                    y = confirmedFloors[nextKnown]
                end
                route[i] = Vector3.new(point.X, y + 2.5, point.Z)
            else
                route[i] = Vector3.new(point.X, confirmedFloors[i] + 2.5, point.Z)
            end
        end
        -- Limit LOS samples while retaining route corners and entrance/exit.
        if #route > 36 then
            local reduced = {}
            for i = 1, 36 do
                table.insert(reduced, route[math.floor((i - 1) * (#route - 1) / 35) + 1])
            end
            route = reduced
        end
        showRushRoutePreview(route)
        return route, routeConfidenceMessage
    end

    local function protectedFromApproach(origins, ground, crouch)
        local blocked = 0
        for index, origin in ipairs(origins) do
            local safe, openFrom, openTo = coverProtected(origin, ground, crouch)
            if safe then
                blocked += 1
            else
                -- Report the EXACT failed body/edge ray, not just a route
                -- midpoint. This makes the diagnostic guide trustworthy.
                return false, blocked, index, openFrom, openTo
            end
        end
        return true, blocked, nil
    end

    local function setCoverCrouch(enabled)
        -- DOORS commonly uses C to toggle crouch. Only toggle on a state
        -- transition; repeatedly pressing C would immediately stand up.
        if coverCrouchActive == enabled then return end
        local function send(down)
            local fn = down and keypress or keyrelease
            if type(fn) == "function" then
                local ok = pcall(fn, 0x43)
                if ok then return end
            end
            pcall(function()
                game:GetService("VirtualInputManager"):SendKeyEvent(down, Enum.KeyCode.C, false, game)
            end)
        end
        send(true)
        task.wait(0.08)
        send(false)
        coverCrouchActive = enabled
        task.wait(0.12)
    end

    -- Detect low overhead clearance along the next walking segment.  The
    -- raycasts deliberately ignore the player's own character, and check
    -- both standing head height and crouched head height.  A hit at standing
    -- height is only a crouch passage when the lower ray is unobstructed.
    local function needsCrouchForSegment(fromPos, toPos)
        local flat = Vector3.new(toPos.X - fromPos.X, 0, toPos.Z - fromPos.Z)
        if flat.Magnitude < 0.3 then return false end
        local direction = flat.Unit
        local distance = math.min(flat.Magnitude, 3.5)
        local character = LocalPlayer.Character
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = character and {character} or {}
        params.IgnoreWater = true
        local floorY = fromPos.Y - 2.5
        local standingOrigin = Vector3.new(fromPos.X, floorY + 4.2, fromPos.Z)
        local lowOrigin = Vector3.new(fromPos.X, floorY + 1.5, fromPos.Z)
        local upperHit = workspace:Raycast(standingOrigin, direction * distance, params)
        if not upperHit or not upperHit.Instance.CanCollide then return false end
        local lowerHit = workspace:Raycast(lowOrigin, direction * distance, params)
        return not (lowerHit and lowerHit.Instance.CanCollide)
    end

    local function passageIsClearWhileCrouched(fromPos, toPos)
        local flat = Vector3.new(toPos.X-fromPos.X, 0, toPos.Z-fromPos.Z)
        if flat.Magnitude < 0.3 then return true end
        local character = LocalPlayer.Character
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = character and {character} or {}
        params.IgnoreWater = true
        local floorY = fromPos.Y - 2.5
        for _, height in ipairs({0.8, 1.6, 2.25}) do
            local origin = Vector3.new(fromPos.X, floorY+height, fromPos.Z)
            local hit = workspace:Raycast(origin, flat.Unit * math.min(flat.Magnitude, 3), params)
            if hit and hit.Instance.CanCollide then return false end
        end
        return true
    end

    -- Debug-only ray-hit markers. These do not affect LOS decisions.
    local function clearLOSDiagnosticMarkers()
        local old = workspace:FindFirstChild("HackPanelLOSRayDiagnostics")
        if old then old:Destroy() end
    end

    local function showLOSDiagnosticHit(fromPos, toPos, index)
        if debugMode ~= "LOS" or not rayLabelsEnabled or index > 6 then return nil end
        local folder = workspace:FindFirstChild("HackPanelLOSRayDiagnostics")
        if not folder then
            folder = Instance.new("Folder")
            folder.Name = "HackPanelLOSRayDiagnostics"
            folder.Parent = workspace
        end
        local accepted, blocker, hit, detail = horizontalCoverRay(fromPos, toPos, true)
        local position = hit and hit.Position or toPos
        local reason = accepted and ("WALL: " .. blocker.Name) or ("REJECT: " .. detail)
        local marker = Instance.new("Part")
        marker.Name = "RayHit" .. index
        marker.Shape = Enum.PartType.Ball
        marker.Size = Vector3.new(0.4, 0.4, 0.4)
        marker.Anchored = true
        marker.CanCollide = false
        marker.CanTouch = false
        marker.CanQuery = false
        marker.Material = Enum.Material.Neon
        marker.Color = accepted and Color3.fromRGB(70, 255, 90) or Color3.fromRGB(255, 80, 70)
        marker.Position = position
        marker.Parent = folder
        if not accepted then
            local vector = toPos - fromPos
            if vector.Magnitude > 0.1 then
                local guide = Instance.new("Part")
                guide.Name = "OpenRushSightline_" .. tostring(index)
                guide.Anchored = true
                guide.CanCollide = false
                guide.CanTouch = false
                guide.CanQuery = false
                guide.Material = Enum.Material.Neon
                guide.Color = Color3.fromRGB(255, 130, 40)
                guide.Transparency = 0.4
                guide.Size = Vector3.new(0.08, 0.08, vector.Magnitude)
                guide.CFrame = CFrame.lookAt((toPos + fromPos) * 0.5, toPos)
                guide.Parent = folder
            end
        end
        local billboard = Instance.new("BillboardGui")
        billboard.Size = UDim2.fromOffset(200, 32)
        billboard.StudsOffset = Vector3.new(0, 1.6 + (index % 3) * 1.5, 0)
        billboard.AlwaysOnTop = true
        billboard.MaxDistance = 45
        billboard.Parent = marker
        local label = Instance.new("TextLabel")
        label.Size = UDim2.fromScale(1, 1)
        label.BackgroundTransparency = 0.3
        label.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
        label.TextColor3 = Color3.new(1, 1, 1)
        label.TextScaled = true
        label.TextWrapped = true
        label.Text = reason
        label.Parent = billboard
        return reason
    end

    -- Independent, bounded whole-room candidate visualizer. The ray-hit
    -- markers above show only diagnostic samples, NOT the search footprint.
    local searchFolder
    local searchCounts = {sampled = 0, ground = 0, los = 0, wall = 0, robust = 0}
    local function clearSearchCandidates()
        if searchFolder then searchFolder:Destroy(); searchFolder = nil end
        local old = workspace:FindFirstChild("HackPanelLOSWholeRoomCandidates")
        if old then old:Destroy() end
        searchCounts = {sampled = 0, ground = 0, los = 0, wall = 0, robust = 0}
    end
    local function showSearchCandidate(position, category, number)
        if not searchVisualEnabled then return end
        if not searchFolder then
            searchFolder = Instance.new("Folder")
            searchFolder.Name = "HackPanelLOSWholeRoomCandidates"
            searchFolder.Parent = workspace
        end
        local colors = {
            ground = Color3.fromRGB(170, 170, 170),
            los = Color3.fromRGB(60, 170, 255),
            wall = Color3.fromRGB(90, 255, 115),
            robust = Color3.fromRGB(255, 220, 60),
        }
        local point = Instance.new("Part")
        point.Name = category .. "_" .. tostring(number)
        point.Shape = Enum.PartType.Ball
        point.Size = Vector3.new(0.36, 0.36, 0.36)
        point.Anchored = true
        point.CanCollide = false
        point.CanTouch = false
        point.CanQuery = false
        point.Material = Enum.Material.Neon
        point.Color = colors[category] or colors.ground
        point.Position = position + Vector3.new(0, 0.35, 0)
        point.Parent = searchFolder
    end

    -- Debug movement uses the same per-frame Humanoid:Move steering as the
    -- working cover follower, rather than MoveToFinished (which times out in
    -- DOORS while its movement controller overrides MoveTo).
    local function debugWalkWaypoints(waypoints, generation, humanoid, root)
        local renderName = "HackPanelLOSDebugWalk"
        local direction = Vector3.zero
        local running = true
        pcall(function() RunService:UnbindFromRenderStep(renderName) end)
        RunService:BindToRenderStep(renderName, Enum.RenderPriority.Input.Value + 2, function()
            if running and humanoid.Parent and humanoid.Health > 0 then
                humanoid:Move(direction, false)
            end
        end)
        local success, reason = true, "arrived"
        for i, waypoint in ipairs(waypoints) do
            if not navigationActive(generation) then success = false; reason = "cancelled"; break end
            if humanoid.Health <= 0 then success = false; reason = "character dead"; break end
            if waypoint.Action == Enum.PathWaypointAction.Jump then humanoid.Jump = true end
            local started, progressAt, last = os.clock(), os.clock(), root.Position
            while true do
                local delta = waypoint.Position - root.Position
                local flat = Vector3.new(delta.X, 0, delta.Z)
                if flat.Magnitude <= 2 then break end
                if not navigationActive(generation) then success = false; reason = "cancelled"; break end
                if os.clock() - started > 6 then success = false; reason = "waypoint timeout"; break end
                if (root.Position - last).Magnitude > 0.4 then
                    last, progressAt = root.Position, os.clock()
                elseif os.clock() - progressAt > 1.6 then
                    success = false; reason = "no movement (controller or collision)"; break
                end
                direction = flat.Unit
                task.wait(0.05)
            end
            if not success then break end
        end
        running = false
        direction = Vector3.zero
        pcall(function() RunService:UnbindFromRenderStep(renderName) end)
        pcall(function() humanoid:Move(Vector3.zero, false) end)
        return success, reason
    end

    local function moveToCover(generation)
        local character = LocalPlayer.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local rushPos = rushPosition()
        if not root or not humanoid or not rushPos then return false, "No cover target" end
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = {character}
        params.IgnoreWater = true
        local choices = {}
        clearLOSDiagnosticMarkers()
        clearSearchCandidates()
        local diagnosticSamples = 0
        local firstHitReasons = {}
        -- Search the entire loaded current room footprint, not a fixed radius.
        -- Grid sampling is bounded for performance; no path calculations occur
        -- until LOS candidates have been validated.
        local current = getCurrentRoom()
        if not current then return false, "Current room unavailable" end
        local okBounds, roomCF, roomSize = pcall(function()
            local cf, size = current:GetBoundingBox()
            return cf, size
        end)
        if not okBounds then return false, "Room bounds unavailable" end
        losStructuralRoom = nil
        refreshLOSStructuralParts(current)
        local approachOrigins, routeError = rushApproachSamples(rushPos, roomCF, roomSize)
        if not approachOrigins then
            -- A failed Rush route cannot validate safe LOS cover.
            -- Never move to an arbitrary destination as a substitute.
            return false, routeError
        end
        local routeEstimated = type(routeError) == "string" and #routeError > 0
        if routeEstimated then
            rushStatus.Text = "DEBUG LOS: estimated Rush route; searching side rooms"
        end
        local floorY = root.Position.Y - humanoid.HipHeight - root.Size.Y * 0.5
        -- Never mistake a spot ON the simulated Rush path for cover. Compare
        -- planar distance to each route SEGMENT, not only the entrance point.
        local function distanceToRushRouteXZ(point)
            local best = math.huge
            for index = 1, #approachOrigins do
                local a = approachOrigins[index]
                local b = approachOrigins[math.min(index + 1, #approachOrigins)]
                local abx, abz = b.X - a.X, b.Z - a.Z
                local apx, apz = point.X - a.X, point.Z - a.Z
                local denom = abx * abx + abz * abz
                local t = denom > 0.001 and math.clamp((apx * abx + apz * abz) / denom, 0, 1) or 0
                local dx, dz = apx - abx * t, apz - abz * t
                best = math.min(best, math.sqrt(dx * dx + dz * dz))
            end
            return best
        end
        -- Generate destinations from structural WALL FACES, rather than
        -- sampling only an evenly spaced grid that favors open floor.
        -- Each wall receives samples on both sides; LOS decides which side
        -- actually hides the character from Rush's computed route.
        local samples = {}
        local seen = {}
        local function addSample(pos)
            if #samples >= 1800 then return end
            local key = string.format("%d:%d", math.floor(pos.X * 2 + 0.5), math.floor(pos.Z * 2 + 0.5))
            if not seen[key] then
                seen[key] = true
                table.insert(samples, pos)
            end
        end
        local wallsFound = 0
        for _, part in ipairs(current:GetDescendants()) do
            if part:IsA("BasePart") and isStructuralCover(part) then
                local name = part.Name:lower()
                local isNamedWall = name:find("wall", 1, true) or name:find("pillar", 1, true)
                    or name:find("column", 1, true)
                local planar = math.max(part.Size.X, part.Size.Z) >= 9
                    and math.min(part.Size.X, part.Size.Z) <= 3 and part.Size.Y >= 4.5
                if isNamedWall or planar or (part.Size.Y >= 3.2 and math.max(part.Size.X, part.Size.Z) >= 3.5) then
                    wallsFound += 1
                    local xLong = part.Size.X >= part.Size.Z
                    local halfLength = (xLong and part.Size.X or part.Size.Z) * 0.5
                    local thickness = (xLong and part.Size.Z or part.Size.X) * 0.5
                    local step = math.max(1.5, math.min(3, halfLength / 6))
                    for along = -halfLength + 0.7, halfLength - 0.7, step do
                        for _, side in ipairs({-1, 1}) do
                            -- A 2.5-stud offset alone misses narrow side-room
                            -- alcoves. Try tucked positions near real wall faces
                            -- as well as a walkable clearance farther away.
                            for _, clearance in ipairs({1.45, 2.5}) do
                                local localPos = xLong
                                    and Vector3.new(along, 0, side * (thickness + clearance))
                                    or Vector3.new(side * (thickness + clearance), 0, along)
                                addSample(part.CFrame:PointToWorldSpace(localPos))
                            end
                        end
                    end
                end
            end
        end
        -- Sparse floor grid remains as a fallback for side rooms whose
        -- enclosing walls are grouped under another model.
        local spacing = math.max(2, math.max(roomSize.X, roomSize.Z) / 36)
        local nx = math.max(1, math.ceil(roomSize.X / spacing))
        local nz = math.max(1, math.ceil(roomSize.Z / spacing))
        for ix = 0, nx do
            for iz = 0, nz do
                local localX = (ix / nx - 0.5) * math.max(0, roomSize.X - 3)
                local localZ = (iz / nz - 0.5) * math.max(0, roomSize.Z - 3)
                addSample(roomCF:PointToWorldSpace(Vector3.new(localX, 0, localZ)))
            end
        end
        local checked = 0
        local groundCandidates, losCandidates, wallCandidates = 0, 0, 0
        for _, world in ipairs(samples) do
                if not navigationActive(generation) then return false, "Cancelled" end
                checked += 1
                searchCounts.sampled += 1
                if checked % 45 == 0 then
                    rushStatus.Text = string.format("LOS: checking %d/%d | wall parts %d", checked, #samples, #losStructuralParts)
                    task.wait()
                end
                local sample = Vector3.new(world.X, floorY + 5, world.Z)
                local ground = workspace:Raycast(sample, Vector3.new(0, -12, 0), params)
                local groundPart = ground and ground.Instance
                -- Side rooms may use many narrow floorboard Parts. Requiring
                -- each board to be 4x4 studs discarded valid side-room floor.
                -- The upward normal and correct floor elevation do the real
                -- work of ruling out walls, raised tables and staircase tops.
                local floorLike = groundPart and groundPart.CanCollide
                    and not isDecorativeCover(groundPart)
                    and math.max(groundPart.Size.X, groundPart.Size.Z) >= 1.2
                if ground and ground.Normal.Y > 0.9 and floorLike
                    and math.abs(ground.Position.Y - floorY) <= 2.5
                    and (ground.Position - rushPos).Magnitude >= 7
                    and roomForPosition(ground.Position + Vector3.new(0, 2.5, 0)) == current then
                    groundCandidates += 1
                    searchCounts.ground += 1
                    showSearchCandidate(ground.Position, "ground", checked)
                    -- This is a proximity safety gate: a route that passes
                    -- within a few studs of the candidate is not a hiding
                    -- destination even when a thin object interrupts one ray.
                    local tooCloseToRoute = distanceToRushRouteXZ(ground.Position) < 4.0
                    local standingBlocked, _, standingOpenIndex, standingFrom, standingTo =
                        protectedFromApproach(approachOrigins, ground.Position, false)
                    local crouchBlocked, _, crouchOpenIndex, crouchFrom, crouchTo =
                        protectedFromApproach(approachOrigins, ground.Position, true)
                    if not standingBlocked and not crouchBlocked and debugMode == "LOS"
                        and rayLabelsEnabled and diagnosticSamples < 6 and checked % 37 == 0 then
                        diagnosticSamples += 1
                        local firstOpen = crouchOpenIndex or standingOpenIndex or 1
                        local fromPoint = crouchFrom or standingFrom
                        local toPoint = crouchTo or standingTo
                        local reason = fromPoint and toPoint and
                            showLOSDiagnosticHit(fromPoint, toPoint, diagnosticSamples)
                        if reason then
                            reason = string.format("route %d/%d: %s", firstOpen, #approachOrigins, reason)
                            firstHitReasons[reason] = (firstHitReasons[reason] or 0) + 1
                        end
                    end
                    if not tooCloseToRoute and (standingBlocked or crouchBlocked) then
                        losCandidates += 1
                        searchCounts.los += 1
                        showSearchCandidate(ground.Position + Vector3.new(0, 0.55, 0), "los", checked)
                        -- The simulated route may bend around corners; a wall
                        -- blocking an earlier waypoint need not block rushPos.
                        local blocker = nil
                        for _, routeOrigin in ipairs(approachOrigins) do
                            local blocked, part = solidCoverBetween(
                                routeOrigin, ground.Position + Vector3.new(0, standingBlocked and 3 or 1.5, 0))
                            if blocked and part then blocker = part; break end
                        end
                        -- Furniture is NOT a wall. Accept structural geometry
                        -- only: named wall/pillar/column or a broad planar wall.
                        local node = blocker
                        local namedWall = false
                        while node and node ~= current.Parent do
                            local name = node.Name:lower()
                            if name:find("wall", 1, true) or name:find("pillar", 1, true)
                                or name:find("column", 1, true) then
                                namedWall = true
                                break
                            end
                            node = node.Parent
                        end
                        local size = blocker and blocker.Size
                        local broadWall = size and math.max(size.X, size.Z) >= 10
                            and math.min(size.X, size.Z) <= 2.5 and size.Y >= 5
                        if blocker and isStructuralCover(blocker) then
                            wallCandidates += 1
                            searchCounts.wall += 1
                            showSearchCandidate(ground.Position + Vector3.new(0, 1.05, 0), "wall", checked)
                            -- Reject edge-of-wall spots: nearby points must also
                            -- be protected, or the player can remain exposed at a doorway.
                            local crouch = not standingBlocked
                            local robust = 0
                            for _, offset in ipairs({
                                Vector3.new(0.65, 0, 0), Vector3.new(-0.65, 0, 0),
                                Vector3.new(0, 0, 0.65), Vector3.new(0, 0, -0.65),
                            }) do
                                if protectedFromApproach(approachOrigins, ground.Position + offset, crouch) then
                                    robust += 1
                                end
                            end
                            if robust >= 2 then
                                searchCounts.robust += 1
                                showSearchCandidate(ground.Position + Vector3.new(0, 1.55, 0), "robust", checked)
                                local distance = (ground.Position - root.Position).Magnitude
                                -- Prefer verified positions near a structural wall,
                                -- but never trade away safety for a closer wall.
                                -- Probe horizontally at torso height, ignoring props.
                                local wallClearance = 8
                                for _, direction in ipairs({
                                    Vector3.new(1,0,0), Vector3.new(-1,0,0),
                                    Vector3.new(0,0,1), Vector3.new(0,0,-1),
                                }) do
                                    local probeOrigin = ground.Position + Vector3.new(0, 2.3, 0)
                                    local hit = workspace:Raycast(probeOrigin, direction * 8, params)
                                    if hit and isStructuralCover(hit.Instance) then
                                        wallClearance = math.min(wallClearance, hit.Distance)
                                    end
                                end
                                table.insert(choices, {
                                    position = ground.Position + Vector3.new(0, 2.5, 0),
                                    crouch = crouch,
                                    -- Prefer the physically closest verified safe position.
                                    -- Reachability is checked by PathfindingService below.
                                    score = distance + math.max(0, wallClearance - 1.25) * 1.5,
                                    wallClearance = wallClearance,
                                })
                            end
                        end
                    end
                end
        end
        table.sort(choices, function(x, y)
            return x.score < y.score
        end)
        -- Cover fallback must stay in the player's CURRENT room.
        for i = #choices, 1, -1 do
            if current and roomForPosition(choices[i].position) ~= current then
                table.remove(choices, i)
            end
        end
        if #choices == 0 then
            -- Do not walk to an arbitrary navigation-test destination.
            -- This button should move only when LOS cover has been verified.
            local topReason, topCount = "none", 0
            for reason, count in pairs(firstHitReasons) do
                if count > topCount then topReason, topCount = reason, count end
            end
            return false, string.format("%s: floor %d LOS %d robust %d; walls %d Rush pts %d rays %d+%d | %s",
                routeEstimated and "ESTIMATED RUSH ROUTE; no cover candidate" or "NO VERIFIED LOS COVER",
                groundCandidates, losCandidates, searchCounts.robust, #losStructuralParts,
                #approachOrigins, losRayDiagnostics.hits, losRayDiagnostics.boxed,
                topReason):sub(1, 190)
        end

        local renderName = "HackPanelRushCoverWalk"
        local function followPath(path, target, choiceRequiresCrouch)
            -- Validate walkability BEFORE moving. A navigation mesh can route
            -- across tall stair risers/raised platforms that DOORS cannot climb.
            -- Sample the actual floor under each route segment, not only waypoint Y.
            local route = path:GetWaypoints()
            local floorParams = RaycastParams.new()
            floorParams.FilterType = Enum.RaycastFilterType.Exclude
            floorParams.FilterDescendantsInstances = {LocalPlayer.Character}
            floorParams.IgnoreWater = true
            local previous = root.Position
            local function floorAt(point)
                local hit = workspace:Raycast(point + Vector3.new(0, 2.5, 0), Vector3.new(0, -8, 0), floorParams)
                if hit and hit.Normal.Y > 0.65 and hit.Instance.CanCollide then
                    return hit.Position.Y
                end
                return nil
            end
            local previousFloor = floorAt(previous)
            for _, waypoint in ipairs(route) do
                local destination = waypoint.Position
                local flatLength = (Vector3.new(destination.X, 0, destination.Z)
                    - Vector3.new(previous.X, 0, previous.Z)).Magnitude
                local samples = math.max(1, math.ceil(flatLength / 0.85))
                for j = 1, samples do
                    local sample = previous:Lerp(destination, j / samples)
                    local floorY = floorAt(sample)
                    if not floorY then
                        return false, "Route has unsupported floor"
                    end
                    if previousFloor and floorY - previousFloor > 1.2 then
                        return false, "Route requires climbing a high step"
                    end
                    if previousFloor and math.abs(floorY - previousFloor) > 2.2 then
                        return false, "Route crosses an abrupt height change"
                    end
                    previousFloor = floorY
                end
                previous = destination
            end
            showPathVisual(path:GetWaypoints(), "COVER")
            local movement = Vector3.zero
            local active, blocked = true, false
            local blockedConnection = path.Blocked:Connect(function() blocked = true end)
            pcall(function() RunService:UnbindFromRenderStep(renderName) end)
            RunService:BindToRenderStep(renderName, Enum.RenderPriority.Input.Value + 2, function()
                if not active then return end
                if humanoid.Parent and humanoid.Health > 0 then
                    humanoid:Move(movement, false)
                end
            end)
            local reached = false
            local ok, err = pcall(function()
                local allWaypoints = path:GetWaypoints()
                for waypointIndex, waypoint in ipairs(allWaypoints) do
                    if blocked or not navigationActive(generation) or humanoid.Health <= 0 then break end
                    if waypoint.Action == Enum.PathWaypointAction.Jump then humanoid.Jump = true end
                    local start, lastProgress, lastPos = os.clock(), os.clock(), root.Position
                    while os.clock() - start < 3.5 do
                        if blocked or not navigationActive(generation) or humanoid.Health <= 0 then break end
                        local delta = waypoint.Position - root.Position
                        local flat = Vector3.new(delta.X, 0, delta.Z)
                        local tolerance = waypointIndex == #allWaypoints and 1.55 or 2
                        if flat.Magnitude <= tolerance then
                            movement = Vector3.zero
                            break
                        end
                        -- Crouch only when an overhead obstacle actually
                        -- blocks standing clearance, and stand again after
                        -- passing it (unless the final cover requires crouch).
                        local lowPassage = needsCrouchForSegment(root.Position, waypoint.Position)
                        if lowPassage and passageIsClearWhileCrouched(root.Position, waypoint.Position) then
                            if not coverCrouchActive then setCoverCrouch(true) end
                        elseif not choiceRequiresCrouch and coverCrouchActive then
                            setCoverCrouch(false)
                        end
                        -- A full-speed Move command overshoots nearby waypoints,
                        -- then reverses each frame. Ease in to avoid ping-pong.
                        movement = flat.Unit * math.clamp((flat.Magnitude - tolerance) / 2.5, 0.2, 1)
                        if (root.Position - lastPos).Magnitude > 0.55 then
                            lastPos, lastProgress = root.Position, os.clock()
                        elseif os.clock() - lastProgress > 1.1 then
                            blocked = true
                            break
                        end
                        task.wait(0.06)
                    end
                    if blocked then break end
                end
                reached = (Vector3.new(root.Position.X, 0, root.Position.Z)
                    - Vector3.new(target.X, 0, target.Z)).Magnitude < 1.8
            end)
            active = false
            movement = Vector3.zero
            blockedConnection:Disconnect()
            pcall(function() RunService:UnbindFromRenderStep(renderName) end)
            pcall(function() humanoid:Move(Vector3.zero, false) end)
            return ok and reached and not blocked, ok and "Path blocked" or tostring(err)
        end

        -- No wall snap, forced facing, or camera override.  Pathfinding owns
        -- positioning; the player keeps full camera and rotation control.

        -- Visit verified cover candidates in nearest-first order. If the closest
        -- cannot be reached, try the next closest. Keep computations bounded
        -- and yield between attempts to avoid freezing the client.
        -- Try small floor-level offsets around each verified destination.
        -- A raycast-safe point can be inside a wall or too close to furniture
        -- for Roblox's navigation mesh to accept as a path endpoint.
        local attempts = 0
        local pathsComputed = 0
        -- Match the working closet navigator: choose a reachable approach
        -- point rather than requiring a path to an exact wall-side sample.
        local maxPaths = 60
        local characterFloorOffset = humanoid.HipHeight + root.Size.Y * 0.5
        local offsets = {
            Vector3.zero,
            Vector3.new(2, 0, 0), Vector3.new(-2, 0, 0),
            Vector3.new(0, 0, 2), Vector3.new(0, 0, -2),
            Vector3.new(3, 0, 3), Vector3.new(-3, 0, 3),
            Vector3.new(3, 0, -3), Vector3.new(-3, 0, -3),
            Vector3.new(1.5, 0, 0), Vector3.new(-1.5, 0, 0),
            Vector3.new(0, 0, 1.5), Vector3.new(0, 0, -1.5),
        }
        local failedReason = "No path to verified cover"
        -- If the player is already within a verified position's arrival
        -- tolerance, stop instead of oscillating between adjacent dots.
        for _, choice in ipairs(choices) do
            local flatDistance = (Vector3.new(root.Position.X, 0, root.Position.Z)
                - Vector3.new(choice.position.X, 0, choice.position.Z)).Magnitude
            if flatDistance <= 2.1 then
                setCoverCrouch(choice.crouch)
                rushStatus.Text = "LOS: already at verified cover - holding position"
                return true
            end
        end
        for i = 1, math.min(#choices, 40) do
            if not navigationActive(generation) then return false, "Cancelled" end
            if pathsComputed >= maxPaths then break end
            local choice = choices[i]
            attempts += 1
            for _, offset in ipairs(offsets) do
                if pathsComputed >= maxPaths then break end
                local target = choice.position + offset
                local floorHit = workspace:Raycast(target + Vector3.new(0, 3, 0), Vector3.new(0, -8, 0), params)
                local floorY = root.Position.Y - humanoid.HipHeight - root.Size.Y * 0.5
                if floorHit and floorHit.Normal.Y > 0.85
                    and floorHit.Instance.CanCollide
                    and math.abs(floorHit.Position.Y - floorY) <= 4.5
                    and (not current or roomForPosition(floorHit.Position + Vector3.new(0, 2.5, 0)) == current)
                    and protectedFromApproach(approachOrigins, floorHit.Position, choice.crouch) then
                    target = floorHit.Position + Vector3.new(0, characterFloorOffset, 0)
                    pathsComputed += 1
                    rushStatus.Text = string.format("LOS: path to nearest safe cover #%d (%d/%d)", attempts, pathsComputed, maxPaths)
                    -- The crouch-sized navigation mesh can reject entire DOORS
                    -- rooms. Try normal standing clearance first, then narrow
                    -- and crouch clearance. Only use routes the engine accepts.
                    local path, pathError
                    for _, agent in ipairs({
                        {radius = 1.5, height = 5},
                        {radius = 2, height = 5},
                        {radius = 1.5, height = 3},
                        {radius = 1, height = 3},
                    }) do
                        if not navigationActive(generation) then break end
                        rushStatus.Text = string.format(
                            "LOS: route %d/%d | agent %.1f x %.1f",
                            pathsComputed, maxPaths, agent.radius, agent.height
                        )
                        local ok, result = pcall(function()
                            local computed = PathfindingService:CreatePath({
                                AgentRadius = agent.radius,
                                AgentHeight = agent.height,
                                AgentCanJump = true,
                                AgentCanClimb = false,
                                WaypointSpacing = 3,
                            })
                            computed:ComputeAsync(root.Position, target)
                            return computed
                        end)
                        if ok and result and result.Status == Enum.PathStatus.Success then
                            path = result
                            break
                        end
                        pathError = ok and (result and tostring(result.Status) or "No path")
                            or tostring(result)
                        task.wait(0.02)
                    end
                    if path then
                        rushStatus.Text = routeEstimated and "DEBUG LOS: moving to candidate (estimated Rush route)"
                            or "LOS: walking to cover"
                        local reached, reason = followPath(path, target, choice.crouch)
                        if reached then
                            setCoverCrouch(choice.crouch)
                            local groundPos = root.Position - Vector3.new(0, 2.5, 0)
                            local currentRushPos = rushPosition()
                            if currentRushPos and protectedFromApproach(
                                approachOrigins, groundPos, choice.crouch) then
                                -- Arriving at verified cover is the end of movement.
                                -- Do not move toward the wall or force the camera.
                                rushStatus.Text = routeEstimated
                                    and "DEBUG LOS: cover candidate reached; Rush route UNVERIFIED"
                                    or "LOS: reached verified cover (camera free)"
                                return true
                            else
                                failedReason = "Reached route but position was exposed"
                                -- Don't immediately ping-pong to another point
                                -- a stud away. Hold still and report uncertainty.
                                local flatDistance = (Vector3.new(root.Position.X, 0, root.Position.Z)
                                    - Vector3.new(target.X, 0, target.Z)).Magnitude
                                if flatDistance <= 2.1 then
                                    return false, "At cover candidate, but final LOS check uncertain; holding position"
                                end
                            end
                        else
                            failedReason = reason or "Could not follow route"
                        end
                    else
                        failedReason = "Pathfinding rejected route (" .. tostring(pathError) .. ")"
                    end
                    task.wait(0.05)
                end
            end
        end
        setCoverCrouch(false)
        return false, "Could not reach verified cover: " .. failedReason
    end

    local function useCoverFallback(generation)
        rushStatus.Text = "No reachable closet - seeking line-of-sight cover..."
        local reached, reason = moveToCover(generation)
        if not reached then
            setCoverCrouch(false)
            rushStatus.Text = "Cover failed: " .. tostring(reason)
            return
        end
        rushStatus.Text = "Behind cover - stay out of Rush's sight"
        local goneSince = nil
        while rushAutoEnabled and rushGeneration == generation do
            if not rushModel() then
                goneSince = goneSince or os.clock()
                if os.clock() - goneSince > 2.5 then break end
            else
                goneSince = nil
            end
            task.wait(0.15)
        end
        if rushAutoEnabled and rushGeneration == generation then
            setCoverCrouch(false)
            rushStatus.Text = "Rush passed - cover complete"
        end
    end

    local function adjacentRoomPassable(currentRoom, adjacentRoom)
        -- Avoid deliberately routing through a visibly locked/closed door.
        -- This is conservative: unknown door states are tested with a short ray.
        if not currentRoom or not adjacentRoom then return false end
        for _, room in ipairs({currentRoom, adjacentRoom}) do
            local door = room:FindFirstChild("Door", true)
            if door then
                for _, key in ipairs({"Locked", "IsLocked"}) do
                    if door:GetAttribute(key) == true then return false end
                    local value = door:FindFirstChild(key)
                    if value and value:IsA("BoolValue") and value.Value then return false end
                end
                local locked = door:FindFirstChild("Lock", true)
                if locked and locked:IsA("BasePart") and locked.Transparency < 0.95 then
                    return false
                end
            end
        end
        return true
    end

    local function handleRush()
        if rushBusy then return end
        rushBusy = true
        local generation = rushGeneration
        local character = LocalPlayer.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if not root then rushBusy = false; return end
        local allCandidates = closetCandidates(root.Position)
        local currentRoom = getCurrentRoom()
        local currentCandidates, adjacentCandidates = {}, {}
        for _, candidate in ipairs(allCandidates) do
            if candidate.currentRoom then
                table.insert(currentCandidates, candidate)
            elseif adjacentRoomPassable(currentRoom, candidate.room) then
                table.insert(adjacentCandidates, candidate)
            end
        end
        -- Priority: CURRENT room closets -> CURRENT room LOS cover -> adjacent unlocked rooms.
        local function attemptClosets(candidates)
            local lastFailure = ""
        for i, candidate in ipairs(candidates) do
            if not rushAutoEnabled or rushGeneration ~= generation then break end
            if isActuallyHiding() then
                rushStatus.Text = "Already hiding"
                return true
            end
            rushStatus.Text = "Rush - approaching closet " .. i .. "/" .. #candidates
            local reached, reason = walkToCloset(candidate, generation)
            if reached then
                -- Prepare at the closet, but don't enter immediately: Hide can
                -- force players out if they remain inside too long.
                rushStatus.Text = "At closet - waiting for Rush to approach"
                local missingSince = nil
                local waitStart = os.clock()
                while rushAutoEnabled and rushGeneration == generation do
                    -- If the player walks away while waiting, guide them back
                    -- to the same closet before Rush reaches attack range.
                    local currentCharacter = LocalPlayer.Character
                    local currentRoot = currentCharacter and currentCharacter:FindFirstChild("HumanoidRootPart")
                    local holder = candidate.prompt and candidate.prompt.Parent
                    local promptPosition = holder and holder:IsA("Attachment") and holder.WorldPosition
                        or (holder and holder:IsA("BasePart") and holder.Position)
                        or candidate.position
                    local promptRange = candidate.prompt and candidate.prompt.MaxActivationDistance or 6
                    if currentRoot and not isActuallyHiding()
                        and (currentRoot.Position - promptPosition).Magnitude > math.max(2, promptRange - 0.25) then
                        rushStatus.Text = "Moved away - returning to closet..."
                        local returned, returnReason = walkToCloset(candidate, generation)
                        if not returned then
                            rushStatus.Text = "Could not return to closet: " .. tostring(returnReason)
                            return true
                        end
                        rushStatus.Text = "Back at closet - waiting for Rush"
                    end
                    local distance = rushDistance()
                    if distance and distance <= RUSH_ENTER_DISTANCE then break end
                    if not distance then
                        missingSince = missingSince or os.clock()
                        if os.clock() - missingSince >= RUSH_MISSING_SECONDS then
                            rushStatus.Text = "Rush disappeared before reaching closet"
                            return true
                        end
                    else
                        missingSince = nil
                    end
                    if os.clock() - waitStart > 35 then
                        rushStatus.Text = "Rush did not approach - waiting for next Rush"
                        return true
                    end
                    task.wait(0.1)
                end
                if not rushAutoEnabled or rushGeneration ~= generation then break end
                local hidden, interactionReason = tryHide(candidate, generation)
                if hidden then
                    rushHiddenByAutomation = true
                    rushHidingCandidate = candidate
                    rushStatus.Text = "Hiding - waiting for Rush to pass"
                    -- Do not exit simply because Rush is far away or briefly
                    -- streams out. Require a close approach, followed by a
                    -- sustained increase in distance (Rush has passed).
                    local safeSince, goneSince = nil, nil
                    local closestDistance = math.huge
                    local rushWasClose = false
                    local recedingSamples = 0
                    local previousDistance = nil
                    while rushAutoEnabled and rushGeneration == generation do
                        local distance = rushDistance()
                        if distance then
                            goneSince = nil
                            closestDistance = math.min(closestDistance, distance)
                            if distance <= 75 then rushWasClose = true end
                            if rushWasClose and previousDistance
                                and distance > previousDistance + 0.6 then
                                recedingSamples = math.min(recedingSamples + 1, 20)
                            elseif previousDistance and distance < previousDistance - 0.6 then
                                recedingSamples = 0
                                safeSince = nil
                            end
                            -- Require that Rush was nearby, is now clearly
                            -- farther than its closest approach, and has
                            -- continued receding for multiple samples.
                            if rushWasClose and recedingSamples >= 3
                                and distance >= RUSH_SAFE_DISTANCE
                                and distance >= closestDistance + 35 then
                                safeSince = safeSince or os.clock()
                            else
                                safeSince = nil
                            end
                            previousDistance = distance
                        else
                            goneSince = goneSince or os.clock()
                        end
                        local passed = safeSince
                            and os.clock() - safeSince >= RUSH_SAFE_SECONDS
                        local vanishedAfterApproach = rushWasClose and goneSince
                            and os.clock() - goneSince >= RUSH_MISSING_SECONDS
                        if passed or vanishedAfterApproach then
                            rushStatus.Text = "Rush passed closet - exiting..."
                            leaveCloset(candidate)
                            rushHiddenByAutomation = false
                            rushHidingCandidate = nil
                            break
                        end
                        task.wait(0.1)
                    end
                else
                    rushStatus.Text = "At closet: " .. (interactionReason or "interaction unconfirmed")
                end
                return true
            end
            lastFailure = reason or "Path failed"
            if lastFailure:find("movement blocked", 1, true) or lastFailure:find("Movement disabled", 1, true) then
                break
            end
        end
            return false
        end

        local completed = attemptClosets(currentCandidates)
        if not completed and rushAutoEnabled and rushGeneration == generation then
            -- Prefer hiding behind a desk/wall in the current room to entering
            -- a different room. Cover failure is nonfatal; try nearby rooms next.
            local covered, reason = moveToCover(generation)
            if covered then
                rushStatus.Text = "Behind cover - waiting for Rush to pass"
                local goneSince = nil
                while rushAutoEnabled and rushGeneration == generation do
                    if not rushModel() then
                        goneSince = goneSince or os.clock()
                        if os.clock() - goneSince > RUSH_MISSING_SECONDS then break end
                    else
                        goneSince = nil
                    end
                    task.wait(0.15)
                end
                setCoverCrouch(false)
                completed = true
            else
                setCoverCrouch(false)
                rushStatus.Text = "Current-room cover unavailable: " .. tostring(reason)
            end
        end
        if not completed and rushAutoEnabled and rushGeneration == generation then
            if #adjacentCandidates > 0 then
                rushStatus.Text = "Trying accessible adjacent-room closet..."
                completed = attemptClosets(adjacentCandidates)
            end
        end
        if not completed and rushAutoEnabled and rushGeneration == generation then
            rushStatus.Text = "No reachable closet or LOS cover in accessible rooms"
        end
        rushBusy = false
    end

    -- Debug tests are independent: Closet only searches closets; LOS only
    -- searches cover. No fake Rush instance is added to workspace.
    local debugClosetButton = makeButton(hotelPages.Auto, "DEBUG: CLOSETS",
        UDim2.new(0.5, -266, 0, 292), UDim2.fromOffset(258, 38))
    local debugLosButton = makeButton(hotelPages.Auto, "DEBUG: LOS COVER",
        UDim2.new(0.5, 8, 0, 292), UDim2.fromOffset(258, 38))
    debugClosetButton.ZIndex = 36
    debugLosButton.ZIndex = 36

    local function startDebug(mode)
        if rushBusy or debugMode then
            rushStatus.Text = "Navigation already running - wait for completion"
            return
        end
        if rushModel() then
            rushStatus.Text = "Real Rush present - debug disabled for safety"
            return
        end
        local character = LocalPlayer.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if not root then rushStatus.Text = "Character not ready"; return end
        rushGeneration += 1
        local generation = rushGeneration
        debugMode = mode
        rushBusy = true
        -- LOS needs a simulated source. Aim it toward the previous room's
        -- entrance when available; otherwise use a point 35 studs behind you.
        local currentRoom, roomNumber = getCurrentRoom()
        local rooms = getCurrentRooms()
        local previousRoom = rooms and roomNumber and rooms:FindFirstChild(tostring(roomNumber - 1))
        local previousDoor = previousRoom and previousRoom:FindFirstChild("Door", true)
        local doorPart = previousDoor and (previousDoor:IsA("BasePart") and previousDoor
            or previousDoor:FindFirstChildWhichIsA("BasePart", true))
        debugRushOrigin = doorPart and (doorPart.Position + Vector3.new(0, 2, 0))
            or (root.Position - root.CFrame.LookVector * 35 + Vector3.new(0, 2, 0))
        task.spawn(function()
            local ok, err = pcall(function()
                if mode == "CLOSET" then
                    rushStatus.Text = "DEBUG CLOSET: searching current room first..."
                    local candidates = closetCandidates(root.Position)
                    table.sort(candidates, function(a,b)
                        if a.currentRoom ~= b.currentRoom then return a.currentRoom end
                        return a.distance < b.distance
                    end)
                    if #candidates == 0 then
                        rushStatus.Text = "DEBUG CLOSET: no closets in current/adjacent rooms"
                        return
                    end
                    local lastReason = "No reachable closet"
                    for _, candidate in ipairs(candidates) do
                        if not navigationActive(generation) then return end
                        rushStatus.Text = "DEBUG CLOSET: navigating to " .. candidate.model.Name
                        local reached, reason = walkToCloset(candidate, generation)
                        if reached then
                            rushStatus.Text = "DEBUG CLOSET: arrived within prompt range (no E pressed)"
                            return
                        end
                        lastReason = tostring(reason)
                    end
                    rushStatus.Text = "DEBUG CLOSET: " .. lastReason
                else
                    rushStatus.Text = "DEBUG LOS: testing cover only (no closets)..."
                    local reached, reason = moveToCover(generation)
                    if reached then
                        rushStatus.Text = "DEBUG LOS: reached Rush-route verified cover"
                        task.wait(2)
                    else
                        rushStatus.Text = "DEBUG LOS: " .. tostring(reason)
                    end
                    setCoverCrouch(false)
                end
            end)
            if not ok then rushStatus.Text = "DEBUG ERROR: " .. tostring(err):sub(1, 95) end
            debugMode = nil
            debugRushOrigin = nil
            rushBusy = false
        end)
    end
    debugClosetButton.MouseButton1Click:Connect(function() startDebug("CLOSET") end)
    debugLosButton.MouseButton1Click:Connect(function() startDebug("LOS") end)

    rushButton.MouseButton1Click:Connect(function()
        rushAutoEnabled = not rushAutoEnabled
        rushGeneration += 1
        if not rushAutoEnabled then clearPathVisual(); clearRushRoutePreview() end
        rushButton.Text = rushAutoEnabled and "RUSH AUTO-HIDE: ON" or "RUSH AUTO-HIDE: OFF"
        rushStatus.Text = rushAutoEnabled and "Watching for Rush..." or "Rush auto-hide is off"
    end)

    task.spawn(function()
        local lastRush = nil
        local rushGoneAt = nil
        while menuGui and menuGui.Parent do
            local currentRush = rushModel()
            if currentRush then
                rushGoneAt = nil
                -- Rush warnings are controlled by the Warnings tab checklist.
                if rushAutoEnabled and currentRush ~= lastRush then
                    lastRush = currentRush
                    task.spawn(handleRush)
                end
            else
                if lastRush then
                    rushGoneAt = rushGoneAt or os.clock()
                    -- Briefly keep the alert to avoid flickering during model streaming.
                    if os.clock() - rushGoneAt >= 1.2 then
                        lastRush = nil
                        refreshEntities()
                        if rushAutoEnabled then
                            -- Rush handler manages disappearance and exiting the closet itself
                            if not isActuallyHiding() then rushStatus.Text = "Watching for Rush..." end
                        else
                            rushStatus.Text = "Rush auto-hide is off"
                        end
                    end
                end
            end
            task.wait(0.2)
        end

    end)

    local function openFloorDetail(name)
        detailTitle.Text = name
        detailPanel.Visible = true
        nav.Visible = false
        cards.Visible = false
        espButton.Visible = name == "THE CANDY VAULT"
        detailMessage.Visible = name ~= "THE CANDY VAULT" and name ~= "THE HOTEL"
        doorPanel.Visible = name == "THE HOTEL"
        if name == "THE HOTEL" then doorCaption.Text = "SELECT HOTEL DOOR" end
        updateEspButton()
    end

    detailBack.MouseButton1Click:Connect(function()
        detailPanel.Visible = false
        cards.Visible = true
        nav.Visible = true
    end)

    buildCards = function(section)
        for _, child in ipairs(cards:GetChildren()) do
            if child:IsA("GuiObject") and child ~= cardLayout then child:Destroy() end
        end
        local names, accentColors
        if section == "Floors" then
            names = {"THE HOTEL", "THE MINES"}
            accentColors = {Color3.fromRGB(255, 218, 183), Color3.fromRGB(210, 211, 255)}
        elseif section == "Subfloors" then
            names = {"THE ARCHIVES", "THE OUTDOORS", "THE STAIRWELL", "THE BACKDOOR"}
            accentColors = {Color3.fromRGB(190, 205, 255), Color3.fromRGB(195, 235, 160), Color3.fromRGB(210, 210, 210), Color3.fromRGB(255, 220, 130)}
        else
            names = {"RUSH MODE", "CRINGLE'S WORKSHOP", "TRICK OR TREAT", "RETRO MODE", "SUPER HARD MODE", "HOTEL-", "THE ROOMS", "THE CANDY VAULT"}
            accentColors = {
                Color3.fromRGB(255, 255, 255), -- Rush Mode: white
                Color3.fromRGB(124, 235, 241), -- Cringle's Workshop: cyan
                Color3.fromRGB(224, 135, 237), -- Trick or Treat: purple-pink
                Color3.fromRGB(255, 236, 144), -- Retro Mode: pale yellow
                Color3.fromRGB(255, 151, 151), -- Super Hard Mode: coral
                Color3.fromRGB(143, 188, 255), -- Hotel-: blue
                Color3.fromRGB(255, 247, 151), -- The Rooms: yellow
                Color3.fromRGB(255, 205, 176), -- The Candy Vault: peach
            }
        end
        for index, name in ipairs(names) do
            local card = Instance.new("TextButton")
            card.Name = name:gsub("%s+", "") .. "Card"
            card.Size = UDim2.fromOffset(610, 155)
            card.BackgroundColor3 = Color3.fromRGB(24, 19, 19)
            card.BackgroundTransparency = 0.18
            card.BorderSizePixel = 0
            card.Text = ""
            card.LayoutOrder = index
            card.ClipsDescendants = true
            card.Parent = cards
            local corner = Instance.new("UICorner")
            corner.CornerRadius = UDim.new(0, 13)
            corner.Parent = card
            local tint = Instance.new("Frame")
            tint.Size = UDim2.fromScale(1, 1)
            tint.BackgroundColor3 = accentColors[index]
            tint.BackgroundTransparency = 0.88
            tint.BorderSizePixel = 0
            tint.Parent = card
            local tintCorner = Instance.new("UICorner")
            tintCorner.CornerRadius = UDim.new(0, 13)
            tintCorner.Parent = tint
            local images = loadedImages[name] or {}
            if images[1] then
                local background = Instance.new("ImageLabel")
                background.Name = "CardBackground"
                background.BackgroundTransparency = 1
                background.Size = UDim2.fromScale(1, 1)
                background.Image = images[1]
                background.ScaleType = Enum.ScaleType.Crop
                background.ZIndex = card.ZIndex + 1
                background.Parent = card
                local imageCorner = Instance.new("UICorner")
                imageCorner.CornerRadius = UDim.new(0, 13)
                imageCorner.Parent = background
            end
            local label = Instance.new("TextLabel")
            label.BackgroundTransparency = 1
            label.Size = UDim2.new(1, -20, 1, 0)
            label.Position = UDim2.fromOffset(10, 0)
            label.Font = Enum.Font.GothamBlack
            label.TextSize = 32
            label.TextColor3 = accentColors[index]
            label.TextStrokeTransparency = 0.65
            label.TextStrokeColor3 = Color3.new(0, 0, 0)
            label.TextWrapped = true
            label.Text = name
            label.ZIndex = card.ZIndex + 3
            label.Parent = card
            if images[2] then
                local wordmark = Instance.new("ImageLabel")
                wordmark.Name = "CardTitle"
                wordmark.BackgroundTransparency = 1
                wordmark.AnchorPoint = Vector2.new(0.5, 0.5)
                wordmark.Position = UDim2.fromScale(0.5, 0.5)
                wordmark.Size = UDim2.new(0.38, 0, 0.80, 0)
                wordmark.Image = images[2]
                wordmark.ScaleType = Enum.ScaleType.Fit
                wordmark.ZIndex = card.ZIndex + 4
                wordmark.Parent = card
                label.Visible = false
            end
            -- Every card gets its own colored rounded outline, matching its floor.
            -- Inset the border so its full thickness remains visible inside the clipped card.
            local borderOverlay = Instance.new("Frame")
            borderOverlay.Name = "CardOutlineOverlay"
            borderOverlay.AnchorPoint = Vector2.new(0.5, 0.5)
            borderOverlay.Position = UDim2.fromScale(0.5, 0.5)
            borderOverlay.Size = UDim2.new(1, -8, 1, -8)
            borderOverlay.BackgroundTransparency = 1
            borderOverlay.BorderSizePixel = 0
            borderOverlay.Active = false
            borderOverlay.ZIndex = card.ZIndex + 10
            borderOverlay.Parent = card

            local borderCorner = Instance.new("UICorner")
            borderCorner.CornerRadius = UDim.new(0, 12)
            borderCorner.Parent = borderOverlay

            local outline = Instance.new("UIStroke")
            outline.Name = "FloorColoredOutline"
            outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
            outline.Color = accentColors[index]
            outline.Thickness = 5
            outline.Transparency = 0
            outline.Parent = borderOverlay
            card.MouseButton1Click:Connect(function()
                openFloorDetail(name)
            end)
        end
    end
    local function selectSection(name)
        currentSection = name
        buildCards(name)
        floorsButton.BackgroundColor3 = name == "Floors" and Color3.fromRGB(100, 72, 48) or Color3.fromRGB(65, 50, 40)
        subfloorsButton.BackgroundColor3 = name == "Subfloors" and Color3.fromRGB(100, 72, 48) or Color3.fromRGB(65, 50, 40)
        visionsButton.BackgroundColor3 = name == "Visions" and Color3.fromRGB(100, 72, 48) or Color3.fromRGB(65, 50, 40)
    end

    -- Main menu is a vertical list. More categories can be added here later.
    local homePanel = Instance.new("Frame")
    homePanel.Name = "HomePanel"
    homePanel.Size = UDim2.fromScale(1, 1)
    homePanel.BackgroundTransparency = 1
    homePanel.Parent = menuBody

    local homeList = Instance.new("ScrollingFrame")
    homeList.Name = "MainMenuList"
    homeList.Size = UDim2.fromScale(1, 1)
    homeList.BackgroundTransparency = 1
    homeList.BorderSizePixel = 0
    homeList.ScrollBarThickness = 6
    homeList.AutomaticCanvasSize = Enum.AutomaticSize.Y
    homeList.CanvasSize = UDim2.new()
    homeList.Parent = homePanel

    local homePadding = Instance.new("UIPadding")
    homePadding.PaddingTop = UDim.new(0, 6)
    homePadding.PaddingBottom = UDim.new(0, 8)
    homePadding.PaddingLeft = UDim.new(0, 6)
    homePadding.PaddingRight = UDim.new(0, 12)
    homePadding.Parent = homeList

    local homeLayout = Instance.new("UIListLayout")
    homeLayout.SortOrder = Enum.SortOrder.LayoutOrder
    homeLayout.Padding = UDim.new(0, 8)
    homeLayout.Parent = homeList

    -- Home category uses the Hotel card styling: image background, centered
    -- plain text (NO Hotel logo), and the same cream rounded outline.
    homeLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    local floorsCategory = Instance.new("TextButton")
    floorsCategory.Name = "FloorsCategory"
    floorsCategory.Size = UDim2.fromOffset(610, 155) -- Same exact shape as the floor cards
    floorsCategory.BackgroundColor3 = Color3.fromRGB(24, 19, 19)
    floorsCategory.BackgroundTransparency = 0.18
    floorsCategory.BorderSizePixel = 0
    floorsCategory.Text = ""
    floorsCategory.ClipsDescendants = true
    floorsCategory.Parent = homeList

    local categoryCorner = Instance.new("UICorner")
    categoryCorner.CornerRadius = UDim.new(0, 13)
    categoryCorner.Parent = floorsCategory

    local homeBackground = Instance.new("ImageLabel")
    homeBackground.Name = "HotelBackground"
    homeBackground.BackgroundTransparency = 1
    homeBackground.Size = UDim2.fromScale(1, 1)
    homeBackground.ScaleType = Enum.ScaleType.Crop
    homeBackground.ZIndex = floorsCategory.ZIndex + 1
    homeBackground.Parent = floorsCategory
    local bgCorner = Instance.new("UICorner")
    bgCorner.CornerRadius = UDim.new(0, 13)
    bgCorner.Parent = homeBackground

    refreshHomeCard = function()
        local hotelImages = loadedImages["THE HOTEL"]
        if hotelImages and hotelImages[1] then
            homeBackground.Image = hotelImages[1]
        end
    end
    refreshHomeCard()

    local categoryLabel = Instance.new("TextLabel")
    categoryLabel.Name = "FloorsLabel"
    categoryLabel.BackgroundTransparency = 1
    categoryLabel.Size = UDim2.fromScale(1, 1)
    categoryLabel.Font = Enum.Font.GothamBlack
    categoryLabel.TextSize = 34
    categoryLabel.Text = "FLOORS"
    categoryLabel.TextColor3 = Color3.fromRGB(255, 231, 206)
    categoryLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    categoryLabel.TextStrokeTransparency = 0.35
    categoryLabel.ZIndex = floorsCategory.ZIndex + 3
    categoryLabel.Parent = floorsCategory

    local homeBorder = Instance.new("Frame")
    homeBorder.Name = "CreamOutlineOverlay"
    homeBorder.AnchorPoint = Vector2.new(0.5, 0.5)
    homeBorder.Position = UDim2.fromScale(0.5, 0.5)
    homeBorder.Size = UDim2.new(1, -8, 1, -8)
    homeBorder.BackgroundTransparency = 1
    homeBorder.Active = false
    homeBorder.ZIndex = floorsCategory.ZIndex + 10
    homeBorder.Parent = floorsCategory
    local borderCorner = Instance.new("UICorner")
    borderCorner.CornerRadius = UDim.new(0, 12)
    borderCorner.Parent = homeBorder
    local homeStroke = Instance.new("UIStroke")
    homeStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    homeStroke.Color = Color3.fromRGB(255, 231, 206)
    homeStroke.Thickness = 5
    homeStroke.Parent = homeBorder

    local function showHome()
        detailPanel.Visible = false
        cards.Visible = true
        nav.Visible = false
        tabPanel.Visible = false
        homePanel.Visible = true
    end

    local function showFloorsMenu()
        detailPanel.Visible = false
        cards.Visible = true
        homePanel.Visible = false
        nav.Visible = true
        tabPanel.Visible = true
        selectSection("Floors")
    end

    floorsCategory.MouseButton1Click:Connect(showFloorsMenu)
    backButton.MouseButton1Click:Connect(showHome)

    floorsButton.MouseButton1Click:Connect(function() selectSection("Floors") end)
    subfloorsButton.MouseButton1Click:Connect(function() selectSection("Subfloors") end)
    visionsButton.MouseButton1Click:Connect(function() selectSection("Visions") end)
    selectSection("Floors")
    showHome()
    task.spawn(fetchAllImages)
end

createMenu()
updateCursor()

-- ==========================================================
-- MENU TOGGLE
-- ==========================================================

inputConnection = UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
    if not scriptRunning then
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

-- Start with ESP disabled.
clearOldESP()
