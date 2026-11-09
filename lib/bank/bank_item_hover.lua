-- Move real bank items under page images to handle clicks.

local Config = require("lib/core/config")
local BankInterface = require("lib/core/bank_interface")
local BankGrid = require("lib/engine/bank_grid")
local BankItemIndex = require("lib/bank/bank_item_index")
local debugLog = require("lib/core/debug_log").Write
local UICoordinates = require("lib/ui/ui_coordinates")
local absolutePosition = UICoordinates.absolutePosition
local interfaceMousePosition = UICoordinates.interfaceMousePosition

local BankItemHover = {}
BankItemHover.__index = BankItemHover

local BANK_ITEMS_STATIC_ID = BankInterface.ITEMS
local GRID_SLOT_SIZE = BankGrid.SLOT_SIZE
local OFFSCREEN_POSITION = -10000
-- Prevent clicks from accidentally rearranging the bank.
local HOVERED_STACK_DRAG_DEAD_ZONE = 255
local HOVERED_STACK_DRAG_DELAY_TICKS = 255
local MISSING_STACK_RETRY_EVENT = Config.CORE_REF .. "_missing_stack_retry"
local BANK_REBUILD_REFRESH_EVENT = Config.CORE_REF .. "_post_rebuild_rebind"
local STALE_READ_EVENT = Config.CORE_REF .. "_stale_page_read"
local DROP_REFRESH_EVENT = Config.CORE_REF .. "_page_drop_refresh"
local DROP_HOOK = Config.CORE_REF .. "_page_item_drop"

local component = BankInterface.Get

function BankItemHover.new(bankView)
    return setmetatable({
        bankView = bankView,
        hoveredBankStack = nil,
        pageInputBlocker = nil,
        itemInputTargets = {},
        -- Only raise visible buttons each tick.
        visibleItemInputTargets = {},
        clickablePageItems = {},
        -- Include placeholders when finding right-clicked items.
        drawnPageItems = {},
        inputBounds = nil,
        lastPointerX = nil,
        lastPointerY = nil,
        -- New bank items may arrive a tick late; retry once.
        hoverRetryPending = false,
        inputVersion = 0,
        postRebuildRefreshRequested = false,
        -- Save each bank slot's position, size, and input settings for restoration.
        bankStacks = {},
        -- Check only stacks Core has moved.
        movedStackKeys = {},
    }, BankItemHover)
end

-- Let clicks reach the topmost overlapping item.
function BankItemHover:UncoverItemTarget(inputTarget, enabled)
    for _, inputTargetRecord in ipairs(self.visibleItemInputTargets) do
        local root = inputTargetRecord.root
        if root == inputTarget then return end
        if root.x < inputTarget.x + inputTarget.width and inputTarget.x < root.x + root.width
            and root.y < inputTarget.y + inputTarget.height and inputTarget.y < root.y + root.height then
            root.clickthrough = enabled
        end
    end
end

-- Let clicks pass through Core's blocker and item button
function BankItemHover:LetClicksReachBankStack(enabled, inputTarget)
    enabled = enabled == true
    if self.pageInputBlocker ~= nil then
        self.pageInputBlocker.clickthrough = enabled
    end
    inputTarget = inputTarget or (self.hoveredBankStack ~= nil and self.hoveredBankStack.hit or nil)
    if inputTarget ~= nil and inputTarget ~= self.pageInputBlocker then
        inputTarget.clickthrough = enabled
        if self.bankView.customView ~= nil then self:UncoverItemTarget(inputTarget, enabled) end
    end
end

-- Measure the difference between native and page scroll positions
function BankItemHover:NativeScrollOffset()
    local pageArea = self.bankView.pageDisplay.pageArea
    if pageArea == nil or pageArea.nativeScrollY == nil then return 0 end
    return pageArea.nativeScrollY - pageArea.scrollY
end

-- Move the stack to the pointer again when the bank's scroll has changed
function BankItemHover:FollowNativeScroll()
    local hoveredStack = self.hoveredBankStack
    if hoveredStack == nil or hoveredStack.nativeOffset == self:NativeScrollOffset() then return end
    self:RestoreHoveredBankStack()
    self:UpdateHoveredItem(true)
end

-- Find the intended bank stack after components change
function BankItemHover:FindNativeItem(
    objectID,
    nativeSlotKey,
    bankOrderKey,
    previousComponentText
)
    local recordedStack = self.bankStacks[nativeSlotKey]
    if recordedStack ~= nil and BankItemIndex.ObjectID(recordedStack.component) == objectID then
        return recordedStack.component, nativeSlotKey
    end
    local bankItemLayer = component(BANK_ITEMS_STATIC_ID)
    if bankItemLayer == nil then return nil end
    local firstMatchingStack = nil
    local firstMatchingSlotKey = nil
    local matchingPreviousComponent = nil
    local matchingPreviousSlotKey = nil
    local matchingSlot = nil
    local matchingSlotKey = nil
    local matchCount = 0
    local stackCounts = {}
    local matchingOccurrence = nil
    local matchingOccurrenceKey = nil
    bankItemLayer:IterateDynamicComponents(function(nativeItem)
        local candidateObjectID = BankItemIndex.ObjectID(nativeItem)
        if candidateObjectID == objectID then
            local stackNumber = (stackCounts[objectID] or 0) + 1
            stackCounts[objectID] = stackNumber
            local candidateInstanceKey = BankItemIndex.ComponentKey(nativeItem)
            local candidateBankOrderKey = BankItemIndex.LayoutKey(
                objectID,
                stackNumber
            )
            matchCount = matchCount + 1
            if firstMatchingStack == nil then
                firstMatchingStack = nativeItem
                firstMatchingSlotKey = candidateInstanceKey
            end
            if candidateInstanceKey == nativeSlotKey then
                matchingSlot = nativeItem
                matchingSlotKey = candidateInstanceKey
                return true
            end
            if candidateBankOrderKey == bankOrderKey then
                matchingOccurrence = nativeItem
                matchingOccurrenceKey = candidateInstanceKey
            end
            if previousComponentText ~= nil and tostring(nativeItem) == previousComponentText then
                matchingPreviousComponent = nativeItem
                matchingPreviousSlotKey = candidateInstanceKey
            end
        end
        return false
    end)
    if matchingSlot ~= nil then return matchingSlot, matchingSlotKey end
    if matchingOccurrence ~= nil then return matchingOccurrence, matchingOccurrenceKey end
    if matchingPreviousComponent ~= nil then return matchingPreviousComponent, matchingPreviousSlotKey end
    if matchCount == 1 then return firstMatchingStack, firstMatchingSlotKey end
    return nil, nil
