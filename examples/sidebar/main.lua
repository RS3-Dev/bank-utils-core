-- Add your own sidebar controls. This button opens the page defined below.
local extension
local page = { title = "Sidebar example", rows = { { slots = { 1944, 1927 } } } }

-- Draw controls inside the space Core supplies
local function drawSidebar(ctx)
    local label = ui.Text.new(ctx.parent)
    label:SetPos(8, 8)
    label:SetSize(ctx.width - 16, 24)
    label.content = "Your plugin's controls go here"
    label.clickthrough = true

    local button = ui.Button.new(ctx.parent)
    button:SetPos(8, 40)
    button:SetSize(ctx.width - 16, 28)
    button.text.content = "Open page"
    button:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
        extension:Open() -- Replace this action with your own button behavior.
    end)
end

-- Core calls drawSidebar when this icon's column opens or resizes.
-- Core destroys the controls when the column closes.
local registration = {
    id = "examples.sidebar", name = "Sidebar example", icon = "LIST_LAYOUT",
    column = { mount = drawSidebar },
}

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
