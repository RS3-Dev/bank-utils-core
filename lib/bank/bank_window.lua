-- Resize and position the bank to make room for the sidebar

local Config = require("lib/core/config")
local BankInterface = require("lib/core/bank_interface")
local BankGrid = require("lib/engine/bank_grid")
local UICoordinates = require("lib/ui/ui_coordinates")
local DebugLog = require("lib/core/debug_log")
local debugLog = DebugLog.Write

-- Always log window failures.
local function report(...)
    if type(log) == "function" then log(...) end
end

local BankWindow = {}

local STATIC = {
    all = 0,
    background = 1,
    content = 2,
    border = 311,
    help = 312,
    close = 317,
}

local FULL_WIDTH_OVERLAYS = { 314, 315, 316, 318, 319, 330, 331, 340 }
local CENTRED_DIALOGS = { 320, 332 }
local BANK_ITEMS_STATIC_ID = BankInterface.ITEMS
local BANK_ITEMS_CONTAINER_STATIC_ID = BankInterface.ITEMS_CONTAINER
local ALL_TAB_BUTTON_STATIC_ID = 166
local ALL_TAB_BUTTON_CATEGORY_ID = 0
local ALL_TAB_BUTTON_DYNAMIC_ID = 0
local CANCEL_CONTROL_STATIC_ID = 257 -- BANK__BOTTOM_PANEL_CANCEL
local CANCEL_LABEL_CATEGORY_ID = 0
local CANCEL_LABEL_DYNAMIC_ID = 9
local PRESET_CLOSE_BUTTON_STATIC_ID = 86 -- BANK__PRESET_CLOSE
local ALL_TAB_SELECTED_SPRITE_ID = 8070 -- BANK_TABS_HORIZONTAL_1
local ALL_TAB_UNSELECTED_SPRITE_ID = 8069 -- BANK_TABS_HORIZONTAL_0
-- The game has no window move or resize events.
local BANK_WINDOW_CHECK_TICKS = 10

-- Round down to keep expansion on whole pixels.
local function halfWidth(value)
    return math.floor(value / 2)
end

local component = BankInterface.Get

-- Find a native child that may disappear between views
local function dynamicComponent(staticID, categoryID, dynamicID)
    local ok, value = pcall(function()
        return ui.Interfaces:GetComponent(
            Config.BANK_INTERFACE_ID,
            staticID,
            categoryID,
            dynamicID
        )
    end)
    return ok and value or nil
end

local MAX_PARENT_DEPTH = 32

-- Handles for the same component may compare unequal.
local function samePart(firstComponent, secondComponent)
    return firstComponent ~= nil and secondComponent ~= nil and (firstComponent == secondComponent or tostring(firstComponent) == tostring(secondComponent))
end

local function readPartLayout(value)
    local position, size = value.position, value.size
    return {
        x = position.x, y = position.y,
        xParent = position.xParentPc, yParent = position.yParentPc,
        xSelf = position.xSelfPc, ySelf = position.ySelfPc,
        width = size.width, height = size.height,
        widthParent = size.widthParentPc, heightParent = size.heightParentPc,
    }
end

-- Adjust position and width without changing anchors.
local function offsetPart(value, x, width)
    local partLayout = readPartLayout(value)
    if width ~= 0 then
        value:SetSize(partLayout.width + width, partLayout.height, partLayout.widthParent, partLayout.heightParent)
    end
    if x ~= 0 then
        value:SetPos(partLayout.x + x, partLayout.y, partLayout.xParent, partLayout.yParent, partLayout.xSelf, partLayout.ySelf)
    end
end

local function round(value)
    return math.floor(value + 0.5)
end

