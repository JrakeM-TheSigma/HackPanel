-- Lifecycle cleanup before the assembled panel is started.
return function(env)
    if type(env.HackPanelNightVisionCleanup) == "function" then
        pcall(env.HackPanelNightVisionCleanup)
    end
    env.HackPanelRunToken = nil
    local player = game:GetService("Players").LocalPlayer
    local gui = player and player:FindFirstChildOfClass("PlayerGui")
    if gui then
        for _, name in ipairs({"UtilityMenuGui","EspLinesOverlay","EspNotifyGui","HackPanelEntityAlert","HackPanelEntityHUD","HackPanelWarningsOverlay","HackPanelStairwellDoorCounter"}) do
            local old = gui:FindFirstChild(name)
            if old then old:Destroy() end
        end
    end
end
