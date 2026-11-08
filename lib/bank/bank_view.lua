-- Switch between the normal bank and pages supplied by plugins

local BankInterface = require("lib/core/bank_interface")
local debugLog = require("lib/core/debug_log").Write
local UICoordinates = require("lib/ui/ui_coordinates")
local BankPageItems = require("lib/bank/bank_page_items")
local BankItemHover = require("lib/bank/bank_item_hover")
local BankWindow = require("lib/bank/bank_window")
local BankWindowRecord = require("lib/bank/bank_window_record")
local SidebarHost = require("lib/bank/sidebar_host")
local BankGrid = require("lib/engine/bank_grid")
local BankPageDisplay = require("lib/engine/bank_page_display")
local CustomView = require("lib/features/extensions/custom_view")
local PageLayout = require("lib/features/extensions/page_layout")

local BankView = {}
BankView.__index = BankView
BankWindow.install(BankView)
SidebarHost.install(BankView)

-- Connect pages, drawing, hover, and the sidebar
function BankView.new(options)
    options = options or {}
    local self = setmetatable({
        pageState = BankPageItems.new(),
        active = false,
        expanded = false,
        -- Extra width and movement Core added to each bank component
        expansion = nil,
        windowRecord = options.windowRecord or BankWindowRecord.new(),
        components = {},
        -- The page the bank shows: an extension's checked page with its owner, or nil
        -- in the native view
        shownPage = nil,
        -- The context of the custom view drawn last, while the bank shows it
        customView = nil,
        sidebarMode = nil,
        -- Extension tab definitions the extension service builds, in the player's rail order
        extensionTabs = {},
        -- Read and save the rail order of extension IDs; the session supplies both
        readRailOrder = options.readRailOrder or function() return {} end,
        saveRailOrder = options.saveRailOrder or function() return false end,
        -- Identifies the current bank opening for item-change notifications
        windowSession = 0,
        -- The repeating check for bank window moves and resizes
        bankWindowWatch = nil,
        nativeViewAll = false,
        itemHover = nil,
        -- Told when the bank view changes; the extension service sets it
        onChange = function() end,
        -- Counts changes that may affect item identities or quantities
        itemsGeneration = 0,
        -- Page changes in progress; extension requests wait while nonzero
        pageTransitions = 0,
        recoveringPageChange = false,
    }, BankView)
    self.pageDisplay = BankPageDisplay.new(self)
    self.itemHover = BankItemHover.new(self)
    return self
end

-- Report a bank view change, noting whether items may have changed
function BankView:Changed(itemsChanged)
    if itemsChanged then self.itemsGeneration = self.itemsGeneration + 1 end
    self.onChange()
end

-- Keep the mounted column's overlay above the page and the sidebar
function BankView:RaiseMountOverlays()
    if self.tabMount ~= nil then self.tabMount:RaiseOverlay() end
end

-- Find the mounted column under the pointer, or nil
function BankView:MountAtPointer()
    local mount = self.tabMount
    if mount == nil or not mount:IsMounted() then return nil end
    local pointerX, pointerY = UICoordinates.interfaceMousePosition()
    if pointerX == nil then return nil end
    local left, top = UICoordinates.absolutePosition(mount.values.parent)
    local x, y = pointerX - left, pointerY - top
    if x >= 0 and y >= 0 and x < mount.bounds.width and y < mount.bounds.height then return mount end
    return nil
end

-- Build the displayed items at their page slots
-- A redraw builds them once and shares them with drawing and input
-- A custom view's items take the areas their components show now
function BankView:BuildPageItems()
    local entries = self.pageState:GetVisibleItems(self.pageDisplay:GridCellInset())
    if self.customView ~= nil then self.customView:Measure(entries) end
    return entries
end

-- End the custom view's context, so its plugin's later calls change nothing
local function revokeCustomView(self)
    local view = self.customView
    self.customView = nil
    if view ~= nil then view:Revoke() end
end

-- End the rendered page, then remove the sidebar
function BankView:DestroyRail()
    self.itemHover:RemovePageInput()
    self.itemHover:RestoreBankItemPositions()
    self.itemHover:CancelMissingStackRetry()
    revokeCustomView(self)
    self.pageDisplay:DestroyRuntimeSprites()
    self:DestroySidebar()
end

-- Move item input with the custom view's components, wherever any of them moves, shows or hides
function BankView:FollowCustomView()
    if self.customView:Follow() then self.itemHover:FollowItemAreas() end
end

-- Match the page arrangement to current bank stacks
-- Missing bank components or an invalid layout trigger recovery to the native view
local function layOutPage(self)
    if BankInterface.Get(BankInterface.ITEMS) == nil then
        error("the bank item layer is unavailable", 0)
    end
    local page = self.shownPage
    local applied, matchCount = self.pageState:ApplyLayout(function(columnCount)
        return PageLayout.Place(page, columnCount)
    end)
    if not applied then error("the extension page could not be laid out", 0) end
    return matchCount
