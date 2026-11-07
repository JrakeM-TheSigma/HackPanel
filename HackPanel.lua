-- HACK PANEL - main branch launcher; modules live on the Modules BRANCH.
local BASE = "https://raw.githubusercontent.com/JrakeM-TheSigma/HackPanel/Modules/"

local function fetch(name)
    local url = BASE .. name .. ".lua"
    local ok, source = pcall(function() return game:HttpGet(url) end)
    if not ok or type(source) ~= "string" then
        error("HACK PANEL download failed for " .. name .. ": " .. tostring(source))
    end
    local chunk, compileError = loadstring(source)
    if not chunk then
        error("HACK PANEL compile failed in " .. name .. ": " .. tostring(compileError))
    end
    local success, result = pcall(chunk)
    if not success then
        error("HACK PANEL runtime error in " .. name .. ": " .. tostring(result))
    end
    return result
end

local env = _G
if type(getgenv) == "function" then
    local ok, value = pcall(getgenv)
    if ok and type(value) == "table" then env = value end
end
if type(env.HackPanelModularCleanup) == "function" then
    pcall(env.HackPanelModularCleanup)
end
local context = {modules = {}, version = "1.0-two-branch-transition"}
env.HackPanelModularContext = context

for _, name in ipairs({"Cleanup", "Auto", "ESP", "Essentials", "Warnings", "Stairwell"}) do
    context.modules[name] = fetch(name)
end
context.modules.Cleanup.run(context)
-- Transition build: Core still contains the original panel and its features.
fetch("Core")
