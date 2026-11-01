-- Read item names and stacking rules from the game's item definitions.

local ObjectConfig = {}

-- Stacking rules: 0 allows stacking in the bank, 1 allows it everywhere, 2 forbids it.
local STACKS_IN_BANK = { [0] = true, [1] = true, [2] = false }

-- Read an item's display name, or return nil if unavailable.
function ObjectConfig.DisplayName(objectID)
    local ok, name = pcall(function() return config.Obj.FromID(objectID).name end)
    return ok and type(name) == "string" and name ~= "" and name or nil
end

-- Check whether copies of an item share a bank stack; return nil if unknown.
function ObjectConfig.StacksInBank(objectID)
    local ok, stackType = pcall(function() return config.Obj.FromID(objectID).stackType end)
    if not ok then return nil end
    return STACKS_IN_BANK[stackType]
end

return ObjectConfig
