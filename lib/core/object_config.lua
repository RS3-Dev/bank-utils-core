-- Read item names and stacking from the client's object configs

local ObjectConfig = {}

-- The client's ObjStackType values: SOMETIMES (0) stacks where an inventory allows, as the
-- bank does; ALWAYS (1) stacks everywhere; NEVER (2) stays apart, as objects with ObjVars do
local STACKS_IN_BANK = { [0] = true, [1] = true, [2] = false }

-- Read an object's display name, or nil when the client has none
function ObjectConfig.DisplayName(objectID)
    local ok, name = pcall(function() return config.Obj.FromID(objectID).name end)
    return ok and type(name) == "string" and name ~= "" and name or nil
end

-- Report whether every copy of an object joins one bank stack, or nil when unreadable
function ObjectConfig.StacksInBank(objectID)
    local ok, stackType = pcall(function() return config.Obj.FromID(objectID).stackType end)
    if not ok then return nil end
    return STACKS_IN_BANK[stackType]
end

return ObjectConfig
