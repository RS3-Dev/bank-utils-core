-- Save the width and movement Core added to each bank component
-- Read once per start; saved only on attach, close, or stop

local Config = require("lib/core/config")
local DebugLog = require("lib/core/debug_log")
local debugLog = DebugLog.Write

local BankWindowRecord = {}
BankWindowRecord.__index = BankWindowRecord

-- Reject damaged saved data; a normal bank window has about a dozen parts
local MAX_PARTS = 32
local MAX_OFFSET = 100000
local PART_FIELDS = { "x", "width", "expandedX", "expandedWidth" }

-- Check that a saved value is a plain number a window offset could be
local function isOffset(value)
    return type(value) == "number" and value == value and math.abs(value) <= MAX_OFFSET
end

-- Copy one recorded part, or nil when any field is not usable
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

-- Copy a record, or nil when anything is unusable; it must hold the window frame
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

-- Describe a record so an unchanged one is not saved again
local function describeRecord(record)
    if record == nil then return "none" end
    local partsDescription = { record.sidebarWidth }
    for _, part in ipairs(record.parts) do
        partsDescription[#partsDescription + 1] = table.concat({ part.slot, part.x, part.width,
            part.expandedX, part.expandedWidth }, ",")
    end
    return table.concat(partsDescription, " ")
end

-- Keep a window record in memory, optionally saving it to PersistentDB
function BankWindowRecord.new(value, persisted, saved)
    return setmetatable({
        value = value,
        persisted = persisted == true,
        saved = saved or describeRecord(value),
    }, BankWindowRecord)
end

-- Read the saved record once
function BankWindowRecord.load()
    local ok, saved = pcall(function()
        return PersistentDB:GetStructuredData(Config.WINDOW_KEY)
    end)
    if not ok then debugLog("Bank Core could not read its bank window record: ", saved) end
    local record = ok and readRecord(saved) or nil
    return BankWindowRecord.new(record, true)
end

-- Save the record if it changed; a rejected save retries at the next attach, close, or stop
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
