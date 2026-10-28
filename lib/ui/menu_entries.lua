-- Order native right-click menu entries; a left click runs the last one

local MenuEntries = {}

-- Find the Cancel entry
local function cancelIndex(menu)
    for index, entry in ipairs(menu.entries) do
        if entry.actionType == MiniMenuActionType.CANCEL then return index end
    end
    return nil
end

-- Move one entry to the highest priority, keeping the others in order
function MenuEntries.Promote(menu, index)
    for current = index, menu.entryCount - 1 do menu:Swap(current, current + 1) end
end

-- Place Cancel at the highest priority, so a left click does nothing
function MenuEntries.PromoteCancel(menu)
    local index = cancelIndex(menu)
    if index == nil then return false end
    MenuEntries.Promote(menu, index)
    return true
end

return MenuEntries
