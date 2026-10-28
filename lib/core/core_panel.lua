-- Draw Core's own settings: debug logging

local CorePanel = {}
CorePanel.__index = CorePanel

local CONTENT_HEIGHT = 94
local TEXT_COLOUR = 0xD7C9ADFF

-- Mount the debug toggle and save status
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
    self.status = prettyui.Text.new(content, {
        text = "", x = x, y = 48, width = width, height = 40,
        font = id.Font.MUSEO_SANS_11PT_REGULAR,
        colour = 0xE57373FF, maxLines = 2,
    })
    self.status.hidden = true
    return self
end

-- Show a save failure, or hide the status after a success
function CorePanel:ShowResult(saved, reason, defaultMessage)
    self.status.content = saved and "" or tostring(reason or defaultMessage)
    self.status.hidden = saved == true
end

-- Save the debug preference, restoring the checkbox if the save is rejected
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

-- Release controls before the host's content layer goes away
-- The toggle releases its own tooltips; the status text goes with the view
function CorePanel:Destroy()
    if self.destroyed then return end
    self.destroyed = true
    self.debugToggle:Destroy()
    self.view:Destroy()
end

return CorePanel
