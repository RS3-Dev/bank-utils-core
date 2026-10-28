-- Build buttons and frames with the native bank appearance

local NativeUi = require("lib/ui/native_ui")
local UICoordinates = require("lib/ui/ui_coordinates")

local BankControls = {}

local NativeButton = {}
NativeButton.__index = NativeButton

-- Build a native-style button with decorative children and one action
-- Without an action, the caller handles the button's input itself
function BankControls.button(parent, content, action, options)
    local self = setmetatable({
        action = action,
        active = options.active == true,
        disabled = options.disabled == true,
        spriteName = options.spriteName,
    }, NativeButton)
    local x, y = options.x or 0, options.y or 0
    local width = options.width or options.size or 24
    local height = options.height or options.size or 24

    self.root = ui.Button.new(parent)
    self.root:SetPos(x, y)
    self.root:SetSize(width, height)
    self.root.text.content = self.spriteName == nil and tostring(content or "") or ""
    if action ~= nil then
        self.root:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
            if not self.disabled then self.action(self, self.active) end
        end)
    end

    -- Hovering also measures the pointer's scale, so a press here needs no earlier hover elsewhere
    UICoordinates.trackPointer(self.root)
    self.root:Subscribe(ui.Hook.ONMOUSEOVER, function(component, hoverX, hoverY)
        UICoordinates.calibratePointer(component, hoverX, hoverY)
        self.hovered = true
        self:_UpdateState()
        return true
    end)
    self.root:Subscribe(ui.Hook.ONMOUSELEAVE, function()
        self.hovered = false
        self:_UpdateState()
        return true
    end)

    -- ui.Button cannot hold children, so its decorations sit beside it and let clicks through
    if self.spriteName ~= nil then
        self.sprites = prettyui.Sprites.SPRITE_BUTTONS[self.spriteName]
        self.icon = ui.Sprite.new(parent)
        local iconSize = options.iconSize or math.max(12, height - 8)
        self.icon:SetPos(x + math.floor((width - iconSize) / 2),
            y + math.floor((height - iconSize) / 2))
        self.icon:SetSize(iconSize, iconSize)
        self.icon.clickthrough = true
    end

    prettyui.Tooltip.bind(self, self.root, parent, options.tooltip)
    self:_UpdateState()
    return self
end

-- Refresh the button's input, label, icon, and selection look
function NativeButton:_UpdateState()
    if self.root == nil then return end
    self.root.enabled = not self.disabled
    self.root.clickthrough = self.disabled
    self.root.stylesheetID = NativeUi.styleID("BUTTON_PANEL")
    self.root.text.rgba = self.active and 0xF2C66DFF or 0xE7D7B0FF
    if self.icon ~= nil and self.sprites ~= nil then
        if self.disabled then
            self.icon.spriteID = self.sprites.disabled or self.sprites.neutral
        elseif self.active or self.hovered then
            self.icon.spriteID = self.sprites.active or self.sprites.neutral
        else
            self.icon.spriteID = self.sprites.neutral
        end
    end
end

-- Stop the hover look, tooltip and pointer measuring, as when the button changes shape
function NativeButton:StopHover()
    prettyui.Tooltip.unbind(self)
    self.root:Unsubscribe(ui.Hook.ONMOUSEOVER)
    self.root:Unsubscribe(ui.Hook.ONMOUSELEAVE)
    UICoordinates.untrackPointer(self.root)
end

-- Remove the tooltip and destroy the button and its decorations
function NativeButton:Destroy()
    prettyui.Tooltip.unbind(self)
    if self.icon ~= nil then self.icon:Destroy() end
    if self.root ~= nil then self.root:Destroy() end
    self.root = nil
    self.icon = nil
end

-- Draw a one-pixel frame that lets clicks through
function BankControls.frame(parent, rgba)
    local frame = ui.Rectangle.new(parent)
    frame.fill = false
    frame.outlineThickness = 1
    frame.rgba = rgba
    frame.clickthrough = true
    return frame
end

return BankControls
