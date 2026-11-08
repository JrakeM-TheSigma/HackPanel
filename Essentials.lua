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
