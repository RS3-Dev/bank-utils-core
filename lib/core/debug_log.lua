-- Show optional debug output only when the saved debug setting is on

local DebugLog = {}

local enabled = false

-- Enable optional console output only when the saved debug preference is true
function DebugLog.SetEnabled(value)
    enabled = value == true
end

-- Send debug messages to the host log only while debugging is on
local function debugLog(...)
    if enabled and type(log) == "function" then log(...) end
end

DebugLog.Write = debugLog

-- Report whether debug messages are being written
function DebugLog.IsEnabled()
    return enabled
end

return DebugLog