end

-- Find a custom view's content height: at least its viewport, the height its plugin
-- returned, and its bound items' bottom, within the height limit for a page
local function viewHeight(view, requested, viewportHeight)
    return math.ceil(math.min(PageLayout.MAX_HEIGHT,
        math.max(viewportHeight, requested or 0, view:BoundBottom())))
end

-- Let the shown page's plugin draw its view in new layers, then attach its bound items
-- The plugin's components keep their own look; Core moves stacks beneath the bound ones
local function drawCustomView(self)
    local page, pageState, pageDisplay = self.shownPage, self.pageState, self.pageDisplay
    -- The plugin reads its bank items from this read while it draws
    local bankItemLayer = pageState:ReadBank()
    if bankItemLayer == nil then error("the bank item layer is unavailable", 0) end
    local parent, overlay = pageDisplay:CreatePageLayers(true)
    if parent == nil then error("the bank item area is unavailable", 0) end
    local pageArea = pageDisplay.pageArea
    local view = CustomView.new(parent, overlay, pageArea.width, pageArea.height, pageDisplay.scrollY, {
        geometry = function() return pageDisplay:ViewGeometry() end,
        release = function(binding) self.itemHover:ReleaseBinding(binding) end,
    })
    self.customView = view
    local drawn, height = page.draw(view.context)
    -- Disposing the extension while it drew empties its page, so nothing of the view stays
    if not drawn or page.draw == nil then error("the extension's view could not be drawn", 0) end
    local columns = BankGrid.ColumnCount(bankItemLayer.width)
    local matchCount = pageState:SetView(view:Place(viewHeight(view, height, pageArea.height)), columns)
    -- Core draws no items of its own here; the content takes its height before items are measured
    pageDisplay:ShowPageLayers({}, {})
    local pageItems = self:BuildPageItems()
    -- The view was just placed over this read, before any stack moved
    self.itemHover:RecordBankItemPositions(pageState.bankItems)
    self.itemHover:BuildPageInput(pageItems)
    return matchCount
end

-- Lay out and draw the shown page, then build item input from the same entries
-- Each drawing first ends the previous custom view's context
local function drawPage(self)
    revokeCustomView(self)
    if self.shownPage.draw ~= nil then return drawCustomView(self) end
    local matchCount = layOutPage(self)
    local pageItems = self:BuildPageItems()
    self.pageDisplay:CreateRuntimeSprites(pageItems)
    -- The page was just laid out over this read, before any stack moved
    self.itemHover:RecordBankItemPositions(self.pageState.bankItems)
    self.itemHover:BuildPageInput(pageItems)
    return matchCount
end

-- Lay the shown page out again over the bank's current items and width
-- The viewport blocker stays above the bank while the page redraws
local function rebuildPage(self)
    self.itemHover:PausePageInput()
    self.itemHover:RestoreBankItemPositions()
    return drawPage(self)
end

-- Switch views: release input and moved stacks, then draw the page and build its input
-- A new page from the same extension and opening is drawn again in place, keeping scroll
local function showPage(self, page)
    if page ~= nil and self:IsPresetViewOpen() then
        debugLog("Bank Core pages are unavailable while the preset selector is open")
        return false
    end
    if page ~= nil and not self.nativeViewAll then
        local detected = self:DetectNativeViewAll()
        if detected ~= nil then self.nativeViewAll = detected end
    end
    if page ~= nil and not self.nativeViewAll then
        debugLog("Bank Core pages require the native View All bank tab")
        return false
    end
    local current = self.shownPage
    local samePageOpening = page ~= nil and current ~= nil
        and page.owner == current.owner and page.key == current.key
    self.shownPage = page
    local matchCount = nil
    if samePageOpening then
        matchCount = rebuildPage(self)
    else
        self.itemHover:RemovePageInput()
        self.itemHover:RestoreBankItemPositions()
        if page == nil then
            revokeCustomView(self)
            self.pageState:Restore()
            self.pageDisplay:DestroyRuntimeSprites()
        else
            matchCount = drawPage(self)
        end
    end
    if page ~= nil then
        debugLog("Bank Core showed ", page.title, " for ", page.owner.id, "; matched ",
            matchCount, " bank item(s)")
    end
    self:UpdateLayoutControls()
    self:Changed(false)
    return true
end

