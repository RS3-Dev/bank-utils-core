-- Read extension page layouts and place them on the bank grid

local BankGrid = require("lib/engine/bank_grid")
local BankItemIndex = require("lib/bank/bank_item_index")
local PlainData = require("lib/features/extensions/plain_data")

local PageLayout = {}

local ROW_FIELDS = { label = true, slots = true }
local GRID_LEFT = BankGrid.LEFT
local GRID_TOP = BankGrid.TOP
local GRID_STEP = BankGrid.STEP
PageLayout.HEADING_HEIGHT = 28
local LABEL_TOP = 3
local LABEL_HEIGHT = PageLayout.HEADING_HEIGHT + LABEL_TOP
-- Count labels, rows, and slots toward one limit.
PageLayout.MAX_ENTRIES = 10000
-- Allow one row of height per entry.
PageLayout.MAX_HEIGHT = PageLayout.MAX_ENTRIES * GRID_STEP

-- A slot is an item ID or false for a blank.
local function readSlot(description)
    if description == false then return { kind = "blank" } end
    if type(description) == "table" then
        if not PlainData.HasOnlyFields(description, { objectID = true, bankSlot = true }) then return nil end
        local objectID = PlainData.ObjectNumber(rawget(description, "objectID"))
        local bankSlot = PlainData.ObjectNumber(rawget(description, "bankSlot"))
        if objectID == nil or bankSlot == nil or bankSlot < 1 then return nil end
        return { kind = "item", objectID = objectID, bankSlot = bankSlot }
    end
    local objectID = PlainData.ObjectNumber(description)
    if objectID == nil then return nil end
    return { kind = "item", objectID = objectID }
end

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
                    return nil, rowDescription .. " slot " .. slotPosition .. " must be an object ID, {objectID, bankSlot}, or false"
                end
            end
            rows[index] = { kind = "row", slots = slots }
        end
    end
    return rows
end

-- Wrap rows; count blank slots and repeated items, but skip labels in slot numbering.
local function placeRows(placedPage, rows, top, columnCount)
    local rowOffsetY, slotPosition, itemCounts = 0, 0, {}
    for _, row in ipairs(rows) do
        if row.kind == "label" then
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
                        bankSlot = description.bankSlot,
                        occurrence = itemOccurrence,
                        position = slotPosition,
                        layoutKey = description.bankSlot and ("bank:" .. description.bankSlot .. ":" .. objectID .. ":" .. itemOccurrence)
                            or BankItemIndex.LayoutKey(objectID, itemOccurrence),
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

-- Build item positions and headings; removed pages draw nothing.
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
