-- Manage registered plugins, their sidebar columns, and the displayed page

local BankInterface = require("lib/core/bank_interface")
local BankItemIndex = require("lib/bank/bank_item_index")
local Config = require("lib/core/config")
local debugLog = require("lib/core/debug_log").Write
local ExtensionMounts = require("lib/features/extensions/extension_mounts")
local PageLayout = require("lib/features/extensions/page_layout")
local PlainData = require("lib/features/extensions/plain_data")

local PluginPages = {}
PluginPages.__index = PluginPages

local TAB_PREFIX = "__bankutils_ext_tab:"
local REFRESH_EVENT = Config.CORE_REF .. "_extension_refresh"
local NOTIFY_EVENT = Config.CORE_REF .. "_extension_notify"
local REGISTRATION_FIELDS = { id = true, name = true, icon = true, column = true, customView = true,
    onClose = true, onBankItems = true, onBankClose = true }
local CALLBACKS = { "customView", "onClose", "onBankItems", "onBankClose" }
local PAGE_FIELDS = { title = true, rows = true }
local ID_LENGTH = 64
local TEXT_LENGTH = 80

local hasOnlyFields = PlainData.HasOnlyFields

-- Check a registration and keep Core's own copy
local function readRegistration(description)
    if type(description) ~= "table" or not hasOnlyFields(description, REGISTRATION_FIELDS) then
        return nil, "a registration is a table of id, name, icon, column, customView, onClose, onBankItems,"
            .. " and onBankClose"
    end
    local id = rawget(description, "id")
    if not PlainData.ID(id, ID_LENGTH) then
        return nil, "id must be 1 to 64 letters, digits, '.', '_' or '-'"
    end
    local registration = { id = id, name = PlainData.Label(rawget(description, "name"), TEXT_LENGTH),
        icon = rawget(description, "icon") }
    if registration.name == nil then return nil, "name must be 1 to " .. TEXT_LENGTH .. " characters" end
    if registration.icon ~= nil and not PlainData.KnownIcon(registration.icon) then
        return nil, "icon must be a PrettyUI sprite-button name"
    end
    if rawget(description, "column") ~= nil then
        if registration.icon == nil then return nil, "a column needs an icon" end
        local callbacks, problem = ExtensionMounts.Read(rawget(description, "column"))
        if callbacks == nil then return nil, problem end
        registration.column = callbacks
    end
    for _, name in ipairs(CALLBACKS) do
        local action = rawget(description, name)
        if action ~= nil and type(action) ~= "function" then return nil, name .. " must be a function" end
        registration[name] = action
    end
    return registration
end

-- Run a plugin's custom view and check the content height it returns
-- A height is nil or a number from 0 to the height limit for a page
local function drawView(customView, view)
    local height = customView(view)
    if height ~= nil and (type(height) ~= "number" or height ~= height or height < 0
        or height > PageLayout.MAX_HEIGHT) then
        error("customView must return nil or a height from 0 to " .. PageLayout.MAX_HEIGHT, 0)
    end
    return height
end

-- Check a page and keep Core's own copy
local function readPage(description)
    if type(description) ~= "table" or not hasOnlyFields(description, PAGE_FIELDS) then
        return nil, "a page is a table of title and rows"
    end
    local title = PlainData.Label(rawget(description, "title"), TEXT_LENGTH)
    if title == nil then return nil, "title must be 1 to " .. TEXT_LENGTH .. " characters" end
    local rows, problem = PageLayout.ReadRows(rawget(description, "rows"), TEXT_LENGTH)
    if rows == nil then return nil, problem end
    return { title = title, rows = rows }
end

-- Connect registered plugins to the bank view
function PluginPages.new(bankView, options)
    local self = setmetatable({
        layout = bankView,
        isInGame = options.isInGame,
        bankIsOpen = options.bankIsOpen,
        owners = {},
        -- Defer rail changes until running column and view callbacks finish
        pluginCallbacks = 0,
        publishPending = false,
        closed = false,
    }, PluginPages)
    -- Give this service unique event names so a reload cannot remove another service's listeners
    local eventSuffix = ":" .. string.match(tostring(self), "%x+$")
    self.refreshEvent = REFRESH_EVENT .. eventSuffix
    self.notifyEvent = NOTIFY_EVENT .. eventSuffix
    bankView.onChange = function() self:Notify() end
    return self
end

-- Report whether a page change or a column or view callback is running now
function PluginPages:IsChanging()
    return self.layout.pageTransitions > 0 or self.pluginCallbacks > 0
end

-- Report whether the bank is open with Core attached
function PluginPages:BankReady()
    return self.isInGame() and self.bankIsOpen() and self.layout.active
end

