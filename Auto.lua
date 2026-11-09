    -- Manual navigation diagnostics. These do not spawn a real Rush.
    local debugMode = nil
    local function navigationActive(generation)
        return (rushAutoEnabled or debugMode ~= nil) and rushGeneration == generation
    end

    local function entityModel(kind)
        local names = kind == "Ambush"
            and {ambushmoving = true, ambush = true}
            or {rushmoving = true, rush = true, rushnew = true}
        for _, child in ipairs(workspace:GetChildren()) do
            if names[child.Name:lower()]
                and (child:IsA("Model") or child:IsA("BasePart")) then
                return child
            end
        end
        return nil
    end

    local function rushModel()
        return entityModel("Rush")
    end

    local function ambushModel()
        return entityModel("Ambush")
    end

    -- Find actual hiding prompts, including beds and wardrobes in nested subrooms.
    -- A visible bed without a usable prompt is not a valid hiding spot.
    local function closetCandidates(origin)
        local current, number = getCurrentRoom()
        local rooms = getCurrentRooms()
        if not rooms then return {} end
        local searchRooms, seenRooms = {}, {}
        local function addRoom(room)
            if room and room:IsA("Model") and not seenRooms[room] then
                seenRooms[room] = true
                table.insert(searchRooms, room)
            end
        end
        addRoom(current)
        if number then
            addRoom(rooms:FindFirstChild(tostring(number - 1)))
            addRoom(rooms:FindFirstChild(tostring(number + 1)))
        end
        -- Streaming/room counters can disagree with the physical subroom.
        -- Include loaded room models nearby, without searching the whole Workspace.
        for _, room in ipairs(rooms:GetChildren()) do
            if room:IsA("Model") and not seenRooms[room] then
                local ok, pivot = pcall(function() return room:GetPivot().Position end)
                if ok and (pivot - origin).Magnitude < 150 then addRoom(room) end
            end
        end
        local candidates, seen = {}, {}
        for _, room in ipairs(searchRooms) do
            for _, prompt in ipairs(room:GetDescendants()) do
                if prompt:IsA("ProximityPrompt") and prompt.Enabled and not seen[prompt] then
                    local ancestor = prompt.Parent
                    local hidingModel, kind
                    while ancestor and ancestor ~= room do
                        local name = ancestor.Name:lower()
                        if name:find("wardrobe", 1, true) or name:find("closet", 1, true) then
                            hidingModel, kind = ancestor, "Closet"
                            break
                        elseif name:find("bed", 1, true) then
                            hidingModel, kind = ancestor, "Bed"
                            break
                        end
                        ancestor = ancestor.Parent
                    end
                    if hidingModel then
                        seen[prompt] = true
                        local holder = prompt.Parent
                        local pos = holder:IsA("Attachment") and holder.WorldPosition
                            or (holder:IsA("BasePart") and holder.Position)
                            or (hidingModel:IsA("Model") and hidingModel:GetPivot().Position)
                        if pos then
                            local distance = (pos - origin).Magnitude
                            if distance <= 110 then
                                table.insert(candidates, {
                                    model = hidingModel, prompt = prompt, position = pos,
                                    distance = distance, room = room,
                                    currentRoom = (room == current), kind = kind
                                })
                            end
                        end
                    end
                end
            end
        end
        table.sort(candidates, function(x, y) return x.distance < y.distance end)
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

    -- Check a character-sized corridor, not just the pathfinding centerline.
    local function corridorBlocked(character, fromPosition, toPosition)
        local flat = Vector3.new(toPosition.X - fromPosition.X, 0, toPosition.Z - fromPosition.Z)
        if flat.Magnitude < 0.3 then return false end
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = {character}
        params.IgnoreWater = true
        local origin = fromPosition + Vector3.new(0, 0.2, 0)
        local cast = workspace:Blockcast(CFrame.new(origin), Vector3.new(3.4, 3.3, 3.4), flat, params)
        return cast ~= nil and cast.Instance ~= nil and cast.Instance.CanCollide
    end

    local function walkToCloset(candidate, generation)
        local character = LocalPlayer.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if not humanoid or not root then return false, "Character not ready" end
        if humanoid.Health <= 0 or humanoid.PlatformStand or humanoid.Sit then
            return false, "Movement disabled (seated / downed)"
        end
        local prompt = candidate.prompt
        if not prompt or not prompt.Parent then return false, "Closet prompt unavailable" end
        local position = candidate.position
        local acceptable = math.max(2, prompt.MaxActivationDistance - 0.25)
        local function closeEnough()
            if not prompt.Parent then return false end
            local parent = prompt.Parent
            local target = parent:IsA("Attachment") and parent.WorldPosition
                or (parent:IsA("BasePart") and parent.Position) or position
            return (root.Position - target).Magnitude <= acceptable
        end
        if closeEnough() then return true end

        local renderName = "HackPanelRushWalk"
        local moveDirection = Vector3.zero
        local movementActive = true
        pcall(function() RunService:UnbindFromRenderStep(renderName) end)
        RunService:BindToRenderStep(renderName, Enum.RenderPriority.Input.Value + 2, function()
            if movementActive and humanoid.Parent and humanoid.Health > 0 then
                humanoid:Move(moveDirection, false)
            end
        end)
        local function stopMoving()
            movementActive = false
            moveDirection = Vector3.zero
            pcall(function() RunService:UnbindFromRenderStep(renderName) end)
            pcall(function() humanoid:Move(Vector3.zero, false) end)
            clearPathVisual()
        end

        local function navigate()
            local lastFailure = "No safe path to closet"
            for retry = 1, 4 do
                if not navigationActive(generation) then return false, "Cancelled" end
                if closeEnough() then return true end
                local delta = root.Position - position
                local direction = Vector3.new(delta.X, 0, delta.Z)
                if direction.Magnitude < 0.1 then direction = Vector3.new(0, 0, 1) end
                direction = direction.Unit
                local radius = math.max(2.5, math.min(4, acceptable - 0.5))
                local side = Vector3.new(-direction.Z, 0, direction.X)
                local approaches = {
                    position + direction * radius,
                    position + side * radius,
                    position - side * radius,
                    position - direction * radius,
                    position + (direction + side).Unit * radius,
                    position + (direction - side).Unit * radius
                }
                local waypoints
                for _, target in ipairs(approaches) do
                    local ok, path = pcall(function()
                        local result = PathfindingService:CreatePath({
                            AgentRadius = 2.5, AgentHeight = 5,
                            AgentCanJump = false, WaypointSpacing = 2
                        })
                        result:ComputeAsync(root.Position, target)
                        return result
                    end)
                    if ok and path and path.Status == Enum.PathStatus.Success then
                        waypoints = path:GetWaypoints()
                        break
                    end
                end
                if not waypoints then return false, "No safe path around obstacles" end
                showPathVisual(waypoints, "CLOSET")
                local blocked = false
                for _, waypoint in ipairs(waypoints) do
                    if closeEnough() then return true end
                    if not navigationActive(generation) then return false, "Cancelled" end
                    local started = os.clock()
                    local lastProgress = os.clock()
                    local previousDistance = math.huge
                    while os.clock() - started < 7 do
                        if closeEnough() then return true end
                        if not navigationActive(generation) then return false, "Cancelled" end
                        if humanoid.Health <= 0 then return false, "Character died" end
                        local deltaToWaypoint = waypoint.Position - root.Position
                        local flat = Vector3.new(deltaToWaypoint.X, 0, deltaToWaypoint.Z)
                        if flat.Magnitude < 2 then break end
                        -- Validate the next short movement segment with the full body width.
                        -- A blocked segment forces a fresh path rather than walking into pillars.
                        local lookahead = math.min(flat.Magnitude, 3.5)
                        if corridorBlocked(character, root.Position, root.Position + flat.Unit * lookahead) then
                            blocked = true
                            lastFailure = "Solid obstacle blocking path"
                            break
                        end
                        moveDirection = flat.Unit
                        if flat.Magnitude < previousDistance - 0.25 then
                            lastProgress = os.clock()
                        elseif os.clock() - lastProgress > 1.3 then
                            blocked = true
                            lastFailure = "Stuck near obstacle"
                            break
                        end
                        previousDistance = flat.Magnitude
                        task.wait(0.06)
                    end
                    moveDirection = Vector3.zero
                    if blocked then break end
                end
                if closeEnough() then return true end
                lastFailure = blocked and lastFailure or "Could not reach closet prompt"
                task.wait(0.12)
            end
            return false, lastFailure
        end
        local ok, reached, reason = pcall(navigate)
        stopMoving()
        if not ok then return false, "Movement error: " .. tostring(reached):sub(1, 80) end
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

    local function entityDistance(kind)
        local entity = entityModel(kind)
        if not entity then return nil end
        local character = LocalPlayer.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if not root then return nil end
        local position
        if entity:IsA("BasePart") then
            position = entity.Position
        else
            local ok, pivot = pcall(function() return entity:GetPivot() end)
            if ok then position = pivot.Position end
        end
        return position and (position - root.Position).Magnitude or nil
    end

    local function rushDistance()
        return entityDistance("Rush")
    end

    local function leaveCloset(candidate)
        rushStatus.Text = "Entity passed - exiting closet..."
        local character = LocalPlayer.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if not humanoid or not root then return false end
        local originalPosition = root.Position
        local initiallyHiding = isActuallyHiding()
        local controls = getPlayerControls()
        local vim = game:GetService("VirtualInputManager")
        local function key(down)
            -- Send both supported input paths; one executor method succeeding
            -- doesn't prove the game received the input.
            local fn = down and keypress or keyrelease
            if type(fn) == "function" then pcall(fn, 0x57) end
            pcall(function() vim:SendKeyEvent(down, Enum.KeyCode.W, false, game) end)
        end
        local exited = false
        local renderName = "HackPanelClosetExit"
        pcall(function() RunService:UnbindFromRenderStep(renderName) end)
        -- DOORS may listen to forward controls or humanoid movement depending on
        -- version. Keep both active for a short interval, then release everything.
        for attempt = 1, 6 do
            if not rushAutoEnabled then break end
            key(true)
            RunService:BindToRenderStep(renderName, Enum.RenderPriority.Input.Value + 3, function()
                if humanoid.Parent and humanoid.Health > 0 then
                    if controls then pcall(function() controls:move(Vector3.new(0, 0, -1), true) end) end
                    humanoid:Move(Vector3.new(0, 0, -1), true)
                end
            end)
            local deadline = os.clock() + 0.65
            while os.clock() < deadline do
                task.wait(0.05)
                if initiallyHiding and not isActuallyHiding() then exited = true; break end
                if not initiallyHiding and (root.Position - originalPosition).Magnitude > 3 then
                    exited = true; break
                end
            end
            pcall(function() RunService:UnbindFromRenderStep(renderName) end)
            key(false)
            if controls then pcall(function() controls:move(Vector3.zero, true) end) end
            pcall(function() humanoid:Move(Vector3.zero, false) end)
            if exited then break end
            task.wait(0.12)
        end
        pcall(function() RunService:UnbindFromRenderStep(renderName) end)
        key(false)
        if controls then pcall(function() controls:move(Vector3.zero, true) end) end
        pcall(function() humanoid:Move(Vector3.zero, false) end)
        if exited then
            rushStatus.Text = "Exited closet"
        else
            rushStatus.Text = "Exit unconfirmed; press W manually"
        end
        return exited
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
                            if distance <= RUSH_ENTER_DISTANCE then rushWasClose = true end
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
                            local exited = leaveCloset(candidate)
                            if exited then
                                rushHiddenByAutomation = false
                                rushHidingCandidate = nil
                            end
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
            rushStatus.Text = "No reachable hiding spot in accessible rooms"
        end
        rushBusy = false
    end

    -- Ambush uses the same proven navigation/closet input as Rush.
    -- Each rebound: wait for approach, let it pass forward AND return,
    -- then briefly exit only after the return pass is moving away.
    local function handleAmbush()
        if rushBusy then return end
        rushBusy = true
        local generation = rushGeneration
        local function active()
            return rushAutoEnabled and rushGeneration == generation
        end
        local ok, err = pcall(function()
            local character = LocalPlayer.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")
            if not root then return end
            local candidates = closetCandidates(root.Position)
            local currentRoom = getCurrentRoom()
            table.sort(candidates, function(a, b)
                if a.currentRoom ~= b.currentRoom then return a.currentRoom end
                return a.distance < b.distance
            end)
            local chosen
            local lastReason = "No hiding spots found"
            for i, candidate in ipairs(candidates) do
                if not active() then return end
                if candidate.currentRoom or adjacentRoomPassable(currentRoom, candidate.room) then
                    rushStatus.Text = "Ambush - reaching " .. (candidate.kind or "hide spot") .. " " .. i .. "/" .. #candidates
                    local reached, reason = walkToCloset(candidate, generation)
                    if reached then chosen = candidate; break end
                    lastReason = tostring(reason or "Path failed")
                end
            end
            if not chosen then
                rushStatus.Text = "Ambush - no reachable hiding spot: " .. lastReason
                return
            end
            local hidden = isActuallyHiding()
            local missingSince = nil
            local returnPasses = 0
            local previousDistance = nil
            local previousSampleAt = nil
            local direction = "stationary"
            local directionSince = os.clock()
            local lastMovementAt = 0
            -- Explicit phases prevent the first outward pass from being
            -- mistaken for a completed return. Stationary samples never
            -- advance the phase or authorize an exit.
            local phase = "await_first_pass"
            local firstPassFarSince = nil
            local returnNearSince = nil
            local retreatFarSince = nil
            local lastHideAttempt = 0
            local function setPhase(nextPhase)
                phase = nextPhase
                firstPassFarSince = nil
                returnNearSince = nil
                retreatFarSince = nil
            end
            while active() do
                local now = os.clock()
                local distance = entityDistance("Ambush")
                if not distance then
                    missingSince = missingSince or now
                    if now - missingSince >= 2 then
                        if hidden then
                            rushStatus.Text = "Ambush gone - leaving closet"
                            leaveCloset(chosen)
                        end
                        rushStatus.Text = "Ambush gone - watching for entities"
                        return
                    end
                else
                    missingSince = nil
                    if previousDistance and previousSampleAt then
                        local delta = distance - previousDistance
                        local nextDirection = math.abs(delta) < 1.5 and "stationary"
                            or (delta > 0 and "away" or "toward")
                        if nextDirection ~= direction then
                            direction = nextDirection
                            directionSince = now
                        end
                        if nextDirection ~= "stationary" then lastMovementAt = now end
                    end
                    local stableAway = direction == "away" and now - directionSince >= 0.18
                        and now - lastMovementAt <= 0.18
                    local stableToward = direction == "toward" and now - directionSince >= 0.12
                        and now - lastMovementAt <= 0.18

                    if not hidden then
                        -- Don't enter merely because a stationary spawn is
                        -- nearby. Emergency proximity still takes priority.
                        local shouldHide = distance <= 65
                            or (distance <= 220 and stableToward)
                        if shouldHide and now - lastHideAttempt >= 0.7 then
                            lastHideAttempt = now
                            rushStatus.Text = "Ambush approaching - hiding early"
                            local success, reason = tryHide(chosen, generation)
                            if success then
                                hidden = true
                                setPhase("await_first_pass")
                            else
                                rushStatus.Text = "Ambush - hide failed: " .. tostring(reason)
                            end
                        elseif direction == "stationary" then
                            rushStatus.Text = "Ambush stationary - waiting at closet"
                        else
                            rushStatus.Text = "Ambush - ready to hide"
                        end
                    else
                        if phase == "await_first_pass" then
                            -- The first pass is complete only after Ambush
                            -- was near and has traveled away for a while.
                            if distance <= 75 then
                                firstPassFarSince = nil
                                setPhase("await_first_departure")
                            end
                        elseif phase == "await_first_departure" then
                            if stableAway and distance >= 110 then
                                firstPassFarSince = firstPassFarSince or now
                                if now - firstPassFarSince >= 0.35 then
                                    setPhase("await_return")
                                end
                            else
                                firstPassFarSince = nil
                            end
                        elseif phase == "await_return" then
                            if stableToward and distance <= 85 then
                                returnNearSince = returnNearSince or now
                                if now - returnNearSince >= 0.12 then
                                    setPhase("await_return_retreat")
                                end
                            else
                                returnNearSince = nil
                            end
                        elseif phase == "await_return_retreat" then
                            -- Never exit just because the distance is large:
                            -- the return must have passed, and Ambush must
                            -- be demonstrably moving AWAY right now.
                            if stableAway and distance >= 130 then
                                retreatFarSince = retreatFarSince or now
                                if now - retreatFarSince >= 0.4 then
                                    rushStatus.Text = "Ambush returned and retreated - resetting Hide"
                                    local exited = leaveCloset(chosen)
                                    if exited then
                                        hidden = false
                                        returnPasses += 1
                                        setPhase("await_first_pass")
                                        previousDistance = nil
                                        previousSampleAt = nil
                                        direction = "stationary"
                                        directionSince = os.clock()
                                    else
                                        rushStatus.Text = "Ambush - exit unconfirmed"
                                    end
                                end
                            else
                                retreatFarSince = nil
                            end
                        end
                        if hidden then
                            rushStatus.Text = "Ambush hidden - " .. phase
                        end
                    end
                    previousDistance = distance
                    previousSampleAt = now
                end
                task.wait(0.06)
            end
        end)
        if not ok then rushStatus.Text = "Ambush error: " .. tostring(err):sub(1, 90) end
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
        if rushModel() or ambushModel() then
            rushStatus.Text = "Entity present - debug disabled for safety"
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
        rushButton.Text = rushAutoEnabled and "ENTITY AUTO-HIDE: ON" or "ENTITY AUTO-HIDE: OFF"
        rushStatus.Text = rushAutoEnabled and "Watching for Rush / Ambush..." or "Entity auto-hide is off"
    end)

    task.spawn(function()
        local lastRush = nil
        local lastAmbush = nil
        local rushGoneAt = nil
        while menuGui and menuGui.Parent do
            local currentRush = rushModel()
            local currentAmbush = ambushModel()
            if currentAmbush and rushAutoEnabled and currentAmbush ~= lastAmbush then
                lastAmbush = currentAmbush
                if not rushBusy then task.spawn(handleAmbush) end
            elseif not currentAmbush then
                lastAmbush = nil
            end
            if currentRush then
                rushGoneAt = nil
                -- Rush warnings are controlled by the Warnings tab checklist.
                if rushAutoEnabled and currentRush ~= lastRush and not currentAmbush then
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
                            if not isActuallyHiding() and not currentAmbush then rushStatus.Text = "Watching for Rush / Ambush..." end
                        else
                            rushStatus.Text = "Entity auto-hide is off"
                        end
                    end
                end
            end
            task.wait(0.2)
        end

    end)

    -- Door 50 Library Solver: isolated function to avoid Luau's 200-local register limit.
    ;(function()
        local page = hotelPages.Auto
        local button = makeButton(page, "SOLVE LIBRARY PUZZLE", UDim2.new(0.5, 12, 0, 292), UDim2.fromOffset(258, 38))
        button.Name = "HackPanelLibrarySolver"
        button.ZIndex = 36

        local symbols = {"circle", "pentagon", "square", "hexagon", "triangle", "star", "x", "diamond"}
        local aliases = {
            circle = {"circle", "○", "◯", "◦"},
            pentagon = {"pentagon", "⬟", "⬠"},
            square = {"square", "□", "▢", "▣"},
            hexagon = {"hexagon", "⬡", "⬢"},
            triangle = {"triangle", "△", "▲"},
            star = {"star", "☆", "★"},
            x = {"cross", "×", "✕", " x "},
            diamond = {"diamond", "◇", "◆"},
        }
        local function identify(value)
            local lower = tostring(value):lower()
            for _, name in ipairs(symbols) do
                for _, alias in ipairs(aliases[name]) do
                    if lower:find(alias, 1, true) then return name end
                end
            end
        end
        local function readClues()
            local values, order = {}, {}
            -- Examine locally replicated values and UI text. Never invent missing clues.
            local roots = {LocalPlayer, PlayerGui}
            local rooms = getCurrentRooms()
            if rooms then
                local library = rooms:FindFirstChild("50")
                if library then table.insert(roots, library) end
            end
            local function ingest(text)
                local s = tostring(text)
                local shape, digit
                for _, name in ipairs(symbols) do
                    for _, alias in ipairs(aliases[name]) do
                        local escaped = alias:gsub("([^%w])", "%%%1")
                        local n = s:lower():match(escaped .. "%s*[:=]%s*(%d)")
                        if n then shape, digit = name, tonumber(n); break end
                    end
                    if shape then break end
                end
                if shape and digit then values[shape] = digit end
                -- Roman-number labels are only trusted when paired with a shape.
                local roman = {I=1, II=2, III=3, IV=4, V=5}
                for token, index in pairs(roman) do
                    local word = s:match("^%s*" .. token .. "%s*[:=]%s*(.-)%s*$")
                    local named = word and identify(word)
                    if named then order[index] = named end
                end
            end
            for _, root in ipairs(roots) do
                for _, object in ipairs(root:GetDescendants()) do
                    if object:IsA("TextLabel") or object:IsA("TextButton") then
                        if object.Visible then ingest(object.Text) end
                    elseif object:IsA("StringValue") then
                        ingest(object.Name .. "=" .. object.Value)
                        ingest(object.Value)
                    elseif object:IsA("IntValue") or object:IsA("NumberValue") then
                        ingest(object.Name .. "=" .. tostring(object.Value))
                    end
                    for _, attribute in ipairs({"Symbol", "Shape", "Digit", "Code", "Hint"}) do
                        local val = object:GetAttribute(attribute)
                        if val ~= nil then ingest(object.Name .. "=" .. tostring(val)) end
                    end
                end
            end
            return values, order
        end

        local dialog = Instance.new("Frame")
        dialog.Name = "LibrarySolverDialog"
        dialog.Size = UDim2.fromOffset(430, 365)
        dialog.AnchorPoint = Vector2.new(0.5, 0.5)
        dialog.Position = UDim2.fromScale(0.5, 0.5)
        dialog.BackgroundColor3 = Color3.fromRGB(30, 24, 25)
        dialog.BorderSizePixel = 0
        dialog.ZIndex = 100
        dialog.Visible = false
        dialog.Parent = page
        Instance.new("UICorner", dialog).CornerRadius = UDim.new(0, 12)
        local stroke = Instance.new("UIStroke", dialog)
        stroke.Color = Color3.fromRGB(220, 183, 145)
        stroke.Thickness = 2
        local function label(text, y, height)
            local obj = Instance.new("TextLabel")
            obj.BackgroundTransparency = 1
            obj.Position = UDim2.fromOffset(15, y)
            obj.Size = UDim2.new(1, -30, 0, height)
            obj.Text = text
            obj.TextColor3 = Color3.fromRGB(255, 232, 206)
            obj.Font = Enum.Font.Gotham
            obj.TextSize = 14
            obj.TextWrapped = true
            obj.ZIndex = 102
            obj.Parent = dialog
            return obj
        end
        label("DOOR 50 • LIBRARY SOLVER", 12, 24).Font = Enum.Font.GothamBold
        local status = label("Reading collected clues...", 39, 39)
        local inputs = {}
        local function field(name, x, y, width)
            local input = Instance.new("TextBox")
            input.Name = name
            input.Position = UDim2.fromOffset(x, y)
            input.Size = UDim2.fromOffset(width, 31)
            input.BackgroundColor3 = Color3.fromRGB(65, 52, 51)
            input.TextColor3 = Color3.new(1, 1, 1)
            input.PlaceholderColor3 = Color3.fromRGB(180, 170, 165)
            input.PlaceholderText = name
            input.Text = ""
            input.TextSize = 14
            input.Font = Enum.Font.Gotham
            input.ClearTextOnFocus = false
            input.ZIndex = 103
            input.Parent = dialog
            Instance.new("UICorner", input).CornerRadius = UDim.new(0, 5)
            return input
        end
        label("Book values (0–9), in this order:", 86, 20)
        local short = {"Circle", "Pentagon", "Square", "Hexagon", "Triangle", "Star", "X", "Diamond"}
        for i, name in ipairs(symbols) do
            local col = (i - 1) % 4
            local row = math.floor((i - 1) / 4)
            inputs[name] = field(short[i], 15 + col * 102, 110 + row * 41, 94)
        end
        label("Paper order (I–V): type symbol names", 195, 20)
        local orderInputs = {}
        for i = 1, 5 do
            orderInputs[i] = field(({"I", "II", "III", "IV", "V"})[i], 15 + (i - 1) * 81, 220, 75)
        end
        local result = label("", 257, 42)
        result.Font = Enum.Font.GothamBold
        result.TextSize = 19
        local solve = makeButton(dialog, "CALCULATE CODE", UDim2.fromOffset(15, 310), UDim2.fromOffset(248, 39))
        solve.ZIndex = 104
        local close = makeButton(dialog, "CLOSE", UDim2.fromOffset(275, 310), UDim2.fromOffset(140, 39))
        close.ZIndex = 104
        close.MouseButton1Click:Connect(function() dialog.Visible = false end)
        local function fillDetected()
            local values, order = readClues()
            local count = 0
            for _, name in ipairs(symbols) do
                if values[name] ~= nil then
                    inputs[name].Text = tostring(values[name])
                    count += 1
                end
            end
            for i = 1, 5 do
                if order[i] then orderInputs[i].Text = order[i] end
            end
            status.Text = "Detected " .. count .. "/8 book values. Fill any missing values and the paper order below."
        end
        local function calculate()
            local values = {}
            for _, name in ipairs(symbols) do
                local raw = inputs[name].Text
                local digit = tonumber(raw)
                if digit and digit % 1 == 0 and digit >= 0 and digit <= 9 then
                    values[name] = digit
                end
            end
            local code = ""
            for i = 1, 5 do
                local shape = identify(orderInputs[i].Text)
                if not shape or values[shape] == nil then
                    result.Text = "Missing/invalid clue for position " .. i
                    return
                end
                code ..= tostring(values[shape])
            end
            result.Text = "LIBRARY CODE: " .. code
        end
        solve.MouseButton1Click:Connect(calculate)
        button.MouseButton1Click:Connect(function()
            dialog.Visible = not dialog.Visible
            if dialog.Visible then
                fillDetected()
                result.Text = ""
            end
        end)
    end)()

    -- Stairwell door counter: separate HUD in the upper-right of the screen.
    -- It reads the local player's current numbered room, not team progress.
