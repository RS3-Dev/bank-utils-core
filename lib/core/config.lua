-- Shared game IDs, saved-data keys, and sidebar sizes.

local Config = {
    CORE_REF = "bankcore",
    PREFERENCES_KEY = "bankcore:settings:v1",
    -- Saved window changes for recovery.
    WINDOW_KEY = "bankcore:window:v1",
    BANK_INTERFACE_ID = 517,
    BANK_INVENTORY_ID = 95,
    -- Includes space after the content.
    SIDEBAR_COLUMN_WIDTH = 244,
    SIDEBAR_TAB_WIDTH = 32,
    SIDEBAR_TAB_GAP = 8,
}
Config.SIDEBAR_WIDTH = Config.SIDEBAR_TAB_WIDTH + Config.SIDEBAR_TAB_GAP + Config.SIDEBAR_COLUMN_WIDTH

return Config
