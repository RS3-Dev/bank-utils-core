-- Draw page items and headings where clicks reach them.

local Config = require("lib/core/config")
local BankInterface = require("lib/core/bank_interface")
local BankPageScroll = require("lib/engine/bank_page_scroll")
local BankGrid = require("lib/engine/bank_grid")
local ObjectConfig = require("lib/core/object_config")
local UICoordinates = require("lib/ui/ui_coordinates")
local relativePosition = UICoordinates.relativePosition
local Theme = require("lib/ui/theme")

local BankPageDisplay = {}
BankPageDisplay.__index = BankPageDisplay
BankPageScroll.install(BankPageDisplay)

local BANK_ITEMS_STATIC_ID = BankInterface.ITEMS
local BANK_ITEMS_CONTAINER_STATIC_ID = BankInterface.ITEMS_CONTAINER
local GRID_LEFT = BankGrid.LEFT
local GRID_SLOT_SIZE = BankGrid.SLOT_SIZE
local GRID_STEP = BankGrid.STEP
local BANK_VIEWPORT_COLOUR = Theme.VIEW_BACKGROUND
local HEADING_HEIGHT = 28
local SECTION_TEXT_COLOUR = Theme.HEADING_TEXT
local SECTION_LINE_COLOUR = Theme.HEADING_LINE
local LABEL_LINE_OFFSET = BankGrid.LABEL_LINE_OFFSET
local VISUAL_SYNC_EVENT = Config.CORE_REF .. "_visual_sync"
-- Wait for a steady width before changing how many items fit per row
local REFLOW_QUIET_TICKS = 10

function BankPageDisplay.new(bankView)
    return setmetatable({
        bankView = bankView,
        layer = nil,
        background = nil,
        contentViewport = nil,
        contentLayer = nil,
        -- Popups above the window.
        viewOverlay = nil,
        -- Drawn items and their sprites, in page order.
        items = {},
        sprites = {},
        pageArea = nil,
        scrollY = nil,
        scrollbarLayer = nil,
        scrollbarBackdrop = nil,
        scrollbar = nil,
        scrollDragStart = nil,
        -- The page opening that owns the saved scroll position.
        scrollOwner = nil,
        scrollKey = nil,
        nativeScrollY = nil,
        scrollInteractionTicks = 0,
        visualSyncing = false,
        -- Wait for width and custom height to settle before redrawing.
        reflowWidth = nil,
        reflowHeight = nil,
        reflowTicks = 0,
        -- Tooltip for an item without a real bank stack.
        nameAnchor = nil,
        nameTooltip = nil,
        nameText = nil,
    }, BankPageDisplay)
end

function BankPageDisplay:ReadPageArea()
    local all = self.bankView.components.all
    local bank = ui.Interfaces:GetInterface(Config.BANK_INTERFACE_ID)
    if bank == nil or all == nil then return nil end
    local bankItemLayer = bank:GetComponent(BANK_ITEMS_STATIC_ID)
    local viewport = bank:GetComponent(BANK_ITEMS_CONTAINER_STATIC_ID)
    if bankItemLayer == nil or viewport == nil then return nil end
    local layerX, layerY = relativePosition(bankItemLayer, all)
    local viewportX, viewportY = relativePosition(viewport, all)
    if layerX == nil or viewportX == nil then return nil end
    return {
        itemLayer = bankItemLayer,
        viewport = viewport,
        x = viewportX,
        y = viewportY,
        width = bankItemLayer.width,
        height = viewport.height,
        contentX = layerX - viewportX,
        contentY = layerY - viewportY,
        scrollY = viewport.scrollY,
    }
end

-- Centre images in their clickable cells.
function BankPageDisplay:GridCellInset()
    local pageState = self.bankView.pageState
    return math.max(0, math.floor((GRID_SLOT_SIZE - pageState.itemWidth) / 2)),
        math.max(0, math.floor((GRID_SLOT_SIZE - pageState.itemHeight) / 2))
end

