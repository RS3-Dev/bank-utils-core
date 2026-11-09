-- Show Core's debug logging and bank geometry settings.

local CorePanel = {}
CorePanel.__index = CorePanel

local CONTENT_HEIGHT = 186
local TEXT_COLOUR = 0xD7C9ADFF

function CorePanel.new(parent, options)
    local preferences = options ~= nil and options.preferences or {}
    local self = setmetatable({
        options = options or {},
        enableDebug = preferences.enableDebug == true,
        destroyed = false,
    }, CorePanel)
    self.view = prettyui.SimpleView.new(parent, {
        width = parent.width, height = parent.height,
        contentHeight = CONTENT_HEIGHT, scrollable = true, scrollStep = 32,
    })
    local content = self.view.content
    local contentWidth = content.width
    if contentWidth <= 0 then contentWidth = math.max(1, parent.width - 18) end
    local width = math.max(1, contentWidth - 24)
    local x = 12
    self.debugToggle = prettyui.CheckboxButton.new(content, {
        { text = "Enable debug", value = "enableDebug",
            tooltip = "Write bank core diagnostics to the client log" },
    }, {
        x = x, y = 12, width = width, colour = TEXT_COLOUR, selectionCursor = false,
        selectedValues = self.enableDebug and { "enableDebug" } or {},
        onChange = function(checkboxGroup) self:ChangeDebug(checkboxGroup:IsSelected("enableDebug")) end,
    })
    for _, option in ipairs(self.debugToggle.items or {}) do
        option.label.font = id.Font.MUSEO_SANS_11PT_REGULAR
    end
    self.resetGeometry = prettyui.SimpleButton.new(content, "Reset geometry", function()
        self:ResetGeometry()
    end, { x = x, y = 48, width = math.min(width, 180), height = 32 })
    prettyui.Text.new(content, {
        text = "Clear saved bank geometry, then close and reopen the bank.",
        x = x, y = 88, width = width, height = 40,
        font = id.Font.MUSEO_SANS_11PT_REGULAR, colour = TEXT_COLOUR, maxLines = 2,
    })
    self.status = prettyui.Text.new(content, {
        text = "", x = x, y = 134, width = width, height = 40,
        font = id.Font.MUSEO_SANS_11PT_REGULAR,
        colour = 0xE57373FF, maxLines = 2,
    })
    self.status.hidden = true
    return self
end

function CorePanel:ShowResult(saved, reason, defaultMessage)
    self.status.rgba = 0xE57373FF
    self.status.content = saved and "" or tostring(reason or defaultMessage)
    self.status.hidden = saved == true
end

-- Show when the reset will take effect.
function CorePanel:ResetGeometry()
    if self.destroyed then return false end
    local cleared, reason = self.options.onResetGeometry()
    self:ShowResult(cleared, reason, "Could not reset bank geometry.")
    if cleared then
        self.status.content = "Geometry cleared. Close and reopen the bank."
        self.status.rgba = TEXT_COLOUR
        self.status.hidden = false
    end
    return cleared, reason
end

-- Undo the checkbox change if saving fails.
function CorePanel:ChangeDebug(enabled)
    if self.destroyed then return false end
    local saved, reason = self.options.onChangeDebug(enabled)
    if saved then
        self.enableDebug = enabled
    else
        self.debugToggle:SetSelected("enableDebug", self.enableDebug, false)
    end
    self:ShowResult(saved, reason, "Could not save the setting.")
    return saved, reason
end

-- Remove controls before the game removes their parent.
function CorePanel:Destroy()
    if self.destroyed then return end
    self.destroyed = true
    self.debugToggle:Destroy()
    self.resetGeometry:Destroy()
    self.view:Destroy()
end

return CorePanel
