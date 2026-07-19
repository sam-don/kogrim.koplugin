--[[
kogrim -- a KOReader client for Grimmory (https://github.com/grimmory-tools/grimmory).

This file is wiring only: menu entries, Dispatcher actions, event handlers.
All behaviour lives in lib/:

    lib/kogrim_settings.lua   preferences, in settings/kogrim.lua
    lib/kogrim_http.lua       socket/ltn12 primitives (GET, POST, download)
    lib/kogrim_api.lua        Grimmory endpoints + JWT lifecycle
    lib/kogrim_account.lua    the server/credentials sheet
    lib/kogrim_download.lua   filenames, destinations, download UX
    lib/kogrim_browser.lua    the browse UI

is_doc_only = false: the plugin must load in the FileManager (where browsing
and downloading make sense) as well as the Reader.
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local Dispatcher      = require("dispatcher")
local Settings        = require("lib/kogrim_settings")
local Account         = require("lib/kogrim_account")
local _               = require("lib/kogrim_i18n").gettext
local T               = require("ffi/util").template

local KoGrim = WidgetContainer:extend{
    name = "kogrim",
    is_doc_only = false,
}

-- The browser pulls a dozen widget modules for a screen most sessions never
-- open, so it is required lazily rather than at file scope. Same reasoning as
-- bookshelf's showColorPicker (bookshelf.koplugin/main.lua:71).
local function browser()
    return require("lib/kogrim_browser")
end

function KoGrim:init()
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
end

-- ---------------------------------------------------------------------------
-- Dispatcher
-- ---------------------------------------------------------------------------

function KoGrim:onDispatcherRegisterActions()
    -- general = true marks an action as available in EVERY context. Do not be
    -- tempted to write `filemanager = true, reader = true` -- despite how it
    -- reads, dispatcher.lua's isActionEnabled() treats action.reader as
    -- "disable everywhere except reader" and action.filemanager as "disable
    -- everywhere except FM", so setting both disables the action in BOTH.
    -- (See the same note in bookshelf.koplugin/main.lua:834.)
    Dispatcher:registerAction("kogrim_browse", {
        category = "none",
        event    = "KoGrimBrowse",
        title    = _("Grimmory: browse library"),
        general  = true,
    })
    Dispatcher:registerAction("kogrim_search", {
        category  = "none",
        event     = "KoGrimSearch",
        title     = _("Grimmory: search"),
        general   = true,
        separator = true,
    })
end

function KoGrim:onKoGrimBrowse()
    browser().show()
    return true
end

function KoGrim:onKoGrimSearch()
    browser().search()
    return true
end

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------

--- Hide the touch menu behind a modal, and return a function that restores it.
-- Dialogs opened from a menu callback would otherwise sit behind the menu.
local function hideMenu(touchmenu_instance)
    if not touchmenu_instance then return function() end end
    local container = touchmenu_instance.show_parent
        or touchmenu_instance.menu_container or touchmenu_instance
    UIManager:close(container)
    return function()
        UIManager:show(container)
        if touchmenu_instance.updateItems then touchmenu_instance:updateItems() end
    end
end

function KoGrim:addToMainMenu(menu_items)
    menu_items.kogrim = {
        text = _("Grimmory"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Browse library"),
                enabled_func = function() return Account.isConfigured() end,
                callback = function(touchmenu_instance)
                    hideMenu(touchmenu_instance)
                    browser().show()
                end,
            },
            {
                text = _("Search…"),
                enabled_func = function() return Account.isConfigured() end,
                separator = true,
                callback = function(touchmenu_instance)
                    hideMenu(touchmenu_instance)
                    browser().search()
                end,
            },
            {
                text_func = function()
                    return T(_("Server and account: %1"), Account.describe())
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    Account.showSettingsDialog(touchmenu_instance)
                end,
            },
            {
                text = _("Test connection"),
                enabled_func = function() return Account.isConfigured() end,
                keep_menu_open = true,
                callback = function() Account.testLogin() end,
            },
            {
                text = _("Settings"),
                sub_item_table = self:settingsMenu(),
                separator = true,
            },
            {
                text = _("Sign out"),
                enabled_func = function() return Account.isConfigured() end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    Account.logout(touchmenu_instance)
                end,
            },
            {
                text = _("About Grimmory"),
                keep_menu_open = true,
                callback = function()
                    local InfoMessage = require("ui/widget/infomessage")
                    UIManager:show(InfoMessage:new{
                        text = T(_([[
kogrim %1

Browse and download books from a self-hosted Grimmory library.

Settings are stored in:
%2

Note: your Grimmory password is stored there in plain text, as KOReader has no keychain on these devices.]]),
                            KoGrim:version(), Settings.path()),
                    })
                end,
            },
        },
    }
end

function KoGrim:settingsMenu()
    local Download = require("lib/kogrim_download")
    return {
        {
            text_func = function()
                return T(_("Download folder: %1"), Download.dir())
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local PathChooser = require("ui/widget/pathchooser")
                local restore = hideMenu(touchmenu_instance)
                UIManager:show(PathChooser:new{
                    path             = Download.dir(),
                    select_directory = true,
                    select_file      = false,
                    show_files       = false,
                    onConfirm = function(path)
                        -- Normalise to the no-trailing-slash form Download.dir
                        -- returns, so the two can be compared and concatenated
                        -- without a double slash creeping in.
                        path = (path == "/") and "/" or path:gsub("/+$", "")
                        Settings.save("download_dir", path)
                    end,
                    -- close_callback fires on ANY close, confirmed or not --
                    -- which is what we want here, since the menu should come
                    -- back either way.
                    close_callback = restore,
                })
            end,
        },
        {
            text_func = function()
                return T(_("Books loaded at a time: %1"), Settings.read("page_size"))
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new{
                    title_text     = _("Books loaded at a time"),
                    -- Not "per page": lists page continuously, and this is the
                    -- size of each batch fetched behind the scenes, not
                    -- anything the user sees a boundary for.
                    info_text      = _("How many books to fetch from the server at once. Higher means fewer pauses while scrolling; lower is quicker on a slow connection."),
                    value          = Settings.read("page_size"),
                    value_min      = 20,
                    value_max      = 300,
                    value_step     = 10,
                    value_hold_step = 50,
                    default_value  = 100,
                    ok_text        = _("Set"),
                    callback = function(spin)
                        Settings.save("page_size", spin.value)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                })
            end,
        },
        {
            text = _("Open books after downloading"),
            checked_func = function() return Settings.nilOrTrue("open_after_download") end,
            callback = function()
                Settings.save("open_after_download",
                    not Settings.nilOrTrue("open_after_download"))
            end,
        },
    }
end

--- Version string from _meta.lua, so the About box can't drift out of step.
function KoGrim:version()
    local ok, meta = pcall(dofile,
        (debug.getinfo(1, "S").source:match("^@(.+/)") or "./") .. "_meta.lua")
    if ok and type(meta) == "table" and meta.version then return meta.version end
    return "?"
end

return KoGrim
