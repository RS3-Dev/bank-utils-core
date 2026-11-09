-- Keep bank menu actions aimed at the right item.

local BankInterface = require("lib/core/bank_interface")
local BankItemIndex = require("lib/bank/bank_item_index")
local DebugLog = require("lib/core/debug_log")
local UICoordinates = require("lib/ui/ui_coordinates")
local MenuEntries = require("lib/ui/menu_entries")
local debugLog = DebugLog.Write

local MiniMenuRouter = {}
MiniMenuRouter.__index = MiniMenuRouter

function MiniMenuRouter.new(session, options)
    return setmetatable({
        session = session,
        options = options,
        -- Reuse bank data until items change.
        nativeIndex = nil,
    }, MiniMenuRouter)
end

local function sameComponent(component, menuItem)
    return component ~= nil
        and component.categoryID == menuItem.categoryID
        and component.dynamicID == menuItem.dynamicID
end

-- Reuse the item lookup until bank items change.
function MiniMenuRouter:NativeEntry(menuItem)
    local bankView = self.session.layout
    local bankSnapshot = self.nativeIndex
    if bankSnapshot == nil or bankSnapshot.generation ~= bankView.itemsGeneration then
        local bankItemLayer = BankInterface.Find(BankInterface.ITEMS)
        bankSnapshot = { generation = bankView.itemsGeneration,
            entries = bankItemLayer ~= nil and BankItemIndex.Collect(bankItemLayer) or {} }
        self.nativeIndex = bankSnapshot
    end
    for _, entry in ipairs(bankSnapshot.entries) do
        if entry.objectID == menuItem.id and sameComponent(entry.component, menuItem) then
            return entry
        end
    end
    return nil
end

function MiniMenuRouter:PageSlotAtPointer()
    local bankView = self.session.layout
    local inputBlocker = bankView.itemHover.pageInputBlocker
    local pageArea = bankView.pageDisplay.pageArea
    local pointerX, pointerY = UICoordinates.interfaceMousePosition()
    if inputBlocker == nil or pageArea == nil or pointerX == nil then return nil end
    local originX, originY = UICoordinates.absolutePosition(inputBlocker)
    local localX, localY = pointerX - originX, pointerY - originY
    if localX < 0 or localY < 0 or localX >= pageArea.width or localY >= pageArea.height then return nil end
    return bankView.pageDisplay:EntryAtPosition(bankView.itemHover.drawnPageItems, pageArea, localX, localY)
end

-- Find the slot for the hovered stack, or check the mouse position.
function MiniMenuRouter:PageMenuSlot(menuItem)
    local bankView = self.session.layout
    local hoveredStack = bankView.itemHover.hoveredBankStack
    local entry = nil
    if menuItem ~= nil then
        if hoveredStack == nil or hoveredStack.suspended or hoveredStack.objectID ~= menuItem.id
            or not sameComponent(hoveredStack.item, menuItem) then
            return nil
        end
        entry = hoveredStack.entry
    else
        entry = self:PageSlotAtPointer()
    end
    if entry == nil then return nil end
    return bankView.pageState:Slot(entry.layoutKey), entry
end

-- Include page slot details only when that plugin's page is up to date.
function MiniMenuRouter:Describe(owner, menu)
    local pluginPages, bankView = self.session.pluginPages, self.session.layout
    local menuType = type(menu)
    if not pluginPages:IsLive(owner) or not pluginPages:BankReady()
        or (menuType ~= "table" and menuType ~= "userdata") then
        return nil
    end
    local menuItem = self.options.bankItemFromMenu(menu)
    local item = nil
    if bankView.shownPage == nil then
        if menuItem == nil then return nil end
        local entry = self:NativeEntry(menuItem)
        item = { objectID = entry ~= nil and entry.objectID or menuItem.id }
    else
        local slot = self:PageMenuSlot(menuItem)
        if slot == nil then return nil end
        item = { objectID = slot.objectID }
        if pluginPages:ShownPage(owner) ~= nil and not owner.redrawPending then item.slot = slot.position end
    end
    -- Share whether bank actions are available, keeping controls private.
    item.interactive = menuItem ~= nil and self:HasNativeInput(menuItem)
    return item
end

local function hasPluginDefaultAction(menu)
    local top = menu.entries[menu.entryCount]
    return top ~= nil and top.actionEntryType == MiniMenuEntryType.PLUGIN
end

-- Block bank actions on stacks hidden or covered by the sidebar.
function MiniMenuRouter:HasNativeInput(menuItem)
    local bankView = self.session.layout
    if not self.session.inGame or not self.options.bankIsOpen()
        or bankView:IsPresetViewOpen() then return false end
    if bankView:MountAtPointer() ~= nil
        or bankView.itemHover:IsBankStackMovedAside(menuItem.id, menuItem.categoryID,
            menuItem.dynamicID) then return false end
    if bankView.shownPage ~= nil then
        -- The hovered stack's placeholder field tells us whether it is empty.
        return self:PageMenuSlot(menuItem) ~= nil and bankView.itemHover.hoveredBankStack.placeholder ~= true
    end
    local entry = self:NativeEntry(menuItem)
    return entry ~= nil and (entry.quantity or 0) > 0
end

-- Default to Cancel so clicks cannot act on hidden bank items.
function MiniMenuRouter:ProtectDefault(menu)
    local bankView = self.session.layout
    if bankView == nil or not bankView.active then return end
    local menuItem = self.options.bankItemFromMenu(menu)
    local columnMount = menuItem == nil and bankView:MountAtPointer() or nil
    local blockNativeAction = false
    if menuItem ~= nil then
        blockNativeAction = bankView.itemHover:IsBankStackMovedAside(menuItem.id, menuItem.categoryID,
            menuItem.dynamicID)
    elseif columnMount ~= nil then
        blockNativeAction = not hasPluginDefaultAction(menu)
    elseif bankView.shownPage ~= nil then
        blockNativeAction = self:PageSlotAtPointer() ~= nil
            and not (bankView.customView ~= nil and hasPluginDefaultAction(menu))
    end
    if blockNativeAction and not MenuEntries.PromoteCancel(menu) then
        debugLog("BankUtils could not promote Cancel for ", tostring(menuItem and menuItem.id or "a menu"))
    end
end

function MiniMenuRouter:HandleMenu(event)
    if not self.session.inGame then return end
    if not self.options.bankIsOpen() then return end
    self:ProtectDefault(event.miniMenu)
end

return MiniMenuRouter
