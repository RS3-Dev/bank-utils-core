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

function BankView.new(options)
    options = options or {}
    local self = setmetatable({
        pageState = BankPageItems.new(),
        active = false,
        expanded = false,
        -- Window changes to undo later.
        expansion = nil,
        windowRecord = options.windowRecord or BankWindowRecord.new(),
        components = {},
        -- The plugin page, or nil for the normal bank.
        shownPage = nil,
        -- The current custom drawing.
        customView = nil,
        sidebarMode = nil,
        -- Plugin tabs in the player's saved order.
        extensionTabs = {},
        -- The session supplies saved tab order access.
        readRailOrder = options.readRailOrder or function() return {} end,
        saveRailOrder = options.saveRailOrder or function() return false end,
        -- Identifies this bank opening for notifications.
        windowSession = 0,
        bankWindowWatch = nil,
        nativeViewAll = false,
        itemHover = nil,
        onChange = function() end,
        itemsGeneration = 0,
        -- Hold plugin requests until the page change finishes.
        pageTransitions = 0,
        recoveringPageChange = false,
    }, BankView)
    self.pageDisplay = BankPageDisplay.new(self)
    self.itemHover = BankItemHover.new(self)
    return self
end

function BankView:Changed(itemsChanged)
    if itemsChanged then self.itemsGeneration = self.itemsGeneration + 1 end
    self.onChange()
end

-- Keep the mounted column's overlay above the page and the sidebar
function BankView:RaiseMountOverlays()
    if self.tabMount ~= nil then self.tabMount:RaiseOverlay() end
end

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

-- Share one set of page items between drawing and input.
function BankView:BuildPageItems()
    local entries = self.pageState:GetVisibleItems(self.pageDisplay:GridCellInset())
    if self.customView ~= nil then self.customView:Measure(entries) end
    return entries
end

-- Disable calls from the previous custom drawing.
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

-- Keep click areas aligned as custom items move or hide.
function BankView:FollowCustomView()
    if self.customView:Follow() then self.itemHover:FollowItemAreas() end
end

-- Match slots to bank stacks; return to the bank if this fails.
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

-- Fit the viewport and custom content within the page height limit.
local function viewHeight(view, requested, viewportHeight)
    return math.ceil(math.min(PageLayout.MAX_HEIGHT,
        math.max(viewportHeight, requested or 0, view:BoundBottom())))
end

-- Draw the plugin's view and place real stacks beneath its bound items.
local function drawCustomView(self)
    local page, pageState, pageDisplay = self.shownPage, self.pageState, self.pageDisplay
    -- Share this bank read with the plugin while it draws.
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
    -- Discard the view if its plugin was removed while drawing.
    if not drawn or page.draw == nil then error("the extension's view could not be drawn", 0) end
    local columns = BankGrid.ColumnCount(bankItemLayer.width)
    local matchCount = pageState:SetView(view:Place(viewHeight(view, height, pageArea.height)), columns)
    -- Set the content height before measuring bound items.
    pageDisplay:ShowPageLayers({}, {})
    local pageItems = self:BuildPageItems()
    -- Save positions before moving any stacks.
    self.itemHover:RecordBankItemPositions(pageState.bankItems)
    self.itemHover:BuildPageInput(pageItems)
    return matchCount
end

-- End the old drawing, then draw the page and set up its input.
local function drawPage(self)
    revokeCustomView(self)
    if self.shownPage.draw ~= nil then return drawCustomView(self) end
    local matchCount = layOutPage(self)
    local pageItems = self:BuildPageItems()
    self.pageDisplay:CreateRuntimeSprites(pageItems)
    -- Save positions before moving any stacks.
    self.itemHover:RecordBankItemPositions(self.pageState.bankItems)
    self.itemHover:BuildPageInput(pageItems)
    return matchCount
end

-- Keep clicks blocked while redrawing.
local function rebuildPage(self)
    self.itemHover:PausePageInput()
    self.itemHover:RestoreBankItemPositions()
    return drawPage(self)
end

-- Switch pages, keeping scroll when redrawing the same opening.
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

-- Return to the bank after failure; log cleanup errors without retrying.
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

-- Block plugin requests during page changes, even if they fail.
local function duringTransition(self, change, argument)
    local previousTransitionDepth = self.pageTransitions
    self.pageTransitions = previousTransitionDepth + 1
    local ok, result = pcall(change, self, argument)
    if not ok then recoverFailedChange(self, result) end
    self.pageTransitions = previousTransitionDepth
    if not ok then error(result, 0) end
    return result
end

-- Show the page, or the normal bank for nil.
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

-- Keep slot order; custom views redraw to show updated quantities.
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

-- Keep hover only while every slot still matches its bank stack.
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

function BankView:RefreshShownPage(forceRebuild)
    return duringTransition(self, refreshPage, forceRebuild)
end

-- Pause hover while rows rewrap to avoid switching the hovered item.
local function reflowPage(self)
    if self.shownPage == nil then return false end
    rebuildPage(self)
    self.pageDisplay:BeginScrollInteraction()
    self:Changed(false)
    return true
end

function BankView:ReflowShownPage()
    return duringTransition(self, reflowPage)
end

-- Update changed bindings; redraw if their bank data is stale.
local function rebindView(self)
    local view = self.customView
    if view == nil or not view.changed then return false end
    self.itemHover:PausePageInput()
    self.pageState:SetView(view:Place(self.pageState.view.height), self.pageState.columns)
    self.itemHover:BuildPageInput(self:BuildPageItems())
    if self.pageState.stale then self.itemHover:RefreshAfterBankRebuild(true) end
    return true
end

function BankView:RebindShownPage()
    return duringTransition(self, rebindView)
end

-- Refresh after native inventory changes
function BankView:HandleInventoryUpdate()
    -- Bank data stays stale until the rebuild rereads it.
    if self.shownPage ~= nil then self.pageState.stale = true end
    self:Changed(true)
    if self.shownPage == nil then
        self:RebuildPageInput()
        return
    end
    self.itemHover:BlockPageInput()
    local hasHoveredStack = self.itemHover:HasHoveredBankStack()
    -- Wait a tick for new bank items to settle.
    self.itemHover:RefreshAfterBankRebuild(not hasHoveredStack)
end

function BankView:ShownPageIsInSync()
    if self.shownPage == nil then return true end
    return self.pageState:IsInSync()
end

return BankView
