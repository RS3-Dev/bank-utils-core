-- Find parts of the game's bank window by their fixed IDs.

local Config = require("lib/core/config")

local BankInterface = {}

-- IDs for the bank's item area and its scrolling container.
BankInterface.ITEMS = 201
BankInterface.ITEMS_CONTAINER = 199

-- Find a bank control; pass any game errors to the caller.
function BankInterface.Get(staticID)
    return ui.Interfaces:GetComponent(Config.BANK_INTERFACE_ID, staticID)
end

-- Return nil if a bank control is missing or cannot be read during a rebuild.
function BankInterface.Find(staticID)
    local ok, value = pcall(BankInterface.Get, staticID)
    return ok and value or nil
end

return BankInterface
