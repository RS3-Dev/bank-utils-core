-- Shared game IDs, saved-data keys, and sidebar sizes.

local Config = {
    -- Shared prefix for Core's event and hook names.
    CORE_REF = "bankcore",
    -- Where Core saves the debug setting and sidebar icon order.
    PREFERENCES_KEY = "bankcore:settings:v1",
    -- Where Core saves window adjustments so they can be undone.
    WINDOW_KEY = "bankcore:window:v1",
    BANK_INTERFACE_ID = 517,
    BANK_INVENTORY_ID = 95,
    -- Width of the sidebar content area, including space after it.
    SIDEBAR_COLUMN_WIDTH = 244,
    -- Width of the icon strip and its gap from the content area.
    SIDEBAR_TAB_WIDTH = 32,
    SIDEBAR_TAB_GAP = 8,
}
-- Total width added to the bank for the sidebar.
Config.SIDEBAR_WIDTH = Config.SIDEBAR_TAB_WIDTH + Config.SIDEBAR_TAB_GAP + Config.SIDEBAR_COLUMN_WIDTH

return Config
