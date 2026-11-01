-- Let other plugins use Core without accessing its internal files.

local PublicAPI = {}

-- Give one plugin controls for its page or view, bank details, and menus.
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

-- Create the shared plugin API for pages and menus.
-- Keep only functions here because the game copies this table.
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
