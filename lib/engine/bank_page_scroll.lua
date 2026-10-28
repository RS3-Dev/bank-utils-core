-- Scroll pages and pause hover while the view settles

local Config = require("lib/core/config")
local BankInterface = require("lib/core/bank_interface")
local BankGrid = require("lib/engine/bank_grid")
local UICoordinates = require("lib/ui/ui_coordinates")
local NativeUi = require("lib/ui/native_ui")
local Theme = require("lib/ui/theme")

local BankPageScroll = {}

local BANK_ITEMS_CONTAINER_STATIC_ID = BankInterface.ITEMS_CONTAINER
local GRID_STEP = BankGrid.STEP
local BANK_VIEWPORT_COLOUR = Theme.VIEW_BACKGROUND
local ENGINE_SCROLL_HOOK = Config.CORE_REF .. "_engine_scroll"
local SCROLLBAR_WIDTH = NativeUi.SCROLLBAR_WIDTH
local SCROLL_INTERACTION_SETTLE_TICKS = 8

-- Find a native bank component by its interface slot
local component = BankInterface.Get

-- Read the page's total height, including its title
function BankPageScroll:ContentHeightForCurrentLayout()
    local placedPage = self.bankView.pageState.view
    return placedPage ~= nil and placedPage.height or 0
end

-- Find the furthest scroll position that keeps the page within the viewport
function BankPageScroll:MaxScrollY(pageArea)
    pageArea = pageArea or self.pageArea or self:ReadPageArea()
    if pageArea == nil then return 0 end
    return math.max(0, self:ContentHeightForCurrentLayout() - pageArea.height)
end

-- Move the native bank viewport; its scrollY is read-only
function BankPageScroll:ApplyViewportScroll(viewport, scrollY)
    viewport:SetScrollPos(0, scrollY)
end

-- Pause hover so scrolling cannot switch the stack beneath a stationary pointer
function BankPageScroll:BeginScrollInteraction()
    self.scrollInteractionTicks = SCROLL_INTERACTION_SETTLE_TICKS
    self.bankView.itemHover:PauseHoverForScroll()
end

-- Start the hover pause for any scroll movement
function BankPageScroll:OnScrollChanged(previousY, newY)
    if previousY == newY then return false end
    self:BeginScrollInteraction()
    return true
end

-- Keep hover off until scrolling has settled for a few ticks
function BankPageScroll:HoldPointerInteractionDuringScroll(scrollChanged)
    if self.scrollInteractionTicks <= 0 then return false end
    self.bankView.itemHover:PauseHoverForScroll()
    if not scrollChanged then
        self.scrollInteractionTicks = self.scrollInteractionTicks - 1
    end
    return true
end

-- Keep the requested offset in range, update the page, and pause hover
function BankPageScroll:SetScrollPosition(requestedScrollY, rebuildInteractiveLayers)
    local pageArea = self:ReadPageArea()
    if pageArea == nil then return false end
    local previousScrollY = self.scrollY
        or pageArea.scrollY
        or 0
    local scrollY = math.max(
        0,
        math.min(self:MaxScrollY(pageArea), math.floor(requestedScrollY))
    )
    self:ApplyViewportScroll(pageArea.viewport, scrollY)
    pageArea.scrollY = scrollY
    self:UpdateListItemPositions(rebuildInteractiveLayers ~= false, scrollY)
    if not self:OnScrollChanged(previousScrollY, scrollY) then
        -- Scrolling at the top or bottom still counts, even though the offset cannot move
        self:BeginScrollInteraction()
    end
    return true
end

-- Move the page by a relative offset
function BankPageScroll:ScrollBy(delta)
    local pageArea = self:ReadPageArea()
    if pageArea == nil then return false end
    local previousScrollY = self.scrollY
        or pageArea.scrollY
        or 0
    self:SetScrollPosition(previousScrollY + delta, true)
    return true
end

-- Make the mouse wheel move the page by rows
function BankPageScroll:BindScrollWheel(componentValue)
    if componentValue == nil then return end
    componentValue:Subscribe(ui.Hook.ONSCROLLWHEEL, ENGINE_SCROLL_HOOK,
        function(_, delta)
            -- Scroll a page only while it is shown; otherwise leave the wheel to the bank
            if self.bankView.shownPage == nil then return false end
            return self:ScrollBy(delta * GRID_STEP)
        end)
end

-- Return a component's wheel input to the host
function BankPageScroll:UnbindScrollWheel(componentValue)
    componentValue:Unsubscribe(ui.Hook.ONSCROLLWHEEL, ENGINE_SCROLL_HOOK)
end

-- Remove custom scrolling and optionally restore the bank's offset
function BankPageScroll:DestroyScrollbar(restoreNativeScroll)
    local viewport = restoreNativeScroll and self.nativeScrollY ~= nil
        and component(BANK_ITEMS_CONTAINER_STATIC_ID) or nil
    if viewport ~= nil then
        -- The bank may be closing, so its viewport can be stale
        pcall(function() viewport:SetScrollPos(0, self.nativeScrollY) end)
    end
    if self.scrollbarLayer ~= nil then
        pcall(function() self.scrollbarLayer:Destroy() end)
    end
    self.scrollbarLayer = nil
    self.scrollbarBackdrop = nil
    self.scrollbar = nil
    self.scrollDragStart = nil
    self.scrollOwner = nil
    self.scrollKey = nil
    self.nativeScrollY = nil
    self.scrollInteractionTicks = 0