end

-- Restore each changed drag setting independently
local function restoreNativeDrag(savedInput)
    if savedInput.dragDeadZoneBlocked then
        local restored = pcall(function()
            savedInput.component.dragConfig.deadZone = savedInput.dragSettings.deadZone
        end)
        savedInput.dragDeadZoneBlocked = not restored
    end
    if savedInput.dragDelayTicksBlocked then
        local restored = pcall(function()
            savedInput.component.dragConfig.dragDelayTicks = savedInput.dragSettings.delayTicks
        end)
        savedInput.dragDelayTicksBlocked = not restored
    end
end

-- Restore the stack's input settings and remove Core's hooks
local function restoreNativeInput(bankStack)
    local savedInput = bankStack.input
    if savedInput == nil then return end
    bankStack.input = nil
    pcall(function() savedInput.component.clickthrough = savedInput.clickthrough end)
    if savedInput.unbindScroll ~= nil then pcall(savedInput.unbindScroll) end
    if savedInput.unbindDrop ~= nil then pcall(savedInput.unbindDrop) end
    restoreNativeDrag(savedInput)
end

-- Save input settings before changing them; restore old handles first.
local function saveNativeInput(bankStack)
    local nativeItem, savedInput = bankStack.component, bankStack.input
    if savedInput ~= nil and savedInput.component == nativeItem then return savedInput end
    restoreNativeInput(bankStack)
    -- The component may disappear while reading drag settings.
    local dragSettingsOK, dragSettings = pcall(function()
        local dragConfig = nativeItem.dragConfig
        return { deadZone = dragConfig.deadZone, delayTicks = dragConfig.dragDelayTicks }
    end)
    savedInput = {
        component = nativeItem,
        clickthrough = nativeItem.clickthrough == true,
        dragSettings = dragSettingsOK and dragSettings or nil,
        dragDeadZoneBlocked = false,
        dragDelayTicksBlocked = false,
    }
    bankStack.input = savedInput
    return savedInput
end

-- Save the original setting before changing click-through.
local function setStackClickthrough(bankStack, value)
    if bankStack.component.clickthrough == value then return end
    saveNativeInput(bankStack)
    pcall(function() bankStack.component.clickthrough = value end)
end

-- Raise the hovered stack's available drag thresholds
function BankItemHover:BlockNativeDrag(bankStack)
    local savedInput = saveNativeInput(bankStack)
    local nativeItem = savedInput.component
    if savedInput.dragSettings ~= nil then
        savedInput.dragDeadZoneBlocked = pcall(function()
            nativeItem.dragConfig.deadZone = HOVERED_STACK_DRAG_DEAD_ZONE
        end)
        savedInput.dragDelayTicksBlocked = pcall(function()
            nativeItem.dragConfig.dragDelayTicks = HOVERED_STACK_DRAG_DELAY_TICKS
        end)
    end
    if not savedInput.dragDeadZoneBlocked and not savedInput.dragDelayTicksBlocked then
        debugLog("BankUtils could not suppress native drag for object ",
            tostring(bankStack.objectID))
    end
    return savedInput.dragDeadZoneBlocked or savedInput.dragDelayTicksBlocked
end

-- The hovered item takes the pointer, so it must scroll the page too
function BankItemHover:BindNativeScroll(bankStack)
    local pageDisplay, savedInput = self.bankView.pageDisplay, bankStack.input
    if savedInput.unbindScroll ~= nil then return end
    local nativeItem = savedInput.component
    pageDisplay:BindScrollWheel(nativeItem)
    savedInput.unbindScroll = function() pageDisplay:UnbindScrollWheel(nativeItem) end
end

-- Refresh after a drop; ignore hooks on old or restored stacks.
function BankItemHover:BindNativeDrop(bankStack)
    local savedInput = bankStack.input
    if savedInput.unbindDrop ~= nil then return end
    local nativeItem = savedInput.component
    nativeItem:Subscribe(ui.Hook.ONDRAGCOMPLETE, DROP_HOOK, function()
        local hoveredStack = self.hoveredBankStack
        if bankStack.input ~= savedInput or hoveredStack == nil
            or hoveredStack.item ~= nativeItem or self.bankView.shownPage == nil then return true end
        -- Block clicks until the game finishes the drop.
        self.dropRefreshPending = true
        hoveredStack.suspended = true
        self:BlockPageInput()
        local inputVersionAtStart = self.inputVersion
        Event.Logic.Subscribe(DROP_REFRESH_EVENT, function()
            Event.Logic.Unsubscribe(DROP_REFRESH_EVENT)
            self.dropRefreshPending = false
            if inputVersionAtStart == self.inputVersion and self.bankView.active
                and self.bankView.shownPage ~= nil then self.bankView:RefreshShownPage(true) end
        end)
        return true
    end)
    savedInput.unbindDrop = function() nativeItem:Unsubscribe(ui.Hook.ONDRAGCOMPLETE, DROP_HOOK) end
