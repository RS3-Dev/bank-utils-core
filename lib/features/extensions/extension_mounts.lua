-- Give sidebar content its own area and popup layer.

local debugLog = require("lib/core/debug_log").Write
local PlainData = require("lib/features/extensions/plain_data")

local ExtensionMounts = {}
local Mount = {}
Mount.__index = Mount

local CALLBACKS = { mount = true, resize = true, unmount = true }

-- Only the mount function, which creates sidebar controls, is required.
function ExtensionMounts.Read(callbacksInput)
    if type(callbacksInput) ~= "table" or not PlainData.HasOnlyFields(callbacksInput, CALLBACKS) then
        return nil, "column must be a table of mount, resize, and unmount"
    end
    local callbacks = {}
    for name in pairs(CALLBACKS) do
        local action = rawget(callbacksInput, name)
        if action ~= nil and type(action) ~= "function" then
            return nil, "column " .. name .. " must be a function"
        end
        callbacks[name] = action
    end
    if callbacks.mount == nil then return nil, "column needs a mount function" end
    return callbacks
end

function ExtensionMounts.new(pluginPages, extension, callbacks)
    return setmetatable({
        service = pluginPages,
        owner = extension,
        callbacks = callbacks,
        -- A failed column stays failed until the plugin registers again.
        state = "closed",
        values = nil,
        bounds = nil,
        host = nil,
    }, Mount)
end

function Mount:IsMounted()
    return self.state == "mounted"
end

-- Remove all layers if setup or plugin drawing fails.
function Mount:Open(hostParent, window, bounds)
    if self.state ~= "closed" then return self.state == "mounted" end
    if not self.service:IsLive(self.owner) then return false end
    local extension = self.owner
    -- Record layers before setup so cleanup can always find them.
    local columnContext = { width = bounds.width, height = bounds.height }
    self.values = columnContext
    local built, problem = pcall(function()
        columnContext.parent = ui.Layer.new(hostParent)
        columnContext.parent:SetPos(bounds.x, bounds.y)
        columnContext.parent:SetSize(bounds.width, bounds.height)
        columnContext.overlay = ui.Layer.new(window)
        columnContext.overlay:SetPos(0, 0)
        columnContext.overlay:SetSize(0, 0, 1.0, 1.0)
        columnContext.overlay.clickthrough = true
    end)
    if not built then
        debugLog("Bank Core could not make the containers for ", extension.id, ": ", tostring(problem))
        self:Revoke()
        self.state = "failed"
        return false
    end
    self.bounds = bounds
    self.host = { parent = hostParent, window = window }
    self.state = "mounted"
    if not self.service:RunPluginCallback(extension, "mount", self.callbacks.mount, columnContext) then
        self:Revoke()
        self.state = "failed"
        return false
    end
    return self.state == "mounted"
end

-- Call the resize function if supplied; otherwise redraw the sidebar content.
function Mount:Resize(bounds)
    if self.state ~= "mounted" then return end
    local previous = self.bounds
    if previous.width == bounds.width and previous.height == bounds.height then
        self.bounds = bounds
        self.values.parent:SetPos(bounds.x, bounds.y)
        return
    end
    if self.callbacks.resize == nil then
        local host = self.host
        self:Close()
        self:Open(host.parent, host.window, bounds)
        return
    end
    self.bounds = bounds
    self.values.width, self.values.height = bounds.width, bounds.height
    self.values.parent:SetPos(bounds.x, bounds.y)
    self.values.parent:SetSize(bounds.width, bounds.height)
    self.service:RunPluginCallback(self.owner, "resize", self.callbacks.resize, self.values)
end

function Mount:RaiseOverlay()
    if self.state == "mounted" then self.values.overlay:MoveToFront() end
end

function Mount:Revoke()
    local columnContext = self.values
    self.values = nil
    if columnContext == nil then return end
    pcall(function() columnContext.parent:Destroy() end)
    pcall(function() columnContext.overlay:Destroy() end)
end

-- Call the plugin's cleanup once, then remove its layers.
function Mount:Close()
    if self.state ~= "mounted" then return end
    self.state = "closing"
    self.service:RunPluginCallback(self.owner, "unmount", self.callbacks.unmount)
    self:Revoke()
    self.state = "closed"
end

return ExtensionMounts
