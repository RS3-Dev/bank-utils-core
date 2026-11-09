-- Read tables with rawget so checking data cannot run plugin code.

local PlainData = {}

local ID_PATTERN = "^[%w_%.%-]+$"
local MAX_OBJECT_ID = 0x7FFFFFFF

function PlainData.ID(value, limit)
    return type(value) == "string"
        and #value <= limit
        and string.match(value, ID_PATTERN) ~= nil
end

function PlainData.Text(value, limit)
    if type(value) ~= "string" then return nil end
    local trimmed = string.match(value, "^%s*(.-)%s*$")
    if trimmed == "" or #trimmed > limit then return nil end
    return trimmed
end

-- Reject missing list entries, extra keys, and lists over the size limit.
function PlainData.Array(value, limit)
    if type(value) ~= "table" then return nil end
    local entries = {}
    for index = 1, limit + 1 do
        local entry = rawget(value, index)
        if entry == nil then break end
        if index > limit then return nil end
        entries[index] = entry
    end
    local fieldCount = 0
    for _ in next, value do
        fieldCount = fieldCount + 1
        if fieldCount > #entries then return nil end
    end
    return entries
end

-- Reject control characters (such as line breaks) and game text tag brackets.
function PlainData.Label(value, limit)
    local text = PlainData.Text(value, limit)
    if text == nil or string.find(text, "[%c<>]") then return nil end
    return text
end

function PlainData.HasOnlyFields(value, allowed)
    for key in next, value do
        if not allowed[key] then return false end
    end
    return true
end

function PlainData.ObjectNumber(entry)
    if math.type(entry) ~= "integer" and not (math.type(entry) == "float" and entry % 1 == 0) then
        return nil
    end
    local objectID = math.tointeger(entry)
    if objectID == nil or objectID < 0 or objectID > MAX_OBJECT_ID then return nil end
    return objectID
end

-- Accept image IDs, PrettyUI icon names, or named game sprite IDs.
function PlainData.ValidIcon(value)
    if type(value) == "number" then
        return value >= 0 and value <= 0x7FFFFFFF and value % 1 == 0
    end
    local sprites = type(prettyui) == "table" and type(prettyui.Sprites) == "table"
        and prettyui.Sprites.SPRITE_BUTTONS or nil
    if type(value) ~= "string" then return false end
    if type(sprites) == "table" and rawget(sprites, value) ~= nil then return true end
    local ok, spriteID = pcall(function() return id.Sprite[value] end)
    return ok and type(spriteID) == "number" and spriteID >= 0
        and spriteID <= 0x7FFFFFFF and spriteID % 1 == 0
end

return PlainData
