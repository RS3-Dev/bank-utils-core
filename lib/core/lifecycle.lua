-- Listen to host events for a started bank session and stop listening on shutdown

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

-- Tie the start and stop helpers to one session
function Lifecycle.new(session, options)
    return setmetatable({
        session = session,
        options = options or {},
    }, Lifecycle)
end

-- Subscribe to the session's events
function Lifecycle:Start()
    local session = self.session
    local options = self.options

    Event.ContentLayerReady.Subscribe(CONTENT_EVENT, function(event)
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
            -- A bank action can open or close the preset view, which no event reports
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

-- Stop the session's event listeners, remove the core panel, then restore the bank
function Lifecycle:Shutdown()
    local session = self.session
    if session.shutDown then return end
    session.shutDown = true

    -- Keep restoring the bank even if another shutdown step fails
    local function cleanup(label, action)
        local ok, message = pcall(action)
        if not ok then
            debugLog("Bank Core shutdown could not clean ", label, ": ", message)
        end
    end

    Event.MiniMenuReady.Unsubscribe(MENU_EVENT)
    Event.ContentLayerReady.Unsubscribe(CONTENT_EVENT)
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
    -- Saved last so a step that failed before saving is retried
    cleanup("bank window record", function() bankView.windowRecord:Save() end)
    session.layout = nil
end

return Lifecycle
