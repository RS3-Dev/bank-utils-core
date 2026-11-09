-- Draw sidebar tabs; click to select, drag to reorder.

local Config = require("lib/core/config")
local BankControls = require("lib/ui/bank_controls")
local NativeUi = require("lib/ui/native_ui")
local Theme = require("lib/ui/theme")
local UICoordinates = require("lib/ui/ui_coordinates")

local SidebarTabRail = {}
SidebarTabRail.__index = SidebarTabRail

local TAB_SIZE = Config.SIDEBAR_TAB_WIDTH
local TAB_GAP = 4
local TAB_STEP = TAB_SIZE + TAB_GAP
local ICON_SIZE = 20
local ICON_INSET = math.floor((TAB_SIZE - ICON_SIZE) / 2)
local ARROW_HEIGHT = 20
local ARROW_ICON_SIZE = 16
local MAX_SLOTS = 24
local BACKDROP_SPRITE = 18035 -- RS3_CHILD_CONTENT_TILE
local DRAG_HOOK = Config.CORE_REF .. "_tab_drag"
-- Distance in game UI units before a press becomes a drag.
local DRAG_DISTANCE = 6
local GHOST_ALPHA = 0.88
local SOURCE_ALPHA = 0.4
local INDICATOR_HEIGHT = 2

-- Choose the visible tabs and arrow positions.
function SidebarTabRail.Layout(tabCount, activeIndex, firstTabIndex, height)
    local tabsWithoutArrows = math.min(MAX_SLOTS, math.floor((height + TAB_GAP) / TAB_STEP))
    if tabCount <= tabsWithoutArrows then
        return { first = 1, shown = tabCount, top = 0, arrows = false }
    end
    local arrowSpace = ARROW_HEIGHT + TAB_GAP
    local visibleTabCount = math.min(MAX_SLOTS,
        math.floor((height - arrowSpace * 2 + TAB_GAP) / TAB_STEP))
    -- If space is tight, show only the active tab.
    if visibleTabCount < 1 then
        return { first = activeIndex or 1, shown = math.min(1, tabCount), top = 0, arrows = false }
    end
    firstTabIndex = math.max(1, math.min(firstTabIndex or 1, tabCount - visibleTabCount + 1))
    if activeIndex ~= nil then
        if activeIndex < firstTabIndex then firstTabIndex = activeIndex end
        if activeIndex > firstTabIndex + visibleTabCount - 1 then firstTabIndex = activeIndex - visibleTabCount + 1 end
    end
    return { first = firstTabIndex, shown = visibleTabCount, top = arrowSpace, arrows = true }
end

function SidebarTabRail.new(parent, options)
    local self = setmetatable({
        x = options.x,
        y = options.y,
        height = options.height,
        onSelect = options.onSelect,
        onReorder = options.onReorder,
        gesture = nil,
        tabs = {},
        activeID = nil,
        first = 1,
        controls = {},
        buttons = {},
        signature = nil,
    }, SidebarTabRail)
    self.root = ui.Layer.new(parent)
    self.root:SetPos(self.x, self.y)
    self.root:SetSize(TAB_SIZE, self.height)
    self.root.clickthrough = false
    -- Keep tooltips outside the rail so they are not clipped.
    prettyui.Tooltip.registerContext(self.root, parent, function(target)
        return UICoordinates.relativePosition(target, parent)
    end)
    self.background = ui.Sprite.new(self.root)
    self.background:SetSize(TAB_SIZE, self.height)
    self.background.spriteID = BACKDROP_SPRITE
    self.background.isTiling = true
    self.background.clickthrough = true
    return self
end

-- End any press or drag before resizing.
function SidebarTabRail:SetHeight(height)
    if height == self.height then return end
    self:StopGesture()
    self.height = height
    self.root:SetSize(TAB_SIZE, height)
    self.background:SetSize(TAB_SIZE, height)
    -- Redraw because arrow positions depend on height.
    self.signature = nil
    self:SetTabs(self.tabs, self.activeID)
end

local function draggedID(self)
    local gesture = self.gesture
    return gesture ~= nil and gesture.dragging and gesture.tabID or nil
end

-- Ignore buttons replaced by a redraw or cancelled drag.
local function isCurrent(self, button)
    if draggedID(self) ~= nil and self.gesture.button == button then return true end
    for _, drawn in ipairs(self.buttons) do
        if drawn == button then return true end
    end
    return false
end

