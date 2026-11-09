-- Find parts of the game's bank window by their fixed IDs.

local Config = require("lib/core/config")

local BankInterface = {}

BankInterface.ITEMS = 201
BankInterface.ITEMS_CONTAINER = 199

function BankInterface.Get(staticID)
    return ui.Interfaces:GetComponent(Config.BANK_INTERFACE_ID, staticID)
end

-- Missing or unreadable controls return nil.
function BankInterface.Find(staticID)
    local ok, value = pcall(BankInterface.Get, staticID)
    return ok and value or nil
end

return BankInterface
