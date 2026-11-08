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

