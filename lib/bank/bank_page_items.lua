-- Track a page's slots and the bank items they display

local BankInterface = require("lib/core/bank_interface")
local BankItemIndex = require("lib/bank/bank_item_index")
local BankGrid = require("lib/engine/bank_grid")
local ObjectConfig = require("lib/core/object_config")

local BankPageItems = {}
BankPageItems.__index = BankPageItems

local BANK_ITEMS_STATIC_ID = BankInterface.ITEMS
local GRID_SLOT_SIZE = BankGrid.SLOT_SIZE
local DEFAULT_ITEM_SIZE = 32
local PLACEHOLDER_ALPHA = 0.45
local PLACEHOLDER_QUANTITY_MODE = ui.ObjectQuantityDisplayMode.ALWAYS

local component = BankInterface.Get

function BankPageItems.new()
    local self = setmetatable({}, BankPageItems)
    self:Restore()
    return self
end

-- Clear page data without moving any native items
function BankPageItems:Restore()
    self.active = false
    self.bankItems = {}
    -- Bank items changed since this read.
    self.stale = false
    self.view = nil
    self.columns = nil
    self.itemWidth = DEFAULT_ITEM_SIZE
    self.itemHeight = DEFAULT_ITEM_SIZE
    self.placeholderWidth = DEFAULT_ITEM_SIZE
    self.placeholderHeight = DEFAULT_ITEM_SIZE
    self.placeholderOutlineWidth = nil
    self.placeholderShadowRGBA = nil
    -- Repeated items that share one bank stack.
    self.sharedStacks = {}
end

function BankPageItems:IsInSync()
    if not self.active then return false end

    local bankItemLayer = component(BANK_ITEMS_STATIC_ID)
    if bankItemLayer == nil then return false end

    -- Compare slots directly without sorting.
    local stacksBySlot = {}
    for _, bankItemSnapshot in ipairs(BankItemIndex.Read(bankItemLayer)) do
        stacksBySlot[bankItemSnapshot.instanceKey] = { objectID = bankItemSnapshot.objectID, quantity = bankItemSnapshot.quantity }
    end
    local snapshotCount = 0
    for _, bankItem in ipairs(self.bankItems) do
        snapshotCount = snapshotCount + 1
        local currentStack = stacksBySlot[bankItem.instanceKey]
        if currentStack == nil
            or currentStack.objectID ~= bankItem.objectID
            or currentStack.quantity ~= bankItem.quantity then
            return false
        end
        stacksBySlot[bankItem.instanceKey] = nil
    end
    for _ in pairs(stacksBySlot) do return false end
    return snapshotCount > 0
end

function BankPageItems:GetPlaceholderStyle()
    return {
        alpha = PLACEHOLDER_ALPHA,
        quantityMode = PLACEHOLDER_QUANTITY_MODE,
    }
end

function BankPageItems:GetLayoutSections()
    return self.view ~= nil and self.view.headings or {}
end

-- Unknown quantities count as stocked, but cannot receive input yet.
local function isPlaceholder(bankItem)
    return bankItem.quantity ~= nil and bankItem.quantity <= 0
end

