local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
-- Remove stale windows from previous executions.
for _, oldName in ipairs({"UtilityMenuGui", "EspLinesOverlay", "EspNotifyGui"}) do
    local old = PlayerGui:FindFirstChild(oldName)
    if old then old:Destroy() end
end
local function getCurrentRooms()
    return workspace:FindFirstChild("CurrentRooms")
end

-- Configuration
local TOGGLE_KEY = Enum.KeyCode.K
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
            if descendant.Name == "Candy" then
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
        local centerX = viewport.X / 2
        local centerY = viewport.Y / 2

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
        setEspEnabled(not isEspActive)
    end)
    updateEspButton()

    local function openFloorDetail(name)
        detailTitle.Text = name
        detailPanel.Visible = true
        nav.Visible = false
        cards.Visible = false
        espButton.Visible = name == "THE CANDY VAULT"
        detailMessage.Visible = name ~= "THE CANDY VAULT"
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