end

-- Restore input settings and remove Core's hooks.
function BankItemHover:RestoreNativeInput()
    for _, bankStack in pairs(self.bankStacks) do restoreNativeInput(bankStack) end
end

-- Move only when needed, except after a rebuild.
local function setPositionIfChanged(nativeItem, x, y, forceRefresh)
    if nativeItem == nil then return false end
    if not forceRefresh
        and nativeItem.x == x
        and nativeItem.y == y then
        return false
    end
    return (pcall(function() nativeItem:SetPos(x, y) end))
end

-- Save the bank's size and anchors before resizing a stack.
local function fitStackSize(bankStack, width, height)
    local nativeItem = bankStack.component
    if bankStack.originalSize == nil then
        local read, size = pcall(function()
            local size = nativeItem.size
            return { width = size.width, height = size.height,
                widthParentPc = size.widthParentPc, heightParentPc = size.heightParentPc }
        end)
        if not read then return false end
        bankStack.originalSize = size
    end
    bankStack.targetWidth, bankStack.targetHeight = width, height
    return (pcall(function()
        if nativeItem.width ~= width or nativeItem.height ~= height then nativeItem:SetSize(width, height, 0, 0) end
    end))
end

-- Restore the bank's size and anchors.
local function restoreStackSize(bankStack)
    local size = bankStack ~= nil and bankStack.originalSize or nil
    if size == nil then return end
    bankStack.originalSize = nil
    pcall(function()
        bankStack.component:SetSize(size.width, size.height, size.widthParentPc, size.heightParentPc)
    end)
end

local function setClickthroughIfChanged(nativeItem, value)
    if nativeItem == nil or nativeItem.clickthrough == value then return end
    pcall(function() nativeItem.clickthrough = value end)
end

-- Distinguish a real stack from a placeholder or an unpublished quantity
local function itemQuantityState(nativeItem)
    local quantity = nativeItem ~= nil and nativeItem.associatedObjectQuantity or nil
    if quantity == nil then return "unknown" end
    if quantity <= 0 then return "placeholder" end
    return "stack"
end

-- Restore moved stacks before forgetting them.
function BankItemHover:RestoreBankItemPositions()
    for _, bankStack in pairs(self.bankStacks) do
        restoreStackSize(bankStack)
        if bankStack.moved and BankItemIndex.ObjectID(bankStack.component) == bankStack.objectID then
            setPositionIfChanged(bankStack.component, bankStack.originalX, bankStack.originalY, true)
        end
        restoreNativeInput(bankStack)
    end
    self.bankStacks = {}
    self.movedStackKeys = {}
end

-- Clean up a stack that no longer occupies its slot.
function BankItemHover:ForgetBankStack(stackKey)
    local bankStack = self.bankStacks[stackKey]
    if bankStack == nil then return end
    restoreStackSize(bankStack)
    restoreNativeInput(bankStack)
    self.bankStacks[stackKey] = nil
    self.movedStackKeys[stackKey] = nil
end

-- Save bank positions; moved stacks keep their original position.
function BankItemHover:RecordBankItemPositions(bankItems)
    if self.bankView.shownPage == nil then return end
    if bankItems == nil then
        local bankItemLayer = component(BANK_ITEMS_STATIC_ID)
        if bankItemLayer == nil then return end
        bankItems = BankItemIndex.Read(bankItemLayer)
    end
    local present = {}
    for _, bankItem in ipairs(bankItems) do
        local stackKey = bankItem.instanceKey
        present[stackKey] = true
        local bankStack = self.bankStacks[stackKey]
        if bankStack ~= nil and bankStack.objectID == bankItem.objectID then
            bankStack.component = bankItem.component
            if not bankStack.moved then bankStack.originalX, bankStack.originalY = bankItem.x, bankItem.y end
        else
            -- A different item starts a fresh record.
            self:ForgetBankStack(stackKey)
            self.bankStacks[stackKey] = { component = bankItem.component, objectID = bankItem.objectID,
                originalX = bankItem.x, originalY = bankItem.y, moved = false }
        end
    end
    for stackKey in pairs(self.bankStacks) do
        if not present[stackKey] then self:ForgetBankStack(stackKey) end
    end
end

function BankItemHover:BankStack(stackKey, nativeItem)
    local bankStack = self.bankStacks[stackKey]
    local objectID = BankItemIndex.ObjectID(nativeItem)
    if bankStack == nil or bankStack.objectID ~= objectID then
        self:ForgetBankStack(stackKey)
        bankStack = { objectID = objectID, originalX = nativeItem.x, originalY = nativeItem.y, moved = false }
        self.bankStacks[stackKey] = bankStack
    end
    bankStack.component = nativeItem
    return bankStack
end

-- Reapply Core's layout; block clicks if a stack refuses its size.
function BankItemHover:MaintainNativeItemPositions()
    if self.bankView.shownPage == nil then return end
    local hoveredStackKey = self.hoveredBankStack ~= nil and self.hoveredBankStack.nativeKey or nil
    local unfit = false
    for stackKey in pairs(self.movedStackKeys) do
        local bankStack = self.bankStacks[stackKey]
        if BankItemIndex.ObjectID(bankStack.component) == bankStack.objectID then
            setStackClickthrough(bankStack, stackKey ~= hoveredStackKey)
            if bankStack.originalSize ~= nil
                and not fitStackSize(bankStack, bankStack.targetWidth, bankStack.targetHeight) then
                unfit = true
            end
            setPositionIfChanged(bankStack.component, bankStack.targetX, bankStack.targetY)
        else
            self.movedStackKeys[stackKey] = nil
        end
    end
    if unfit then
        self:BlockPageInput()
        self:RestoreHoveredBankStack()
    end