-- Group by item ID, stocked first, preserving bank order.
local function groupStacksByObject(bankItems)
    local stockedStacksByObject, placeholdersByObject = {}, {}
    for _, bankItem in ipairs(bankItems) do
        local stackGroup = isPlaceholder(bankItem) and placeholdersByObject or stockedStacksByObject
        local objectStacks = stackGroup[bankItem.objectID]
        if objectStacks == nil then
            objectStacks = {}
            stackGroup[bankItem.objectID] = objectStacks
        end
        objectStacks[#objectStacks + 1] = bankItem
    end
    for objectID, objectStacks in pairs(placeholdersByObject) do
        local allObjectStacks = stockedStacksByObject[objectID] or {}
        stockedStacksByObject[objectID] = allObjectStacks
        for _, bankItem in ipairs(objectStacks) do allObjectStacks[#allObjectStacks + 1] = bankItem end
    end
    return stockedStacksByObject
end

-- Shared stacks serve every copy; other items use separate stacks.
local function stackForSlot(stacksByObject, sharedStacks, slot)
    local objectStacks = stacksByObject[slot.objectID]
    if objectStacks == nil then return nil end
    if slot.bankSlot ~= nil then
        for _, stack in ipairs(objectStacks) do
            if stack.bankSlot == slot.bankSlot then return stack end
        end
        -- Filtered pages must keep the exact stack they requested.
        return nil
    end
    return objectStacks[sharedStacks[slot.objectID] and 1 or slot.occurrence]
end

-- Check once per repeated item whether its copies share a stack.
local function readSharedStacks(view)
    local sharedStacks = {}
    for _, slot in ipairs(view.slots) do
        if slot.occurrence == 2 then
            sharedStacks[slot.objectID] = ObjectConfig.StacksInBank(slot.objectID) == true
        end
    end
    return sharedStacks
end

-- Pair each page image with its bank stack and visible click area.
local function pageItem(self, slot, quantity, bankItem, insetX, insetY)
    local placeholder = quantity ~= nil and quantity <= 0
    -- Empty stacks use placeholder styling.
    local nativeComponent = not placeholder and bankItem ~= nil and bankItem.component or nil
    return {
        objectID = slot.objectID,
        layoutKey = slot.layoutKey,
        binding = slot.binding,
        x = slot.x,
        y = slot.y,
        area = slot.x ~= nil and { x = slot.x - insetX, y = slot.y - insetY,
            width = GRID_SLOT_SIZE, height = GRID_SLOT_SIZE } or nil,
        width = nativeComponent ~= nil and nativeComponent.width or self.placeholderWidth,
        height = nativeComponent ~= nil and nativeComponent.height or self.placeholderHeight,
        quantity = placeholder and 0 or quantity,
        quantityMode = placeholder and PLACEHOLDER_QUANTITY_MODE
            or (nativeComponent ~= nil and nativeComponent.associatedObjectQuantityMode or nil),
        outlineWidth = placeholder and self.placeholderOutlineWidth
            or (nativeComponent ~= nil and nativeComponent.outlineWidth or nil),
        shadowRGBA = placeholder and self.placeholderShadowRGBA
            or (nativeComponent ~= nil and nativeComponent.shadowRGBA or nil),
        alpha = placeholder and PLACEHOLDER_ALPHA or 1,
        placeholder = placeholder,
        bankItem = bankItem,
    }
end

-- Build page items in layout order; click areas include the image insets.
function BankPageItems:GetVisibleItems(insetX, insetY)
    local items = {}
    if self.view == nil then return items end
    local stacksByObject = groupStacksByObject(self.bankItems)
    for _, slot in ipairs(self.view.slots) do
        local bankItem = stackForSlot(stacksByObject, self.sharedStacks, slot)
        -- Keep unknown quantities as shown; missing stacks show none held.
        local quantity = 0
        if bankItem ~= nil then quantity = bankItem.component.associatedObjectQuantity end
        items[#items + 1] = pageItem(self, slot, quantity, bankItem, insetX, insetY)
    end
    return items
end

function BankPageItems:Slot(layoutKey)
    return self.view ~= nil and self.view.members[layoutKey] or nil
end

-- Check whether bank changes assigned a different stack to any slot.
function BankPageItems:StacksReassigned(freshBankItems)
    if self.view == nil then return false end
    if freshBankItems == nil then
        local bankItemLayer = component(BANK_ITEMS_STATIC_ID)
        if bankItemLayer == nil then return true end
        freshBankItems = BankItemIndex.Read(bankItemLayer)
    end
    local stacksBySlot, count = {}, 0
    for _, bankItemSnapshot in ipairs(freshBankItems) do
        stacksBySlot[bankItemSnapshot.instanceKey] = bankItemSnapshot
        count = count + 1
    end
    if count ~= #self.bankItems then return true end
    local currentBankItems = {}
    for index, bankItem in ipairs(self.bankItems) do
        local bankItemSnapshot = stacksBySlot[bankItem.instanceKey]
        if bankItemSnapshot == nil or bankItemSnapshot.objectID ~= bankItem.objectID then return true end
        currentBankItems[index] = { objectID = bankItemSnapshot.objectID, instanceKey = bankItemSnapshot.instanceKey,
            quantity = bankItemSnapshot.quantity, bankSlot = bankItemSnapshot.bankSlot }
    end
    local previousStacksByObject, currentStacksByObject = groupStacksByObject(self.bankItems), groupStacksByObject(currentBankItems)
    for _, slot in ipairs(self.view.slots) do
        local previousStack = stackForSlot(previousStacksByObject, self.sharedStacks, slot)
        local currentStack = stackForSlot(currentStacksByObject, self.sharedStacks, slot)
        if (previousStack and previousStack.instanceKey) ~= (currentStack and currentStack.instanceKey) then return true end
    end
    return false
end

-- Read item sizes and placeholder styling.
local function captureDisplayMetrics(self, items)
    local sampleComponent = items[1] and items[1].component or nil
    local itemWidth = sampleComponent ~= nil and sampleComponent.width or nil
    local itemHeight = sampleComponent ~= nil and sampleComponent.height or nil
    local placeholderComponent = nil
    for _, bankItemSnapshot in ipairs(items) do
        if bankItemSnapshot.quantity ~= nil and bankItemSnapshot.quantity <= 0 then
            placeholderComponent = bankItemSnapshot.component
            break
        end
    end

    self.itemWidth = itemWidth ~= nil and itemWidth > 0
        and itemWidth or DEFAULT_ITEM_SIZE
    self.itemHeight = itemHeight ~= nil and itemHeight > 0
        and itemHeight or DEFAULT_ITEM_SIZE
    local placeholderWidth = placeholderComponent ~= nil
        and placeholderComponent.width or nil
    local placeholderHeight = placeholderComponent ~= nil
        and placeholderComponent.height or nil
    self.placeholderWidth = placeholderWidth ~= nil and placeholderWidth > 0
        and placeholderWidth or self.itemWidth
    self.placeholderHeight = placeholderHeight ~= nil and placeholderHeight > 0
        and placeholderHeight or self.itemHeight
    self.placeholderOutlineWidth = placeholderComponent ~= nil
        and placeholderComponent.outlineWidth or nil
    self.placeholderShadowRGBA = placeholderComponent ~= nil
        and placeholderComponent.shadowRGBA or nil
end

-- Refresh bank stacks without changing the page arrangement
function BankPageItems:RefreshBankItems()
    if not self.active then return false end
    local bankItemLayer = component(BANK_ITEMS_STATIC_ID)
    if bankItemLayer == nil then return false end
    local items = BankItemIndex.Collect(bankItemLayer)
    self.bankItems = items
    self.stale = false
    -- Previously unreadable item types may be available now.
    self.sharedStacks = readSharedStacks(self.view)
    captureDisplayMetrics(self, items)
    return true
end

-- Read bank items once for the page and its plugin.
function BankPageItems:ReadBank()
    local bankItemLayer = component(BANK_ITEMS_STATIC_ID)
    if bankItemLayer == nil then return nil end
    local items = BankItemIndex.Collect(bankItemLayer)
    self.bankItems = items
    self.stale = false
    captureDisplayMetrics(self, items)
    self.active = true
    return bankItemLayer
end

-- Apply the page layout and count slots with bank stacks.
function BankPageItems:SetView(view, columns)
    self.view = view
    self.columns = columns
    self.sharedStacks = readSharedStacks(view)
    local matchCount, stacksByObject = 0, groupStacksByObject(self.bankItems)
    for _, slot in ipairs(view.slots) do
        if stackForSlot(stacksByObject, self.sharedStacks, slot) ~= nil then matchCount = matchCount + 1 end
    end
    return matchCount
end

-- Lay out the page; missing stacks appear as ghost images.
function BankPageItems:ApplyLayout(place)
    local bankItemLayer = self:ReadBank()
    if bankItemLayer == nil then return false, 0 end
    local columns = BankGrid.ColumnCount(bankItemLayer.width)
    return true, self:SetView(place(columns), columns)
end

return BankPageItems