-- Widen the bank, keeping right-edge controls aligned and dialogs centred.
local function expansionChanges(parts, width)
    local expansionPlan, halfAddedWidth = {}, halfWidth(width)
    local function add(slot, value, x, change)
        if value ~= nil then
            expansionPlan[#expansionPlan + 1] = { slot = slot, value = value, x = x, width = change }
        end
    end
    -- Move the host frame when present; otherwise move the window layer.
    if parts.host ~= nil and not samePart(parts.host, parts.all) then
        add("host", parts.host, -halfAddedWidth, width)
        add("all", parts.all, 0, width)
    else
        add("all", parts.all, -halfAddedWidth, width)
    end
    add("background", parts.background, 0, width)
    add("border", parts.border, 0, width)
    for key, value in pairs(parts.overlays) do add("overlay" .. key, value, 0, width) end
    for key, value in pairs(parts.dialogs) do add("dialog" .. key, value, halfAddedWidth, 0) end
    add("content", parts.content, width, 0)
    add("help", parts.help, width, 0)
    add("close", parts.close, width, 0)
    return expansionPlan
end

-- Include width inherited from the parent.
local function widthChange(value, expansionPlan, depth)
    if value == nil or depth > MAX_PARENT_DEPTH then return 0 end
    for _, change in ipairs(expansionPlan) do
        if samePart(change.value, value) then return change.width end
    end
    local parentWidthRatio = readPartLayout(value).widthParent
    if parentWidthRatio == 0 then return 0 end
    return parentWidthRatio * widthChange(value.parent, expansionPlan, depth + 1)
end

-- Avoid adding width already inherited from the parent.
local function expandWindow(parts, width)
    local expansionPlan = expansionChanges(parts, width)
    local appliedOffsets = {}
    for _, change in ipairs(expansionPlan) do
        local partLayout = readPartLayout(change.value)
        local parentWidthChange = widthChange(change.value.parent, expansionPlan, 1)
        appliedOffsets[#appliedOffsets + 1] = {
            slot = change.slot,
            value = change.value,
            width = round(change.width - partLayout.widthParent * parentWidthChange),
            x = round(change.x - partLayout.xParent * parentWidthChange - partLayout.xSelf * change.width),
        }
    end
    for _, entry in ipairs(appliedOffsets) do offsetPart(entry.value, entry.x, entry.width) end
    return appliedOffsets
end

-- Undo Core's offsets while preserving the player's resizing.
local function undoExpansion(appliedOffsets)
    local allPartsRestored = true
    for _, entry in ipairs(appliedOffsets) do
        local ok, message = pcall(function() offsetPart(entry.value, -entry.x, -entry.width) end)
        if not ok then
            allPartsRestored = false
            debugLog("Bank Core could not restore the bank's ", entry.slot, ": ", tostring(message))
        end
    end
    return allPartsRestored
end

local function findPartByName(parts, slot)
    local overlay = string.match(slot, "^overlay(.+)$")
    if overlay ~= nil then return parts.overlays[tonumber(overlay) or overlay] end
    local dialog = string.match(slot, "^dialog(.+)$")
    if dialog ~= nil then return parts.dialogs[tonumber(dialog) or dialog] end
    return parts[slot]
end

-- Use the frame that received the saved expansion.
local function findFrameRecord(record)
    local layer = nil
    for _, entry in ipairs(record.parts) do
        if entry.slot == "host" then return entry end
        if entry.slot == "all" then layer = entry end
    end
    return layer
end

-- Look up a fresh frame in case its handle changed.
local function findCurrentFrame(slot)
    local ok, value = pcall(function()
        if slot == "host" then
            return ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__BANK_WINDOW)
        end
        return component(STATIC.all)
    end)
    return ok and value or nil
end

-- Old handles may no longer respond.
local function tryReadPartLayout(value)
    local ok, partLayout = pcall(readPartLayout, value)
    if not ok or type(partLayout.x) ~= "number" or type(partLayout.width) ~= "number" then return nil end
    return partLayout
end

-- Undo only the saved expansion still present; retry failures on the next attach.
function BankWindow.RecoverExpansion(parts, record)
    if record == nil then return true end
    local frame = findFrameRecord(record)
    local appliedOffsets = {}
    for _, entry in ipairs(record.parts) do
        local value = not entry.restored and findPartByName(parts, entry.slot) or nil
        local partLayout = value ~= nil and tryReadPartLayout(value) or nil
        if partLayout ~= nil and (entry.x ~= 0 or entry.width ~= 0)
            and partLayout.width == entry.expandedWidth
            and (entry == frame or partLayout.x == entry.expandedX) then
            appliedOffsets[#appliedOffsets + 1] = { slot = entry.slot, value = value, x = entry.x,
                width = entry.width, entry = entry, nativeX = partLayout.x - entry.x }
        elseif entry == frame and partLayout ~= nil
            and partLayout.width ~= entry.expandedWidth - entry.width then
            debugLog("Bank Core kept a bank window width set while it was off: ", partLayout.width)
        end
    end
    if #appliedOffsets > 0 then
        report("Bank Core taking a kept sidebar expansion of ", record.sidebarWidth,
            " pixels off the bank")
        undoExpansion(appliedOffsets)
    end
    local recovered = true
    for _, change in ipairs(appliedOffsets) do
        local entry = change.entry
        local value = entry == frame and findCurrentFrame(entry.slot) or change.value
        local partLayout = value ~= nil and tryReadPartLayout(value) or nil
        if partLayout ~= nil and partLayout.x == change.nativeX
            and partLayout.width == entry.expandedWidth - entry.width then
            entry.restored = true
        else
            recovered = false
        end
    end
    if not recovered then
        report("Bank Core could not take a kept sidebar expansion off the bank; will retry")
        return false
    end
    return true
