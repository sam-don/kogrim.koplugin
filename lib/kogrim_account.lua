-- kogrim_account.lua
-- The server/credentials sheet and the login/logout helpers.
--
-- Uses MultiInputDialog so URL, username and password are entered in one pass
-- rather than three sequential dialogs. Neither sibling plugin in this repo
-- has a multi-field example; the reference is KOReader's own
-- plugins/opds.koplugin/opdsbrowser.lua addNewCatalog, which uses the same
-- fields{} / getFields() contract and the same text_type = "password" masking.

local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Api         = require("lib/kogrim_api")
local Http        = require("lib/kogrim_http")
local Settings    = require("lib/kogrim_settings")
local _           = require("lib/kogrim_i18n").gettext

local Account = {}

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function Account.isConfigured() return Api.isConfigured() end

--- Summary line for the settings menu, e.g. "alice @ grimmory.example.com".
function Account.describe()
    if not Api.isConfigured() then return _("Not configured") end
    local host = (Api.baseUrl() or ""):gsub("^https?://", "")
    return Settings.read("username", "") .. " @ " .. host
end

--- Verify the stored credentials against the server, reporting either way.
-- on_done(ok) is optional and fires after the message is shown.
function Account.testLogin(on_done)
    local info = InfoMessage:new{ text = _("Connecting to Grimmory…") }
    UIManager:show(info)
    -- Let the message paint before the blocking socket call. On e-ink an
    -- unyielded blocking call means the user stares at the old screen for the
    -- whole request and assumes the tap was lost.
    UIManager:scheduleIn(0.1, function()
        Http.runWhenOnline(function()
            local ok, err = Api.login()
            UIManager:close(info)
            if ok then
                -- /app/users/me returns AppUserInfo, which is permissions only
                -- (isAdmin, canUpload, canDownload, ...) -- there is no name in
                -- it. It is fetched anyway because it proves the freshly issued
                -- token is actually accepted, and because a user without
                -- download permission should hear about it now rather than
                -- after picking a book.
                local user = Api.getCurrentUser()
                local message = _("Connected to Grimmory.")
                -- NB: the admin flag arrives as `admin`, not `isAdmin` --
                -- Jackson strips the "is" prefix from the isAdmin() getter.
                -- (canUpload/canDownload keep their names, because Lombok
                -- generates isCanDownload() and only the leading "is" goes.)
                if type(user) == "table" and user.canDownload == false
                        and user.admin ~= true then
                    message = _("Connected, but this account is not allowed to download books. Ask your Grimmory admin to grant the download permission.")
                end
                UIManager:show(InfoMessage:new{ text = message, timeout = 3 })
            else
                UIManager:show(InfoMessage:new{ text = tostring(err) })
            end
            if on_done then on_done(ok and true or false) end
        end, function(e)
            UIManager:close(info)
            UIManager:show(InfoMessage:new{ text = tostring(e) })
            if on_done then on_done(false) end
        end)
    end)
end

--- The server & account sheet. touchmenu_instance is optional; when present
-- its rows are refreshed after saving so the summary line updates in place.
function Account.showSettingsDialog(touchmenu_instance)
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Grimmory server"),
        fields = {
            {
                description = _("Server URL"),
                text = Settings.read("server_url", ""),
                hint = "https://grimmory.example.com",
            },
            {
                description = _("Username"),
                text = Settings.read("username", ""),
            },
            {
                description = _("Password"),
                text = Settings.read("password", ""),
                text_type = "password",
            },
        },
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local fields = dialog:getFields()
                    local url  = trim(fields[1])
                    local user = trim(fields[2])
                    local pass = fields[3] or ""  -- never trim a password
                    if url == "" then
                        UIManager:show(InfoMessage:new{
                            text = _("A server URL is required."),
                        })
                        return
                    end
                    -- Changing server or user invalidates any cached session.
                    if url ~= Settings.read("server_url", "")
                            or user ~= Settings.read("username", "") then
                        Api.logout()
                    end
                    Settings.save("server_url", url)
                    Settings.save("username", user)
                    Settings.save("password", pass)
                    UIManager:close(dialog)
                    if touchmenu_instance and touchmenu_instance.updateItems then
                        touchmenu_instance:updateItems()
                    end
                    Account.testLogin(function()
                        if touchmenu_instance and touchmenu_instance.updateItems then
                            touchmenu_instance:updateItems()
                        end
                    end)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Drop the session tokens. The URL and username survive, so signing back in
-- is one field rather than three.
function Account.logout(touchmenu_instance)
    Api.logout()
    Settings.delete("password")
    UIManager:show(InfoMessage:new{ text = _("Signed out of Grimmory."), timeout = 2 })
    if touchmenu_instance and touchmenu_instance.updateItems then
        touchmenu_instance:updateItems()
    end
end

return Account
