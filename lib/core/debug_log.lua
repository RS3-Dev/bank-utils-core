-- Write debug messages only when logging is enabled.

local DebugLog = {}

local enabled = false

-- Turn logging on only when the setting is true.
function DebugLog.SetEnabled(value)
    enabled = value == true
end

-- Write to the game's log if logging is enabled and the log is available.
local function debugLog(...)
    if enabled and type(log) == "function" then log(...) end
end

DebugLog.Write = debugLog

-- Check whether debug logging is enabled.
function DebugLog.IsEnabled()
    return enabled
end

return DebugLog