-- Restore the native bank after a page change fails
-- A failed leave is logged once and not retried
local function recoverFailedChange(self, message)
    if self.recoveringPageChange or self.shownPage == nil then return end
    debugLog("Bank Core left ", self.shownPage.title,
        " after a failed page change: ", tostring(message))
    self.recoveringPageChange = true
    local ok, cleanupMessage = pcall(showPage, self, nil)
    self.recoveringPageChange = false
    if not ok then
        debugLog("Bank Core could not return to the native bank view: ",
            tostring(cleanupMessage))
    end
end

-- Run a page change while extension page requests are turned away
-- Restore the transition count before reporting an error to the caller
local function duringTransition(self, change, argument)
    local previousTransitionDepth = self.pageTransitions
    self.pageTransitions = previousTransitionDepth + 1
    local ok, result = pcall(change, self, argument)
    if not ok then recoverFailedChange(self, result) end
    self.pageTransitions = previousTransitionDepth
    if not ok then error(result, 0) end
    return result
end

-- Show a page, or the native view for nil, while extension page requests are turned away
function BankView:ShowPage(page)
    return duringTransition(self, showPage, page)
end

-- Track the native tab, and leave a page when the bank moves off All Items
function BankView:SetNativeViewAll(enabled)
    enabled = enabled == true
    if enabled and self.nativeViewAll then return end
    self.nativeViewAll = enabled
    if not enabled and self.shownPage ~= nil then self:ShowPage(nil) end
    self:Changed(false)
end

-- Reconnect the current page without changing its items or slot order
-- A custom view instead draws again, so its plugin shows the new quantities
function BankView:RefreshPageItems()
    if self.shownPage == nil or not self.pageState.active or self.customView ~= nil then return false end
    self.itemHover:PausePageInput()
    self.itemHover:RestoreBankItemPositions()
    if not self.pageState:RefreshBankItems() then return false end
    local pageItems = self:BuildPageItems()
    if not self.pageDisplay:RefreshRuntimeSprites(pageItems) then
        self.pageDisplay:CreateRuntimeSprites(pageItems)
    end
    self.itemHover:RecordBankItemPositions(self.pageState.bankItems)
    self.itemHover:BuildPageInput(pageItems)
    self:Changed(true)
    return true
end

-- Refresh the page's quantities, or rebuild it when its bank stacks change
-- The hovered stack is kept only while every slot still shows the same stack
local function refreshPage(self, forceRebuild)
    if forceRebuild ~= true
        and self.itemHover:HasHoveredBankStack()
        and not self.pageState:StacksReassigned()
        and self.itemHover:RefreshHoveredBankStack() then
        return true
    end
    if forceRebuild ~= true
        and self.pageState.active
        and self:RefreshPageItems() then
        return true
    end
    if self.shownPage ~= nil then rebuildPage(self) end
    self:Changed(true)
    return true
end

-- Refresh or rebuild the shown page while extension page requests are turned away
function BankView:RefreshShownPage(forceRebuild)
    return duringTransition(self, refreshPage, forceRebuild)
end

-- Rewrap the shown page at a new column count
-- Pause hover so rewrapping cannot put a different stack under a stationary pointer
local function reflowPage(self)
    if self.shownPage == nil then return false end
    rebuildPage(self)
    self.pageDisplay:BeginScrollInteraction()
    self:Changed(false)
    return true
end

-- Rewrap the shown page while extension page requests are turned away
function BankView:ReflowShownPage()
    return duringTransition(self, reflowPage)
end

-- Rebuild a custom view's item input from the bindings its plugin changed, over the bank
-- snapshot it was drawn with, without drawing the view again
-- A snapshot the bank has changed since still draws the view again with a new read
local function rebindView(self)
    local view = self.customView
    if view == nil or not view.changed then return false end
    self.itemHover:PausePageInput()
    self.pageState:SetView(view:Place(self.pageState.view.height), self.pageState.columns)
    self.itemHover:BuildPageInput(self:BuildPageItems())
    if self.pageState.stale then self.itemHover:RefreshAfterBankRebuild(true) end
    return true
end

-- Rebuild changed custom view bindings while extension page requests are turned away
function BankView:RebindShownPage()
    return duringTransition(self, rebindView)
end

-- Refresh after native inventory changes
function BankView:HandleInventoryUpdate()
    -- A shown page's bank items are stale until the rebuild rereads the bank
    if self.shownPage ~= nil then self.pageState.stale = true end
    self:Changed(true)
    if self.shownPage == nil then
        self:RebuildPageInput()
        return
    end
    self.itemHover:BlockPageInput()
    local hasHoveredStack = self.itemHover:HasHoveredBankStack()
    -- New native items can exist before their positions settle, so wait a tick
    self.itemHover:RefreshAfterBankRebuild(not hasHoveredStack)
end

-- Check whether the recorded bank items still match bank quantities
function BankView:ShownPageIsInSync()
    if self.shownPage == nil then return true end
    return self.pageState:IsInSync()
end

return BankView
