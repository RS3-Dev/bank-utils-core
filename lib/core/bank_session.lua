-- Manage the bank session, plugins, events, and settings.

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

-- Check less often as the game's bank updates settle.
local function shouldCheckBankItems(tick)
    return tick <= 4
        or tick == 8
        or tick == 16
        or tick == 32
        or tick == 64
        or tick == 96
        or tick == BANK_ITEMS_SETTLE_TICKS
end

local function bankIsOpen()
    return ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__BANK_WINDOW) ~= nil
end

local function isBankInventoryEvent(event)
    return event.inv.id == Config.BANK_INVENTORY_ID
end

-- Check the control's parents too.
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

local function selectedEntryBelongsToBank(event)
    local entry = event.entry
    local componentData = entry.componentData
    local component = componentData and componentData.component
    return component ~= nil and belongsToBank(component)
end

-- Match bank tab actions regardless of case or formatting.
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

-- Create the session; Start adds event listeners.
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

function BankSession:StopLayoutRetry()
    Event.Logic.Unsubscribe(BANK_ATTACH_RETRY_EVENT)
    self.layoutRetryTicks = 0
    self.layoutReadyTicks = 0
end

function BankSession:StopFilterSettle()
    Event.Logic.Unsubscribe(BANK_ITEMS_SETTLE_EVENT)
    self.filterSettleTicks = 0
end

-- Refresh the page while bank updates settle.
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

-- Wait for several ready checks before adding controls.
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

function BankSession:SavePreference(key, value)
    if self.shutDown then return false, "Bank Core is not running." end
    local preferences = {}
    for name, current in pairs(self.preferences) do preferences[name] = current end
    preferences[key] = value
    if not CorePreferences.save(preferences) then return false, "Could not save the setting." end
    self.preferences = preferences
    return true
end

function BankSession:SetDebugPreference(enabled)
    local saved, reason = self:SavePreference("enableDebug", enabled == true)
    if not saved then return false, reason end
    DebugLog.SetEnabled(self.preferences.enableDebug)
    return true
end

-- Undo window changes before forgetting them; reconnect on the next bank opening.
function BankSession:ResetGeometry()
    if self.shutDown then return false, "Bank Core is not running." end
    local ok, message = pcall(function() self:CloseBank() end)
    if not ok then
        debugLog("Bank Core could not detach for a geometry reset: ", tostring(message))
        return false, "Could not reset geometry. Close the bank and try again."
    end
    local cleared, reason = self.layout.windowRecord:Clear()
    if not cleared then return false, reason end
    self.layout.lastBankWindowMeasurements = nil
    return true
end

function BankSession:CreateContentLayer(parent)
    if self.shutDown then return end
    self:DestroyPanel()
    self.panel = CorePanel.new(parent, {
        preferences = self.preferences,
        onChangeDebug = function(enabled) return self:SetDebugPreference(enabled) end,
        onResetGeometry = function() return self:ResetGeometry() end,
    })
end

function BankSession:DestroyPanel()
    if self.panel ~= nil then self.panel:Destroy() end
    self.panel = nil
end

function BankSession:SuspendGameUI()
    self.inGame = false
    self:StopLayoutRetry()
    self:StopFilterSettle()
    self.pluginPages:BankClosed("game_state")
    self.layout:Restore()
end

-- Attach if the bank is already open.
function BankSession:ResumeGameUI()
    if self.shutDown then return end
    self.inGame = true
    self.layout:Changed(false)
    if bankIsOpen() then self:BeginLayoutRetry() end
end

function BankSession:CloseBank()
    self:StopLayoutRetry()
    self:StopFilterSettle()
    self.pluginPages:BankClosed("closed")
    self.layout:Restore()
end

function BankSession:Start()
    DebugLog.SetEnabled(self.preferences.enableDebug)
    self.lifecycle:Start()
end

-- Close plugins before stopping the session.
function BankSession:Shutdown()
    if self.shutDown then return end
    -- Continue shutdown even if page cleanup fails.
    local function close(label, action)
        local ok, message = pcall(action)
        if not ok then debugLog("Bank Core shutdown could not close ", label, ": ", message) end
    end
    -- Let the page clean up before removing its bank view.
    close("extension pages", function() self.pluginPages:Close() end)
    self.lifecycle:Shutdown()
end

return BankSession
