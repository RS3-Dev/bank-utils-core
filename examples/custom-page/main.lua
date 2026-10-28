-- Draw items at your own positions. Change these IDs, positions and sizes.
local items = {
    { objectID = 1944, x = 16, y = 40, size = 40 }, -- Egg
    { objectID = 1927, x = 100, y = 72, size = 56 }, -- Bucket of milk
}
local extension

-- Draw your UI, then bind its item pictures
local function drawPage(view)
    local panel = ui.Layer.new(view.parent)
    panel:SetPos(16, 16)
    panel:SetSize(view.width - 32, 160)
    panel.clickthrough = true -- Let input reach Core beneath the pictures.

    local label = ui.Text.new(panel)
    label:SetPos(8, 8)
    label:SetSize(panel.width - 16, 24)
    label.content = "Your custom layout"
    label.clickthrough = true

    for _, item in ipairs(items) do
        local picture = ui.Sprite.new(panel)
        picture:SetPos(item.x, item.y)
        picture:SetSize(item.size, item.size)
        picture:SetAssociatedObject(item.objectID)
        picture.associatedObjectQuantityMode = ui.ObjectQuantityDisplayMode.NEVER
        assert(view:BindItem(picture, item.objectID)) -- Native hover, menus and dragging.
    end
    return 200 -- Total content height; Core supplies scrolling if needed.
end

-- Core calls drawPage when this icon opens. SetPage is not needed here.
local registration = {
    id = "examples.custom-page", name = "Custom page", icon = "GRID_LAYOUT",
    customView = drawPage,
}
-- When your layout data changes, call extension:Refresh() to draw it again.

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
