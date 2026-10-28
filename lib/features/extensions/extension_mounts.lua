-- Give a plugin a clipped sidebar column and a separate layer for popups
-- Run the plugin's callbacks and destroy both layers when the column closes

local debugLog = require("lib/core/debug_log").Write
local PlainData = require("lib/features/extensions/plain_data")

local ExtensionMounts = {}
local Mount = {}
Mount.__index = Mount

local CALLBACKS = { mount = true, resize = true, unmount = true }

-- Copy a column's callbacks: mount is required, the others are optional
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

-- Bind one extension's column callbacks to its owner and service
function ExtensionMounts.new(pluginPages, extension, callbacks)
    return setmetatable({
        service = pluginPages,
        owner = extension,
        callbacks = callbacks,
        -- closed, mounted, closing, or failed; failed lasts until the extension registers again
        state = "closed",
        values = nil,
        bounds = nil,
        host = nil,
    }, Mount)
end

-- Report whether the plugin's column is mounted now
function Mount:IsMounted()
    return self.state == "mounted"
end

-- Create the containers and call the plugin's mount with them
-- A container the client refuses, or a mount that errors, leaves no container and is marked failed
function Mount:Open(hostParent, window, bounds)
    if self.state ~= "closed" then return self.state == "mounted" end
    if not self.service:IsLive(self.owner) then return false end
    local extension = self.owner
    -- Each container is recorded as soon as it exists, so a refusal setting up either removes both
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

-- Move and resize the column, telling the plugin its new size
-- Without a resize callback the column is mounted again at the new size, unless unmount disposed it
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

-- Keep the overlay above everything else Core draws
function Mount:RaiseOverlay()
    if self.state == "mounted" then self.values.overlay:MoveToFront() end
end

-- Destroy the column and its popup layer
function Mount:Revoke()
    local columnContext = self.values
    self.values = nil
    if columnContext == nil then return end
    pcall(function() columnContext.parent:Destroy() end)
    pcall(function() columnContext.overlay:Destroy() end)
end

-- Tell the plugin its column closes, then destroy it regardless
-- Closing again during unmount does nothing
function Mount:Close()
    if self.state ~= "mounted" then return end
    self.state = "closing"
    self.service:RunPluginCallback(self.owner, "unmount", self.callbacks.unmount)
    self:Revoke()
    self.state = "closed"
end

return ExtensionMounts
