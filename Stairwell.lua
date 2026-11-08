    -- Keep Stairwell HUD/marker locals in their own register frame.
    local stairCounterGui, clearStairDoorMarkers, stairCounterButton, stairEspButton = (function()
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
        return stairCounterGui, clearStairDoorMarkers, stairCounterButton, stairEspButton
    end)()

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
    ;(function()
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
