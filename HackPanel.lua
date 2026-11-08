-- HACK PANEL - main branch launcher; source fragments on Modules branch.
-- Modules are concatenated in source order to preserve the original local scope.
local BASE = "https://raw.githubusercontent.com/JrakeM-TheSigma/HackPanel/Modules/"
local env = _G
if type(getgenv) == "function" then
    local ok, result = pcall(getgenv)
    if ok and type(result) == "table" then env = result end
end
local function download(name)
    local url = BASE .. name .. ".lua"
    local ok, body = pcall(function() return game:HttpGet(url) end)
    if not ok or type(body) ~= "string" or #body == 0 then
        error("HACK PANEL download failed: " .. name .. " " .. tostring(body))
    end
    return body
end
local cleanupChunk, cleanupError = loadstring(download("Cleanup"), "Cleanup.lua")
if not cleanupChunk then error(cleanupError) end
local cleanup = cleanupChunk()
if type(cleanup) == "function" then pcall(cleanup, env) end
local order = {"Core", "Essentials", "Warnings", "ESP", "Auto", "Stairwell"}
local parts = {}
for _, name in ipairs(order) do
    parts[#parts + 1] = "-- BEGIN " .. name .. ".lua\n" .. download(name) .. "\n-- END " .. name .. ".lua\n"
end
local source = table.concat(parts, "\n")
local chunk, compileError = loadstring(source, "HackPanel Modular")
if not chunk then error("HACK PANEL compile error: " .. tostring(compileError)) end
local ok, runtimeError = pcall(chunk)
if not ok then error("HACK PANEL runtime error: " .. tostring(runtimeError)) end
