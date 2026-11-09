-- The last menu entry is the default left-click action.

local MenuEntries = {}

local function cancelIndex(menu)
    for index, entry in ipairs(menu.entries) do
        if entry.actionType == MiniMenuActionType.CANCEL then return index end
    end
    return nil
end

-- Move an entry to the default action without reordering the others.
function MenuEntries.Promote(menu, index)
    for current = index, menu.entryCount - 1 do menu:Swap(current, current + 1) end
end

-- Default to Cancel so left clicks do nothing.
function MenuEntries.PromoteCancel(menu)
    local index = cancelIndex(menu)
    if index == nil then return false end
    MenuEntries.Promote(menu, index)
    return true
end

return MenuEntries
