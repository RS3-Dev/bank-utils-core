-- Find bank stacks by slot or their order among matching items.

local BankItemIndex = {}

function BankItemIndex.ObjectID(component)
    return component ~= nil and component.associatedObjectID or nil
end

function BankItemIndex.ComponentKey(component)
    local categoryID, dynamicID = component.categoryID, component.dynamicID
    if categoryID == dynamicID then return dynamicID end
    return "component:" .. categoryID .. ":" .. dynamicID
end

-- Match an item ID and its place among copies.
function BankItemIndex.LayoutKey(objectID, stackNumber)
    stackNumber = stackNumber or 1
    if objectID == nil then return nil end
    return "object:" .. tostring(objectID) .. ":" .. tostring(stackNumber)
end

-- Number copies in bank order; perks and other item details do not distinguish them.
local function comesFirstInBank(firstItem, secondItem)
    if firstItem.y == secondItem.y then
        if firstItem.x == secondItem.x then
            return firstItem.component.dynamicID < secondItem.component.dynamicID
        end
        return firstItem.x < secondItem.x
    end
    return firstItem.y < secondItem.y
end

-- Keep the game's item order.
function BankItemIndex.Read(bankItemLayer)
    local bankItems = {}
    bankItemLayer:IterateDynamicComponents(function(bankComponent)
        local objectID = BankItemIndex.ObjectID(bankComponent)
        if objectID ~= nil and objectID >= 0 then
            bankItems[#bankItems + 1] = {
                component = bankComponent,
                objectID = objectID,
                instanceKey = BankItemIndex.ComponentKey(bankComponent),
                bankSlot = bankComponent.dynamicID + 1,
                x = bankComponent.x,
                y = bankComponent.y,
                quantity = bankComponent.associatedObjectQuantity,
            }
        end
        return false
    end)
    return bankItems
end

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
