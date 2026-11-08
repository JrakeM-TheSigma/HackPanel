-- Item and key ESP implementation (moved from Core.lua).
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

clearOldESP = function()
    if mainRenderConnection then
        mainRenderConnection:Disconnect()
        mainRenderConnection = nil
    end

    if backgroundScanTask then
        task.cancel(backgroundScanTask)
        backgroundScanTask = nil
    end
    if disconnectItemWatchers then disconnectItemWatchers() end

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

    local part = (item.Name == "KeyObtain" and item:FindFirstChild("Key", true)) or getPhysicalPart(item)
    if part and not part:IsA("BasePart") then part = getPhysicalPart(part) end
    if not part then
        return
    end

    if category == "KEYS" and item.Name == "KeyObtain" then
        if not item:IsDescendantOf(getCurrentRooms() or workspace) then return end
    elseif not belongsToCurrentRoom(item, part) then return end

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
    highlight.Adornee = (item.Name == "KeyObtain") and part or (highlightPartOnly and part or item)
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

-- Track only the currently relevant room and Drops. DescendantAdded catches
-- newly spawned loot immediately, without a repeated full-room scan.
local itemWatchers = {}
local watchedRoom, watchedDrops, watchedRooms
local function inspectItem(descendant)
    if not isEspActive or not descendant or not descendant.Parent then return end
    if hotelKeyEspEnabled and descendant.Name == "KeyObtain" then
        local rooms = getCurrentRooms()
        local room = rooms and descendant:FindFirstAncestorWhichIsA("Model")
        if rooms and descendant:IsDescendantOf(rooms) and descendant:FindFirstChild("Key", true) then
            trackItemInstance(descendant, "KEY", true, "KEYS")
        end
    end
    if hotelKeyEspEnabled then return end
    if descendant.Name == "KeyJewelry" and (descendant:IsA("Model") or descendant:IsA("BasePart") or descendant:IsA("Tool")) then
        trackItemInstance(descendant, "KEY JEWELRY", false, "KEYS")
    end
    if descendant.Name == "Candy" and not hotelEspMode then
        trackItemInstance(descendant, "CANDY", false, "CANDY")
    elseif descendant.Parent and descendant.Parent.Name == "SalvageItems" and descendant.Name ~= "JewelryCase" then
        trackItemInstance(descendant, nil, false, "ITEMS")
    end
    if descendant.Parent and descendant.Parent.Name == "JewelryCase" and (descendant:IsA("Model") or descendant:IsA("Tool")) then
        trackItemInstance(descendant, descendant.Name, false, "ITEMS")
    end
end
local function watchItemContainer(container)
    if not container or itemWatchers[container] then return end
    itemWatchers[container] = container.DescendantAdded:Connect(function(child)
        -- Defer once to allow item parts/handles to replicate.
        task.defer(function()
            if isEspActive and isCurrentRun() then
                inspectItem(child)
                if hotelKeyEspEnabled then
                    local ancestor = child:FindFirstAncestor("KeyObtain")
                    if ancestor then inspectItem(ancestor) end
                end
            end
        end)
    end)
    for _, child in ipairs(container:GetDescendants()) do inspectItem(child) end
end
disconnectItemWatchers = function()
    for _, connection in pairs(itemWatchers) do connection:Disconnect() end
    table.clear(itemWatchers)
    watchedRoom, watchedDrops, watchedRooms = nil, nil, nil
end
local function scanAllLocations()
    if not isEspActive then return end
    local room = getCurrentRoom()
    local drops = workspace:FindFirstChild("Drops")
    if hotelKeyEspEnabled then
        local rooms = getCurrentRooms()
        if rooms ~= watchedRooms then
            disconnectItemWatchers()
            watchedRooms = rooms
            if rooms then watchItemContainer(rooms) end
        end
        return
    end
    if room ~= watchedRoom or drops ~= watchedDrops then
        disconnectItemWatchers()
        watchedRoom, watchedDrops = room, drops
        watchItemContainer(room)
        if drops and drops ~= room then watchItemContainer(drops) end
    end
