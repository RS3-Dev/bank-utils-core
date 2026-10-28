-- Find native bank interface components by their static slot

local Config = require("lib/core/config")

local BankInterface = {}

-- Static slots of the bank's item layer and the viewport that scrolls it
BankInterface.ITEMS = 201
BankInterface.ITEMS_CONTAINER = 199

-- Find a bank component, letting host errors reach the caller
function BankInterface.Get(staticID)
    return ui.Interfaces:GetComponent(Config.BANK_INTERFACE_ID, staticID)
end

-- Find a bank component that can be missing while the bank rebuilds
function BankInterface.Find(staticID)
    local ok, value = pcall(BankInterface.Get, staticID)
    return ok and value or nil
end

return BankInterface
