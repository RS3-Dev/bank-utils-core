-- Native custom tabs occupy consecutive inventory slots; the main tab follows.
-- Verified with BANK_TAB2/3 and bank inventory slots, independently of UI positions.
local NativeTabs = {}

function NativeTabs.Read(entries)
    local sizes, total, maximum = {}, 0, 0
    for _, entry in ipairs(entries) do maximum = math.max(maximum, entry.bankSlot or 0) end
    for tab = 2, 15 do
        local ok, value = pcall(function() return var.VarPlayer["BANK_TAB" .. tab].value end)
        if not ok or type(value) ~= "number" or value < 0 or value % 1 ~= 0 then return nil end
        sizes[tab], total = value, total + value
    end
    -- A partial/rebuilding inventory must not produce false placement confirmations.
    if total > maximum then return nil end
    return sizes
end

function NativeTabs.ForSlot(sizes, bankSlot)
    if sizes == nil or type(bankSlot) ~= "number" or bankSlot < 1 or bankSlot % 1 ~= 0 then return nil end
    local boundary = 0
    for tab = 2, 15 do
        boundary = boundary + sizes[tab]
        if bankSlot <= boundary then return tab end
    end
    return 1
end

return NativeTabs
