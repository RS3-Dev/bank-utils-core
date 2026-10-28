-- Connect the bank view, plugin API, client events, menus and settings
-- Only the core entry point calls Start, so tests can build sessions safely

local BankWindowRecord = require("lib/bank/bank_window_record")
local Config = require("lib/core/config")
local CorePanel = require("lib/core/core_panel")
local CorePreferences = require("lib/core/core_preferences")
local DebugLog = require("lib/core/debug_log")
local PluginPages = require("lib/features/extensions/plugin_pages")
local Lifecycle = require("lib/core/lifecycle")
local MiniMenuRouter = require("lib/core/mini_menu_router")
local PublicAPI = require("lib/core/public_api")
local BankView = require("lib/bank/bank_view")
local debugLog = DebugLog.Write

local BankSession = {}
BankSession.__index = BankSession

local BANK_ATTACH_RETRY_EVENT = Config.CORE_REF .. "_layout_retry"
local BANK_ITEMS_SETTLE_EVENT = Config.CORE_REF .. "_filter_settle"
local BANK_ITEMS_SETTLE_TICKS = 128
local BANK_READY_TICKS_REQUIRED = 8
local BANK_ATTACH_RETRY_TICKS = 120

-- Space out checks while the client's bank updates settle
local function shouldCheckBankItems(tick)
    return tick <= 4
        or tick == 8
        or tick == 16
        or tick == 32
        or tick == 64
        or tick == 96
        or tick == BANK_ITEMS_SETTLE_TICKS
end

-- Check whether the native bank window is currently mounted
local function bankIsOpen()
    return ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__BANK_WINDOW) ~= nil
end

-- Recognize updates for the bank inventory rather than other containers
local function isBankInventoryEvent(event)
    return event.inv.id == Config.BANK_INVENTORY_ID
end

-- Walk up a component's parents to tell bank menu actions from other windows
local function belongsToBank(component)
    local current = component
    local depth = 0
    while current ~= nil and depth < 32 do
        if current.interfaceID == Config.BANK_INTERFACE_ID then return true end
        current = current.parent
        depth = depth + 1
    end
    return false
end

-- Find the bank item represented by native right-click menu entries
local function bankItemFromMenu(miniMenu)
    if miniMenu == nil or miniMenu.entries == nil then return nil end

    for _, entry in ipairs(miniMenu.entries) do
        local componentData = entry.componentData
        local object = componentData and componentData.objConfig
        local component = componentData and componentData.component
        if object ~= nil and component ~= nil and belongsToBank(component) then
            return {
                id = object.id,
                name = object.name,
                categoryID = component.categoryID,
                dynamicID = component.dynamicID,
            }
        end
    end

    return nil
end

-- Check whether the selected menu action came from a bank component
local function selectedEntryBelongsToBank(event)
    local entry = event.entry
    local componentData = entry.componentData
    local component = componentData and componentData.component
    return component ~= nil and belongsToBank(component)
end

-- Recognize All Items and native tab choices by menu verb, ignoring markup and case
local function bankViewSelection(event)
    if not selectedEntryBelongsToBank(event) then return nil end
    local actionText = string.lower(event.entry.verbText
        :gsub("<[^>]->", "")
        :match("^%s*(.-)%s*$"))
    if actionText == "view all" then return "all" end
    if actionText == "view"
        or actionText == "view tab"
        or string.match(actionText, "^view tab %d+$") ~= nil then
        return "tab"
    end
    return nil
end

-- Create the bank session before subscribing to client events
-- Options may replace the saved preferences and bank window record
function BankSession.new(options)
    options = options or {}
    local session = setmetatable({
        preferences = options.preferences or CorePreferences.load(),
        layout = nil,
        panel = nil,
        lifecycle = nil,
        menuRouter = nil,
        layoutRetryTicks = 0,
        layoutReadyTicks = 0,
        filterSettleTicks = 0,
        inGame = Player.IsAvailable(),
        shutDown = false,
    }, BankSession)
    session.layout = BankView.new({
        windowRecord = options.windowRecord or BankWindowRecord.load(),
        readRailOrder = function() return session.preferences.railOrder end,
        saveRailOrder = function(railOrder) return session:SavePreference("railOrder", railOrder) end,
    })
    session.pluginPages = PluginPages.new(session.layout, {
        isInGame = function() return session.inGame end,
        bankIsOpen = bankIsOpen,
    })
    session.menuRouter = MiniMenuRouter.new(session, {
        bankIsOpen = bankIsOpen,
        bankItemFromMenu = bankItemFromMenu,
    })
    session.publicAPI = PublicAPI.new(session.pluginPages, session.menuRouter)
    session.lifecycle = Lifecycle.new(session, {
        bankIsOpen = bankIsOpen,
        isBankInventoryEvent = isBankInventoryEvent,
        bankViewSelection = bankViewSelection,
        selectedEntryBelongsToBank = selectedEntryBelongsToBank,
    })
    return session
end

