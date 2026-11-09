-- Write debug messages only when logging is enabled.

local DebugLog = {}

local enabled = false

function DebugLog.SetEnabled(value)
    enabled = value == true
end

local function debugLog(...)
    if enabled and type(log) == "function" then log(...) end
end

DebugLog.Write = debugLog

function DebugLog.IsEnabled()
    return enabled
end

return DebugLog
