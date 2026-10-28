-- Static host IDs, event prefix, storage keys, and sidebar dimensions

local Config = {
    -- Prefix for the bank core's event subscriptions and hook names
    CORE_REF = "bankcore",
    -- The bank core's own preferences: debug logging and the sidebar icon order
    PREFERENCES_KEY = "bankcore:settings:v1",
    -- The offsets the sidebar added to the bank window until taken off
    WINDOW_KEY = "bankcore:window:v1",
    BANK_INTERFACE_ID = 517,
    BANK_INVENTORY_ID = 95,
    -- The sidebar's content column and the space after it
    SIDEBAR_COLUMN_WIDTH = 244,
    -- The vertical tab rail and the gap between it and the content column
    SIDEBAR_TAB_WIDTH = 32,
    SIDEBAR_TAB_GAP = 8,
}
-- How far the sidebar widens the bank: tab rail, gap, content column, and the space after it
Config.SIDEBAR_WIDTH = Config.SIDEBAR_TAB_WIDTH + Config.SIDEBAR_TAB_GAP + Config.SIDEBAR_COLUMN_WIDTH

return Config