local function isOver(button, x, y)
    local root = button.root
    return x >= root.x and x < root.x + root.width and y >= root.y and y < root.y + root.height
end

function SidebarTabRail:IndexOf(tabID)
    for index, tab in ipairs(self.tabs) do
        if tab.id == tabID then return index end
    end
    return nil
end

-- Update tabs, keeping the active or moved tab visible.
function SidebarTabRail:SetTabs(tabs, activeID, focusID)
    if tabs ~= self.tabs then self:StopGesture() end
    local keptID = focusID or activeID
    if draggedID(self) ~= nil then keptID = nil end
    self.tabs = tabs
    self.activeID = activeID
    self.view = SidebarTabRail.Layout(#tabs, self:IndexOf(keptID), self.first, self.height)
    self.first = self.view.first
    self:Draw()
end

-- Scroll tabs without changing the selection.
function SidebarTabRail:Scroll(tabOffset)
    if self.view == nil or not self.view.arrows then return false end
    self.view = SidebarTabRail.Layout(#self.tabs, nil, self.first + tabOffset, self.height)
    if self.view.first == self.first then return false end
    self.first = self.view.first
    self:Draw()
    return true
end

-- Skip redraws when nothing changed.
local function describeVisibleTabs(self)
    local parts = { tostring(self.activeID), self.view.first, self.view.shown,
        tostring(self.view.arrows), tostring(draggedID(self)) }
    for _, tab in ipairs(self.tabs) do
        parts[#parts + 1] = tab.id .. "|" .. type(tab.icon) .. ":" .. tab.icon .. "|" .. (tab.tooltip or tab.label)
    end
    return table.concat(parts, "\n")
end

-- Remove drawn controls and end any press on them.
function SidebarTabRail:Clear()
    if draggedID(self) == nil then self.gesture = nil end
    for index = #self.controls, 1, -1 do
        pcall(function() self.controls[index]:Destroy() end)
    end
    self.controls = {}
    self.buttons = {}
    self.upArrow = nil
    self.downArrow = nil
end

local function addSelectionFrame(self, y)
    local frame = BankControls.frame(self.root, Theme.SELECTED_BORDER)
    frame:SetPos(0, y)
    frame:SetSize(TAB_SIZE, TAB_SIZE)
    frame:MoveToFront()
    self.controls[#self.controls + 1] = frame
end

-- Draw a copy of the dragged icon that lets clicks through.
local function newGhost(self, button, active)
    local frame = ui.Button.new(self.root)
    frame:SetSize(TAB_SIZE, TAB_SIZE)
    frame.text.content = ""
    frame.stylesheetID = NativeUi.styleID("BUTTON_PANEL")
    frame.alpha = GHOST_ALPHA
    frame.clickthrough = true
    local icon = ui.Sprite.new(self.root)
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon.spriteID = button.icon.spriteID
    icon.alpha = GHOST_ALPHA
    icon.clickthrough = true
    local ghost = { frame = frame, icon = icon }
    if active then
        ghost.outline = BankControls.frame(self.root, Theme.SELECTED_BORDER)
        ghost.outline:SetSize(TAB_SIZE, TAB_SIZE)
    end
    return ghost
end

function SidebarTabRail:Draw()
    local drawnTabsSummary = describeVisibleTabs(self)
    if drawnTabsSummary == self.signature then return end
    self:Clear()
    self.signature = drawnTabsSummary
    local visibleTabs = self.view
    local dragged = draggedID(self)
    for visibleTabIndex = 1, visibleTabs.shown do
        local tab = self.tabs[visibleTabs.first + visibleTabIndex - 1]
        local y = visibleTabs.top + (visibleTabIndex - 1) * TAB_STEP
        -- Select on release rather than press.
        local button = BankControls.button(self.root, nil, nil, {
            x = 0,
            y = y,
            size = TAB_SIZE,
            iconSize = ICON_SIZE,
            spriteName = type(tab.icon) == "string" and tab.icon or nil,
            spriteID = type(tab.icon) == "number" and tab.icon or nil,
            tooltip = tab.tooltip or tab.label,
            active = tab.id == self.activeID,
        })
        button.tabID = tab.id
        self:BindTab(button)
        self.buttons[#self.buttons + 1] = button
        self.controls[#self.controls + 1] = button
        if tab.id == self.activeID then addSelectionFrame(self, y) end
        -- Leave a faded copy in the original position.
        if tab.id == dragged then
            button.root.alpha = SOURCE_ALPHA
            button.icon.alpha = SOURCE_ALPHA
        end
    end
    if visibleTabs.arrows then self:DrawArrows() end
    self:RaiseDrag()
end

function SidebarTabRail:DrawArrows()
    local visibleTabs = self.view
    local function arrow(y, spriteName, tooltip, tabOffset, disabled)
        local button = BankControls.button(self.root, nil, function()
            self:Scroll(tabOffset)
        end, {
            x = 0,
            y = y,
            width = TAB_SIZE,
            height = ARROW_HEIGHT,
            iconSize = ARROW_ICON_SIZE,
            spriteName = spriteName,
            tooltip = tooltip,
            disabled = disabled,
        })
        self.controls[#self.controls + 1] = button
        return button
    end
    self.upArrow = arrow(0, "ARROW_UP", "More tabs above", -1, visibleTabs.first == 1)
    self.downArrow = arrow(self.height - ARROW_HEIGHT, "ARROW_DOWN",
        "More tabs below", 1, visibleTabs.first + visibleTabs.shown - 1 >= #self.tabs)
end

-- Handle presses and drags, ignoring events from replaced buttons.
function SidebarTabRail:BindTab(button)
    local function handle(action)
        return function()
            if isCurrent(self, button) then action(self, button) end
            return true
        end
    end
    local root = button.root
    root:Subscribe(ui.Hook.ONCLICK, DRAG_HOOK, handle(self.Press))
    -- The game can send either hold or drag events.
    root:Subscribe(ui.Hook.ONHOLD, DRAG_HOOK, handle(self.MoveGesture))
    root:Subscribe(ui.Hook.ONDRAG, DRAG_HOOK, handle(self.MoveGesture))
    -- Either release event ends the drag; ignore duplicates.
    root:Subscribe(ui.Hook.ONRELEASE, DRAG_HOOK, handle(self.Release))
    root:Subscribe(ui.Hook.ONDRAGCOMPLETE, DRAG_HOOK, handle(self.Release))
end

function SidebarTabRail:Pointer()
    local x, y = UICoordinates.interfaceMousePosition()
    if x == nil then return nil, nil end
    local originX, originY = UICoordinates.absolutePosition(self.root)
    return x - originX, y - originY
end

function SidebarTabRail:Contains(x, y)
    return x ~= nil and x >= 0 and x < TAB_SIZE and y >= 0 and y < self.height
end

-- Arrow direction: -1 above, 1 below, nil elsewhere.
function SidebarTabRail:ArrowAt(y)
    if not self.view.arrows then return nil end
    if y < ARROW_HEIGHT then return -1 end
    if y >= self.height - ARROW_HEIGHT then return 1 end
    return nil
end

-- Find the drop position and its visible gap.
function SidebarTabRail:DropTarget(y)
    local view = self.view
    if y < view.top or self:ArrowAt(y) ~= nil then return nil end
    -- Drop before the icon's top half, after its bottom half.
    local gap = math.floor((y - view.top - TAB_SIZE / 2) / TAB_STEP) + 1
    gap = math.max(0, math.min(view.shown, gap))
    local before = view.first + gap
    local from = self:IndexOf(self.gesture.tabID)
    if from == nil or before == from or before == from + 1 then return nil end
    return before, gap
end

-- A new press cancels a stuck drag.
function SidebarTabRail:Press(button)
    if self.gesture ~= nil and self.gesture.dragging then
        self:CancelDrag()
        return
    end
    local x, y = self:Pointer()
    self.gesture = { button = button, tabID = button.tabID, x = x, y = y, dragging = false }
end

-- Start dragging once the pointer moves far enough.
function SidebarTabRail:MoveGesture(button)
    local gesture = self.gesture
    if gesture == nil or gesture.button ~= button or gesture.x == nil then return end
    local x, y = self:Pointer()
    if x == nil then return end
    if not gesture.dragging then
        if math.abs(x - gesture.x) < DRAG_DISTANCE and math.abs(y - gesture.y) < DRAG_DISTANCE then
            return
        end
        self:BeginDrag()
    end
    self:UpdateDrag(x, y)
end

-- Keep the pressed button as an invisible cover so it still receives drag events.
function SidebarTabRail:BeginDrag()
    local gesture = self.gesture
    local button = gesture.button
    gesture.dragging = true
    for index, control in ipairs(self.controls) do
        if control == button then
            table.remove(self.controls, index)
            break
        end
    end
    button:StopHover()
    local cover = button.root
    -- Tooltip removal resets input settings; override them afterward.
    cover.clickthrough = false
    cover.alpha = 0
    cover:SetPos(0, 0)
    cover:SetSize(TAB_SIZE, self.height)
    button.icon.hidden = true
    -- Cancel outside the rail, where release events may not arrive.
    cover:Subscribe(ui.Hook.ONMOUSELEAVE, function()
        if not self:Contains(self:Pointer()) then self:CancelDrag() end
        return true
    end)
    gesture.ghost = newGhost(self, button, gesture.tabID == self.activeID)
    gesture.indicator = ui.Rectangle.new(self.root)
    gesture.indicator:SetSize(TAB_SIZE, INDICATOR_HEIGHT)
    gesture.indicator.fill = true
    gesture.indicator.rgba = Theme.SELECTED_BORDER
    gesture.indicator.clickthrough = true
    gesture.indicator.hidden = true
    self:Draw()
end

-- Move the drag preview; scroll once per arrow visit.
function SidebarTabRail:UpdateDrag(x, y)
    local gesture = self.gesture
    if not self:Contains(x, y) then
        self:CancelDrag()
        return
    end
    local arrow = self:ArrowAt(y)
    if arrow ~= gesture.arrow then
        gesture.arrow = arrow
        if arrow ~= nil then self:Scroll(arrow) end
    end
    local ghost = gesture.ghost
    local ghostY = math.max(0, math.min(self.height - TAB_SIZE, math.floor(y - TAB_SIZE / 2)))
    ghost.frame:SetPos(0, ghostY)
    ghost.icon:SetPos(ICON_INSET, ghostY + ICON_INSET)
    if ghost.outline ~= nil then ghost.outline:SetPos(0, ghostY) end
    local before, gap = self:DropTarget(y)
    gesture.indicator.hidden = before == nil
    if before ~= nil then
        local lineY = self.view.top + gap * TAB_STEP - (TAB_GAP + INDICATOR_HEIGHT) // 2
        gesture.indicator:SetPos(0, math.max(0, math.min(self.height - INDICATOR_HEIGHT, lineY)))
    end
end

-- Keep the drag preview above redrawn icons.
function SidebarTabRail:RaiseDrag()
    local gesture = self.gesture
    if gesture == nil or not gesture.dragging then return end
    local ghost = gesture.ghost
    gesture.button.root:MoveToFront()
    gesture.indicator:MoveToFront()
    ghost.frame:MoveToFront()
    ghost.icon:MoveToFront()
    if ghost.outline ~= nil then ghost.outline:MoveToFront() end
end

-- Release to select or drop; without a pointer, only selection works.
function SidebarTabRail:Release(button)
    local gesture = self.gesture
    if gesture == nil or gesture.button ~= button then return end
    local x, y = self:Pointer()
    if not gesture.dragging then
        self.gesture = nil
        if x ~= nil and not isOver(button, x, y) then return end
        if self.onSelect ~= nil then self.onSelect(gesture.tabID) end
        return
    end
    if not self:Contains(x, y) then
        self:CancelDrag()
        return
    end
    local before = self:DropTarget(y)
    self:StopGesture()
    if before ~= nil and self.onReorder ~= nil then
        local from = self:IndexOf(gesture.tabID)
        local tabIDs = {}
        for _, tab in ipairs(self.tabs) do tabIDs[#tabIDs + 1] = tab.id end
        table.remove(tabIDs, from)
        table.insert(tabIDs, before > from and before - 1 or before, gesture.tabID)
        self.onReorder(tabIDs, gesture.tabID)
    end
    -- Restore the icon if the move was not displayed.
    self:Draw()
end

-- Clear the gesture and report whether it was a drag.
function SidebarTabRail:StopGesture()
    local gesture = self.gesture
    self.gesture = nil
    if gesture == nil or not gesture.dragging then return false end
    local ghost = gesture.ghost
    -- The outline may be missing; keep it last so cleanup reaches every part.
    for _, part in ipairs({ ghost.frame, ghost.icon, gesture.indicator, gesture.button, ghost.outline }) do
        pcall(function() part:Destroy() end)
    end
    return true
end

function SidebarTabRail:CancelDrag()
    if self:StopGesture() then self:Draw() end
end

function SidebarTabRail:Destroy()
    self:StopGesture()
    self:Clear()
    if self.root ~= nil then prettyui.Tooltip.unregisterContext(self.root) end
    if self.root ~= nil then pcall(function() self.root:Destroy() end) end
    self.root = nil
    self.background = nil
end

return SidebarTabRail
