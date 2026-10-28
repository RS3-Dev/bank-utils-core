-- Validate plugin input without running custom table lookup functions

local PlainData = {}

local ID_PATTERN = "^[%w_%.%-]+$"
local MAX_OBJECT_ID = 0x7FFFFFFF

-- Accept an extension identifier within a length limit
function PlainData.ID(value, limit)
    return type(value) == "string"
        and #value <= limit
        and string.match(value, ID_PATTERN) ~= nil
end

-- Read a trimmed, non-empty display text within a length limit
function PlainData.Text(value, limit)
    if type(value) ~= "string" then return nil end
    local trimmed = string.match(value, "^%s*(.-)%s*$")
    if trimmed == "" or #trimmed > limit then return nil end
    return trimmed
end

-- Copy a plain array, refusing gaps, extra keys, and long lists
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

-- Read display text, refusing control characters and the client's markup brackets
function PlainData.Label(value, limit)
    local text = PlainData.Text(value, limit)
    if text == nil or string.find(text, "[%c<>]") then return nil end
    return text
end

-- Check that a table names only the allowed fields
function PlainData.HasOnlyFields(value, allowed)
    for key in next, value do
        if not allowed[key] then return false end
    end
    return true
end

-- Read an object ID, or nil when it is not a whole ID in range
function PlainData.ObjectNumber(entry)
    if math.type(entry) ~= "integer" and not (math.type(entry) == "float" and entry % 1 == 0) then
        return nil
    end
    local objectID = math.tointeger(entry)
    if objectID == nil or objectID < 0 or objectID > MAX_OBJECT_ID then return nil end
    return objectID
end

-- Accept a PrettyUI sprite-button name the running PrettyUI defines
function PlainData.KnownIcon(name)
    local sprites = type(prettyui) == "table" and type(prettyui.Sprites) == "table"
        and prettyui.Sprites.SPRITE_BUTTONS or nil
    return type(name) == "string" and type(sprites) == "table" and rawget(sprites, name) ~= nil
end

return PlainData
