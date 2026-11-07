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
for _, descendant in ipairs(workspace:GetDescendants()) do
    if (descendant:IsA("Highlight") and descendant.Name == "HackPanelEntityOutline")
        or (descendant:IsA("BoxHandleAdornment") and descendant.Name == "HackPanelEntityBox") then
        descendant:Destroy()
    end
end
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
local SCAN_INTERVAL_SECONDS = 3.0
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
        while isEspActive and isCurrentRun() do
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

    local lastEspDraw = 0
    mainRenderConnection = RunService.RenderStepped:Connect(function()
        if not isCurrentRun() then
            mainRenderConnection:Disconnect()
            return
        end
        if os.clock() - lastEspDraw < 0.085 then return end
        lastEspDraw = os.clock()
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
    autoDescription.Text = "Rush assistance and door controls"
    autoDescription.TextColor3 = Color3.fromRGB(245, 225, 197)
    autoDescription.Font = Enum.Font.Gotham
    autoDescription.TextSize = 14
    autoDescription.ZIndex = 36
    autoDescription.Parent = hotelPages.Auto

    -- Item ESP is intentionally available only in THE CANDY VAULT.
    -- Other floors retain Entity Wall ESP and floor-specific ESP tools.

    -- Adaptive fixture night vision. A single heartbeat handles both already-dark
    -- rooms and lights that fade out while the player remains in a room.
    local nightVisionEnabled = false
    local activeFloorName = "THE HOTEL"
    local stairLightingOriginal = nil
    local stairCounterEnabled = false
    local stairEspEnabled = false
    local LightingService = game:GetService("Lighting")
    local function restoreStairLighting()
        if stairLightingOriginal then
            LightingService.Ambient = stairLightingOriginal.ambient
            LightingService.OutdoorAmbient = stairLightingOriginal.outdoor
            LightingService.Brightness = stairLightingOriginal.brightness
            LightingService.ExposureCompensation = stairLightingOriginal.exposure
            stairLightingOriginal = nil
        end
    end
    local function applyStairLighting()
        if activeFloorName ~= "THE STAIRWELL" then return end
        if not stairLightingOriginal then
            stairLightingOriginal = {ambient=LightingService.Ambient,
                outdoor=LightingService.OutdoorAmbient,
                brightness=LightingService.Brightness,
                exposure=LightingService.ExposureCompensation}
        end
        -- Global fill light works even in rooms with no actual lamp objects.
        LightingService.Ambient = Color3.fromRGB(165, 165, 165)
        LightingService.OutdoorAmbient = Color3.fromRGB(165, 165, 165)
        LightingService.Brightness = math.max(LightingService.Brightness, 3)
        LightingService.ExposureCompensation = math.max(LightingService.ExposureCompensation, 0.65)
    end
    local nvGeneration = 0
    local nvRecords = {}
    local nvVisualRecords = {}
    local nvRoomConnection = nil
    local nvScanGeneration = 0
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
        if not nvIsLight(light) or nvRecords[light] then return end
        -- Dark rooms can use lights outside the named fixture folders.
        local brightness = light.Brightness
        -- Dark-room fixtures often start at exactly zero. They must still be
        -- registered, even when there is no known fixture fallback.
        local fallback = nvFallback(light)
        local fixture = light:FindFirstAncestor("LightFixture")
            or light:FindFirstAncestor("Light_Fixtures")
            or light:FindFirstAncestor("Chandelier")
            or light:FindFirstAncestor("Lamp")
            or light:FindFirstAncestor("WallLamp")
            or light:FindFirstAncestor("WallLight")
        local rec = {
            baseline = brightness > 0.025 and brightness or 0.3,
            initialRange = light.Range,
            initialEnabled = light.Enabled,
            initialBrightness = brightness,
            lastObserved = brightness,
            lastChange = os.clock(),
            restored = false,
            broken = brightness <= 0.025,
            fixture = fixture,
        }
        nvRecords[light] = rec
    end
    -- Learn the original visual properties from an already-lit lamp, rather
    -- than inventing a yellow tint. ReplicatedStorage templates are preferred.
    local nvReferenceByName = {}
    local nvReferenceDefault = nil
    local nvReferenceReady = false
    local nvBulbNames = {neon=true, bulb=true, lightbulb=true,
        lightpart=true, diffuser=true, glow=true}
    local function nvIsBulb(part)
        return part:IsA("BasePart") and nvBulbNames[part.Name:lower()] == true
    end
    local function nvReference(part)
        return {material=part.Material, color=part.Color,
            transparency=part.Transparency, reflectance=part.Reflectance}
    end
    local function nvCollectReferences(root, generation, requireLit)
        if not root then return end
        local descendants = root:GetDescendants()
        for i, part in ipairs(descendants) do
            if not nightVisionEnabled or generation ~= nvGeneration then return end
            if nvIsBulb(part) and part.Material == Enum.Material.Neon then
                local qualifies = true
                if requireLit then
                    qualifies = false
                    local fixture = part.Parent
                    for _ = 1, 4 do
                        if not fixture then break end
                        for _, light in ipairs(fixture:GetDescendants()) do
                            if nvIsLight(light) and light.Enabled and light.Brightness > 0.3 then
                                qualifies = true
                                break
                            end
                        end
                        if qualifies then break end
                        fixture = fixture.Parent
                    end
                end
                if qualifies then
                    local ref = nvReference(part)
                    local key = part.Name:lower()
                    if not nvReferenceByName[key] then nvReferenceByName[key] = ref end
                    if not nvReferenceDefault then nvReferenceDefault = ref end
                end
            end
            if i % 175 == 0 then task.wait() end
        end
    end
    local function nvVisual(fixture)
        if not fixture then return end
        for _, part in ipairs(fixture:GetDescendants()) do
            if nvIsBulb(part) then
                if not nvVisualRecords[part] then
                    nvVisualRecords[part] = {
                        initialTransparency = part.Transparency,
                        initialMaterial = part.Material,
                        initialColor = part.Color,
                        initialReflectance = part.Reflectance,
                    }
                end
                -- Prefer a matching real bulb; avoid using an unrelated template
                -- whose color could give the fixture an unwanted tint.
                local reference = nvReferenceByName[part.Name:lower()]
                if reference then
                    pcall(function()
                        part.Material = reference.material
                        part.Color = reference.color
                        part.Transparency = reference.transparency
                        part.Reflectance = reference.reflectance
                    end)
                end
                -- No fabricated tint when a matching real lamp isn't available.
            end
        end
    end
    local function nvTick(rooms)
        local now = os.clock()
        local restoredCount = 0
        local trackedCount = 0
        -- Light discovery is handled by a batched initial scan and DescendantAdded.
        -- Never traverse the entire CurrentRooms tree on every tick.
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
                if current <= 0.025 then
                    rec.broken = true
                end
                if rec.fixture then brokenFixtures[rec.fixture] = true end
                -- Apply the minimum immediately, including lights starting at 0.
                -- Keep it active if the game disables or dims it again.
                if current < 0.3 or not light.Enabled or light.Range <= 0 then
                    pcall(function()
                        light.Enabled = true
                        light.Brightness = math.max(current, 0.3)
                        if light.Range <= 0 then light.Range = 16 end
                    end)
                    rec.lastObserved = light.Brightness
                    rec.restored = true
                end
                if rec.restored then restoredCount += 1 end
            end
        end
        -- Wait until genuine lamp appearance has been sampled before changing bulbs.
        if nvReferenceReady then
        for fixture in pairs(brokenFixtures) do
            if fixture.Parent and not fixture:GetAttribute("HackPanelNVVisualChecked") then
                -- Scan each fixture only once, not on every periodic tick.
                nvVisual(fixture)
                fixture:SetAttribute("HackPanelNVVisualChecked", true)
            end
        end
        end
        nvLabel.Text = string.format("Fixture lights: %d | restored: %d | lamp reference: %s", trackedCount, restoredCount, nvReferenceDefault and "found" or "not found")
    end
    local function disableNightVision()
        restoreStairLighting()
        nightVisionEnabled = false
        nvGeneration += 1
        nvScanGeneration += 1
        if nvRoomConnection then nvRoomConnection:Disconnect(); nvRoomConnection = nil end
        -- Undo *only* NV modifications, returning broken lights to darkness.
        for light, rec in pairs(nvRecords) do
            if light.Parent and rec.restored then
                pcall(function()
                    light.Brightness = rec.initialBrightness
                    light.Enabled = rec.initialEnabled
                    light.Range = rec.initialRange
                end)
            end
        end
        for part, rec in pairs(nvVisualRecords) do
            if part.Parent then
                pcall(function()
                    part.Transparency = rec.initialTransparency
                    part.Material = rec.initialMaterial
                    part.Color = rec.initialColor
                    part.Reflectance = rec.initialReflectance
                end)
            end
        end
        for light, rec in pairs(nvRecords) do
            if rec.fixture and rec.fixture.Parent then
                pcall(function() rec.fixture:SetAttribute("HackPanelNVVisualChecked", nil) end)
            end
        end
        table.clear(nvRecords)
        table.clear(nvVisualRecords)
        table.clear(nvReferenceByName)
        nvReferenceDefault = nil
        nvReferenceReady = false
        nvLabel.Text = "Night Vision: OFF"
    end
    local function enableNightVision()
        if nightVisionEnabled then return end
        local rooms = getCurrentRooms()
        if not rooms then nvLabel.Text = "CurrentRooms not found"; return end
        nightVisionEnabled = true
        applyStairLighting()
        nvGeneration += 1
        local generation = nvGeneration
        -- Collect a real Neon bulb from templates first, then existing lit rooms.
        -- Scans are batched, run only on activation, and do not block the UI.
        task.spawn(function()
            local replicated = game:GetService("ReplicatedStorage")
            nvCollectReferences(replicated, generation, false)
            if not nvReferenceDefault then
                nvCollectReferences(rooms, generation, true)
            end
            if nightVisionEnabled and generation == nvGeneration then
                nvReferenceReady = true
            end
        end)
        -- Newly streamed lights are discovered without a full room traversal.
        nvRoomConnection = rooms.DescendantAdded:Connect(function(obj)
            if nightVisionEnabled and generation == nvGeneration and nvIsLight(obj) then
                nvRegister(obj)
            end
        end)
        -- First discovery is distributed across frames to prevent a freeze.
        task.spawn(function()
            local descendants = rooms:GetDescendants()
            for i, obj in ipairs(descendants) do
                if not nightVisionEnabled or generation ~= nvGeneration then return end
                if nvIsLight(obj) then nvRegister(obj) end
                if i % 175 == 0 then task.wait() end
            end
        end)
        task.spawn(function()
            while nightVisionEnabled and generation == nvGeneration do
                pcall(nvTick, rooms)
                task.wait(1.0)
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
    local lastEntityHudUpdate = 0
    local entityHudConnection = RunService.RenderStepped:Connect(function()
        if not isCurrentRun() then return end
        -- Entity labels and tracers do not need to update at full FPS.
        local hudNow = os.clock()
        if hudNow - lastEntityHudUpdate < 0.10 then return end
        lastEntityHudUpdate = hudNow
        if not entityEspEnabled then return end
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
                -- BoundingBox() on animated multi-part models every frame is
                -- expensive; the tracked physical part is sufficient for HUD.
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
    -- Incremental descendant traversal: unlike GetDescendants(), this yields
    -- every small batch, avoiding a large CPU/allocation spike in one frame.
    local function collectWorldNodesCooperatively()
        local nodes = {}
        local pending = workspace:GetChildren()
        local index = 1
        local processed = 0
        while index <= #pending do
            if not isCurrentRun() or not menuGui or not menuGui.Parent then
                return nil
            end
            local obj = pending[index]
            index += 1
            nodes[#nodes + 1] = obj
            for _, child in ipairs(obj:GetChildren()) do
                pending[#pending + 1] = child
            end
            processed += 1
            if processed >= 100 then
                processed = 0
                task.wait()
            end
        end
        return nodes
    end
    local function refreshEntities()
        local found, present = {}, {}
        local candidates = {}
        local ambushPositions = {}
        if entityEspEnabled then
            -- One workspace traversal, never one nested traversal per Rush.
            local worldNodes = collectWorldNodesCooperatively()
            if not worldNodes then return end
            for i, obj in ipairs(worldNodes) do
                if i % 150 == 0 then task.wait() end
                local name = getEntityName(obj)
                if name then
                    candidates[#candidates + 1] = obj
                    if name == "Ambush" then
                        local part = getEntityPart(obj)
                        if part then ambushPositions[#ambushPositions + 1] = part.Position end
                    end
                end
            end
        end
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
                    for _, ambushPosition in ipairs(ambushPositions) do
                        if (rushPart.Position - ambushPosition).Magnitude < 5 then return end
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
                    if not part:IsA("BasePart") or #boxes >= 8 then return end
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
            for _, obj in ipairs(candidates) do inspect(obj) end
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
        local objects = collectWorldNodesCooperatively()
        if not objects then return end
        for i, obj in ipairs(objects) do
            if i % 150 == 0 then task.wait() end
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
        while isCurrentRun() and menuGui and menuGui.Parent do
            local ok, err = pcall(updateWarningMonitor)
            if not ok then
                warningStatus.Text = "Warning monitor error: " .. tostring(err):sub(1,110)
            end
            task.wait(1.0)
        end
        alertBanner.Visible = false
        if alertGui.Parent then alertGui:Destroy() end
    end)
    entityEspButton.MouseButton1Click:Connect(function()
        entityEspEnabled = not entityEspEnabled
        entityEspButton.Text = entityEspEnabled and "ENTITY WALL ESP: ON" or "ENTITY WALL ESP: OFF"
        -- The scheduled scan loop below will refresh without overlapping scans.
    end)
    task.spawn(function()
        while isCurrentRun() and menuGui and menuGui.Parent do
            local ok, err = pcall(refreshEntities)
            if not ok then
                espInfo.Text = "ESP error: " .. tostring(err):sub(1,140)
                -- ESP errors must not overwrite the independent warning status.
                espInfo.Text = "ESP detection error: " .. tostring(err):sub(1,140)
            end
            task.wait(2.0)
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
        -- Priority: current-room closets, then accessible adjacent-room closets.
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
            if #adjacentCandidates > 0 then
                rushStatus.Text = "Trying accessible adjacent-room closet..."
                completed = attemptClosets(adjacentCandidates)
            end
        end
        if not completed and rushAutoEnabled and rushGeneration == generation then
            rushStatus.Text = "No reachable closet in accessible rooms"
        end
        rushBusy = false
    end

    -- Closet navigation test; no fake Rush is spawned.
    local debugClosetButton = makeButton(hotelPages.Auto, "DEBUG: CLOSETS",
        UDim2.new(0.5, -266, 0, 292), UDim2.fromOffset(258, 38))
    debugClosetButton.ZIndex = 36

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
        task.spawn(function()
            local ok, err = pcall(function()
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
            end)
            if not ok then rushStatus.Text = "DEBUG ERROR: " .. tostring(err):sub(1, 95) end
            debugMode = nil
            rushBusy = false
        end)
    end
    debugClosetButton.MouseButton1Click:Connect(function() startDebug("CLOSET") end)

    rushButton.MouseButton1Click:Connect(function()
        rushAutoEnabled = not rushAutoEnabled
        rushGeneration += 1
        if not rushAutoEnabled then clearPathVisual() end
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

    -- Stairwell door counter: separate HUD in the upper-right of the screen.
    -- It reads the local player's current numbered room, not team progress.
    local stairCounterGui = Instance.new("ScreenGui")
    stairCounterGui.Name = "HackPanelStairwellDoorCounter"
    stairCounterGui.ResetOnSpawn = false
    stairCounterGui.IgnoreGuiInset = false
    stairCounterGui.DisplayOrder = 10001
    stairCounterGui.Enabled = false
    stairCounterGui.Parent = PlayerGui

    local stairCounterFrame = Instance.new("Frame")
    stairCounterFrame.Name = "CounterBackground"
    stairCounterFrame.AnchorPoint = Vector2.new(1, 0)
    stairCounterFrame.Position = UDim2.new(1, -18, 0, 62)
    stairCounterFrame.Size = UDim2.fromOffset(170, 65)
    stairCounterFrame.BackgroundColor3 = Color3.fromRGB(23, 21, 27)
    stairCounterFrame.BackgroundTransparency = 0.16
    stairCounterFrame.BorderSizePixel = 0
    stairCounterFrame.Parent = stairCounterGui
    Instance.new("UICorner", stairCounterFrame).CornerRadius = UDim.new(0, 10)
    local stairStroke = Instance.new("UIStroke")
    stairStroke.Color = Color3.fromRGB(154, 151, 164)
    stairStroke.Transparency = 0.5
    stairStroke.Parent = stairCounterFrame

    local stairCounterTitle = Instance.new("TextLabel")
    stairCounterTitle.BackgroundTransparency = 1
    stairCounterTitle.Position = UDim2.fromOffset(8, 5)
    stairCounterTitle.Size = UDim2.new(1, -16, 0, 19)
    stairCounterTitle.Font = Enum.Font.GothamBold
    stairCounterTitle.TextSize = 12
    stairCounterTitle.TextColor3 = Color3.fromRGB(195, 195, 203)
    stairCounterTitle.Text = "STAIRWELL DOOR"
    stairCounterTitle.Parent = stairCounterFrame

    local stairCounterValue = Instance.new("TextLabel")
    stairCounterValue.BackgroundTransparency = 1
    stairCounterValue.Position = UDim2.fromOffset(8, 24)
    stairCounterValue.Size = UDim2.new(1, -16, 0, 34)
    stairCounterValue.Font = Enum.Font.GothamBlack
    stairCounterValue.TextSize = 28
    stairCounterValue.TextColor3 = Color3.fromRGB(245, 243, 248)
    stairCounterValue.Text = "--"
    stairCounterValue.Parent = stairCounterFrame

    task.spawn(function()
        while isCurrentRun() and menuGui and menuGui.Parent and stairCounterGui.Parent do
            if stairCounterGui.Enabled then
                local _, roomNumber = getCurrentRoom()
                stairCounterValue.Text = roomNumber and string.format("%03d", roomNumber) or "--"
            end
            task.wait(0.5)
        end
        if stairCounterGui.Parent then stairCounterGui:Destroy() end
    end)

    -- Stairwell-only ESP: entrance and explicitly named RIGHT fire exit.
    -- Scan only the current room, and only while this tab is open.
    local stairDoorMarkers = {}
    local function clearStairDoorMarkers()
        for _, marker in pairs(stairDoorMarkers) do
            if marker and marker.Parent then marker:Destroy() end
        end
        table.clear(stairDoorMarkers)
    end
    local function stairDoorPart(object)
        if object:IsA("BasePart") then return object end
        if object:IsA("Model") then
            return object.PrimaryPart or object:FindFirstChildWhichIsA("BasePart", true)
        end
        return object:FindFirstChildWhichIsA("BasePart", true)
    end
    local function stairDoorType(object)
        local name = object.Name:lower():gsub("[%s_%-]", "")
        if name:find("rightfireexit", 1, true) or name:find("fireexitright", 1, true)
            or name:find("rightemergencyexit", 1, true) then
            return "RIGHT FIRE EXIT"
        end
        if name == "doorentrance" or name == "entrancedoor"
            or name == "entrance" or name == "entrydoor" then
            return "ENTRANCE DOOR"
        end
        return nil
    end
    local function updateStairDoorMarkers()
        if activeFloorName ~= "THE STAIRWELL" or not stairEspEnabled then
            clearStairDoorMarkers()
            return
        end
        local room = getCurrentRoom()
        local found = {}
        if room then
            for _, object in ipairs(room:GetDescendants()) do
                local label = stairDoorType(object)
                if label then
                    local part = stairDoorPart(object)
                    if part and part:IsDescendantOf(workspace) then
                        -- One marker per type, preferring the named model/part.
                        if not found[label] then found[label] = part end
                    end
                end
            end
        end
        for label, marker in pairs(stairDoorMarkers) do
            if not found[label] or marker.Adornee ~= found[label] then
                marker:Destroy()
                stairDoorMarkers[label] = nil
            end
        end
        for label, part in pairs(found) do
            if not stairDoorMarkers[label] then
                local marker = Instance.new("BillboardGui")
                marker.Name = "HackPanelStairwellDoorESP"
                marker.Adornee = part
                marker.AlwaysOnTop = true
                marker.Size = UDim2.fromOffset(190, 35)
                marker.StudsOffsetWorldSpace = Vector3.new(0, 3.2, 0)
                marker.MaxDistance = 450
                local textLabel = Instance.new("TextLabel")
                textLabel.Size = UDim2.fromScale(1, 1)
                textLabel.BackgroundColor3 = Color3.fromRGB(16, 19, 24)
                textLabel.BackgroundTransparency = 0.25
                textLabel.TextColor3 = label == "RIGHT FIRE EXIT"
                    and Color3.fromRGB(130, 255, 145) or Color3.fromRGB(120, 205, 255)
                textLabel.TextStrokeTransparency = 0.25
                textLabel.Font = Enum.Font.GothamBold
                textLabel.TextScaled = true
                textLabel.Text = label
                textLabel.Parent = marker
                Instance.new("UICorner", textLabel).CornerRadius = UDim.new(0, 7)
                marker.Parent = PlayerGui
                stairDoorMarkers[label] = marker
            end
        end
    end
    task.spawn(function()
        while isCurrentRun() and stairCounterGui.Parent and menuGui.Parent do
            if activeFloorName == "THE STAIRWELL" and stairEspEnabled then updateStairDoorMarkers()
            elseif next(stairDoorMarkers) then clearStairDoorMarkers() end
            task.wait(1)
        end
        clearStairDoorMarkers()
    end)

    -- Stairwell-specific controls live in their corresponding Hotel-style tabs.
    local stairCounterButton = makeButton(hotelPages.Essentials, "STAIRWELL DOOR COUNTER: OFF",
        UDim2.new(0.5, -155, 0, 285), UDim2.fromOffset(310, 46))
    stairCounterButton.ZIndex = 36
    stairCounterButton.MouseButton1Click:Connect(function()
        stairCounterEnabled = not stairCounterEnabled
        stairCounterGui.Enabled = activeFloorName == "THE STAIRWELL" and stairCounterEnabled
        stairCounterButton.Text = "STAIRWELL DOOR COUNTER: " .. (stairCounterEnabled and "ON" or "OFF")
    end)
    local stairEspButton = makeButton(hotelPages.ESP, "STAIRWELL DOOR ESP: OFF",
        UDim2.new(0.5, -155, 0, 100), UDim2.fromOffset(310, 48))
    stairEspButton.ZIndex = 36
    stairEspButton.MouseButton1Click:Connect(function()
        stairEspEnabled = not stairEspEnabled
        stairEspButton.Text = "STAIRWELL DOOR ESP: " .. (stairEspEnabled and "ON" or "OFF")
        if not stairEspEnabled then clearStairDoorMarkers() end
    end)
    local function refreshStairControls()
        local isStair = activeFloorName == "THE STAIRWELL"
        stairCounterButton.Visible = isStair
        stairEspButton.Visible = isStair
        nightButton.Text = nightVisionEnabled and "NIGHT VISION: ON" or "NIGHT VISION: OFF"
    end

    local function openFloorDetail(name)
        detailTitle.Text = name
        activeFloorName = name
        stairCounterGui.Enabled = name == "THE STAIRWELL" and stairCounterEnabled
        if nightVisionEnabled then
            if name == "THE STAIRWELL" then applyStairLighting()
            else restoreStairLighting() end
        end
        detailPanel.Visible = true
        nav.Visible = false
        cards.Visible = false
        if name ~= "THE CANDY VAULT" and isEspActive then
            setEspEnabled(false)
        end
        espButton.Visible = name == "THE CANDY VAULT"
        -- Reuse the Hotel's Auto / ESP / Essentials / Warnings tabs
        -- on every Floor and Subfloor detail, but never on Visions.
        local hasHotelTools = currentSection == "Floors" or currentSection == "Subfloors"
        detailMessage.Visible = not hasHotelTools and name ~= "THE CANDY VAULT"
        doorPanel.Visible = hasHotelTools
        if hasHotelTools then
            doorCaption.Text = "SELECT " .. name .. " DOOR"
        end
        refreshStairControls()
        updateEspButton()
    end

    detailBack.MouseButton1Click:Connect(function()
        activeFloorName = ""
        restoreStairLighting()
        stairCounterGui.Enabled = false
        clearStairDoorMarkers()
        refreshStairControls()
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

    -- Separate function keeps home-screen locals out of createMenu register allocation.
    (function()
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
    end)()
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