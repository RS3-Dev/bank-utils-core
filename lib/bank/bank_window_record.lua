-- Save window changes so Core can undo them later.

local Config = require("lib/core/config")
local DebugLog = require("lib/core/debug_log")
local debugLog = DebugLog.Write

local BankWindowRecord = {}
BankWindowRecord.__index = BankWindowRecord

-- Limit saved parts to reject damaged data.
local MAX_PARTS = 32
local MAX_OFFSET = 100000
local PART_FIELDS = { "x", "width", "expandedX", "expandedWidth" }

local function isOffset(value)
    return type(value) == "number" and value == value and math.abs(value) <= MAX_OFFSET
end

local function readPart(value)
    if type(value) ~= "table" or type(value.slot) ~= "string"
        or string.match(value.slot, "^%a+%d*$") == nil then
        return nil
    end
    local part = { slot = value.slot }
    for _, field in ipairs(PART_FIELDS) do
        if not isOffset(value[field]) then return nil end
        part[field] = value[field]
    end
    return part
end

-- Reject invalid records or records missing the window frame.
local function readRecord(value)
    if type(value) ~= "table" or not isOffset(value.sidebarWidth) or value.sidebarWidth <= 0
        or type(value.parts) ~= "table" or #value.parts > MAX_PARTS then
        return nil
    end
    local record = { sidebarWidth = value.sidebarWidth, parts = {} }
    local seenPartNames = {}
    for _, entry in ipairs(value.parts) do
        local part = readPart(entry)
        if part == nil or seenPartNames[part.slot] then return nil end
        seenPartNames[part.slot] = true
        record.parts[#record.parts + 1] = part
    end
    if not seenPartNames.host and not seenPartNames.all then return nil end
    return record
end

-- Skip saving unchanged records.
local function describeRecord(record)
    if record == nil then return "none" end
    local partsDescription = { record.sidebarWidth }
    for _, part in ipairs(record.parts) do
        partsDescription[#partsDescription + 1] = table.concat({ part.slot, part.x, part.width,
            part.expandedX, part.expandedWidth }, ",")
    end
    return table.concat(partsDescription, " ")
end

function BankWindowRecord.new(value, persisted, saved)
    return setmetatable({
        value = value,
        persisted = persisted == true,
        saved = saved or describeRecord(value),
    }, BankWindowRecord)
end

function BankWindowRecord.load()
    local ok, saved = pcall(function()
        return PersistentDB:GetStructuredData(Config.WINDOW_KEY)
    end)
    if not ok then debugLog("Bank Core could not read its bank window record: ", saved) end
    local record = ok and readRecord(saved) or nil
    return BankWindowRecord.new(record, true)
end

-- Only forget the record after removing its saved copy.
function BankWindowRecord:Clear()
    if self.persisted then
        local ok, deleted = pcall(function()
            return not PersistentDB:CheckExists(Config.WINDOW_KEY)
                or PersistentDB:Delete(Config.WINDOW_KEY)
        end)
        if not ok or deleted ~= true then
            return false, "Could not clear saved bank geometry. Try again."
        end
    end
    self.value = nil
    self.saved = describeRecord(nil)
    return true
end

-- Retry failed saves when Core connects to the bank, the bank closes, or Core stops.
function BankWindowRecord:Save()
    local currentSummary = describeRecord(self.value)
    if not self.persisted or self.value == nil or currentSummary == self.saved then return true end
    local copy = readRecord(self.value)
    if copy == nil then
        debugLog("Bank Core did not save an unreadable bank window record")
        return false
    end
    local ok, saved = pcall(function()
        return PersistentDB:SetStructuredData(Config.WINDOW_KEY, copy)
    end)
    if not ok or saved == false then
        debugLog("Bank Core could not save its bank window record: ", tostring(saved))
        return false
    end
    self.saved = currentSummary
    return true
end

return BankWindowRecord