end

-- Update the scrollbar thumb from content height and offset
function BankPageScroll:RefreshScrollbar(pageArea)
    if self.scrollbar == nil then return end
    pageArea = pageArea or self.pageArea or self:ReadPageArea()
    if pageArea == nil then return end
    self.scrollbar:Refresh(math.max(1, self:ContentHeightForCurrentLayout()), pageArea.scrollY)
end

-- Centre the thumb on the pointer's height in the track
-- Click coordinates have no documented origin, so this uses the calibrated pointer
local function scrollToPointer(self, track)
    local _, mouseY = UICoordinates.interfaceMousePosition()
    if mouseY == nil then return true end
    local _, trackY = UICoordinates.absolutePosition(track)
    return self:SetScrollPosition(self.scrollbar:ScrollFromTrack(mouseY - trackY,
        math.max(1, self:ContentHeightForCurrentLayout())), true)
end

-- Start a thumb drag from the pointer and the page's offset, leaving the page still
local function startThumbDrag(self)
    local _, mouseY = UICoordinates.interfaceMousePosition()
    if mouseY == nil then return true end
    self.scrollDragStart = {
        mouseY = mouseY,
        scrollY = self.pageArea ~= nil and self.pageArea.scrollY or 0,
    }
    return true
end

-- Move the page by the held pointer's travel since the thumb was pressed
local function dragThumb(self)
    local _, mouseY = UICoordinates.interfaceMousePosition()
    local start = self.scrollDragStart
    if mouseY == nil or start == nil then return true end
    local maxScrollY = self:MaxScrollY()
    local thumbTravel = self.scrollbar:ThumbTravel(
        math.max(1, self:ContentHeightForCurrentLayout()))
    if maxScrollY > 0 and thumbTravel > 0 then
        self:SetScrollPosition(
            start.scrollY + (mouseY - start.mouseY) * maxScrollY / thumbTravel,
            true
        )
    end
    return true
end

-- Build the scrollbar layer, backdrop, and controls as one widget
-- It is recorded only once complete; a refused part or hook removes the layer and fails
-- the page change, whose recovery still restores the bank's recorded scroll
local function buildScrollbar(self, height)
    local layer = ui.Layer.new(self.bankView.components.all)
    local backdrop, scrollbar
    local built, message = pcall(function()
        layer.clickthrough = false
        backdrop = ui.Rectangle.new(layer)
        backdrop:SetPos(0, 0)
        backdrop.fill = true
        backdrop.rgba = BANK_VIEWPORT_COLOUR
        backdrop.clickthrough = false
        scrollbar = NativeUi.createScrollbar(layer, {
            height = height,
            onUp = function() return self:ScrollBy(-GRID_STEP) end,
            onDown = function() return self:ScrollBy(GRID_STEP) end,
            onTrackClick = function(track) return scrollToPointer(self, track) end,
            onThumbClick = function() return startThumbDrag(self) end,
            onThumbHold = function() return dragThumb(self) end,
            onThumbRelease = function()
                self.scrollDragStart = nil
                return true
            end,
        })
        -- Anywhere over the scrollbar the wheel scrolls the page, and hovering calibrates
        -- the pointer, so a click or drag here needs no earlier hover over a page item
        for _, part in ipairs({ layer, scrollbar.upArrow, scrollbar.downArrow, scrollbar.track,
            scrollbar.thumb }) do
            self:BindScrollWheel(part)
            UICoordinates.trackPointer(part)
        end
    end)
    if not built then
        layer:Destroy()
        error(message, 0)
    end
    self.scrollbarLayer = layer
    self.scrollbarBackdrop = backdrop
    self.scrollbar = scrollbar
end

-- Create scroll controls once, then fit and refresh them with the viewport
function BankPageScroll:CreateScrollbar(pageArea)
    if self.bankView.components.all == nil then return end
    if self.scrollbarLayer == nil then
        if self.nativeScrollY == nil then
            self.nativeScrollY = pageArea.viewport.scrollY
        end
        buildScrollbar(self, pageArea.height)
    end

    self.scrollbarLayer:SetPos(pageArea.x + pageArea.width, pageArea.y)
    self.scrollbarLayer:SetSize(SCROLLBAR_WIDTH, pageArea.height)
    self.scrollbarBackdrop:SetSize(SCROLLBAR_WIDTH, pageArea.height)
    self.scrollbar.height = pageArea.height
    self:RefreshScrollbar(pageArea)
    self.scrollbarLayer:MoveToFront()
end

-- Add these scrolling methods to the BankPageDisplay class
function BankPageScroll.install(target)
    for name, method in pairs(BankPageScroll) do
        if name ~= "install" then target[name] = method end
    end
end

return BankPageScroll