end

-- Follow quantity changes without losing native placeholder input
function BankItemHover:CheckHoveredBankStack()
    local hoveredStack = self.hoveredBankStack
    if hoveredStack == nil or self.bankView.shownPage == nil then return false end
    local bankStack = self.bankStacks[hoveredStack.nativeKey]
    local nativeItem = bankStack ~= nil and bankStack.component or hoveredStack.item
    if nativeItem ~= nil and BankItemIndex.ObjectID(nativeItem) ~= hoveredStack.objectID then
        nativeItem = nil
    end
    local state = itemQuantityState(nativeItem)
    if state == "stack" or state == "placeholder" then
        local placeholder = state == "placeholder"
        if hoveredStack.placeholder ~= placeholder then
            hoveredStack.placeholder = placeholder
            self.bankView.pageDisplay:UpdatePlaceholder(nativeItem, hoveredStack.entry.bankItem.instanceKey)
        end
        return false
    end

    self:BlockPageInput()
    if hoveredStack.hit ~= nil then hoveredStack.hit.clickthrough = false end
    self:RestoreHoveredBankStack()
    return true
end

-- Check for bank stacks overlapping the hovered item.
local function overlapsTarget(bankStack, hoveredStack)
    local nativeItem = bankStack.component
    local width, height = nativeItem.width, nativeItem.height
    local targetX, targetY = hoveredStack.targetX, hoveredStack.targetY
    return bankStack.originalX + width > targetX
        and bankStack.originalX < targetX + (hoveredStack.targetWidth or GRID_SLOT_SIZE)
        and bankStack.originalY + height > targetY
        and bankStack.originalY < targetY + (hoveredStack.targetHeight or GRID_SLOT_SIZE)
end

-- Move overlapping stacks aside so clicks reach the right item.
function BankItemHover:MoveOverlappingBankStacksAside(hoveredStackKey, hoveredStack, forceRefresh)
    for stackKey, bankStack in pairs(self.bankStacks) do
        if stackKey ~= hoveredStackKey and overlapsTarget(bankStack, hoveredStack) then
            setStackClickthrough(bankStack, true)
            if setPositionIfChanged(
                bankStack.component,
                OFFSCREEN_POSITION,
                OFFSCREEN_POSITION,
                forceRefresh
            ) then
                bankStack.moved = true
            end
            bankStack.targetX, bankStack.targetY, bankStack.movedAside = OFFSCREEN_POSITION, OFFSCREEN_POSITION, true
            self.movedStackKeys[stackKey] = true
        end
    end
end

-- Restore stacks and input settings; keep hooks until their records are removed.
function BankItemHover:RestoreMovedBankStacks(hoveredStackKey, retainHostPositions)
    for stackKey in pairs(self.movedStackKeys) do
        local bankStack = self.bankStacks[stackKey]
        if stackKey == hoveredStackKey or bankStack.movedAside then
            local nativeItem = bankStack.component
            if not retainHostPositions then restoreStackSize(bankStack) end
            if not retainHostPositions
                and BankItemIndex.ObjectID(nativeItem) == bankStack.objectID then
                setPositionIfChanged(nativeItem, bankStack.originalX, bankStack.originalY)
            end
            local savedInput = bankStack.input
            if savedInput ~= nil then
                setClickthroughIfChanged(savedInput.component, savedInput.clickthrough)
                restoreNativeDrag(savedInput)
            end
            bankStack.moved, bankStack.movedAside = false, false
            self.movedStackKeys[stackKey] = nil
        end
    end
end

function BankItemHover:CancelMissingStackRetry()
    Event.Logic.Unsubscribe(MISSING_STACK_RETRY_EVENT)
end

function BankItemHover:CancelBankRebuildRefresh()
    Event.Logic.Unsubscribe(BANK_REBUILD_REFRESH_EVENT)
    self.postRebuildRefreshRequested = false
end

-- Wait a tick for new bank items after a rebuild.
function BankItemHover:RefreshAfterBankRebuild(refreshShownPage)
    self:CancelBankRebuildRefresh()
    -- The drop already queued a refresh.
    if self.dropRefreshPending then return end
    self.postRebuildRefreshRequested = refreshShownPage == true
    local inputVersionAtStart = self.inputVersion
    Event.Logic.Subscribe(BANK_REBUILD_REFRESH_EVENT, function()
        local shouldRefreshPage = self.postRebuildRefreshRequested
        self:CancelBankRebuildRefresh()
        if self.inputVersion ~= inputVersionAtStart
            or not self.bankView.active
            or self.bankView.shownPage == nil
            or (self.pageInputBlocker == nil and not shouldRefreshPage) then return
        end

        if shouldRefreshPage then
            self.bankView:RefreshShownPage()
            return
        end
        -- Reuse this bank read for both checks.
        local bankItemLayer = component(BANK_ITEMS_STATIC_ID)
        local bankItems = bankItemLayer ~= nil and BankItemIndex.Read(bankItemLayer) or nil
        self:RecordBankItemPositions(bankItems)
        if self.bankView.pageDisplay.scrollInteractionTicks > 0 then
            self:PauseHoverForScroll()
            self:RaisePageInput()
            return
        end
        local hadHoveredStack = self.hoveredBankStack ~= nil
        -- Rebuild if a slot now points to another stack.
        if hadHoveredStack and self.bankView.pageState:StacksReassigned(bankItems) then
            self.bankView:RefreshShownPage()
            return
        end
        local refreshed = false
        if hadHoveredStack then
            refreshed = self:RefreshHoveredBankStack(false)
        end
        if not refreshed then
            self:UpdateHoveredItem(true)
            if hadHoveredStack and self.hoveredBankStack == nil then
                self.bankView:RefreshShownPage()
                return
            end
        end
        if self.hoveredBankStack ~= nil then
            self:MaintainNativeItemPositions()
        end
        self:RaisePageInput()
    end)
