-- Draw the sidebar's icon strip and content column.

local Config = require("lib/core/config")
local BankControls = require("lib/ui/bank_controls")
local NativeUi = require("lib/ui/native_ui")
local Theme = require("lib/ui/theme")
local SidebarTabRail = require("lib/ui/sidebar_tab_rail")
local UICoordinates = require("lib/ui/ui_coordinates")

local SidebarFrame = {}

local CONTENT_OFFSET = Config.SIDEBAR_TAB_WIDTH + Config.SIDEBAR_TAB_GAP

-- BankView calls the icon strip tabRail and the content column rail.
function SidebarFrame.Create(bankView, parent, height, x, y, actions)
    bankView.tabRail = SidebarTabRail.new(parent, {
        x = x,
        y = y,
        height = height,
        onSelect = actions.onSelect,
        onReorder = actions.onReorder,
    })
    bankView.rail = ui.Layer.new(parent)
    bankView.rail:SetPos(x + CONTENT_OFFSET, y)
    bankView.rail:SetSize(Config.SIDEBAR_COLUMN_WIDTH - 8, height)
    bankView.rail.clickthrough = false
    prettyui.Tooltip.registerContext(bankView.rail, parent, function(tooltipTarget)
        return UICoordinates.relativePosition(tooltipTarget, parent)
    end)
    -- Keep the background behind plugin controls.
    bankView.railBackground = ui.Sprite.new(bankView.rail)
    bankView.railBackground:SetSize(Config.SIDEBAR_COLUMN_WIDTH - 8, height)
    bankView.railBackground.spriteID = NativeUi.PANEL_BACKGROUND_SPRITE
    bankView.railBackground.isTiling = true
    bankView.railBackground.clickthrough = true

    -- A positive outline size draws the border inside the panel.
    bankView.railFrame = BankControls.frame(bankView.rail, Theme.FRAME)
    bankView.railFrame:SetSize(0, 0, 1.0, 1.0)
end

function SidebarFrame.Resize(bankView, height)
    bankView.tabRail:SetHeight(height)
    bankView.rail:SetSize(Config.SIDEBAR_COLUMN_WIDTH - 8, height)
    bankView.railBackground:SetSize(Config.SIDEBAR_COLUMN_WIDTH - 8, height)
end

function SidebarFrame.RaiseEdges(bankView)
    if bankView.railFrame ~= nil then bankView.railFrame:MoveToFront() end
end

function SidebarFrame.Destroy(bankView)
    if bankView.tabRail ~= nil then bankView.tabRail:Destroy() end
    if bankView.rail ~= nil then prettyui.Tooltip.unregisterContext(bankView.rail) end
    if bankView.rail ~= nil then pcall(function() bankView.rail:Destroy() end) end
    bankView.tabRail = nil
    bankView.rail = nil
    bankView.railBackground = nil
    bankView.railFrame = nil
end

return SidebarFrame
