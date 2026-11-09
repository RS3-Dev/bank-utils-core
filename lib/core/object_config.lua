-- Read item names and stacking rules from the game.

local ObjectConfig = {}

-- Stacking: 0 = bank only, 1 = everywhere, 2 = never.
local STACKS_IN_BANK = { [0] = true, [1] = true, [2] = false }

function ObjectConfig.DisplayName(objectID)
    local ok, name = pcall(function() return config.Obj.FromID(objectID).name end)
    return ok and type(name) == "string" and name ~= "" and name or nil
end

-- Return nil if stacking rules are unknown.
function ObjectConfig.StacksInBank(objectID)
    local ok, stackType = pcall(function() return config.Obj.FromID(objectID).stackType end)
    if not ok then return nil end
    return STACKS_IN_BANK[stackType]
end

return ObjectConfig
