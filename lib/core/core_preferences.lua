-- Load and save Core's preferences: debug logging and the sidebar icon order
local Config = require("lib/core/config")
local PlainData = require("lib/features/extensions/plain_data")
local CorePreferences = {}

-- Remembered extension IDs, including plugins not loaded now; IDs follow the registration rule
local MAX_RAIL_ORDER = 64
local ID_LENGTH = 64

-- Create Core's default preferences
function CorePreferences.defaults()
    return { enableDebug = false, railOrder = {} }
end

-- Copy a saved icon order, dropping invalid and repeated extension IDs
local function readRailOrder(value)
    local railOrder, seen = {}, {}
    if type(value) ~= "table" then return railOrder end
    for _, extensionID in ipairs(value) do
        if #railOrder == MAX_RAIL_ORDER then break end
        if PlainData.ID(extensionID, ID_LENGTH) and not seen[extensionID] then
            seen[extensionID] = true
            railOrder[#railOrder + 1] = extensionID
        end
    end
    return railOrder
end

-- Read valid saved preferences over defaults
function CorePreferences.load()
    local value = CorePreferences.defaults()
    local ok, saved = pcall(function()
        return PersistentDB:GetStructuredData(Config.PREFERENCES_KEY)
    end)
    if not ok or type(saved) ~= "table" then return value end
    if type(saved.enableDebug) == "boolean" then value.enableDebug = saved.enableDebug end
    value.railOrder = readRailOrder(saved.railOrder)
    return value
end

-- Save Core's preferences
function CorePreferences.save(value)
    local ok, saved = pcall(function()
        return PersistentDB:SetStructuredData(Config.PREFERENCES_KEY,
            { enableDebug = value.enableDebug == true, railOrder = value.railOrder })
    end)
    return ok and saved ~= false
end
return CorePreferences