-- Describe the visible area and grid for a custom view.
function BankPageDisplay:ViewGeometry()
    local pageArea, pageState = self.pageArea, self.bankView.pageState
    local x, y = UICoordinates.absolutePosition(self.layer)
    return { x = x, y = y, width = pageArea.width, height = pageArea.height, scrollY = self.scrollY,
        columns = BankGrid.ColumnCount(pageArea.width), itemWidth = pageState.itemWidth,
        itemHeight = pageState.itemHeight, cellWidth = GRID_SLOT_SIZE, cellHeight = GRID_SLOT_SIZE,
        stepX = GRID_STEP, stepY = GRID_STEP }
end

-- Apply supplied sprite settings; keep the rest.
local function applyAppearance(sprite, pageItem)
    if pageItem.quantity ~= nil then sprite.associatedObjectQuantity = pageItem.quantity end
    if pageItem.quantityMode ~= nil then sprite.associatedObjectQuantityMode = pageItem.quantityMode end
    if pageItem.outlineWidth ~= nil then sprite.outlineWidth = pageItem.outlineWidth end
    if pageItem.shadowRGBA ~= nil then sprite.shadowRGBA = pageItem.shadowRGBA end
    sprite.alpha = pageItem.alpha
end

function BankPageDisplay:StopVisualSync()
    self.visualSyncing = false
    Event.Logic.Unsubscribe(VISUAL_SYNC_EVENT)
end

function BankPageDisplay:RaiseItemName()
    if self.nameText ~= nil then self.nameTooltip:Show() end
end

-- Supply tooltips for items without a bank stack.
function BankPageDisplay:ShowItemName(pageItem, pageArea)
    local name = pageItem ~= nil and ObjectConfig.DisplayName(pageItem.objectID) or nil
    if name == nil then return self:HideItemName() end
    local parent = self.bankView.components.all
    if self.nameAnchor == nil then
        self.nameAnchor = ui.Layer.new(parent)
        self.nameTooltip = prettyui.Tooltip.attach(self.nameAnchor, parent, name)
        -- The tooltip anchor must let clicks through.
        self.nameAnchor.clickthrough = true
    elseif self.nameText ~= name then
        self.nameTooltip:SetText(name)
    end
    local area = pageItem.area
    self.nameAnchor:SetPos(pageArea.x + pageArea.contentX + area.x,
        pageArea.y + pageArea.contentY + area.y - pageArea.scrollY)
    self.nameAnchor:SetSize(area.width, area.height)
    self.nameText = name
    self.nameTooltip:Show()
end

function BankPageDisplay:HideItemName()
    if self.nameText == nil then return end
    self.nameText = nil
    self.nameTooltip:Hide()
end

function BankPageDisplay:DestroyItemName()
    local tooltip, anchor = self.nameTooltip, self.nameAnchor
    self.nameAnchor, self.nameTooltip, self.nameText = nil, nil, nil
    if tooltip ~= nil then pcall(function() tooltip:Destroy() end) end
    if anchor ~= nil then pcall(function() anchor:Destroy() end) end
end

-- Removing layers also removes their contents.
local function destroyPageLayers(self)
    local layer, overlay = self.layer, self.viewOverlay
    self.layer, self.viewOverlay = nil, nil
    if layer ~= nil then pcall(function() layer:Destroy() end) end
    if overlay ~= nil then pcall(function() overlay:Destroy() end) end
end

-- Stop updates, remove the page, and restore native scrolling
function BankPageDisplay:DestroyRuntimeSprites()
    self:StopVisualSync()
    self:DestroyItemName()
    self.items = {}
    self.sprites = {}
    destroyPageLayers(self)
    self.background = nil
    self.contentViewport = nil
    self.contentLayer = nil
    self.pageArea = nil
    self.scrollY = nil
    self:DestroyScrollbar(true)
end

-- Content must be at least as tall as the viewport.
function BankPageDisplay:FitContent(pageArea)
    if self.contentViewport == nil then return end
    local contentHeight = math.max(pageArea.height, self:ContentHeightForCurrentLayout())
    self.contentViewport:SetSize(pageArea.width, pageArea.height)
    self.contentViewport:SetScrollSize(pageArea.width, contentHeight)
    self.contentLayer:SetPos(pageArea.contentX, pageArea.contentY)
    self.contentLayer:SetSize(pageArea.itemLayer.width, contentHeight)