end

function BankWindow:LogBankWindowMeasurements(reason)
    if not DebugLog.IsEnabled() then return end
    local parts = self.components
    local options = game and game.options
    local scale = options and options.InterfaceScale
    debugLog("Bank Core bank window ", reason, ": expanded ", tostring(self.expanded),
        ", interface scale ", tostring(scale and scale.setting))
    local list = {
        { "host", parts.host }, { "all", parts.all }, { "background", parts.background },
        { "border", parts.border }, { "content", parts.content }, { "help", parts.help },
        { "close", parts.close },
        { "viewport", BankInterface.Find(BANK_ITEMS_CONTAINER_STATIC_ID) },
        { "items", BankInterface.Find(BANK_ITEMS_STATIC_ID) },
    }
    for _, entry in ipairs(list) do
        local name, value = entry[1], entry[2]
        local ok, line = pcall(function()
            local partLayout = readPartLayout(value)
            local anchorDetails = string.format("pos %s,%s parent %s,%s self %s,%s size %sx%s parent %s,%s",
                partLayout.x, partLayout.y, partLayout.xParent, partLayout.yParent, partLayout.xSelf, partLayout.ySelf,
                partLayout.width, partLayout.height, partLayout.widthParent, partLayout.heightParent)
            -- Compare both position sources during scaling and scrolling.
            local x, y = UICoordinates.absolutePosition(value)
            local global = value.xyGlobal
            return string.format("%s,%s %sx%s; %s; screen %s,%s API %s,%s",
                value.x, value.y, value.width, value.height, anchorDetails, x, y, global.x, global.y)
        end)
        debugLog("Bank Core bank window ", name, ": ", ok and line or "unreadable")
    end
end

function BankWindow:RebuildPageInput()
    self.itemHover:RemovePageInput()
    if self.shownPage ~= nil then self.itemHover:BuildPageInput() end
end

-- Remember the player's window size while the sidebar is open
function BankWindow:CaptureFrame()
    local record = self.windowRecord.value
    local entry = record ~= nil and findFrameRecord(record) or nil
    local value = entry ~= nil and findPartByName(self.components, entry.slot) or nil
    if value == nil then return end
    local partLayout = tryReadPartLayout(value)
    if partLayout == nil then
        debugLog("Bank Core could not read the bank window frame; keeping its last width")
        return
    end
    entry.expandedX, entry.expandedWidth = partLayout.x, partLayout.width
end

-- Find window parts by their saved slot names.
local function lookUpParts()
    local parts = {
        host = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__BANK_WINDOW),
        overlays = {},
        dialogs = {},
    }
    local bank = ui.Interfaces:GetInterface(Config.BANK_INTERFACE_ID)
    if bank == nil then return parts end
    for slot, staticID in pairs(STATIC) do parts[slot] = bank:GetComponent(staticID) end
    for _, staticID in ipairs(FULL_WIDTH_OVERLAYS) do
        parts.overlays[staticID] = bank:GetComponent(staticID)
    end
    for _, staticID in ipairs(CENTRED_DIALOGS) do
        parts.dialogs[staticID] = bank:GetComponent(staticID)
    end
    return parts
end

local function frameOffsets(entry)
    local frame = findCurrentFrame(entry.slot)
    return frame ~= nil and tryReadPartLayout(frame) or nil
end

-- Undo sidebar expansion, keeping player resizes and the recovery record.
function BankWindow:RestoreBankWindowSizeAndPosition()
    BankWindow.CaptureFrame(self)
    local allPartsRestored = undoExpansion(self.expansion or {})
    self.expansion = nil
    local record = self.windowRecord.value
    if record == nil then return end
    local entry = findFrameRecord(record)
    local partLayout = frameOffsets(entry)
    -- Use fresh handles to undo any remaining expansion.
    if partLayout ~= nil and partLayout.width == entry.expandedWidth then
        local ok, message = pcall(function()
            allPartsRestored = BankWindow.RecoverExpansion(lookUpParts(), record)
        end)
        if not ok then debugLog("Bank Core could not look up the bank's parts: ", message) end
        -- Check offsets again on the next attach.
        for _, part in ipairs(record.parts) do part.restored = nil end
        partLayout = frameOffsets(entry)
    end
    if partLayout == nil then
        debugLog("Bank Core could not read the bank window frame after restoring it")
    elseif not allPartsRestored or partLayout.width ~= entry.expandedWidth - entry.width then
        report("Bank Core could not confirm the bank window lost the sidebar's width: ",
            partLayout.width, " for ", entry.expandedWidth - entry.width)
    end