-- End bank readiness checks and reset the retry counters
function BankSession:StopLayoutRetry()
    Event.Logic.Unsubscribe(BANK_ATTACH_RETRY_EVENT)
    self.layoutRetryTicks = 0
    self.layoutReadyTicks = 0
end

-- End delayed bank checks after a bank action
function BankSession:StopFilterSettle()
    Event.Logic.Unsubscribe(BANK_ITEMS_SETTLE_EVENT)
    self.filterSettleTicks = 0
end

-- Recheck the displayed page while bank updates settle
function BankSession:BeginFilterSettle()
    if not self.inGame or self.layout.shownPage == nil then return end
    self:StopFilterSettle()
    self.filterSettleTicks = 0
    Event.Logic.Subscribe(BANK_ITEMS_SETTLE_EVENT, function()
        if not self.inGame
            or not bankIsOpen()
            or self.layout.shownPage == nil then
            self:StopFilterSettle()
            return
        end
        self.filterSettleTicks = self.filterSettleTicks + 1
        if shouldCheckBankItems(self.filterSettleTicks)
            and not self.layout:ShownPageIsInSync() then
            self.layout:RefreshShownPage()
        end
        if self.filterSettleTicks >= BANK_ITEMS_SETTLE_TICKS then
            self:StopFilterSettle()
        end
    end)
end

-- Wait several ready ticks before attaching controls to an opened bank
function BankSession:BeginLayoutRetry()
    if not self.inGame then return end
    self:StopLayoutRetry()
    self.layoutRetryTicks = BANK_ATTACH_RETRY_TICKS
    Event.Logic.Subscribe(BANK_ATTACH_RETRY_EVENT, function()
        if not self.inGame then
            self:StopLayoutRetry()
            return
        end
        if not bankIsOpen() then
            self.layoutReadyTicks = 0
        elseif self.layout:IsReady() then
            self.layoutReadyTicks = self.layoutReadyTicks + 1
        else
            self.layoutReadyTicks = 0
        end
        if self.layoutReadyTicks >= BANK_READY_TICKS_REQUIRED
            and self.layout:Apply() then
            self:StopLayoutRetry()
            return
        end
        self.layoutRetryTicks = self.layoutRetryTicks - 1
        if self.layoutRetryTicks <= 0 then self:StopLayoutRetry() end
    end)
end

-- Save one changed preference and keep the others as they are
function BankSession:SavePreference(key, value)
    if self.shutDown then return false, "Bank Core is not running." end
    local preferences = {}
    for name, current in pairs(self.preferences) do preferences[name] = current end
    preferences[key] = value
    if not CorePreferences.save(preferences) then return false, "Could not save the setting." end
    self.preferences = preferences
    return true
end

-- Save the debug preference and apply it to logging
function BankSession:SetDebugPreference(enabled)
    local saved, reason = self:SavePreference("enableDebug", enabled == true)
    if not saved then return false, reason end
    DebugLog.SetEnabled(self.preferences.enableDebug)
    return true
end

-- Draw Core's debug setting on the host's content layer
function BankSession:CreateContentLayer(parent)
    if self.shutDown then return end
    self:DestroyPanel()
    self.panel = CorePanel.new(parent, {
        preferences = self.preferences,
        onChangeDebug = function(enabled) return self:SetDebugPreference(enabled) end,
    })
end

-- Remove Core's settings from the host content layer
function BankSession:DestroyPanel()
    if self.panel ~= nil then self.panel:Destroy() end
    self.panel = nil
end

-- Stop bank checks and restore the window when leaving the game
function BankSession:SuspendGameUI()
    self.inGame = false
    self:StopLayoutRetry()
    self:StopFilterSettle()
    self.pluginPages:BankClosed("game_state")
    self.layout:Restore()
end

-- Restore in-game state and attach controls if the bank is open
function BankSession:ResumeGameUI()
    if self.shutDown then return end
    self.inGame = true
    self.layout:Changed(false)
    if bankIsOpen() then self:BeginLayoutRetry() end
end

-- Leave the bank when it closes: stop checks and restore the bank
function BankSession:CloseBank()
    self:StopLayoutRetry()
    self:StopFilterSettle()
    self.pluginPages:BankClosed("closed")
    self.layout:Restore()
end

-- Start bank event handling with the saved debug preference
function BankSession:Start()
    DebugLog.SetEnabled(self.preferences.enableDebug)
    self.lifecycle:Start()
end

-- Close the extension API, stop events, and restore the bank
-- Failed steps are logged so the bank is still restored
function BankSession:Shutdown()
    if self.shutDown then return end
    -- Run one step that must not stop the rest of shutdown
    local function close(label, action)
        local ok, message = pcall(action)
        if not ok then debugLog("Bank Core shutdown could not close ", label, ": ", message) end
    end
    -- The page API closes first so a shown page leaves normally
    close("extension pages", function() self.pluginPages:Close() end)
    self.lifecycle:Shutdown()
end

return BankSession
