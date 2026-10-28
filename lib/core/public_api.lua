-- Publish the extension API other plugins use instead of private modules

local PublicAPI = {}

-- Build one extension's methods for its page or view, bank reads, and menus
local function createExtensionHandle(pluginPages, menuRouter, extension)
    return {
        SetPage = function(_, page) return pluginPages:SetPage(extension, page) end,
        Refresh = function() return pluginPages:Refresh(extension) end,
        Open = function() return pluginPages:Open(extension) end,
        Close = function() return pluginPages:ClosePage(extension) end,
        IsOpen = function() return pluginPages:IsOpen(extension) end,
        GetBankItems = function() return pluginPages:BankItems(extension) end,
        GetBankBounds = function() return pluginPages:BankBounds(extension) end,
        GetMenuItem = function(_, menu) return menuRouter:Describe(extension, menu) end,
        Dispose = function() return pluginPages:DisposeOwner(extension) end,
    }
end

-- Build the API table for one page service and its menus
-- The host clones it, so it holds only functions
function PublicAPI.new(pluginPages, menuRouter)
    return {
        Register = function(registration)
            local extension, reason, detail = pluginPages:RegisterOwner(registration)
            if extension == nil then return nil, reason, detail end
            return createExtensionHandle(pluginPages, menuRouter, extension)
        end,
    }
end

return PublicAPI
