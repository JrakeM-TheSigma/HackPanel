    -- Entity ESP and independently configurable entity warnings.
    local entityList = {"Rush","Ambush","Seek","Figure","Eyes","Screech","Halt","A-60","A-90","A-120","Blitz","Haste","Vacuum","Giggle","Grumble","Dread","Lookman","Dupe"}
    local aliases = {
        rush="Rush", rushmoving="Rush", rushnew="Rush", rushrig="Rush",
        ambush="Ambush", ambushmoving="Ambush", ambushrig="Ambush",
        seek="Seek", seekmoving="Seek", seekrig="Seek",
        figure="Figure", figuremoving="Figure", figurerig="Figure",
        eyes="Eyes", eyesmoving="Eyes", screech="Screech", shade="Halt", dupe="Dupe", seekmovingnewclone="Seek",
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