end
local function startBackgroundLiveScanner()
    if backgroundScanTask then task.cancel(backgroundScanTask) end
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

    mainRenderConnection = RunService.RenderStepped:Connect(function()
        if not isCurrentRun() then
            mainRenderConnection:Disconnect()
            return
        end
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

            local isPast = item and part and (not hotelKeyEspEnabled) and not belongsToCurrentRoom(item, part)
            if not item or not item.Parent or not part or not part.Parent or isPast then
                if target.Highlight and target.Highlight.Parent then
                    target.Highlight:Destroy()
                end

                if activeLines[target] then activeLines[target]:Destroy() end
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


-- Item ESP controls use the shared Core menu buttons.
setEspEnabled = function(enabled)
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
        showToggleMessage(hotelKeyEspEnabled and "HOTEL KEY ESP: ENABLED" or "CANDY / ITEMS / KEYS ESP: ENABLED", Color3.fromRGB(0, 255, 0))
    else
        showToggleMessage(hotelKeyEspEnabled and "HOTEL KEY ESP: DISABLED" or "CANDY / ITEMS / KEYS ESP: DISABLED", Color3.fromRGB(255, 0, 0))
    end

    updateEspButton()
end


-- Entity ESP and warnings follow below.
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
    -- Dupe's entity object and its visible fake door are siblings under SideroomDupe.
    -- Keep tracking the Dupe entity for warnings, but anchor ESP to DoorFake.
    local function getDupeDoor(obj)
        if obj.Name:lower() ~= "dupe" then return nil end
        local side = obj.Parent
        if side and side.Name == "SideroomDupe" then
            return side:FindFirstChild("DoorFake")
        end
        return nil
    end
    local function getEntityPart(obj)
        local door = getDupeDoor(obj)
        if door then
            if door:IsA("BasePart") then return door end
            return door.PrimaryPart or door:FindFirstChildWhichIsA("BasePart", true)
        end
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
        if not isCurrentRun() then return end
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
    -- Entity registry: event-driven and limited to relevant containers.
    -- Shared by ESP and Warnings; no recurring full Workspace traversal.
    local entityNodes, entityWatchers = {}, {}
    local function registerEntity(node)
        if not node or not node.Parent then return end
        local n = node.Name:lower()
        if getEntityName(node) or n == "shade" or n == "dupe" or n == "seekmovingnewclone" then
            entityNodes[node] = true
        end
    end
    local function watchEntityContainer(container, handler)
        if not container or entityWatchers[container] then return end
        entityWatchers[container] = container.ChildAdded:Connect(function(child)
            registerEntity(child)
            if handler then handler(child) end
        end)
        for _, child in ipairs(container:GetChildren()) do
            registerEntity(child)
            if handler then handler(child) end
        end
    end
    local function watchDupe(side)
        if not side then return end
        watchEntityContainer(side)
    end
    local function watchFigure(setup)
        if not setup then return end
        watchEntityContainer(setup)
    end
    local function watchRoom(room)
        if not room or not room:IsA("Model") then return end
        watchEntityContainer(room, function(child)
            if child.Name == "FigureSetup" then watchFigure(child)
            elseif child.Name == "SideroomDupe" then watchDupe(child) end
        end)
    end
    local function watchRooms(folder)
        watchEntityContainer(folder, watchRoom)
    end
    watchEntityContainer(workspace, function(child)
        if child.Name == "CurrentRooms" then watchRooms(child) end
    end)
    if workspace.CurrentCamera then watchEntityContainer(workspace.CurrentCamera) end
    entityWatchers.__camera = workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
        if workspace.CurrentCamera then watchEntityContainer(workspace.CurrentCamera) end
    end)
    task.spawn(function()
        while isCurrentRun() and menuGui and menuGui.Parent do
            task.wait(5)
            for node in pairs(entityNodes) do
                if not node.Parent or not node:IsDescendantOf(workspace) then entityNodes[node] = nil end
            end
        end
        for _, connection in pairs(entityWatchers) do connection:Disconnect() end
        table.clear(entityNodes)
    end)
    local function collectWorldNodesCooperatively()
        local nodes = {}
        for node in pairs(entityNodes) do
            if node.Parent and node:IsDescendantOf(workspace) then
                nodes[#nodes+1] = node
            else
                entityNodes[node] = nil
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
            if name == "Dupe" and entityHighlights[obj] then
                local door = getDupeDoor(obj)
                local firstBox = entityHighlights[obj][1]
                if door and firstBox and firstBox.Adornee and not firstBox.Adornee:IsDescendantOf(door) then
                    clearHighlight(obj)
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
                local visualTarget = getDupeDoor(obj) or obj
                if visualTarget:IsA("BasePart") then
                    adorn(visualTarget)
                else
                    for _, part in ipairs(visualTarget:GetDescendants()) do
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
            task.wait(0.20)
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
            task.wait(0.20)
        end
        for obj in pairs(entityHighlights) do clearHighlight(obj) end
        for obj in pairs(entityHudItems) do removeEntityHud(obj) end
        entityHudConnection:Disconnect()
        entityHud:Destroy()
        alertGui:Destroy()
    end)
    showHotelTab("Auto")

