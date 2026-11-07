local M = {}
function M.run(context)
    local env = (type(getgenv) == "function" and getgenv()) or _G
    -- The previous panel uses the following names. Never scan all workspace parts here.
    local names = {UtilityMenuGui=true, EspLinesOverlay=true, EspNotifyGui=true,
        HackPanelEntityAlert=true, HackPanelEntityHUD=true, HackPanelStairwellDoorCounter=true}
    local player = game:GetService("Players").LocalPlayer
    local gui = player and player:FindFirstChildOfClass("PlayerGui")
    if gui then
        for _, child in ipairs(gui:GetChildren()) do
            if names[child.Name] then child:Destroy() end
        end
    end
    env.HackPanelModularCleanup = function()
        if env.HackPanelModularContext ~= context then return end
        local nv = env.HackPanelNightVisionCleanup
        if type(nv) == "function" then pcall(nv) end
        if gui then
            for _, child in ipairs(gui:GetChildren()) do
                if names[child.Name] then child:Destroy() end
            end
        end
        env.HackPanelRunToken = {}
        pcall(function() game:GetService("RunService"):UnbindFromRenderStep("HackPanelFreeCursor") end)
    end
end
return M
