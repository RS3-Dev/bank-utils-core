-- SPDX-License-Identifier: BSD-2-Clause
-- Copyright (C) 2026 Bank Core contributors

-- Start Bank Core's single bank session and publish its extension API

-- Keep the debug preference even if the last session failed to stop
local DebugLog = require("lib/core/debug_log")
local debugLog = DebugLog.Write

local previous = rawget(_G, "__bankcore_session")
if previous ~= nil then
    local ok, message = pcall(function() previous:Shutdown() end)
    if not ok then debugLog("Bank Core could not fully stop the previous reload: ", message) end
end
-- Reloads share one Lua state, so stop the old session before loading modules again
if rawget(_G, "__bankcore_session") == previous then
    _G.__bankcore_session = nil
end
-- Stop publishing the previous API; its extensions already refuse every call
if previous ~= nil and rawget(_G, "__bankcore_api") == previous.publicAPI then
    _G.__bankcore_api = nil
end
previous = nil
pcall(function() collectgarbage("collect") end)

-- Clear this plugin's cached modules so callbacks use the new code
-- Keep this list in sync with lib/; the debug log stays loaded
if package ~= nil and package.loaded ~= nil then
    for _, moduleName in ipairs({
        "lib/bank/bank_item_hover",
        "lib/bank/bank_item_index",
        "lib/bank/bank_page_items",
        "lib/bank/bank_view",
        "lib/bank/bank_window",
        "lib/bank/bank_window_record",
        "lib/bank/sidebar_host",
        "lib/core/bank_interface",
        "lib/core/bank_session",
        "lib/core/config",
        "lib/core/core_panel",
        "lib/core/core_preferences",
        "lib/core/lifecycle",
        "lib/core/mini_menu_router",
        "lib/core/object_config",
        "lib/core/public_api",
        "lib/engine/bank_grid",
        "lib/engine/bank_page_display",
        "lib/engine/bank_page_scroll",
        "lib/features/extensions/custom_view",
        "lib/features/extensions/extension_mounts",
        "lib/features/extensions/page_layout",
        "lib/features/extensions/plain_data",
        "lib/features/extensions/plugin_pages",
        "lib/ui/bank_controls",
        "lib/ui/menu_entries",
        "lib/ui/native_ui",
        "lib/ui/sidebar_frame",
        "lib/ui/sidebar_tab_rail",
        "lib/ui/theme",
        "lib/ui/ui_coordinates",
    }) do
        package.loaded[moduleName] = nil
    end
end

local BankSession = require("lib/core/bank_session")
local session = BankSession.new()
_G.__bankcore_session = session
session:Start()

-- Plugins use the bankcore API supplied by the client, or this shared global
local api = session.publicAPI
_G.__bankcore_api = api

-- Stop the session and release its references when Bank Core unloads
function PluginShutdown()
    session:Shutdown()
    if rawget(_G, "__bankcore_session") == session then
        _G.__bankcore_session = nil
    end
    if rawget(_G, "__bankcore_api") == api then
        _G.__bankcore_api = nil
    end
end

return api
