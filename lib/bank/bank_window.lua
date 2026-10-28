-- Resize and position the bank to make room for the sidebar

local Config = require("lib/core/config")
local BankInterface = require("lib/core/bank_interface")
local BankGrid = require("lib/engine/bank_grid")
local UICoordinates = require("lib/ui/ui_coordinates")
local DebugLog = require("lib/core/debug_log")
local debugLog = DebugLog.Write

-- Report a window failure to the host log even with debug output off
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
local PRESET_FULL_LAYER_STATIC_ID = 260
local ALL_TAB_SELECTED_SPRITE_ID = 8070 -- BANK_TABS_HORIZONTAL_1
local ALL_TAB_UNSELECTED_SPRITE_ID = 8069 -- BANK_TABS_HORIZONTAL_0
-- Check for window moves and resizes; the client has no event for either
local BANK_WINDOW_CHECK_TICKS = 10

-- Round half a width down so expansion stays aligned to whole pixels
local function halfWidth(value)
    return math.floor(value / 2)
end

-- Find a native bank component by its interface slot
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

-- Compare host components, whose handles may not compare equal
local function samePart(firstComponent, secondComponent)
    return firstComponent ~= nil and secondComponent ~= nil and (firstComponent == secondComponent or tostring(firstComponent) == tostring(secondComponent))
end

-- Read a part's position, size and attachment rules
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

-- Add to a part's horizontal offset and width offset, keeping every anchor
local function offsetPart(value, x, width)
    local partLayout = readPartLayout(value)
    if width ~= 0 then
        value:SetSize(partLayout.width + width, partLayout.height, partLayout.widthParent, partLayout.heightParent)
    end
    if x ~= 0 then
        value:SetPos(partLayout.x + x, partLayout.y, partLayout.xParent, partLayout.yParent, partLayout.xSelf, partLayout.ySelf)
    end
end

-- Round an offset to whole interface units
local function round(value)
    return math.floor(value + 0.5)
end

-- Plan how far each part moves and widens when the window widens
-- Content and right-edge controls follow the right edge; dialogs stay centred
local function expansionChanges(parts, width)
    local expansionPlan, halfAddedWidth = {}, halfWidth(width)
    -- Add a part that may be missing
    local function add(slot, value, x, change)
        if value ~= nil then
            expansionPlan[#expansionPlan + 1] = { slot = slot, value = value, x = x, width = change }
        end
    end
    -- A separate host frame carries the move; otherwise the window layer does
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

-- Find how much a component widens, from its own plan or its parent's
local function widthChange(value, expansionPlan, depth)
    if value == nil or depth > MAX_PARENT_DEPTH then return 0 end
    for _, change in ipairs(expansionPlan) do
        if samePart(change.value, value) then return change.width end
    end
    local parentWidthRatio = readPartLayout(value).widthParent
    if parentWidthRatio == 0 then return 0 end
    return parentWidthRatio * widthChange(value.parent, expansionPlan, depth + 1)
end

-- Add only the width and movement not already supplied by parent-relative sizing
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

-- Take the added offsets back off, keeping any resize made while expanded
-- A part the host removed may refuse; return whether every undo worked
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

-- Find a part by the slot name the expansion record uses
local function findPartByName(parts, slot)
    local overlay = string.match(slot, "^overlay(.+)$")
    if overlay ~= nil then return parts.overlays[tonumber(overlay) or overlay] end
    local dialog = string.match(slot, "^dialog(.+)$")
    if dialog ~= nil then return parts.dialogs[tonumber(dialog) or dialog] end
    return parts[slot]
end

-- Find the recorded window frame: the host when expansion moved it, else the window layer
local function findFrameRecord(record)
    local layer = nil
    for _, entry in ipairs(record.parts) do
        if entry.slot == "host" then return entry end
        if entry.slot == "all" then layer = entry end
    end
    return layer
end

-- Look up the window frame again in case the host replaced its handle
local function findCurrentFrame(slot)
    local ok, value = pcall(function()
        if slot == "host" then
            return ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__BANK_WINDOW)
        end
        return component(STATIC.all)
    end)
    return ok and value or nil
end

-- Read a part's horizontal offsets, or nil when its handle no longer answers
local function tryReadPartLayout(value)
    local ok, partLayout = pcall(readPartLayout, value)
    if not ok or type(partLayout.x) ~= "number" or type(partLayout.width) ~= "number" then return nil end
    return partLayout
end

-- Undo a recorded expansion the client kept or put back, part by part
-- Only parts still at their widened offsets change; each undo is read back to check it
-- Returns false until every undo works, so a later attach retries the rest
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

-- Log component offsets, parent-relative sizing and screen positions
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
            -- Compare both coordinate sources during live scaling and scrolling checks
            local x, y = UICoordinates.absolutePosition(value)
            local global = value.xyGlobal
            return string.format("%s,%s %sx%s; %s; screen %s,%s API %s,%s",
                value.x, value.y, value.width, value.height, anchorDetails, x, y, global.x, global.y)
        end)
        debugLog("Bank Core bank window ", name, ": ", ok and line or "unreadable")
    end
end

-- Rebuild item buttons for the displayed page
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

