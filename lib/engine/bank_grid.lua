-- Define the bank grid dimensions used by drawing, input and scrolling

local BankGrid = {}

-- Left inset of the first column inside the bank item layer
BankGrid.LEFT = 8
-- Top inset of the first row
BankGrid.TOP = 4
-- Distance from one row or column to the next
BankGrid.STEP = 44
-- Size of one item cell
BankGrid.SLOT_SIZE = 40

-- Headings sit above a separator this far below the heading's top
BankGrid.LABEL_LINE_OFFSET = 22

local GRID_LEFT = BankGrid.LEFT
local GRID_STEP = BankGrid.STEP
local GRID_SLOT_SIZE = BankGrid.SLOT_SIZE

-- Fit as many columns as the item layer allows; the last needs only SLOT_SIZE
function BankGrid.ColumnCount(itemLayerWidth)
    return math.max(
        1,
        math.floor((itemLayerWidth - GRID_LEFT - GRID_SLOT_SIZE) / GRID_STEP) + 1
    )
end

return BankGrid