end

-- Widen the bank for the sidebar and record what it added
function BankWindow:WidenBankForSidebar()
    self.expansion = expandWindow(self.components, Config.SIDEBAR_WIDTH)
    local record = { sidebarWidth = Config.SIDEBAR_WIDTH, parts = {} }
    for _, entry in ipairs(self.expansion) do
        local partLayout = readPartLayout(entry.value)
        record.parts[#record.parts + 1] = { slot = entry.slot, x = entry.x, width = entry.width,
            expandedX = partLayout.x, expandedWidth = partLayout.width }
    end
    self.windowRecord.value = record
end

function BankWindow:ReadBankWindowMeasurements()
    if not self.active then return nil end
    local frame = self.components.host or self.components.all
    -- Window parts may disappear between checks.
    local itemLayer = BankInterface.Find(BANK_ITEMS_STATIC_ID)
    local itemWidth = itemLayer ~= nil and itemLayer.width or 0
    if frame == nil or itemWidth <= 0 then return nil end
    local x, y = UICoordinates.absolutePosition(frame)
    -- Use the column count of the displayed layout.
    local columns = self.shownPage ~= nil and self.pageState.columns
        or BankGrid.ColumnCount(itemWidth)
    return {
        columns = columns,
        bounds = { x = x, y = y, width = frame.width,
            height = frame.height },
    }
end

local function describeBankWindowMeasurements(bankWindowMeasurements)
    if bankWindowMeasurements == nil then return "closed" end
    local bounds = bankWindowMeasurements.bounds
    return table.concat({ bankWindowMeasurements.columns, bounds.x, bounds.y, bounds.width, bounds.height }, " ")
end

function BankWindow:WatchBankWindow()
    -- Bank panels can change without events, even when no plugin page is open.
    self.onChange()
    if self.expanded then
        local content = BankInterface.Find(STATIC.content)
        local height = content ~= nil and content.height or 0
        if height > 0 then self:ResizeSidebar(height) end
    end
    local signature = describeBankWindowMeasurements(self:ReadBankWindowMeasurements())
    if signature == self.lastBankWindowMeasurements then return end
    self.lastBankWindowMeasurements = signature
    -- Save to disk on bank close or shutdown.
    if self.expanded then self:CaptureFrame() end
    self:LogBankWindowMeasurements("changed")
end

function BankWindow:StartBankWindowWatch()
    self:StopBankWindowWatch()
    self.windowSession = self.windowSession + 1
    -- Give each bank opening its own listener.
    self.bankWindowWatch = Config.CORE_REF .. "_bank_window_watch:"
        .. string.match(tostring(self), "%x+$") .. ":" .. self.windowSession
    local ticks = 0
    Event.Logic.Subscribe(self.bankWindowWatch, function()
        ticks = ticks + 1
        if ticks < BANK_WINDOW_CHECK_TICKS then return end
        ticks = 0
        self:WatchBankWindow()
    end)
end

function BankWindow:StopBankWindowWatch()
    if self.bankWindowWatch == nil then return end
    self.windowSession = self.windowSession + 1
    Event.Logic.Unsubscribe(self.bankWindowWatch)
    self.bankWindowWatch = nil
end

-- Wait for visible bank parts with usable sizes.
function BankWindow:IsReady()
    if self.active then return true end
    local bank = ui.Interfaces:GetInterface(Config.BANK_INTERFACE_ID)
    if bank == nil then return false end
    local all = bank:GetComponent(STATIC.all)
    local backgroundLayer = bank:GetComponent(STATIC.background)
    local content = bank:GetComponent(STATIC.content)
    local border = bank:GetComponent(STATIC.border)
    local viewport = bank:GetComponent(BANK_ITEMS_CONTAINER_STATIC_ID)
    local itemLayer = bank:GetComponent(BANK_ITEMS_STATIC_ID)
    if all == nil or backgroundLayer == nil or content == nil or border == nil
        or viewport == nil or itemLayer == nil then
        return false
    end
    if all.hidden == true or content.hidden == true or viewport.hidden == true then
        return false
    end
    return all.width > 0
        and all.height > 0
        and backgroundLayer.width > 0
        and content.width > 0
        and content.height > 0
        and viewport.width > 0
        and viewport.height > 0
        and itemLayer.width > 0
