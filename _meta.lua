local _ = require("lib/kogrim_i18n").gettext
return {
    -- KEEP `name`, equal to the .koplugin directory id ("kogrim"). Current
    -- KOReader nightlies deprecate it (koreader#15096: a harmless
    -- "name in _meta.lua is deprecated" WARN) and key enable/disable off the
    -- directory id instead -- but on stable releases it is load-bearing.
    --
    -- Why: the PluginLoader loads a DISABLED plugin from its _meta.lua, NOT
    -- main.lua. The plugin-manager "enable" toggle then keys plugins_disabled
    -- by that loaded name. With no name in _meta, the loader falls back to a
    -- path match (e.g. "mnt/.../kogrim"), so enabling clears the wrong key and
    -- never removes plugins_disabled["kogrim"] -- the plugin stays stuck
    -- disabled. See bookshelf.koplugin/_meta.lua for the full writeup.
    name = "kogrim",
    fullname = _("Grimmory"),
    description = _([[Browse and download books from a self-hosted Grimmory library. Uses Grimmory's app API, so lists carry read status, reading progress and series information rather than a bare OPDS catalogue.]]),
    version = "0.1.0",
}