end

-- Align page images and input targets with the current scroll position
function BankPageDisplay:UpdateListItemPositions(rebuildInteractiveLayers, requestedScrollY)
    local bankView = self.bankView
    if self.layer == nil or bankView.shownPage == nil then return false, false end
    local pageArea = self:ReadPageArea()
    if pageArea == nil then return false, false end
    local maxScrollY = self:MaxScrollY(pageArea)
    local observedScrollY = pageArea.scrollY
    local targetScrollY = requestedScrollY
    if targetScrollY == nil then
        -- Bank actions can briefly reset our scroll offset.
        targetScrollY = self.scrollY
    end
    if targetScrollY == nil then targetScrollY = observedScrollY end
    targetScrollY = math.max(0, math.min(maxScrollY, targetScrollY))
    if targetScrollY ~= observedScrollY then
        self:ApplyViewportScroll(pageArea.viewport, targetScrollY)
    end
    -- Use the scroll offset the bank actually accepted.
    pageArea.nativeScrollY = pageArea.viewport.scrollY
    pageArea.scrollY = targetScrollY
    local previousPageArea = self.pageArea
    local scrollChanged = self.scrollY ~= pageArea.scrollY
    local pageAreaChanged = previousPageArea == nil
        or previousPageArea.x ~= pageArea.x
        or previousPageArea.y ~= pageArea.y
        or previousPageArea.width ~= pageArea.width
        or previousPageArea.height ~= pageArea.height
        or previousPageArea.contentX ~= pageArea.contentX
        or previousPageArea.contentY ~= pageArea.contentY
    self.scrollY = pageArea.scrollY
    self.pageArea = pageArea
    if bankView.customView ~= nil then bankView.customView.context.scrollY = self.scrollY end
    if pageAreaChanged then
        self.layer:SetPos(pageArea.x, pageArea.y)
        self.layer:SetSize(pageArea.width, pageArea.height)
        self:FitContent(pageArea)
    end
    if (scrollChanged or pageAreaChanged) and self.contentViewport ~= nil then
        self.contentViewport:SetScrollPos(0, pageArea.scrollY)
    end
    if pageAreaChanged and self.scrollbar ~= nil then
        self:CreateScrollbar(pageArea)
    elseif scrollChanged then
        self:RefreshScrollbar(pageArea)
    end
    if rebuildInteractiveLayers and (scrollChanged or pageAreaChanged) then
        bankView.itemHover:ResizePageInput(pageArea)
    end
    return scrollChanged, pageAreaChanged
end

-- Redraw once the page size settles.
function BankPageDisplay:ReflowSettledWidth()
    local width, view = self.pageArea.width, self.bankView.customView
    local height = view ~= nil and self.pageArea.height or nil
    if width ~= self.reflowWidth or height ~= self.reflowHeight then
        self.reflowWidth, self.reflowHeight, self.reflowTicks = width, height, 0
        return false
    end
    self.reflowTicks = self.reflowTicks + 1
    if self.reflowTicks ~= REFLOW_QUIET_TICKS then return false end
    if view ~= nil then
        if width == view.width and height == view.height then return false end
    elseif BankGrid.ColumnCount(width) == self.bankView.pageState.columns then
        return false
    end
    return self.bankView:ReflowShownPage()
end

