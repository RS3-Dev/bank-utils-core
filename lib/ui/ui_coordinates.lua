-- Match mouse positions to the game interface at any display scale.

local UICoordinates = {}

local MAX_PARENT_DEPTH = 32
local POINTER_HOOK = "bankcore_pointer_scale"
local calibratedPointerScale, gameScaleAtCalibration

local function interfaceScale()
    local scaleOption = game and game.options and game.options.InterfaceScale
    local scalePercent = scaleOption and tonumber(scaleOption.setting) or 100
    return scalePercent > 0 and scalePercent / 100 or 1
end

-- Compare mouse and control positions to measure the game's display scale.
function UICoordinates.calibratePointer(component, x, y)
    if type(x) ~= "number" or type(y) ~= "number" then return false end
    local mousePixels, componentPosition = Mouse.GetPosition(), component.xyGlobal
    if mousePixels == nil or componentPosition == nil then return false end
    local interfaceX, interfaceY = componentPosition.x + x, componentPosition.y + y
    if math.abs(interfaceX) < 32 or math.abs(interfaceY) < 32 then return false end
    local scaleX, scaleY = mousePixels.x / interfaceX, mousePixels.y / interfaceY
    if scaleX < 0.5 or scaleX > 4 or scaleY < 0.5 or scaleY > 4
        or math.abs(scaleX - scaleY) > math.max(scaleX, scaleY) * 0.1 then return false end
    calibratedPointerScale = math.abs(interfaceX) >= math.abs(interfaceY) and scaleX or scaleY
    gameScaleAtCalibration = interfaceScale()
    return true
end

-- Update the mouse position measurement while hovering this control.
function UICoordinates.trackPointer(component)
    component:Subscribe(ui.Hook.ONMOUSEREPEAT, POINTER_HOOK, function(component, x, y)
        UICoordinates.calibratePointer(component, x, y)
        return false
    end)
end

-- Stop tracking when the component changes shape.
function UICoordinates.untrackPointer(component)
    component:Unsubscribe(ui.Hook.ONMOUSEREPEAT, POINTER_HOOK)
end

function UICoordinates.relativePosition(component, ancestor)
    local x, y, parentComponent, parentCount = 0, 0, component, 0
    while parentComponent ~= nil and parentComponent ~= ancestor and parentCount < MAX_PARENT_DEPTH do
        x = x + parentComponent.x
        y = y + parentComponent.y
        parentComponent = parentComponent.parent
        parentCount = parentCount + 1
    end
    if parentComponent ~= ancestor then return nil, nil end
    return x, y
end

-- Find the part of a control still visible inside the given container.
function UICoordinates.visibleArea(component, root)
    if component.visibleGlobal == false then return nil end
    local left, top, right, bottom = 0, 0, component.width, component.height
    local node, depth = component, 0
    while node ~= root do
        if node.hidden == true or node.visible == false or depth >= MAX_PARENT_DEPTH then return nil end
        local parent = node.parent
        if parent == nil then return nil end
        local x, y = node.x, node.y
        if parent ~= root then x, y = x - (parent.scrollX or 0), y - (parent.scrollY or 0) end
        left, top, right, bottom = left + x, top + y, right + x, bottom + y
        if parent ~= root then
            left, top = math.max(left, 0), math.max(top, 0)
            right, bottom = math.min(right, parent.width), math.min(bottom, parent.height)
        end
        if right <= left or bottom <= top then return nil end
        node, depth = parent, depth + 1
    end
    if root.hidden == true or root.visible == false then return nil end
    return left, top, right - left, bottom - top
end

function UICoordinates.absolutePosition(component)
    local x, y, parentComponent, parentCount = 0, 0, component, 0
    while parentComponent ~= nil and parentCount < MAX_PARENT_DEPTH do
        x = x + parentComponent.x
        y = y + parentComponent.y
        parentComponent = parentComponent.parent
        parentCount = parentCount + 1
    end
    return x, y
end

-- Adjust mouse positions to match the game's display scale.
function UICoordinates.interfaceMousePosition()
    -- Mouse positions do not include the game's display scaling.
    local position = Mouse.GetPosition()
    if position == nil then return nil, nil end
    local scale = interfaceScale()
    if gameScaleAtCalibration == scale then scale = calibratedPointerScale end
    return position.x / scale, position.y / scale
end

return UICoordinates
