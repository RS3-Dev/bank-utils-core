-- Read and index the bank's real item components
-- Native slot IDs locate components; matching-item numbers describe bank order

local BankItemIndex = {}

-- Read the item ID associated with a native bank component
function BankItemIndex.ObjectID(component)
    return component ~= nil and component.associatedObjectID or nil
end

-- Build a lookup key from the client's slot IDs
function BankItemIndex.ComponentKey(component)
    local categoryID, dynamicID = component.categoryID, component.dynamicID
    if categoryID == dynamicID then return dynamicID end
    return "component:" .. categoryID .. ":" .. dynamicID
end

-- Build a key from the item ID and its number among matching stacks
function BankItemIndex.LayoutKey(objectID, stackNumber)
    stackNumber = stackNumber or 1
    if objectID == nil then return nil end
    return "object:" .. tostring(objectID) .. ":" .. tostring(stackNumber)
end

-- Sort by row, then column, then native slot ID
-- These numbers follow bank order, so moving a stack can change its number
-- They do not distinguish weapons by perks or other item details
local function comesFirstInBank(firstItem, secondItem)
    if firstItem.y == secondItem.y then
        if firstItem.x == secondItem.x then
            return firstItem.component.dynamicID < secondItem.component.dynamicID
        end
        return firstItem.x < secondItem.x
    end
    return firstItem.y < secondItem.y
end

-- Read native bank components in the order the client supplies them
function BankItemIndex.Read(bankItemLayer)
    local bankItems = {}
    bankItemLayer:IterateDynamicComponents(function(bankComponent)
        local objectID = BankItemIndex.ObjectID(bankComponent)
        if objectID ~= nil and objectID >= 0 then
            bankItems[#bankItems + 1] = {
                component = bankComponent,
                objectID = objectID,
                instanceKey = BankItemIndex.ComponentKey(bankComponent),
                x = bankComponent.x,
                y = bankComponent.y,
                quantity = bankComponent.associatedObjectQuantity,
            }
        end
        return false
    end)
    return bankItems
end

-- Sort bank stacks and number repeated item IDs
function BankItemIndex.Collect(bankItemLayer)
    local bankItems = BankItemIndex.Read(bankItemLayer)
    table.sort(bankItems, comesFirstInBank)
    local stackCounts = {}
    for _, bankItem in ipairs(bankItems) do
        local objectID = bankItem.objectID
        local stackNumber = (stackCounts[objectID] or 0) + 1
        stackCounts[objectID] = stackNumber
        bankItem.copy = stackNumber
        bankItem.layoutKey = BankItemIndex.LayoutKey(objectID, stackNumber)
    end
    return bankItems
end

return BankItemIndex