-- Find the bank window's parts, keyed by the slots the expansion record uses
-- The top-level frame is in its own interface; without the bank's, its parts are missing
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

-- Read the window frame through a fresh lookup
local function frameOffsets(entry)
    local frame = findCurrentFrame(entry.slot)
    return frame ~= nil and tryReadPartLayout(frame) or nil
end

-- Remove Core's added width and movement
-- Keep size changes the player made while the sidebar was open
-- Keep the record in case the client brings back the wider size
function BankWindow:RestoreBankWindowSizeAndPosition()
    BankWindow.CaptureFrame(self)
    local allPartsRestored = undoExpansion(self.expansion or {})
    self.expansion = nil
    local record = self.windowRecord.value
    if record == nil then return end
    local entry = findFrameRecord(record)
    local partLayout = frameOffsets(entry)
    -- A handle held since attach may be replaced; undo what still shows on fresh ones
    if partLayout ~= nil and partLayout.width == entry.expandedWidth then
        local ok, message = pcall(function()
            allPartsRestored = BankWindow.RecoverExpansion(lookUpParts(), record)
        end)
        if not ok then debugLog("Bank Core could not look up the bank's parts: ", message) end
        -- A later attach decides again from the offsets it finds
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

-- Read the bank window bounds and item columns
function BankWindow:ReadBankWindowMeasurements()
    if not self.active then return nil end
    local frame = self.components.host or self.components.all
    -- The watch reads this every few ticks, so a missing part must not cause an error
    local itemLayer = BankInterface.Find(BANK_ITEMS_STATIC_ID)
    local itemWidth = itemLayer ~= nil and itemLayer.width or 0
    if frame == nil or itemWidth <= 0 then return nil end
    local x, y = UICoordinates.absolutePosition(frame)
    -- A shown page reports the columns its rows are laid out at
    local columns = self.shownPage ~= nil and self.pageState.columns
        or BankGrid.ColumnCount(itemWidth)
    return {
        columns = columns,
        bounds = { x = x, y = y, width = frame.width,
            height = frame.height },
    }
end

-- Summarize window measurements to detect changes
local function describeBankWindowMeasurements(bankWindowMeasurements)
    if bankWindowMeasurements == nil then return "closed" end
    local bounds = bankWindowMeasurements.bounds
    return table.concat({ bankWindowMeasurements.columns, bounds.x, bounds.y, bounds.width, bounds.height }, " ")
end

-- Follow bank moves and resizes, and fit the sidebar
function BankWindow:WatchBankWindow()
    if self.expanded then
        -- A missing part must not cause an error here either
        local content = BankInterface.Find(STATIC.content)
        local height = content ~= nil and content.height or 0
        if height > 0 then self:ResizeSidebar(height) end
    end
    local signature = describeBankWindowMeasurements(self:ReadBankWindowMeasurements())
    if signature == self.lastBankWindowMeasurements then return end
    self.lastBankWindowMeasurements = signature
    -- Kept in memory; saved when the bank closes or Core stops
    if self.expanded then self:CaptureFrame() end
    self:LogBankWindowMeasurements("changed")
    self.onChange()
end

-- Start checking the bank window every few ticks
function BankWindow:StartBankWindowWatch()
    self:StopBankWindowWatch()
    self.windowSession = self.windowSession + 1
    -- Each open watches under its own name so reopened banks never share one
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

-- Stop checking the bank window
function BankWindow:StopBankWindowWatch()
    if self.bankWindowWatch == nil then return end
    self.windowSession = self.windowSession + 1
    Event.Logic.Unsubscribe(self.bankWindowWatch)
    self.bankWindowWatch = nil
end

-- Wait until the bank's required components have usable sizes and are visible
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

    -- IsReady found every required part
    self.components = lookUpParts()
    local all = self.components.all

    -- Restore any leftover expansion before adding the sidebar width again
    if not BankWindow.RecoverExpansion(self.components, self.windowRecord.value) then
        self.components = {}
        self.windowRecord:Save()
        return false
    end
    self:LogBankWindowMeasurements("attached")

    self.active = true
    self.nativeViewAll = self:DetectNativeViewAll() == true
    self:WidenBankForSidebar()
    -- Saved first so a crash or failed shutdown can be recovered
    self.windowRecord:Save()
    self:CreateSidebar(all, self.components.content.height)
    self.expanded = true
    self:LogBankWindowMeasurements("expanded")
    self:StartBankWindowWatch()
    self:Changed(true)
    return true
end

-- Read whether the native preset editor is visible
function BankWindow:IsPresetViewOpen()
    local preset = component(PRESET_FULL_LAYER_STATIC_ID)
    if preset == nil or preset.hidden == true then return false end
    -- The preset panel stays full size when closed, so check whether it is visible
    return preset.visible == true
end

-- Read the native All Items tab state
function BankWindow:DetectNativeViewAll()
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

-- Leave the bank, remove plugin controls, and restore the native window
-- A failed step's error is raised only after the window is restored and saved
function BankWindow:Restore()
    local failure = nil
    -- Run one teardown step, keeping the first failure
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

-- Add these window methods to the BankView class
function BankWindow.install(target)
    for name, method in pairs(BankWindow) do
        if name ~= "install" then target[name] = method end
    end
end

return BankWindow