end

-- Retry missing items once before rebuilding.
function BankItemHover:RetryMissingStack()
    self:CancelMissingStackRetry()
    Event.Logic.Subscribe(MISSING_STACK_RETRY_EVENT, function()
        self:CancelMissingStackRetry()
        if not self.bankView.active or self.bankView.shownPage == nil then
            self:RestoreHoveredBankStack()
            return
        end
        if not self:RefreshHoveredBankStack(false) then
            self.bankView:RefreshShownPage()
        end
    end)
end

-- Restore bank positions before sorting matching stacks.
function BankItemHover:BeginStaleRead()
    Event.Logic.Subscribe(STALE_READ_EVENT, function()
        Event.Logic.Unsubscribe(STALE_READ_EVENT)
        local bankView = self.bankView
        if bankView.active and bankView.shownPage ~= nil and bankView.pageState.stale
            and self.hoveredBankStack == nil then
            bankView:RefreshShownPage()
        end
    end)
end

-- Block clicks and restore stacks when hover ends.
function BankItemHover:RestoreHoveredBankStack()
    self:CancelMissingStackRetry()
    local hoveredStack = self.hoveredBankStack
    if hoveredStack == nil then
        if self.bankView.shownPage == nil then self:RestoreNativeInput() end
        return
    end
    self:LetClicksReachBankStack(false, hoveredStack.hit)
    self.hoveredBankStack = nil
    if self.bankView.shownPage ~= nil then
        self:RestoreMovedBankStacks(hoveredStack.nativeKey)
        if self.bankView.pageState.stale then self:BeginStaleRead() end
    else
        local bankStack = self.bankStacks[hoveredStack.nativeKey]
        if bankStack ~= nil then
            restoreStackSize(bankStack)
            setPositionIfChanged(bankStack.component, bankStack.originalX, bankStack.originalY)
        end
        self:RestoreNativeInput()
    end
end

-- Release the hovered stack when its binding changes.
function BankItemHover:ReleaseBinding(binding)
    local hoveredStack = self.hoveredBankStack
    if hoveredStack == nil or hoveredStack.entry.binding ~= binding then return end
    self:BlockPageInput()
    self:RestoreHoveredBankStack()
end

-- Raise the blocker before restoring stacks.
function BankItemHover:BlockPageInput()
    self:LetClicksReachBankStack(false)
    if self.pageInputBlocker == nil then return false end
    self.pageInputBlocker:MoveToFront()
    return true
end

-- Stop item input but keep the blocker.
function BankItemHover:PausePageInput()
    self:CancelBankRebuildRefresh()
    self:BlockPageInput()
    self:RestoreHoveredBankStack()
    self.lastPointerX = nil
    self.lastPointerY = nil
    self.hoverRetryPending = false
end

-- Cancel pending work and remove page input.
function BankItemHover:RemovePageInput()
    Event.Logic.Unsubscribe(DROP_REFRESH_EVENT)
    self.dropRefreshPending = false
    self:CancelBankRebuildRefresh()
    Event.Logic.Unsubscribe(STALE_READ_EVENT)
    self:BlockPageInput()
    self.inputVersion = self.inputVersion + 1
    self:RestoreHoveredBankStack()
    for _, inputTargetRecord in ipairs(self.itemInputTargets) do
        pcall(function()
            inputTargetRecord.root.clickthrough = true
            inputTargetRecord.root.enabled = false
            inputTargetRecord.root:SetSize(0, 0)
        end)
        pcall(function() inputTargetRecord.root:Destroy() end)
    end
    self.itemInputTargets = {}
    self.visibleItemInputTargets = {}
    if self.pageInputBlocker ~= nil then
        pcall(function()
            self.pageInputBlocker.clickthrough = true
            self.pageInputBlocker.enabled = false
            self.pageInputBlocker:SetSize(0, 0)
        end)
        pcall(function() self.pageInputBlocker:Destroy() end)
    end
    self.pageInputBlocker = nil
    self.clickablePageItems = {}
    self.drawnPageItems = {}
    self.inputBounds = nil
    self.lastPointerX = nil
    self.lastPointerY = nil
    self.hoverRetryPending = false
end

