-- kogrim_settings.lua
--
-- All kogrim preferences live in a dedicated settings file at
-- <datadir>/settings/kogrim.lua (LuaSettings format) rather than mixed into
-- the global settings.reader.lua. This keeps the user's settings.reader.lua
-- tidy and gives an eventual "delete plugin settings on uninstall" feature a
-- clear target file to remove. Modelled on
-- bookshelf.koplugin/lib/bookshelf_settings_store.lua, minus the sub-store
-- routing and legacy migrations -- this plugin is new, so there is nothing to
-- migrate and nothing large enough to warrant its own file.
--
--   Store.read("page_size", 30)
--   Store.save("server_url", "https://grimmory.example.com")
--   Store.delete("access_token")
--   Store.isTrue("open_after_download")
--
-- SECURITY NOTE: the Grimmory username, password and JWT tokens are stored
-- here in plaintext. This matches how KOReader's own OPDS plugin stores
-- catalogue credentials in settings.reader.lua -- there is no keychain on the
-- target devices. Anyone with filesystem access to the device can read them.

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local SETTINGS_PATH = DataStorage:getSettingsDir() .. "/kogrim.lua"

local Store = {}
local _settings = nil

-- Defaults for keys where "unset" should not mean "nil" at every call site.
local DEFAULTS = {
    -- Batch size for book lists. Lists page continuously (Menu shows ~14 rows
    -- per screen on a Kobo), so this is really "how many screens before the
    -- next pause". 100 is roughly seven screens -- far enough that most
    -- browsing never hits a boundary, small enough to stay quick on Wi-Fi.
    page_size          = 100,
    open_after_download = true,
    default_sort       = "title",
    default_dir        = "asc",
}

local function _open()
    if _settings then return _settings end
    _settings = LuaSettings:open(SETTINGS_PATH)
    return _settings
end

function Store.read(key, default)
    local v = _open():readSetting(key)
    if v == nil then
        if default ~= nil then return default end
        return DEFAULTS[key]
    end
    return v
end

function Store.save(key, value)
    local s = _open()
    s:saveSetting(key, value)
    -- LuaSettings:saveSetting only updates the in-memory table; the file isn't
    -- touched until flush() runs. Relying on KOReader's shutdown hook is
    -- fragile: KOReader can be SIGTERM-killed (Kindle frame switching), OOM'd,
    -- or closed via a path that never broadcasts onFlushSettings. And unlike
    -- G_reader_settings, this standalone file is not covered by autosave.
    -- Every save() sits at a user-action boundary where durability beats the
    -- cost of one file write.
    s:flush()
end

function Store.delete(key)
    local s = _open()
    s:delSetting(key)
    s:flush()
end

function Store.isTrue(key)
    local v = Store.read(key)
    return v == true
end

-- nilOrTrue: for toggles that default ON. Kept distinct from isTrue so a
-- call site can't accidentally flip the default by choosing the wrong helper.
function Store.nilOrTrue(key)
    local v = _open():readSetting(key)
    if v == nil then
        local d = DEFAULTS[key]
        return d == nil or d == true
    end
    return v == true
end

function Store.flush()
    if _settings then _settings:flush() end
end

-- Path the settings live at. Exposed so an "uninstall plugin" feature (or the
-- About dialog) can find it without re-deriving the convention.
function Store.path() return SETTINGS_PATH end

return Store
