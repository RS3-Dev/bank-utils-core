-- Shared bank grid measurements.

local BankGrid = {}

-- Space before the first column.
BankGrid.LEFT = 8
-- Space above the first row.
BankGrid.TOP = 4
-- Distance between rows or columns.
BankGrid.STEP = 44
BankGrid.SLOT_SIZE = 40

-- Distance from heading top to its divider.
BankGrid.LABEL_LINE_OFFSET = 22

local GRID_LEFT = BankGrid.LEFT
local GRID_STEP = BankGrid.STEP
local GRID_SLOT_SIZE = BankGrid.SLOT_SIZE

-- The last column only needs enough space for its item.
function BankGrid.ColumnCount(itemLayerWidth)
    return math.max(
        1,
        math.floor((itemLayerWidth - GRID_LEFT - GRID_SLOT_SIZE) / GRID_STEP) + 1
    )
end

return BankGrid
