-- Start and stop the bank session's game event listeners.

local Config = require("lib/core/config")
local DebugLog = require("lib/core/debug_log")
local debugLog = DebugLog.Write

local Lifecycle = {}
Lifecycle.__index = Lifecycle

local MENU_EVENT = Config.CORE_REF .. "_menu"
local BANK_ACTION_EVENT = Config.CORE_REF .. "_bank_action"
local BANK_OPEN_EVENT = Config.CORE_REF .. "_bank_open"
local BANK_CLOSE_EVENT = Config.CORE_REF .. "_bank_close"
local BANK_UPDATE_EVENT = Config.CORE_REF .. "_bank_update"
local GAME_STATE_EVENT = Config.CORE_REF .. "_game_state"
local CONTENT_EVENT = Config.CORE_REF .. "_content"
local SETTINGS_EVENT = Config.CORE_REF .. "_settings"

-- Connect event handling to one bank session.
function Lifecycle.new(session, options)
    return setmetatable({
        session = session,
        options = options or {},
    }, Lifecycle)
end

-- Listen for game events and send them to the session.
function Lifecycle:Start()
    local session = self.session
    local options = self.options

    Event.ContentLayerReady.Subscribe(CONTENT_EVENT, function(event)
        session:CreateContentLayer(event.component)
    end)
    Event.SettingsLayerReady.Subscribe(SETTINGS_EVENT, function(event)
        session:CreateContentLayer(event.component)
    end)

    Event.GameStateChanged.Subscribe(GAME_STATE_EVENT, function(event)
        if event.newState == GameState.GAME then
            session:ResumeGameUI()
        else
            session:SuspendGameUI()
        end
    end)
    Event.MiniMenuReady.Subscribe(MENU_EVENT, function(event)
        session.menuRouter:HandleMenu(event)
    end)
    Event.MiniMenuEntrySelected.Subscribe(BANK_ACTION_EVENT, function(event)
        local selectedBankTab = options.bankViewSelection(event)
        if session.inGame and selectedBankTab ~= nil then
            local entry = event.entry
            session:StopFilterSettle()
            session.layout.itemHover:RestoreHoveredBankStack()
            if session.layout.shownPage ~= nil then session.layout:ShowPage(nil) end
            session.layout:SetNativeViewAll(selectedBankTab == "all")
            debugLog("Bank Core returned control to the native bank after ",
                entry.verbText, " ", entry.subjectText)
            return
        end
        if session.inGame and options.selectedEntryBelongsToBank(event) then
            -- Check for preset view changes here because they have no separate event.
            session.layout:Changed(false)
            if session.layout.shownPage ~= nil
                and not session.layout.itemHover:HasHoveredBankStack() then
                session:BeginFilterSettle()
            end
        end
    end)

    Event.InventoryAdded.Subscribe(BANK_OPEN_EVENT, function(event)
        if session.inGame and options.isBankInventoryEvent(event) then
            session:BeginLayoutRetry()
        end
    end)
    Event.InventoryRemoved.Subscribe(BANK_CLOSE_EVENT, function(event)
        if session.inGame and options.isBankInventoryEvent(event) then
            session:CloseBank()
        end
    end)
    Event.InventoryUpdated.Subscribe(BANK_UPDATE_EVENT, function(event)
        if session.inGame and options.isBankInventoryEvent(event) then
            session.layout:HandleInventoryUpdate()
        end
    end)
    if session.inGame and options.bankIsOpen() then session:BeginLayoutRetry() end

    debugLog("Bank Core started its bank session")
end

-- Stop event listeners, remove Core's panel, and undo bank window changes.
function Lifecycle:Shutdown()
    local session = self.session
    if session.shutDown then return end
    session.shutDown = true

    -- Catch cleanup errors so later steps can still restore the bank.
    local function cleanup(label, action)
        local ok, message = pcall(action)
        if not ok then
            debugLog("Bank Core shutdown could not clean ", label, ": ", message)
        end
    end

    Event.MiniMenuReady.Unsubscribe(MENU_EVENT)
    Event.ContentLayerReady.Unsubscribe(CONTENT_EVENT)
    Event.SettingsLayerReady.Unsubscribe(SETTINGS_EVENT)
    Event.MiniMenuEntrySelected.Unsubscribe(BANK_ACTION_EVENT)
    Event.GameStateChanged.Unsubscribe(GAME_STATE_EVENT)
    Event.InventoryAdded.Unsubscribe(BANK_OPEN_EVENT)
    Event.InventoryRemoved.Unsubscribe(BANK_CLOSE_EVENT)
    Event.InventoryUpdated.Unsubscribe(BANK_UPDATE_EVENT)
    session:StopFilterSettle()
    session:StopLayoutRetry()

    cleanup("core panel", function() session:DestroyPanel() end)
    local bankView = session.layout
    if bankView == nil then return end
    cleanup("bank layout", function() bankView:Restore() end)
    -- Save last so any unsaved window changes can be retried later.
    cleanup("bank window record", function() bankView.windowRecord:Save() end)
    session.layout = nil
end

return Lifecycle
