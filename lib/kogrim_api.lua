-- kogrim_api.lua
-- Grimmory endpoints and JWT token lifecycle, layered over kogrim_http.
--
-- Grimmory (https://github.com/grimmory-tools/grimmory) is a fork of Booklore
-- and ships a purpose-built app API under /api/v1/app/*. It returns paginated
-- summaries carrying read status, reading progress, personal rating and series
-- info -- which is why this plugin uses it in preference to the server's OPDS
-- feed (KOReader's stock OPDS plugin already covers that case, and would drop
-- all of the above).
--
-- Endpoints used (verified against the backend controllers on main):
--   POST /api/v1/auth/login          {username,password} -> AccessTokenDto
--   POST /api/v1/auth/refresh        {refreshToken}      -> AccessTokenDto
--   GET  /api/v1/app/users/me                            -> AppUserInfo
--   GET  /api/v1/app/libraries                           -> AppLibrarySummary[]
--   GET  /api/v1/app/shelves                             -> AppShelfSummary[]
--   GET  /api/v1/app/books?page&size&sort&dir&libraryId&shelfId
--                                    -> AppPageResponse<AppBookSummary>
--   GET  /api/v1/app/books/search?q&page&size            -> AppPageResponse
--   GET  /api/v1/app/books/continue-reading?limit        -> AppBookSummary[]
--   GET  /api/v1/app/books/recently-added?limit          -> AppBookSummary[]
--   GET  /api/v1/app/books/{id}                          -> AppBookDetail
--   GET  /api/v1/books/{id}/download                     -> file stream
--
-- Every call returns `data, err` -- err is a human-readable string safe to put
-- straight into an InfoMessage.

local Http     = require("lib/kogrim_http")
local Settings = require("lib/kogrim_settings")
local logger   = require("logger")
local _        = require("lib/kogrim_i18n").gettext

local Api = {}

-- Guards the 401 recovery path. Api.call re-enters itself after refreshing;
-- without this a server that 401s the refresh endpoint too would recurse until
-- the stack blew. Module-local (not per-instance) because the plugin is
-- instantiated twice -- once in the FileManager, once in the Reader.
local _recovering = false

--- Normalised base URL: no trailing slash, https:// assumed when no scheme.
function Api.baseUrl()
    local url = Settings.read("server_url", "")
    if type(url) ~= "string" then return nil end
    url = url:gsub("^%s+", ""):gsub("%s+$", ""):gsub("/+$", "")
    if url == "" then return nil end
    if not url:match("^https?://") then url = "https://" .. url end
    return url
end

function Api.isConfigured()
    local url = Api.baseUrl()
    local user = Settings.read("username", "")
    return url ~= nil and type(user) == "string" and user ~= ""
end

function Api.hasToken()
    local t = Settings.read("access_token")
    return type(t) == "string" and t ~= ""
end

function Api.authHeaders()
    local h = { Accept = "application/json" }
    local token = Settings.read("access_token")
    if type(token) == "string" and token ~= "" then
        h["Authorization"] = "Bearer " .. token
    end
    return h
end

local function storeTokens(dto)
    if type(dto) ~= "table" or type(dto.accessToken) ~= "string" then return false end
    Settings.save("access_token", dto.accessToken)
    if type(dto.refreshToken) == "string" then
        Settings.save("refresh_token", dto.refreshToken)
    end
    -- `expires` is the token lifetime as reported by the server. Stored for
    -- display only: we do NOT pre-emptively refresh on it, because device
    -- clocks on e-readers drift badly across suspend. The 401 retry path in
    -- Api.call is the authority on when a token has gone stale.
    if dto.expires ~= nil then Settings.save("token_expires", dto.expires) end
    return true
end

--- Authenticate and persist the tokens. Returns true or nil, err.
-- url/user/pass are optional -- omitted, the stored values are used.
function Api.login(url, user, pass)
    url  = url  or Api.baseUrl()
    user = user or Settings.read("username", "")
    pass = pass or Settings.read("password", "")
    if not url or url == "" then return nil, _("No server URL configured.") end
    if user == "" then return nil, _("No username configured.") end

    local data, err = Http.postJson(url .. "/api/v1/auth/login",
        { username = user, password = pass })
    if not data then
        if err == "HTTP 401" or err == "HTTP 403" then
            return nil, _("Login failed: incorrect username or password.")
        end
        return nil, _("Could not reach the server: ") .. tostring(err)
    end
    if not storeTokens(data) then
        return nil, _("The server did not return an access token.")
    end
    logger.dbg("[kogrim] logged in to", url)
    return true
end

--- Exchange the refresh token for a new access token. Returns true or nil, err.
local function refresh()
    local url = Api.baseUrl()
    local rt  = Settings.read("refresh_token")
    if not url or type(rt) ~= "string" or rt == "" then return nil, "no refresh token" end
    local data, err = Http.postJson(url .. "/api/v1/auth/refresh", { refreshToken = rt })
    if not data or not storeTokens(data) then return nil, err or "refresh rejected" end
    logger.dbg("[kogrim] refreshed access token")
    return true
end

--- The single choke point for authenticated GETs.
-- On 401 it tries, in order: refresh the token, then a full re-login with the
-- stored credentials -- then retries the original request exactly once.
-- Returns data, err.
function Api.call(path)
    local url = Api.baseUrl()
    if not url then return nil, _("No server URL configured.") end

    if not Api.hasToken() then
        local ok, err = Api.login()
        if not ok then return nil, err end
    end

    local data, err, code = Http.getJson(url .. path, Api.authHeaders())
    if data then return data end

    if code == 401 and not _recovering then
        _recovering = true
        local recovered = refresh()
        if not recovered then
            -- Refresh token expired or revoked too -- fall back to the stored
            -- credentials. This is why the password is kept, not just the token.
            recovered = Api.login()
        end
        _recovering = false
        if recovered then
            data, err = Http.getJson(url .. path, Api.authHeaders())
            if data then return data end
        else
            return nil, _("Session expired. Check your Grimmory credentials.")
        end
    end
    return nil, tostring(err)
end

function Api.getCurrentUser() return Api.call("/api/v1/app/users/me") end
function Api.getShelves()     return Api.call("/api/v1/app/shelves") end

--- Libraries, with a fallback to the pre-app endpoint.
--
-- /api/v1/app/libraries returns HTTP 500 on at least some real deployments
-- (observed on a server whose /app/shelves and /app/books are both healthy).
-- AppLibrarySummary carries an enum list and a nested paths list that the
-- older /api/v1/libraries DTO does not, which is the likely culprit -- so
-- falling back to that endpoint sidesteps it rather than reimplementing it.
--
-- Library (the fallback DTO) has id/name/icon but no bookCount, so the count
-- simply doesn't render for those rows. Everything kogrim needs to browse a
-- library -- its id -- is present in both.
function Api.getLibraries()
    local data, err = Api.call("/api/v1/app/libraries")
    if type(data) == "table" then return data end
    logger.dbg("[kogrim] /app/libraries failed (", tostring(err),
        "), falling back to /api/v1/libraries")
    local legacy = Api.call("/api/v1/libraries")
    if type(legacy) == "table" then return legacy end
    -- Report the ORIGINAL error: the fallback is an implementation detail and
    -- its error message would only misdirect.
    return nil, err
end

--- Paginated book list. opts: { page, size, libraryId, shelfId, sort, dir }
-- Returns an AppPageResponse: {content, page, size, totalElements, totalPages,
-- hasNext, hasPrevious}.
function Api.getBooks(opts)
    opts = opts or {}
    local q = Http.buildQuery{
        { "page",      opts.page or 0 },
        { "size",      opts.size or Settings.read("page_size") },
        { "sort",      opts.sort or Settings.read("default_sort") },
        { "dir",       opts.dir  or Settings.read("default_dir") },
        { "libraryId", opts.libraryId },
        { "shelfId",   opts.shelfId },
    }
    return Api.call("/api/v1/app/books" .. q)
end

--- Free-text search. Same AppPageResponse shape as getBooks.
function Api.searchBooks(query, page, size)
    local q = Http.buildQuery{
        { "q",    query },
        { "page", page or 0 },
        { "size", size or Settings.read("page_size") },
    }
    return Api.call("/api/v1/app/books/search" .. q)
end

-- These two return a bare array, not an AppPageResponse. Callers wrap them.
function Api.getContinueReading(limit)
    return Api.call("/api/v1/app/books/continue-reading"
        .. Http.buildQuery{ { "limit", limit or 20 } })
end

function Api.getRecentlyAdded(limit)
    return Api.call("/api/v1/app/books/recently-added"
        .. Http.buildQuery{ { "limit", limit or 20 } })
end

-- Book ids come from server JSON and get concatenated into a URL path, so they
-- are checked to be plain integers first. Without this, an id of "1/../../x"
-- (or a rapidjson null sentinel, which stringifies to "userdata: 0x...")
-- would be spliced straight into the request path.
local function bookPathId(book_id)
    if type(book_id) == "number" and book_id == math.floor(book_id) then
        return string.format("%d", book_id)
    end
    if type(book_id) == "string" and book_id:match("^%d+$") then
        return book_id
    end
    return nil
end

function Api.getBookDetail(book_id)
    local id = bookPathId(book_id)
    if not id then return nil, _("That book has an unusable id.") end
    return Api.call("/api/v1/app/books/" .. id)
end

--- Stream a book's primary file to dest_path. Returns dest_path or nil, err.
-- Note this hits /api/v1/books/... (the main API), not /api/v1/app/... -- the
-- app API exposes no download endpoint of its own.
function Api.downloadBook(book_id, dest_path)
    local url = Api.baseUrl()
    if not url then return nil, _("No server URL configured.") end
    if not Api.hasToken() then
        local ok, err = Api.login()
        if not ok then return nil, err end
    end
    local id = bookPathId(book_id)
    if not id then return nil, _("That book has an unusable id.") end
    local target = url .. "/api/v1/books/" .. id .. "/download"
    local path, err = Http.downloadToFile(target, Api.authHeaders(), dest_path)
    if path then return path end
    -- Downloads bypass Api.call, so replay its 401 recovery here rather than
    -- making the user re-open the settings dialog mid-download.
    if tostring(err):match("401") and not _recovering then
        _recovering = true
        local recovered = refresh() or Api.login()
        _recovering = false
        if recovered then
            return Http.downloadToFile(target, Api.authHeaders(), dest_path)
        end
    end
    return nil, err
end

--- Clear the session but keep the server URL, so logging back in is one field.
function Api.logout()
    Settings.delete("access_token")
    Settings.delete("refresh_token")
    Settings.delete("token_expires")
end

return Api
