-- Show an item grid. Change the title, labels and item IDs for your plugin.
local page = {
    title = "Supplies",
    rows = {
        { label = "Ingredients" },
        { slots = { 1944, false, 1927 } }, -- Egg, blank space, bucket of milk
    },
}

-- Use your plugin's own ID, display name and rail icon here.
local registration = { id = "examples.standard-page", name = "Standard page", icon = "STAR" }
local extension
-- When your items change, call extension:SetPage(page) again.

-- Remove this plugin's registration and displayed content
local function disconnect()
    if extension ~= nil then extension:Dispose() end
    extension = nil
end

-- Connect to Core, including after it reloads
local function connect()
    disconnect()
    local core = bankcore or rawget(_G, "__bankcore_api")
    if core ~= nil then extension = core.Register(registration) end
    if extension == nil then
        local published = rawget(_G, "__bankcore_api")
        if published ~= nil and published ~= core then extension = published.Register(registration) end
    end
    if extension ~= nil then extension:SetPage(page) end
end

-- Reconnect when Core loads or reloads
function PluginDependencyUpdate(event)
    if event.pluginIdentifier ~= "bankcore" then return end
    if event.enabled then connect() else disconnect() end
end

-- Release the registration when your plugin unloads
function PluginShutdown()
    disconnect()
end

connect()