-- Report whether the bank shows its All Items tab
function PluginPages:ViewAll()
    local bankView = self.layout
    return bankView.nativeViewAll or bankView:DetectNativeViewAll() == true
end

-- Explain why a page cannot be shown now, or return nil when it can
function PluginPages:OpenBlocker()
    if not self:BankReady() or BankInterface.Get(BankInterface.ITEMS) == nil then
        return "bank_closed"
    end
    if self:IsChanging() then return "busy" end
    if self.layout:IsPresetViewOpen() then return "preset_open" end
    if not self:ViewAll() then return "not_all_items" end
    return nil
end

-- Check that an extension still belongs to this live service
function PluginPages:IsLive(extension)
    return not self.closed and self.owners[extension.id] == extension
end

-- Find the page the bank shows now when it is the extension's, or nil
function PluginPages:ShownPage(extension)
    local page = self.layout.shownPage
    return page ~= nil and page.owner == extension and page or nil
end

-- Give the sidebar rail an entry for every extension with an icon, by ID
-- The sidebar arranges them in the player's order
-- An entry without a column opens the extension's page instead of being selected
function PluginPages:PublishTabs()
    -- A column may be running inside the sidebar rebuild, so publish next tick
    if self.pluginCallbacks > 0 then
        self.publishPending = true
        self:QueueRefresh()
        return
    end
    self.publishPending = false
    local extensionIDs = {}
    for extensionID, extension in pairs(self.owners) do
        if extension.icon ~= nil then extensionIDs[#extensionIDs + 1] = extensionID end
    end
    table.sort(extensionIDs)
    local tabs = {}
    for _, extensionID in ipairs(extensionIDs) do
        local extension = self.owners[extensionID]
        tabs[#tabs + 1] = { id = TAB_PREFIX .. extension.id, extensionID = extension.id,
            label = extension.name, tooltip = extension.name, icon = extension.icon, mount = extension.mount,
            open = extension.mount == nil and function() self:Open(extension) end or nil }
    end
    self.layout:SetExtensionTabs(tabs)
end

-- Run a bank page change, logging a failure the bank has already recovered from
function PluginPages:Transition(action)
    local ok, result = pcall(action)
    if not ok then debugLog("Bank Core could not change the extension page: ", result) end
    return ok, result
end

-- Finish held-back work on the next logic tick
function PluginPages:QueueRefresh()
    if self.closed then return end
    Event.Logic.Subscribe(self.refreshEvent, function()
        Event.Logic.Unsubscribe(self.refreshEvent)
        self:RunQueued()
    end)
end

-- Finish work held back while a column callback or a page change ran
function PluginPages:RunQueued()
    if self.publishPending then self:PublishTabs() end
    self:LeaveRemovedPage()
    local page = self.layout.shownPage
    if page ~= nil and page.owner.redrawPending then self:Redraw(page.owner) end
end

-- Return the bank to its native view when the shown page's extension is gone
function PluginPages:LeaveRemovedPage()
    local page = self.layout.shownPage
    if page == nil or self:IsLive(page.owner) then return end
    -- A running page change finishes first; the next tick leaves the page
    if self:IsChanging() then
        self:QueueRefresh()
        return
    end
    self:Transition(function() self.layout:ShowPage(nil) end)
end

-- Register an extension, replacing an earlier one with the same ID
function PluginPages:RegisterOwner(description)
    if self.closed then return nil, "stopped" end
    if self.pluginCallbacks > 0 then return nil, "busy" end
    local registration, problem = readRegistration(description)
    if registration == nil then return nil, "invalid", problem end
    -- The replacement publishes the rail once, so a selected column stays selected
    local previous = self.owners[registration.id]
    if previous ~= nil then self:DisposeOwner(previous, true) end
    local extension = { id = registration.id, name = registration.name, icon = registration.icon, callbacks = registration,
        page = nil, opens = 0, shown = false, heardItems = nil, bankClosed = false }
    if registration.column ~= nil then extension.mount = ExtensionMounts.new(self, extension, registration.column) end
    -- A custom view can open at once; Core draws its page by running the plugin's callback
    local customView = registration.customView
    if customView ~= nil then
        extension.page = { owner = extension, key = extension.opens, title = extension.name,
            draw = function(view) return self:RunPluginCallback(extension, "customView", drawView, customView, view) end }
    end
    self.owners[extension.id] = extension
    -- The rail changes next tick, so no column mounts before the plugin has its extension
    if extension.icon ~= nil or (previous ~= nil and previous.icon ~= nil) then
        self.publishPending = true
        self:QueueRefresh()
    end
    -- Notify the new extension when bank items become readable
    self:Notify()
    return extension
end

-- Remove an extension with its rail entry and shown page; repeating does nothing
-- A shown page is emptied at once, so a rebuild before the bank leaves it draws nothing
-- A replaced extension leaves publishing the rail to its replacement
function PluginPages:DisposeOwner(extension, replaced)
    if not self:IsLive(extension) then return true end
    self.owners[extension.id] = nil
    local page = self:ShownPage(extension)
    if page ~= nil then page.title, page.rows, page.draw = "", {}, nil end
    if extension.icon ~= nil and not replaced then self:PublishTabs() end
    self:LeaveRemovedPage()
    return true
end

-- Draw the extension's page again in place, or next tick during a page change
-- A failed redraw returns the bank to its own view
function PluginPages:Redraw(extension)
    extension.redrawPending = false
    if self:ShownPage(extension) == nil or not self:IsLive(extension) then return end
    if self:IsChanging() then
        extension.redrawPending = true
        self:QueueRefresh()
        return
    end
    self:Transition(function() return self.layout:ShowPage(extension.page) end)
end

-- Keep the extension's page, drawing it again next tick when the bank shows it
-- Opening before that tick draws the latest page and cancels the queued redraw
-- An extension that draws a custom view has no page to set
function PluginPages:SetPage(extension, description)
    if not self:IsLive(extension) then return false, "stale" end
    if extension.callbacks.customView ~= nil then
        return false, "invalid", "this extension draws a custom view; register it without customView to set a page"
    end
    local page, problem = readPage(description)
    if page == nil then return false, "invalid", problem end
    -- Keep the current opening number so a redraw retains its scroll position
    page.owner, page.key = extension, extension.opens
    extension.page = page
    if self:ShownPage(extension) ~= nil then
        extension.redrawPending = true
        self:QueueRefresh()
    end
    return true
end

-- Draw the extension's shown page or view again next tick; a hidden one is left alone
-- Refused while a page change or callback runs, so a view cannot keep redrawing itself
function PluginPages:Refresh(extension)
    if not self:IsLive(extension) then return false, "stale" end
    if self:IsChanging() then return false, "busy" end
    if self:ShownPage(extension) ~= nil then
        extension.redrawPending = true
        self:QueueRefresh()
    end
    return true
end

-- Show the extension's page in place of whatever the bank shows, or explain why not
function PluginPages:Open(extension)
    if not self:IsLive(extension) then return false, "stale" end
    if extension.page == nil then return false, "no_page" end
    local blockedReason = self:OpenBlocker()
    if blockedReason ~= nil then return false, blockedReason end
    -- Each opening is a new view that starts at the top, and draws the current page itself
    extension.redrawPending = false
    extension.opens = extension.opens + 1
    extension.page.key = extension.opens
    local ok, shown = self:Transition(function() return self.layout:ShowPage(extension.page) end)
    -- A half-built page is not left showing; the bank is back in its native view
    if not ok or not shown then return false, "failed" end
    extension.shown = true
    return true
end

-- Return the bank to its own view when it shows the extension's page
function PluginPages:ClosePage(extension)
    if not self:IsLive(extension) then return false, "stale" end
    if self:ShownPage(extension) == nil then return true end
    if self:IsChanging() then return false, "busy" end
    if not self:Transition(function() self.layout:ShowPage(nil) end) then return false, "failed" end
    return true
end

-- Report whether the bank shows the extension's page
function PluginPages:IsOpen(extension)
    return self:IsLive(extension) and self:ShownPage(extension) ~= nil
end

-- Explain why bank items cannot be read now, or return nil when they can
function PluginPages:ItemsBlocker()
    if not self:BankReady() then return "bank_closed" end
    if not self:ViewAll() then return "not_all_items" end
    return nil
end

-- Copy bank stacks in View All order with their quantities
-- A displayed page uses the bank positions saved before Core moved any stacks
function PluginPages:BankItems(extension)
    if not self:IsLive(extension) then return nil, "stale" end
    local blockedReason = self:ItemsBlocker()
    if blockedReason ~= nil then return nil, blockedReason end
    local bankView = self.layout
    local entries = nil
    if bankView.shownPage ~= nil then
        -- Wait for a fresh bank snapshot after an inventory change
        local pageState = bankView.pageState
        entries = pageState.active and not pageState.stale and pageState.bankItems or nil
    else
        local itemLayer = BankInterface.Find(BankInterface.ITEMS)
        entries = itemLayer ~= nil and BankItemIndex.Collect(itemLayer) or nil
    end
    if entries == nil then return nil, "busy" end
    local items = {}
    for index, entry in ipairs(entries) do
        items[index] = { objectID = entry.objectID, quantity = math.max(0, entry.quantity or 0) }
    end
    return items
end

-- Report the open bank window's screen bounds and grid columns, or nil
function PluginPages:BankBounds(extension)
    if not self:IsLive(extension) or not self:BankReady() then return nil end
    local bankWindowMeasurements = self.layout:ReadBankWindowMeasurements()
    if bankWindowMeasurements == nil then return nil end
    local bounds = bankWindowMeasurements.bounds
    return { x = bounds.x, y = bounds.y, width = bounds.width, height = bounds.height,
        columns = bankWindowMeasurements.columns }
end

-- Run an extension's column or view callback, catching and always logging an error
-- Returns whether it finished and what it returned
function PluginPages:RunPluginCallback(extension, name, action, ...)
    if action == nil then return true end
    self.pluginCallbacks = self.pluginCallbacks + 1
    local ok, result = pcall(action, ...)
    self.pluginCallbacks = self.pluginCallbacks - 1
    if not ok and type(log) == "function" then
        log("Bank Core extension ", extension.id, " ", name, " failed: ", tostring(result))
    end
    return ok, result
end

-- Tell every extension next tick that the bank Core attached to has closed
-- Called before the bank is restored; a second call for the same bank does nothing
function PluginPages:BankClosed()
    if self.closed or not self.layout.active then return end
    for _, extension in pairs(self.owners) do extension.bankClosed = true end
    self:Notify()
end

-- Schedule one notification pass for the next tick
function PluginPages:Notify()
    if self.closed then return end
    Event.Logic.Subscribe(self.notifyEvent, function()
        Event.Logic.Unsubscribe(self.notifyEvent)
        self:DeliverChanges()
    end)
end

-- Call one plugin without letting its error stop other callbacks
local function callExtensionCallback(extension, name)
    local action = extension.callbacks[name]
    if action == nil then return end
    local ok, message = pcall(action)
    if not ok then debugLog("Bank Core extension ", extension.id, " ", name, " failed: ", message) end
end

-- Report whether the bank's items can be read now and are not waiting for a reread
function PluginPages:ItemsReadable()
    return self:ItemsBlocker() == nil and not self.layout.pageState.stale
        and (self.layout.shownPage ~= nil or BankInterface.Find(BankInterface.ITEMS) ~= nil)
end

-- Tell one extension what changed since it last heard: the bank closing, its page closing,
-- then its items
-- Disposing or replacing the extension ends the delivery
function PluginPages:DeliverTo(extension)
    if extension.bankClosed then
        extension.bankClosed = false
        callExtensionCallback(extension, "onBankClose")
        if not self:IsLive(extension) then return end
    end
    -- Skip the close notification if the extension has already reopened its page
    local shown = self:ShownPage(extension) ~= nil
    if extension.shown and not shown then
        extension.shown = false
        callExtensionCallback(extension, "onClose")
        if not self:IsLive(extension) then return end
    elseif shown then
        extension.shown = true
    end
    if not self:ItemsReadable() then return end
    local bankView = self.layout
    local itemsVersion = bankView.windowSession .. ":" .. bankView.itemsGeneration
    if itemsVersion ~= extension.heardItems then
        extension.heardItems = itemsVersion
        callExtensionCallback(extension, "onBankItems")
    end
end

-- Deliver changes to every live extension, ordered by ID
function PluginPages:DeliverChanges()
    local extensionIDs = {}
    for extensionID in pairs(self.owners) do extensionIDs[#extensionIDs + 1] = extensionID end
    table.sort(extensionIDs)
    local owners = {}
    for index, extensionID in ipairs(extensionIDs) do owners[index] = self.owners[extensionID] end
    for _, extension in ipairs(owners) do
        if self:IsLive(extension) then self:DeliverTo(extension) end
    end
end

-- Drop every extension at once, leave a shown page, and refuse all later calls
-- Clear the rail once so shutdown cannot mount another plugin's column
-- Extensions hear at once that their page and the bank closed
function PluginPages:Close()
    if self.closed then return end
    local bankOpen = self.layout.active
    local page = self.layout.shownPage
    local shownExtension = page ~= nil and page.owner or nil
    local extensionsToClose = {}
    for _, extension in pairs(self.owners) do extensionsToClose[#extensionsToClose + 1] = extension end
    table.sort(extensionsToClose, function(a, b) return a.id < b.id end)
    self.owners = {}
    if page ~= nil then page.title, page.rows, page.draw = "", {}, nil end
    self:PublishTabs()
    self:LeaveRemovedPage()
    Event.Logic.Unsubscribe(self.refreshEvent)
    Event.Logic.Unsubscribe(self.notifyEvent)
    self.closed = true
    self.layout = nil
    for _, extension in ipairs(extensionsToClose) do
        if extension.shown or extension == shownExtension then callExtensionCallback(extension, "onClose") end
        if bankOpen or extension.bankClosed then callExtensionCallback(extension, "onBankClose") end
    end
end

return PluginPages