-- Only the visible part of an item receives clicks.
function BankItemHover:PositionItemInputTargets(pageArea)
    pageArea = pageArea or self.inputBounds or self.bankView.pageDisplay.pageArea
    if pageArea == nil then return false end
    local viewportLeft = pageArea.x
    local viewportTop = pageArea.y
    local viewportRight = viewportLeft + pageArea.width
    local viewportBottom = viewportTop + pageArea.height
    local activeInputTarget = self.hoveredBankStack ~= nil
        and self.hoveredBankStack.hit or nil
    local visibleTargets = {}

    for _, inputTargetRecord in ipairs(self.itemInputTargets) do
        local area = inputTargetRecord.entry ~= nil and inputTargetRecord.entry.area or nil
        if area == nil then
            inputTargetRecord.root:SetSize(0, 0)
            inputTargetRecord.root.enabled = false
            inputTargetRecord.root.clickthrough = true
        else
            local entryLeft = pageArea.x + pageArea.contentX + area.x
            local entryTop = pageArea.y + pageArea.contentY + area.y - pageArea.scrollY
            local left = math.max(viewportLeft, entryLeft)
            local top = math.max(viewportTop, entryTop)
            local right = math.min(viewportRight, entryLeft + area.width)
            local bottom = math.min(viewportBottom, entryTop + area.height)
            local width = math.max(0, right - left)
            local height = math.max(0, bottom - top)
            inputTargetRecord.root:SetPos(left, top)
            inputTargetRecord.root:SetSize(width, height)
            local visible = width > 0 and height > 0
            inputTargetRecord.root.enabled = visible
            inputTargetRecord.root.clickthrough = inputTargetRecord.root == activeInputTarget or not visible
            if visible then visibleTargets[#visibleTargets + 1] = inputTargetRecord end
        end
    end
    self.visibleItemInputTargets = visibleTargets
    if activeInputTarget ~= nil and self.bankView.customView ~= nil then
        self:UncoverItemTarget(activeInputTarget, true)
    end
    return true
end

-- Reuse item input targets
function BankItemHover:UpdateItemInputTargets(pageArea)
    for index, pageItem in ipairs(self.clickablePageItems) do
        local inputTargetRecord = self.itemInputTargets[index]
        if inputTargetRecord == nil then
            -- Record it first so cleanup can remove a failed build.
            local root = ui.Button.new(self.bankView.components.all)
            inputTargetRecord = { root = root, entry = nil }
            self.itemInputTargets[index] = inputTargetRecord
            UICoordinates.trackPointer(root)
            root.alpha = 0
            root.text.content = ""
            root.clickthrough = false
            self.bankView.pageDisplay:BindScrollWheel(root)
            local inputVersionAtStart = self.inputVersion
            root:Subscribe(ui.Hook.ONMOUSEOVER, function(component, x, y)
                UICoordinates.calibratePointer(component, x, y)
                local currentPageItem = inputTargetRecord.entry
                if self.inputVersion ~= inputVersionAtStart
                    or self.bankView.shownPage == nil
                    or inputTargetRecord.root ~= root
                    or currentPageItem == nil then return false
                end
                local stackWasMoved = self:MoveBankStackToSlot(root, currentPageItem)
                if not stackWasMoved then
                    root.clickthrough = false
                    self:LetClicksReachBankStack(false)
                end
                return true
            end)
        end
        inputTargetRecord.entry = pageItem
        pageItem.hitTarget = inputTargetRecord.root
    end
    for index = #self.clickablePageItems + 1, #self.itemInputTargets do
        self.itemInputTargets[index].entry = nil
    end
    self:PositionItemInputTargets(pageArea)
end

-- Block clicks while finding and positioning the real stack
function BankItemHover:RefreshHoveredBankStack(
    allowRecovery,
    resolvedItem,
    resolvedNativeKey
)
    local hoveredStack = self.hoveredBankStack
    if hoveredStack == nil or self.bankView.shownPage == nil then return false end
    if self.dropRefreshPending then self:BlockPageInput() return false end
    -- Rebuilt bank items may cover our buttons; raise the blocker first.
    self:BlockPageInput()
    if hoveredStack.hit ~= nil then hoveredStack.hit.clickthrough = false end

    local nativeItem = resolvedItem
    local nativeKey = resolvedNativeKey
    local bankItem = hoveredStack.entry.bankItem
    if nativeItem == nil then
        nativeItem, nativeKey = self:FindNativeItem(
            hoveredStack.objectID,
            hoveredStack.nativeKey,
            bankItem.layoutKey,
            tostring(hoveredStack.item)
        )
    end
    if nativeItem == nil then
        hoveredStack.suspended = true
        setClickthroughIfChanged(hoveredStack.item, true)
        if allowRecovery ~= false then
            self:RetryMissingStack()
            return true
        end
        self:RestoreHoveredBankStack()
        return false
    end
    self:CancelMissingStackRetry()
    local quantityState = itemQuantityState(nativeItem)
    -- Restore the old slot's size when the stack changes slots.
    if nativeKey ~= hoveredStack.nativeKey then restoreStackSize(self.bankStacks[hoveredStack.nativeKey]) end
    -- Empty bank slots can still be dragged.
    self:RestoreMovedBankStacks(hoveredStack.nativeKey, quantityState ~= "unknown")
    local bankStack = self:BankStack(nativeKey, nativeItem)
    hoveredStack.suspended = false
    hoveredStack.item = nativeItem
    hoveredStack.placeholder = quantityState == "placeholder"
    hoveredStack.nativeKey = nativeKey
    if quantityState == "unknown" then
        -- Keep native input blocked until the stack's quantity can be read
        self:RestoreHoveredBankStack()
        return false
    end
    -- Use the bank's current stack and quantity.
    bankItem.component, bankItem.quantity = nativeItem, nativeItem.associatedObjectQuantity
    self.bankView.pageDisplay:UpdatePlaceholder(nativeItem, bankItem.instanceKey)

    -- Some pages allow dragging items into bank tabs.
    if self.bankView.shownPage.allowNativeDrag == true then
        restoreNativeDrag(saveNativeInput(bankStack))
    else
        self:BlockNativeDrag(bankStack)
    end
    self:BindNativeScroll(bankStack)
    self:BindNativeDrop(bankStack)
    bankStack.targetX, bankStack.targetY = hoveredStack.targetX, hoveredStack.targetY
    self.movedStackKeys[nativeKey] = true

    -- Rebuilt stacks may be back in place; move overlaps aside again.
    self:MoveOverlappingBankStacksAside(nativeKey, hoveredStack, true)
    -- Match the shown item's size before allowing clicks.
    if hoveredStack.targetWidth ~= nil
        and not fitStackSize(bankStack, hoveredStack.targetWidth, hoveredStack.targetHeight) then
        self:RestoreHoveredBankStack()
        return false
    end
    setPositionIfChanged(nativeItem, hoveredStack.targetX, hoveredStack.targetY, true)
    bankStack.moved = true
    setStackClickthrough(bankStack, false)
    self:RaisePageInput()
    self:LetClicksReachBankStack(true, hoveredStack.hit)
    return true
end

function BankItemHover:HasHoveredBankStack()
    return self.hoveredBankStack ~= nil
end

-- Block menu actions on stacks moved aside.
function BankItemHover:IsBankStackMovedAside(
    objectID,
    categoryID,
    dynamicID
)
    if objectID == nil or categoryID == nil or dynamicID == nil then return false end
    -- Menu slot IDs match the saved stack keys.
    local stackKey = BankItemIndex.ComponentKey({ categoryID = categoryID, dynamicID = dynamicID })
    local bankStack = self.movedStackKeys[stackKey] and self.bankStacks[stackKey] or nil
    return bankStack ~= nil and bankStack.movedAside
        and (bankStack.objectID == objectID or BankItemIndex.ObjectID(bankStack.component) == objectID)
end

-- Find the stack's visible bank position and custom size, if any.
function BankItemHover:StackTarget(pageItem)
    local nativeScrollDifference = self:NativeScrollOffset()
    local area = pageItem.area
    if area == nil or pageItem.bankItem == nil then return nil end
    if pageItem.binding == nil then return pageItem.x, pageItem.y + nativeScrollDifference end
    local pageArea = self.inputBounds or self.bankView.pageDisplay.pageArea
    local viewLeft, viewTop = -pageArea.contentX, pageArea.scrollY - pageArea.contentY
    local left, top = math.max(area.x, viewLeft), math.max(area.y, viewTop)
    local right = math.min(area.x + area.width, viewLeft + pageArea.width)
    local bottom = math.min(area.y + area.height, viewTop + pageArea.height)
    if right <= left or bottom <= top then return nil end
    return left, top + nativeScrollDifference, right - left, bottom - top
end

-- Place the bank stack under its page image.
function BankItemHover:MoveBankStackToSlot(inputTarget, pageItem, forceRefresh)
    if self.dropRefreshPending then self:BlockPageInput() return false end
    if self.bankView.shownPage == nil then return true end
    local targetX, targetY, targetWidth, targetHeight = self:StackTarget(pageItem)
    if self.bankView.pageDisplay.scrollInteractionTicks > 0 or targetX == nil then
        self:BlockPageInput()
        self:RestoreHoveredBankStack()
        self:LetClicksReachBankStack(false, inputTarget)
        return false
    end
    -- Account for the bank's scroll position.
    local nativeScrollDifference = self:NativeScrollOffset()
    local hoveredStack = self.hoveredBankStack
    if hoveredStack ~= nil
        and hoveredStack.entry == pageItem
        and hoveredStack.hit == inputTarget
        and hoveredStack.targetX == targetX and hoveredStack.targetY == targetY
        and hoveredStack.targetWidth == targetWidth and hoveredStack.targetHeight == targetHeight then
        -- Keep the stack in place unless the bank changed.
        local bankStack = self.bankStacks[hoveredStack.nativeKey]
        local nativeItem = bankStack ~= nil and bankStack.component or nil
        local quantityState = itemQuantityState(nativeItem)
        if not forceRefresh and not hoveredStack.suspended and not self.bankView.pageState.stale
            and nativeItem == hoveredStack.item and BankItemIndex.ObjectID(nativeItem) == pageItem.objectID
            and quantityState ~= "unknown"
            and hoveredStack.placeholder == (quantityState == "placeholder") then
            return true
        end
        return self:RefreshHoveredBankStack()
    end

    self:BlockPageInput()
    self:RestoreHoveredBankStack()
    local bankItem = pageItem.bankItem
    local nativeItem, nativeKey = self:FindNativeItem(
        pageItem.objectID,
        bankItem.instanceKey,
        bankItem.layoutKey,
        tostring(bankItem.component)
    )
    -- Retry next tick if the bank item is not ready.
    if nativeItem == nil then return false end
    self.hoveredBankStack = {
        -- The drawn item and the real stack receiving clicks.
        entry = pageItem,
        item = nativeItem,
        objectID = pageItem.objectID,
        nativeKey = nativeKey,
        targetX = targetX,
        targetY = targetY,
        -- Custom items resize their bank stack.
        targetWidth = targetWidth,
        targetHeight = targetHeight,
        nativeOffset = nativeScrollDifference,
        hit = inputTarget,
    }
    return self:RefreshHoveredBankStack(nil, nativeItem, nativeKey)
end

-- Reuse page input targets after a refresh.
function BankItemHover:BuildPageInput(entries)
    if self.bankView.shownPage == nil then
        self:RemovePageInput()
        return
    end
    self:CancelBankRebuildRefresh()
    self:BlockPageInput()
    self:RestoreHoveredBankStack()
    local pageArea = self.bankView.pageDisplay.pageArea or self.bankView.pageDisplay:ReadPageArea()
    if pageArea == nil then
        self:RemovePageInput()
        return
    end

    entries = entries or self.bankView:BuildPageItems()
    -- Custom items without a stack still block items beneath them.
    local interactivePageItems = {}
    for _, pageItem in ipairs(entries) do
        if pageItem.bankItem ~= nil or pageItem.binding ~= nil then
            interactivePageItems[#interactivePageItems + 1] = pageItem
        end
    end
    self.clickablePageItems = interactivePageItems
    self.drawnPageItems = entries
    self.inputBounds = pageArea
    self.hoverRetryPending = false

    if self.pageInputBlocker == nil then
        self.pageInputBlocker = ui.Button.new(self.bankView.components.all)
        UICoordinates.trackPointer(self.pageInputBlocker)
        self.pageInputBlocker.alpha = 0
        self.pageInputBlocker.text.content = ""
        self.bankView.pageDisplay:BindScrollWheel(self.pageInputBlocker)
    end
    self.pageInputBlocker:SetPos(pageArea.x, pageArea.y)
    self.pageInputBlocker:SetSize(pageArea.width, pageArea.height)
    self:LetClicksReachBankStack(false)
    self.pageInputBlocker:MoveToFront()
    self:UpdateItemInputTargets(pageArea)
    self:RaisePageInput()
    self:UpdateHoveredItem(true)
    self:RefreshAfterBankRebuild()
    self:RaisePageInput()
end

-- Resize the blocker and item targets when the viewport changes
function BankItemHover:ResizePageInput(pageArea)
    if self.pageInputBlocker == nil then return false end
    pageArea = pageArea or self.bankView.pageDisplay.pageArea or self.bankView.pageDisplay:ReadPageArea()
    if pageArea == nil then return false end
    self.inputBounds = pageArea
    self.pageInputBlocker:SetPos(pageArea.x, pageArea.y)
    self.pageInputBlocker:SetSize(pageArea.width, pageArea.height)
    self:PositionItemInputTargets(pageArea)
    return true
end

-- Release hover while scrolling until the pointer moves again
function BankItemHover:PauseHoverForScroll()
    local inputBlocker = self.pageInputBlocker
    if inputBlocker == nil then return false end
    self:RestoreHoveredBankStack()
    self:LetClicksReachBankStack(false)
    self.hoverRetryPending = false
    self.bankView.pageDisplay:HideItemName()
    local pointerX, pointerY = interfaceMousePosition()
    if pointerX == nil then return false end
    local originX, originY = absolutePosition(inputBlocker)
    self.lastPointerX = pointerX - originX
    self.lastPointerY = pointerY - originY
    return true
end

-- Move the stack under the pointer, retrying once if it is not ready
function BankItemHover:UpdateHoveredItem(forceRefresh)
    if self.dropRefreshPending then self:BlockPageInput() return false end
    local inputBlocker = self.pageInputBlocker
    if inputBlocker == nil or self.bankView.shownPage == nil then return false end
    local pageArea = self.inputBounds or self.bankView.pageDisplay.pageArea
        or self.bankView.pageDisplay:ReadPageArea()
    if pageArea == nil then return false end
    local pointerX, pointerY = interfaceMousePosition()
    if pointerX == nil then
        self.bankView.pageDisplay:HideItemName()
        return false
    end
    local originX, originY = absolutePosition(inputBlocker)
    local localX = pointerX - originX
    local localY = pointerY - originY
    local pointerMoved = self.lastPointerX ~= localX
        or self.lastPointerY ~= localY
    if not forceRefresh and not pointerMoved then
        if self.hoveredBankStack ~= nil then return true end
        if not self.hoverRetryPending then return false end
    end
    self.lastPointerX = localX
    self.lastPointerY = localY

    local pointerInsideViewport = localX >= 0 and localX < pageArea.width
        and localY >= 0 and localY < pageArea.height
    -- The topmost item gets the pointer, even without a bank stack.
    local pageDisplay = self.bankView.pageDisplay
    local pageItem = pointerInsideViewport and pageDisplay:EntryAtPosition(
        self.drawnPageItems,
        pageArea,
        localX,
        localY
    ) or nil
    if pageItem ~= nil and pageItem.bankItem ~= nil then
        pageDisplay:HideItemName()
        local stackWasMoved = self:MoveBankStackToSlot(
            pageItem.hitTarget or inputBlocker,
            pageItem,
            forceRefresh
        )
        if stackWasMoved and self.hoveredBankStack ~= nil then
            self.hoverRetryPending = false
            return true
        end
        -- Retry once next tick, rather than every frame.
        self.hoverRetryPending = forceRefresh or pointerMoved
        return false
    end
    self.hoverRetryPending = false
    self:RestoreHoveredBankStack()
    self:LetClicksReachBankStack(false)
    -- Show a name when the bank cannot provide a tooltip.
    pageDisplay:ShowItemName(pageItem, pageArea)
    return false
end

-- Move click areas with custom items and recheck the pointer.
function BankItemHover:FollowItemAreas()
    self:PositionItemInputTargets()
    self.lastPointerX, self.lastPointerY = nil, nil
end

-- Keep custom controls, tooltips, and popups above item input.
function BankItemHover:RaisePageInput()
    if self.pageInputBlocker == nil then return false end
    local pageDisplay = self.bankView.pageDisplay
    local custom = self.bankView.customView ~= nil
    self.pageInputBlocker:MoveToFront()
    if not custom then pageDisplay:RaiseItemName() end
    for _, inputTargetRecord in ipairs(self.visibleItemInputTargets) do
        inputTargetRecord.root:MoveToFront()
    end
    if custom then
        pageDisplay.layer:MoveToFront()
        pageDisplay:RaiseItemName()
        pageDisplay.viewOverlay:MoveToFront()
    end
    self.bankView:RaiseMountOverlays()
    return true
end

return BankItemHover