-- Keep updates running during rebuilds so old cleanup cannot stop new updates.
function BankPageDisplay:StartVisualSync()
    local bankView = self.bankView
    self.reflowWidth = self.pageArea.width
    self.reflowHeight = bankView.customView ~= nil and self.pageArea.height or nil
    self.reflowTicks = 0
    if self.visualSyncing then return end
    self.visualSyncing = true
    Event.Logic.Subscribe(VISUAL_SYNC_EVENT, function()
        if not bankView.active or bankView.shownPage == nil or self.layer == nil then
            self:StopVisualSync()
            return
        end
        if bankView:IsPresetViewOpen() then
            bankView:ShowPage(nil)
            return
        end
        if bankView.itemHover.dropRefreshPending then
            bankView.itemHover:BlockPageInput()
            return
        end
        -- Refresh changed bindings once per tick.
        local view = bankView.customView
        if view ~= nil and view.changed then
            bankView:RebindShownPage()
            return
        end
        -- Keep click areas aligned with custom items.
        if view ~= nil then bankView:FollowCustomView() end
        local previousScrollY = self.scrollY
        local scrollChanged, pageAreaChanged = self:UpdateListItemPositions(true)
        if pageAreaChanged then
            bankView.itemHover:RecordBankItemPositions()
        end
        -- Rewrapping already reset the width check.
        if self:ReflowSettledWidth() then return end
        bankView.itemHover:FollowNativeScroll()
        if scrollChanged then
            self:OnScrollChanged(previousScrollY, self.scrollY)
        end
        if bankView.itemHover:HasHoveredBankStack() then
            if bankView.itemHover:CheckHoveredBankStack() then
                bankView:RefreshShownPage()
                return
            end
        end
        if not self:HoldPointerInteractionDuringScroll(scrollChanged) then
            bankView.itemHover:UpdateHoveredItem(pageAreaChanged)
        end
        if bankView.itemHover:HasHoveredBankStack() then
            bankView.itemHover:MaintainNativeItemPositions()
        end
        self.layer:MoveToFront()
        bankView.itemHover:RaisePageInput()
    end)
end

-- Redraws keep their scroll position; new page openings start at the top.
local function startingScroll(self, pageArea)
    local page = self.bankView.shownPage
    if self.scrollOwner == page.owner and self.scrollKey == page.key then
        return self.scrollY or pageArea.scrollY
    end
    if self.scrollbarLayer == nil and self.nativeScrollY == nil then
        self.nativeScrollY = pageArea.scrollY
    end
    self.scrollOwner, self.scrollKey = page.owner, page.key
    return 0
end

-- Record new layers before setup so cleanup can remove a failed build.
function BankPageDisplay:CreatePageLayers(custom)
    local all = self.bankView.components.all
    local pageArea = self:ReadPageArea()
    if pageArea == nil then return nil end
    local scrollY = math.max(0, math.min(self:MaxScrollY(pageArea), startingScroll(self, pageArea)))
    if scrollY ~= pageArea.scrollY then self:ApplyViewportScroll(pageArea.viewport, scrollY) end
    pageArea.scrollY = scrollY
    self.pageArea, self.scrollY = pageArea, scrollY

    destroyPageLayers(self)
    self.layer = ui.Layer.new(all)
    self.layer:SetPos(pageArea.x, pageArea.y)
    self.layer:SetSize(pageArea.width, pageArea.height)
    self.layer.clickthrough = true

    self.background = ui.Rectangle.new(self.layer)
    self.background:SetPos(0, 0)
    self.background:SetSize(0, 0, 1.0, 1.0)
    self.background.fill = true
    self.background.rgba = BANK_VIEWPORT_COLOUR
    self.background.clickthrough = true

    -- The outer layer stays fixed while its contents scroll together.
    self.contentViewport = ui.Layer.new(self.layer)
    self.contentLayer = ui.Layer.new(self.contentViewport)
    self.contentViewport:SetPos(0, 0)
    self:FitContent(pageArea)
    self.contentViewport:SetScrollPos(0, scrollY)
    for _, content in ipairs({ self.contentViewport, self.contentLayer }) do
        content.clickthrough = true
        content.enabled = custom == true
    end
    if custom then
        self.viewOverlay = ui.Layer.new(all)
        self.viewOverlay:SetPos(0, 0)
        self.viewOverlay:SetSize(0, 0, 1.0, 1.0)
        self.viewOverlay.clickthrough = true
    end
    return self.contentLayer, self.viewOverlay
end

-- Fit the page after drawing, when its full height is known.
function BankPageDisplay:ShowPageLayers(pageItems, sprites)
    self.items, self.sprites = pageItems, sprites
    self:FitContent(self.pageArea)
    self:UpdateListItemPositions(false, self.scrollY)
    self:CreateScrollbar(self.pageArea)
    self.layer:MoveToFront()
    if self.scrollbarLayer ~= nil then self.scrollbarLayer:MoveToFront() end
    self:StartVisualSync()
end

