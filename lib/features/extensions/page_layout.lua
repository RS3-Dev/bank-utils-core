-- Read extension page layouts and place them on the bank grid

local BankGrid = require("lib/engine/bank_grid")
local BankItemIndex = require("lib/bank/bank_item_index")
local PlainData = require("lib/features/extensions/plain_data")

local PageLayout = {}

local ROW_FIELDS = { label = true, slots = true }
local GRID_LEFT = BankGrid.LEFT
local GRID_TOP = BankGrid.TOP
local GRID_STEP = BankGrid.STEP
-- Reserve this height for the page title
PageLayout.HEADING_HEIGHT = 28
-- Offset section labels below the preceding item row
local LABEL_TOP = 6
local LABEL_HEIGHT = 34
-- Labels, rows, and slots on one page, counted together
PageLayout.MAX_ENTRIES = 10000
-- The tallest content a page or custom view may have: a row step for every entry
PageLayout.MAX_HEIGHT = PageLayout.MAX_ENTRIES * GRID_STEP

-- Read one slot: false for a blank, or an object ID
local function readSlot(description)
    if description == false then return { kind = "blank" } end
    local objectID = PlainData.ObjectNumber(description)
    if objectID == nil then return nil end
    return { kind = "item", objectID = objectID }
end

-- Read a page's layout rows, counting entries toward the limit
function PageLayout.ReadRows(description, textLength)
    if type(description) ~= "table" then return nil, "rows must be a list" end
    local remainingEntries = PageLayout.MAX_ENTRIES
    local rowInputs = PlainData.Array(description, remainingEntries)
    if rowInputs == nil then
        return nil, "rows must be a list within the " .. PageLayout.MAX_ENTRIES .. " entry page limit"
    end
    local rows = {}
    for index, rowInput in ipairs(rowInputs) do
        local rowDescription = "row " .. index
        if type(rowInput) ~= "table" or not PlainData.HasOnlyFields(rowInput, ROW_FIELDS)
            or (rawget(rowInput, "label") == nil) == (rawget(rowInput, "slots") == nil) then
            return nil, rowDescription .. " must have either a label or slots"
        end
        remainingEntries = remainingEntries - 1
        if remainingEntries < 0 then
            return nil, "a page may hold at most " .. PageLayout.MAX_ENTRIES .. " labels, rows, and slots"
        end
        local label = rawget(rowInput, "label")
        if label ~= nil then
            label = PlainData.Label(label, textLength)
            if label == nil then
                return nil, rowDescription .. " label must be 1 to " .. textLength .. " characters"
            end
            rows[index] = { kind = "label", text = label }
        else
            local slotInputs = PlainData.Array(rawget(rowInput, "slots"), math.max(0, remainingEntries))
            if slotInputs == nil then
                return nil, rowDescription .. " slots must be a list within the "
                    .. PageLayout.MAX_ENTRIES .. " entry page limit"
            end
            remainingEntries = remainingEntries - #slotInputs
            local slots = {}
            for slotPosition, slotInput in ipairs(slotInputs) do
                slots[slotPosition] = readSlot(slotInput)
                if slots[slotPosition] == nil then
                    return nil, rowDescription .. " slot " .. slotPosition .. " must be an object ID or false"
                end
            end
            rows[index] = { kind = "row", slots = slots }
        end
    end
    return rows
end

-- Place the layout's rows; a label takes one line and rows wrap as needed
-- Lines and columns are a grid step apart
-- Repeated item IDs number their copies; slot positions count blanks
-- Labels do not count as item slots
local function placeRows(placedPage, rows, top, columnCount)
    local rowOffsetY, slotPosition, itemCounts = 0, 0, {}
    for _, row in ipairs(rows) do
        if row.kind == "label" then
            -- Keep the label close to the items above it
            placedPage.headings[#placedPage.headings + 1] = {
                label = row.text,
                y = top + GRID_TOP + rowOffsetY + LABEL_TOP,
            }
            rowOffsetY = rowOffsetY + LABEL_HEIGHT
        else
            for index, description in ipairs(row.slots) do
                slotPosition = slotPosition + 1
                if description.kind == "item" then
                    local objectID = description.objectID
                    local itemOccurrence = (itemCounts[objectID] or 0) + 1
                    itemCounts[objectID] = itemOccurrence
                    local slot = {
                        kind = "item",
                        objectID = objectID,
                        occurrence = itemOccurrence,
                        position = slotPosition,
                        layoutKey = BankItemIndex.LayoutKey(objectID, itemOccurrence),
                        x = GRID_LEFT + ((index - 1) % columnCount) * GRID_STEP,
                        y = top + GRID_TOP + rowOffsetY + (index - 1) // columnCount * GRID_STEP,
                    }
                    placedPage.slots[#placedPage.slots + 1] = slot
                    placedPage.members[slot.layoutKey] = slot
                end
            end
            rowOffsetY = rowOffsetY + math.max(1, math.ceil(#row.slots / columnCount)) * GRID_STEP
        end
    end
    return rowOffsetY > 0 and GRID_TOP + rowOffsetY or 0
end

-- Place a page's title and layout rows at a column count
-- Return item positions, headings, slot lookups and the total page height
-- An emptied page, whose extension has gone, has no title and draws nothing
function PageLayout.Place(record, columnCount)
    local placedPage = { slots = {}, headings = {}, members = {}, height = 0 }
    local y = 0
    if record.title ~= "" then
        placedPage.headings[1] = { label = record.title, y = 0 }
        y = PageLayout.HEADING_HEIGHT
    end
    placedPage.height = y + placeRows(placedPage, record.rows, y, columnCount)
    return placedPage
end

return PageLayout