end

-- Find the bank parts, add sidebar space, and watch window changes
function BankWindow:Apply()
    if self.active then return true end
    if not self:IsReady() then return false end

    self.components = lookUpParts()
    local all = self.components.all

    -- Undo leftover expansion before adding sidebar space.
    if not BankWindow.RecoverExpansion(self.components, self.windowRecord.value) then
        self.components = {}
        self.windowRecord:Save()
        return false
    end
    self:LogBankWindowMeasurements("attached")

    self.active = true
    self.nativeViewAll = self:DetectNativeViewAll() == true
    self:WidenBankForSidebar()
    -- Save first so a crash can be recovered.
    self.windowRecord:Save()
    self:CreateSidebar(all, self.components.content.height)
    self.expanded = true
    self:LogBankWindowMeasurements("expanded")
    self:StartBankWindowWatch()
    self:Changed(true)
    return true
end

-- Hidden controls may still exist; rebuilds may remove them.
local function controlIsVisible(staticID)
    local ok, visible = pcall(function()
        local control = component(staticID)
        return control ~= nil and control.hidden ~= true
            and control.visible == true and control.visibleGlobal ~= false
    end)
    return ok and visible == true
end

-- Search and filters share the same text control.
function BankWindow:ReadNativeFilterMode()
    if not controlIsVisible(CANCEL_CONTROL_STATIC_ID) then return nil end
    local label = dynamicComponent(CANCEL_CONTROL_STATIC_ID, CANCEL_LABEL_CATEGORY_ID, CANCEL_LABEL_DYNAMIC_ID)
    local ok, text = pcall(function()
        if label == nil or label.hidden == true or label.visible ~= true
            or label.visibleGlobal == false then return nil end
        return label.content
    end)
    if not ok or type(text) ~= "string" then return nil end
    text = text:gsub("<[^>]*>", ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
    local normalized = text:lower()
    if normalized == "cancel search" then return "search", text end
    if normalized == "clear filter" then return "filter", text end
    return nil, text:sub(1, 80)
end

-- Check the label to distinguish search from filters.
function BankWindow:IsSearchActive()
    return self:ReadNativeFilterMode() == "search"
end

-- A visible cancel button means bank filters are active.
function BankWindow:IsFilterActive()
    return self:ReadNativeFilterMode() == "filter"
end

-- A visible close button means the preset selector is open.
function BankWindow:IsPresetViewOpen()
    return controlIsVisible(PRESET_CLOSE_BUTTON_STATIC_ID)
end

function BankWindow:DetectNativeViewAll()
    -- The first child shows whether the tab is selected.
    local tabBackground = dynamicComponent(
        ALL_TAB_BUTTON_STATIC_ID,
        ALL_TAB_BUTTON_CATEGORY_ID,
        ALL_TAB_BUTTON_DYNAMIC_ID
    )
    if tabBackground == nil then return nil end

    local spriteID = tabBackground.spriteID
    if spriteID == ALL_TAB_SELECTED_SPRITE_ID then return true end
    if spriteID == ALL_TAB_UNSELECTED_SPRITE_ID then return false end
    return nil
end

-- Restore and save the window before reporting cleanup errors.
function BankWindow:Restore()
    local failure = nil
    -- Continue cleanup after errors, keeping the first failure.
    local function step(action)
        local ok, message = pcall(action)
        if not ok then
            debugLog("Bank Core could not fully leave the bank: ", tostring(message))
            failure = failure or message
        end
    end
    step(function() self.pageState:Restore() end)
    self.shownPage = nil
    self.nativeViewAll = false
    step(function() self:DestroyRail() end)
    step(function() self:StopBankWindowWatch() end)
    if self.active then step(function() self:RestoreBankWindowSizeAndPosition() end) end
    self.active = false
    self.expanded = false
    self.components = {}
    self.windowRecord:Save()
    self:Changed(true)
    if failure ~= nil then error(failure, 0) end
end

function BankWindow.install(target)
    for name, method in pairs(BankWindow) do
        if name ~= "install" then target[name] = method end
    end
end

return BankWindow
