-- Draw plugin tabs and the selected sidebar content.

local Config = require("lib/core/config")
local debugLog = require("lib/core/debug_log").Write
local SidebarFrame = require("lib/ui/sidebar_frame")

local SidebarHost = {}

local RAIL_X = 12
local RAIL_Y = 44
local MESSAGE_INSET = 8

-- Use saved tab order, with new tabs at the end.
local function sortByRailOrder(tabs, railOrder)
    local byExtension, sorted, placed = {}, {}, {}
    for _, tab in ipairs(tabs) do byExtension[tab.extensionID] = tab end
    for _, extensionID in ipairs(railOrder) do
        local tab = byExtension[extensionID]
        if tab ~= nil and not placed[tab] then
            sorted[#sorted + 1] = tab
            placed[tab] = true
        end
    end
    for _, tab in ipairs(tabs) do
        if not placed[tab] then sorted[#sorted + 1] = tab end
    end
    return sorted
end

-- Save the new tab order without moving unloaded plugins.
local function mergeRailOrder(railOrder, tabs)
    local shown, saved, order, last = {}, {}, {}, nil
    for _, tab in ipairs(tabs) do shown[tab.extensionID] = true end
    for index, extensionID in ipairs(railOrder) do
        order[index], saved[extensionID] = extensionID, true
        if shown[extensionID] then last = index end
    end
    last = last or #order
    for _, tab in ipairs(tabs) do
        if not saved[tab.extensionID] then
            last = last + 1
            table.insert(order, last, tab.extensionID)
        end
    end
    -- Only replace positions belonging to loaded tabs.
    local shownIndex = 1
    for index, extensionID in ipairs(order) do
        if shown[extensionID] then
            order[index] = tabs[shownIndex].extensionID
            shownIndex = shownIndex + 1
        end
    end
    return order
end

function SidebarHost:FindSidebarTab(tabID)
    for _, tab in ipairs(self.extensionTabs) do
        if tab.id == tabID then return tab end
    end
    return nil
end

function SidebarHost:FirstSidebarTab()
    for _, tab in ipairs(self.extensionTabs) do
        if tab.mount ~= nil then return tab.id end
    end
    return nil
end

function SidebarHost:CloseTabMount()
    local columnMount = self.tabMount
    self.tabMount = nil
    if columnMount ~= nil then columnMount:Close() end
end

-- Replace the sidebar content when selection changes.
function SidebarHost:RefreshTabMount(tab)
    local columnMount = tab ~= nil and tab.mount or nil
    if self.tabMount ~= nil and self.tabMount ~= columnMount then self:CloseTabMount() end
    if columnMount == nil or self.tabMount == columnMount then return end
    -- Leave room for the outline.
    if columnMount:Open(self.rail, self.components.all, self:TabMountBounds()) then
        self.tabMount = columnMount
    end
    SidebarFrame.RaiseEdges(self)
end

function SidebarHost:TabMountBounds()
    return { x = 1, y = 1, width = Config.SIDEBAR_COLUMN_WIDTH - 10, height = self.sidebarHeight - 2 }
end

-- Show the selected content or explain why it is unavailable.
function SidebarHost:RefreshSidebar()
    if self.emptyLabel == nil then return end
    local tab = self:FindSidebarTab(self.sidebarMode)
    self:RefreshTabMount(tab)
    if tab == nil then
        self.emptyLabel.content = "No bank plugins found."
    else
        self.emptyLabel.content = "This tab could not be shown."
    end
    self.emptyLabel.hidden = self.tabMount ~= nil
end

-- Show a message for missing or failed content.
local function createEmptyLabel(parent)
    local label = prettyui.Text.new(parent, {
        text = "",
        x = MESSAGE_INSET,
        y = MESSAGE_INSET,
        width = Config.SIDEBAR_COLUMN_WIDTH - 24,
        height = 72,
        colour = 0xB7AA8EFF,
        maxLines = 4,
    })
    label.alignHorizontal = ui.AlignMode.CENTRE
    label.alignVertical = ui.AlignMode.TOPLEFT
    return label
end

function SidebarHost:CreateSidebar(parent, height)
    self.sidebarHeight = height
    SidebarFrame.Create(self, parent, height, RAIL_X, RAIL_Y, {
        onSelect = function(tabID) self:SetSidebarMode(tabID) end,
        onReorder = function(tabIDs, movedID) self:ReorderSidebarTabs(tabIDs, movedID) end,
    })
    self.emptyLabel = createEmptyLabel(self.rail)
    self:UpdateLayoutControls()
    self:RefreshSidebar()
    SidebarFrame.RaiseEdges(self)
end

-- Resize the sidebar and its plugin content.
function SidebarHost:ResizeSidebar(height)
    if self.rail == nil or height == self.sidebarHeight then return end
    self.sidebarHeight = height
    SidebarFrame.Resize(self, height)
    if self.tabMount ~= nil then
        self.tabMount:Resize(self:TabMountBounds())
        -- Show why the content failed to resize.
        if not self.tabMount:IsMounted() then
            self.tabMount = nil
            self:RefreshSidebar()
        end
    end
end

-- Remove the sidebar and its contents.
function SidebarHost:DestroySidebar()
    self:CloseTabMount()
    self.emptyLabel = nil
    SidebarFrame.Destroy(self)
end

function SidebarHost:UpdateLayoutControls()
    if self.tabRail == nil then return end
    self.tabRail:SetTabs(self.extensionTabs, self.sidebarMode)
end

-- Show the sidebar content, or open the page if there is none.
function SidebarHost:SetSidebarMode(selectedTabID)
    local tab = self:FindSidebarTab(selectedTabID)
    if tab ~= nil and tab.mount == nil then
        if tab.open ~= nil then tab.open() end
        return
    end
    if tab == nil then selectedTabID = self:FirstSidebarTab() end
    if self.sidebarMode == selectedTabID then
        self:UpdateLayoutControls()
        return
    end
    self.sidebarMode = selectedTabID
    self:UpdateLayoutControls()
    self:RefreshSidebar()
    self:Changed(false)
end

-- Keep the selected tab unless it was removed.
function SidebarHost:SetExtensionTabs(tabs)
    self.extensionTabs = sortByRailOrder(tabs, self.readRailOrder())
    local selected = self:FindSidebarTab(self.sidebarMode)
    if selected == nil or selected.mount == nil then
        self.sidebarMode = self:FirstSidebarTab()
    end
    self:UpdateLayoutControls()
    self:RefreshSidebar()
    self:Changed(false)
end

-- Save the tab order before redrawing; keep the current content and page.
function SidebarHost:ReorderSidebarTabs(tabIDs, movedID)
    if #tabIDs ~= #self.extensionTabs then return false end
    local tabs, used, moved = {}, {}, false
    for index, tabID in ipairs(tabIDs) do
        local tab = self:FindSidebarTab(tabID)
        if tab == nil or used[tab] then return false end
        tabs[index], used[tab] = tab, true
        moved = moved or tab ~= self.extensionTabs[index]
    end
    if not moved then return false end
    if not self.saveRailOrder(mergeRailOrder(self.readRailOrder(), tabs)) then
        if type(log) == "function" then
            log("Bank Core could not save the new sidebar icon order, so the icons keep their"
                .. " previous order. Drag the icon again to retry.")
        end
        return false
    end
    self.extensionTabs = tabs
    if self.tabRail ~= nil then self.tabRail:SetTabs(tabs, self.sidebarMode, movedID) end
    return true
end

function SidebarHost.install(bankViewClass)
    for name, method in pairs(SidebarHost) do
        if name ~= "install" then bankViewClass[name] = method end
    end
end

return SidebarHost
