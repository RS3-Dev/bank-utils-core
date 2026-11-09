-- Connect custom drawings to real bank items.

local BankItemIndex = require("lib/bank/bank_item_index")
local debugLog = require("lib/core/debug_log").Write
local PageLayout = require("lib/features/extensions/page_layout")
local PlainData = require("lib/features/extensions/plain_data")
local UICoordinates = require("lib/ui/ui_coordinates")

local CustomView = {}
CustomView.__index = CustomView

-- Give this drawing access to Core until it closes or redraws.
function CustomView.new(parent, overlay, width, height, scrollY, actions)
    local self = setmetatable({
        parent = parent,
        width = width,
        height = height,
        actions = actions,
        -- Item links in creation order, also indexed by their UI component.
        bindings = {},
        byElement = {},
        bound = 0,
        nextID = 1,
        live = true,
        -- Update clickable areas when item links change.
        changed = false,
    }, CustomView)
    self.context = {
        parent = parent,
        overlay = overlay,
        width = width,
        height = height,
        scrollY = scrollY,
        BindItem = function(_, element, objectID) return self:Bind(element, objectID) end,
        UnbindItem = function(_, element) return self:Unbind(element) end,
        GetGeometry = function() return self:Geometry() end,
    }
    return self
end

-- Only accept components we can still read inside this view.
function CustomView:Contains(element)
    local elementType = type(element)
    if (elementType ~= "userdata" and elementType ~= "table") or element == self.parent then return false end
    local read, x = pcall(UICoordinates.relativePosition, element, self.parent)
    return read and x ~= nil
end

-- Restore whether clicks pass through this component.
local function restoreClickthrough(binding)
    if binding.clickthrough == true then return end
    pcall(function() binding.element.clickthrough = binding.clickthrough end)
end

-- Linking the same component again keeps its ID; a new item releases the old stack.
function CustomView:Bind(element, objectID)
    if not self.live then return nil, "stale" end
    local number = PlainData.ObjectNumber(objectID)
    if number == nil then return nil, "invalid", "objectID must be a whole number from 0 to 2147483647" end
    if not self:Contains(element) then
        return nil, "invalid", "element must be a component inside view.parent"
    end
    local binding = self.byElement[element]
    if binding ~= nil then
        if binding.objectID ~= number then
            binding.objectID = number
            self:Release(binding)
        end
        return binding.id
    end
    if self.bound >= PageLayout.MAX_ENTRIES then
        return nil, "invalid", "a view binds at most " .. PageLayout.MAX_ENTRIES .. " items"
    end
    binding = { id = self.nextID, element = element, objectID = number, active = true }
    self.nextID, self.bound = self.nextID + 1, self.bound + 1
    self.bindings[#self.bindings + 1] = binding
    self.byElement[element] = binding
    self.changed = true
    -- Let clicks reach Core beneath the drawing.
    pcall(function()
        binding.clickthrough = element.clickthrough
        if binding.clickthrough ~= true then element.clickthrough = true end
    end)
    return binding.id
end

-- Stop clicks now; update clickable areas on the next game update.
function CustomView:Release(binding)
    local entry = binding.entry
    binding.entry = nil
    if entry ~= nil then entry.area = nil end
    self.changed = true
    self.actions.release(binding)
end

function CustomView:Unbind(element)
    if not self.live then return false, "stale" end
    local binding = self.byElement[element]
    if binding == nil then return true end
    binding.active = false
    self.byElement[element] = nil
    self.bound = self.bound - 1
    restoreClickthrough(binding)
    self:Release(binding)
    return true
end

function CustomView:Geometry()
    if not self.live then return nil, "stale" end
    return self.actions.geometry()
end

-- Disable the old drawing and restore how its components handle clicks.
function CustomView:Revoke()
    if not self.live then return end
    self.live = false
    for _, binding in ipairs(self.bindings) do
        if binding.active then restoreClickthrough(binding) end
    end
    self.bindings, self.byElement = {}, {}
end

-- Match repeated items to stacks in the same order as grid pages.
function CustomView:Place(height)
    local bindings, slots, members, occurrences = {}, {}, {}, {}
    for _, binding in ipairs(self.bindings) do
        if binding.active then
            bindings[#bindings + 1] = binding
            local objectID = binding.objectID
            local occurrence = (occurrences[objectID] or 0) + 1
            occurrences[objectID] = occurrence
            local slot = { kind = "item", objectID = objectID, occurrence = occurrence, position = binding.id,
                layoutKey = BankItemIndex.LayoutKey(objectID, occurrence), binding = binding }
            slots[#slots + 1] = slot
            members[slot.layoutKey] = slot
        end
    end
    self.bindings, self.changed = bindings, false
    return { slots = slots, headings = {}, members = members, height = height }
end

-- Find the bottom edge of the lowest linked item image.
function CustomView:BoundBottom()
    local bottom = 0
    for _, binding in ipairs(self.bindings) do
        local read, _, y, _, height = pcall(UICoordinates.visibleArea, binding.element, self.parent)
        if read and y ~= nil then bottom = math.max(bottom, y + height) end
    end
    return bottom
end

-- Keep hidden item links, but remove links to components that no longer exist.
local function measure(self, entry, rootWidth, rootHeight)
    local binding = entry.binding
    if not binding.active or binding.objectID ~= entry.objectID then return false end
    local read, left, top, width, height = pcall(UICoordinates.visibleArea, binding.element, self.parent)
    if not read or (left == nil and not self:Contains(binding.element)) then
        debugLog("Bank Core unbound custom view item ", binding.id, ", which it can no longer find")
        self:Unbind(binding.element)
        return true
    end
    local right, bottom = nil, nil
    if left ~= nil then
        right, bottom = math.min(left + width, rootWidth), math.min(top + height, rootHeight)
        left, top = math.max(left, 0), math.max(top, 0)
    end
    local area = entry.area
    if left == nil or right <= left or bottom <= top then
        entry.area = nil
        return area ~= nil
    end
    if area ~= nil and area.x == left and area.y == top and area.width == right - left
        and area.height == bottom - top then
        return false
    end
    entry.area = { x = left, y = top, width = right - left, height = bottom - top }
    return true
end

function CustomView:Measure(entries)
    local rootWidth, rootHeight = self.parent.width, self.parent.height
    for _, entry in ipairs(entries) do
        if entry.binding ~= nil then
            entry.binding.entry = entry
            measure(self, entry, rootWidth, rootHeight)
        end
    end
end

-- Recheck item positions and report changed click areas.
function CustomView:Follow()
    local rootWidth, rootHeight = self.parent.width, self.parent.height
    local changed = false
    for _, binding in ipairs(self.bindings) do
        local entry = binding.entry
        if entry ~= nil and measure(self, entry, rootWidth, rootHeight) then changed = true end
    end
    return changed
end

return CustomView
