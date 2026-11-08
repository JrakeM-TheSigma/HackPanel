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