-- Redraw with the same item data used for clicks.
function BankPageDisplay:CreateRuntimeSprites(pageItems)
    local contentLayer = self:CreatePageLayers(false)
    if contentLayer == nil then return end
    local pageArea = self.pageArea

    local function addHeading(text, relativeY)
        local header = ui.Layer.new(contentLayer)
        local headerWidth = math.max(1, pageArea.width - pageArea.contentX - GRID_LEFT * 2)
        header:SetPos(GRID_LEFT, relativeY)
        header:SetSize(headerWidth, HEADING_HEIGHT)
        header.clickthrough = true

        local label = prettyui.Text.new(header, {
            text = text,
            x = 0,
            y = 0,
            width = headerWidth,
            height = LABEL_LINE_OFFSET,
            colour = SECTION_TEXT_COLOUR,
            font = id.Font.MUSEO_SANS_11PT_REGULAR,
            maxLines = 1,
        })
        label.clickthrough = true

        local separator = ui.Rectangle.new(header)
        separator:SetPos(0, LABEL_LINE_OFFSET)
        separator:SetSize(headerWidth, 1)
        separator.fill = true
        separator.rgba = SECTION_LINE_COLOUR
        separator.clickthrough = true
    end

    for _, section in ipairs(self.bankView.pageState:GetLayoutSections()) do
        addHeading(section.label, section.y)
    end

    local sprites = {}
    for index, pageItem in ipairs(pageItems) do
        local sprite = ui.Sprite.new(contentLayer)
        sprite:SetPos(pageItem.x, pageItem.y)
        sprite:SetSize(pageItem.width, pageItem.height)
        sprite:SetAssociatedObject(pageItem.objectID)
        applyAppearance(sprite, pageItem)
        sprite.clickthrough = true
        sprites[index] = sprite
    end
    self:ShowPageLayers(pageItems, sprites)
end

-- Refresh sprites in place unless their size changed.
function BankPageDisplay:RefreshRuntimeSprites(pageItems)
    if #pageItems ~= #self.items then return false end
    -- Check all matches before changing any sprites.
    for index, drawnItem in ipairs(self.items) do
        local pageItem = pageItems[index]
        if pageItem.layoutKey ~= drawnItem.layoutKey or pageItem.objectID ~= drawnItem.objectID
            or pageItem.width ~= drawnItem.width or pageItem.height ~= drawnItem.height then
            return false
        end
    end

    for index, sprite in ipairs(self.sprites) do
        pcall(applyAppearance, sprite, pageItems[index])
    end
    self.items = pageItems
    return true
end

-- Update every slot showing the changed stack.
function BankPageDisplay:UpdatePlaceholder(item, instanceKey)
    if item == nil then return false end
    local objectID = item.associatedObjectID
    if objectID == nil then return false end
    local quantity = item.associatedObjectQuantity
    local placeholder = quantity ~= nil and quantity <= 0
    local placeholderStyle = self.bankView.pageState:GetPlaceholderStyle()
    local appearance = {
        quantity = item.associatedObjectQuantity,
        quantityMode = placeholder and placeholderStyle.quantityMode
            or item.associatedObjectQuantityMode,
        alpha = placeholder and placeholderStyle.alpha or 1,
    }
    for index, drawnItem in ipairs(self.items) do
        local bankItem = drawnItem.bankItem
        if drawnItem.objectID == objectID and bankItem ~= nil and bankItem.instanceKey == instanceKey then
            pcall(applyAppearance, self.sprites[index], appearance)
        end
    end
    return placeholder
end

-- Find the item under the pointer; the last bound item wins overlaps.
function BankPageDisplay:EntryAtPosition(pageItems, pageArea, x, y)
    x = tonumber(x)
    y = tonumber(y)
    if x == nil or y == nil or pageItems == nil then return nil end
    local contentX, contentY = x - pageArea.contentX, y - pageArea.contentY + pageArea.scrollY
    for index = #pageItems, 1, -1 do
        local area = pageItems[index].area
        if area ~= nil and contentX >= area.x and contentX < area.x + area.width
            and contentY >= area.y and contentY < area.y + area.height then
            return pageItems[index]
        end
    end
    return nil
end

return BankPageDisplay
