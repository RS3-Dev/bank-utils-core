-- Pause item hover while the page scrolls.

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

local component = BankInterface.Get

function BankPageScroll:ContentHeightForCurrentLayout()
    local placedPage = self.bankView.pageState.view
    return placedPage ~= nil and placedPage.height or 0
end

function BankPageScroll:MaxScrollY(pageArea)
    pageArea = pageArea or self.pageArea or self:ReadPageArea()
    if pageArea == nil then return 0 end
    return math.max(0, self:ContentHeightForCurrentLayout() - pageArea.height)
end

-- Move the visible area because scrollY cannot be changed directly.
function BankPageScroll:ApplyViewportScroll(viewport, scrollY)
    viewport:SetScrollPos(0, scrollY)
end

-- Pause hover so scrolling cannot change the item under the mouse.
function BankPageScroll:BeginScrollInteraction()
    self.scrollInteractionTicks = SCROLL_INTERACTION_SETTLE_TICKS
    self.bankView.itemHover:PauseHoverForScroll()
end

function BankPageScroll:OnScrollChanged(previousY, newY)
    if previousY == newY then return false end
    self:BeginScrollInteraction()
    return true
end

-- Wait a few game updates after scrolling before enabling hover.
function BankPageScroll:HoldPointerInteractionDuringScroll(scrollChanged)
    if self.scrollInteractionTicks <= 0 then return false end
    self.bankView.itemHover:PauseHoverForScroll()
    if not scrollChanged then
        self.scrollInteractionTicks = self.scrollInteractionTicks - 1
    end
    return true
end

-- Keep scrolling within the page limits and pause hover.
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
        -- Pause hover even at the scroll limits.
        self:BeginScrollInteraction()
    end
    return true
end

function BankPageScroll:ScrollBy(delta)
    local pageArea = self:ReadPageArea()
    if pageArea == nil then return false end
    local previousScrollY = self.scrollY
        or pageArea.scrollY
        or 0
    self:SetScrollPosition(previousScrollY + delta, true)
    return true
end

function BankPageScroll:BindScrollWheel(componentValue)
    if componentValue == nil then return end
    componentValue:Subscribe(ui.Hook.ONSCROLLWHEEL, ENGINE_SCROLL_HOOK,
        function(_, delta)
            -- Leave the wheel to the bank when the page is hidden.
            if self.bankView.shownPage == nil then return false end
            return self:ScrollBy(delta * GRID_STEP)
        end)
end

function BankPageScroll:UnbindScrollWheel(componentValue)
    componentValue:Unsubscribe(ui.Hook.ONSCROLLWHEEL, ENGINE_SCROLL_HOOK)
end

-- Remove page scrolling and optionally restore the bank's scroll position.
function BankPageScroll:DestroyScrollbar(restoreNativeScroll)
    local viewport = restoreNativeScroll and self.nativeScrollY ~= nil
        and component(BANK_ITEMS_CONTAINER_STATIC_ID) or nil
    if viewport ~= nil then
        -- The scroll area may disappear as the bank closes.
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

function BankPageScroll:RefreshScrollbar(pageArea)
    if self.scrollbar == nil then return end
    pageArea = pageArea or self.pageArea or self:ReadPageArea()
    if pageArea == nil then return end
    self.scrollbar:Refresh(math.max(1, self:ContentHeightForCurrentLayout()), pageArea.scrollY)
end

-- Use the measured mouse position; click events do not say where (0, 0) is.
local function scrollToPointer(self, track)
    local _, mouseY = UICoordinates.interfaceMousePosition()
    if mouseY == nil then return true end
    local _, trackY = UICoordinates.absolutePosition(track)
    return self:SetScrollPosition(self.scrollbar:ScrollFromTrack(mouseY - trackY,
        math.max(1, self:ContentHeightForCurrentLayout())), true)
end

-- Start dragging without jumping the page.
local function startThumbDrag(self)
    local _, mouseY = UICoordinates.interfaceMousePosition()
    if mouseY == nil then return true end
    self.scrollDragStart = {
        mouseY = mouseY,
        scrollY = self.pageArea ~= nil and self.pageArea.scrollY or 0,
    }
    return true
end

-- Scroll by the distance the pointer has moved.
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

-- Remove the whole scrollbar if any part fails to build.
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
        -- Hovering measures mouse position so clicks and drags work immediately.
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

-- Reuse scroll controls when the visible area changes size.
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

function BankPageScroll.install(target)
    for name, method in pairs(BankPageScroll) do
        if name ~= "install" then target[name] = method end
    end
end

return BankPageScroll
