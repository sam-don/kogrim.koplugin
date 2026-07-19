-- kogrim_http.lua
-- Generic network primitives: JSON GET/POST, a binary download to a file, a
-- Wi-Fi gate, URL encoding. No knowledge of Grimmory -- kogrim_api builds the
-- URLs and supplies the auth headers.
--
-- Lifted from bookshelf.koplugin/lib/bookshelf_cover_fetch.lua, which already
-- has the right shape. KOReader's patched socket/http resolves https
-- transparently (its SCHEMES table routes https through ssl.https), so both
-- schemes work through the one require.
--
-- Every function returns `value, err` and never throws: the whole socket
-- quartet is pcall-required so a platform with a broken SSL build degrades to
-- a readable error rather than a Lua traceback in the middle of the UI.

local lfs    = require("libs/libkoreader-lfs")
local logger = require("logger")

local Http = {}

Http.USER_AGENT = "KOReader-kogrim"

-- Lazily resolved once. Returns nil when the platform can't do sockets at all.
local function sockets()
    local ok, http, ltn12, socket, socketutil = pcall(function()
        return require("socket/http"),
               require("ltn12"),
               require("socket"),
               require("socketutil")
    end)
    if not ok then return nil end
    return http, ltn12, socket, socketutil
end

-- JSON codec. rapidjson is the fast C decoder KOReader ships; require("json")
-- is the pure-Lua fallback. Resolved once at first use.
local _json
local function json()
    if _json then return _json end
    local ok, mod = pcall(require, "rapidjson")
    if ok and mod and mod.decode and mod.encode then _json = mod; return _json end
    local ok2, mod2 = pcall(require, "json")
    if ok2 and mod2 and mod2.decode and mod2.encode then _json = mod2; return _json end
    return nil
end

--- Percent-encode a query-string value.
function Http.urlEncode(s)
    if s == nil then return "" end
    return (tostring(s):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

--- Build "?a=1&b=2" from an ordered list of {key, value} pairs.
-- Takes a list rather than a map because Grimmory accepts repeated keys for
-- its list filters (status=READ&status=UNREAD), which a map cannot express.
function Http.buildQuery(pairs_list)
    local parts = {}
    for _i, kv in ipairs(pairs_list or {}) do
        local k, v = kv[1], kv[2]
        if k and v ~= nil and v ~= "" then
            parts[#parts + 1] = Http.urlEncode(k) .. "=" .. Http.urlEncode(v)
        end
    end
    if #parts == 0 then return "" end
    return "?" .. table.concat(parts, "&")
end

-- ensureDir(dir) -> ok
-- lfs.mkdir is single-level, so walk up and create parents first (mkdir -p).
function Http.ensureDir(dir)
    if not dir or dir == "" then return false end
    if lfs.attributes(dir, "mode") == "directory" then return true end
    local parent = dir:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and lfs.attributes(parent, "mode") ~= "directory" then
        Http.ensureDir(parent)
    end
    lfs.mkdir(dir)
    return lfs.attributes(dir, "mode") == "directory"
end

-- runWhenOnline(fn[, on_error]) -> ok
-- Ensure connectivity (prompting the user to enable Wi-Fi if needed) then run
-- fn. NEVER forces a silent connection -- if the user declines the prompt, the
-- callback simply never fires, which is the correct cancel UX. Falls all the
-- way back to running fn directly on platforms with no NetworkMgr.
function Http.runWhenOnline(fn, on_error)
    local ok_net, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_net and NetworkMgr and type(NetworkMgr.runWhenOnline) == "function" then
        local ok_run = pcall(function()
            NetworkMgr:runWhenOnline(function()
                local ok, err = pcall(fn)
                if not ok and on_error then on_error(tostring(err)) end
            end)
        end)
        if ok_run then return true end
    end
    local ok, err = pcall(fn)
    if not ok then
        if on_error then on_error(tostring(err)) end
        return false, err
    end
    return true
end

--- Core request. opts: { url, method, headers, body, timeout }
-- timeout: "api" (default) or "file" -- selects the socketutil constant pair.
-- Returns body_string, status_code  or  nil, err, status_code.
function Http.request(opts)
    local http, ltn12, socket, socketutil = sockets()
    if not http then return nil, "socket unavailable" end

    local headers = {}
    for k, v in pairs(opts.headers or {}) do headers[k] = v end
    headers["User-Agent"] = headers["User-Agent"] or Http.USER_AGENT

    local source
    if opts.body then
        headers["Content-Type"]   = headers["Content-Type"] or "application/json"
        headers["Content-Length"] = tostring(#opts.body)
        source = ltn12.source.string(opts.body)
    end

    local chunks = {}
    local ok, code = pcall(function()
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        -- socketutil's total_timeout is enforced ONLY by its own custom sinks,
        -- never by plain ltn12 sinks -- set_timeout's own comment spells this
        -- out: LuaSocket resets the socket timeout on every chunk, so the
        -- wall-clock cap lives in the sink. Using socketutil.table_sink here is
        -- what actually applies LARGE_TOTAL_TIMEOUT (30s) to an API call, so a
        -- server that accepts the connection then dribbles bytes forever gets
        -- given up on instead of hanging the UI.
        --
        -- Downloads deliberately do NOT do this -- see downloadToFile.
        local sink = socketutil.table_sink and socketutil.table_sink(chunks)
            or ltn12.sink.table(chunks)
        local c = socket.skip(1, http.request({
            url      = opts.url,
            method   = opts.method or "GET",
            headers  = headers,
            source   = source,
            sink     = sink,
            redirect = true,
        }))
        socketutil:reset_timeout()
        return c
    end)
    -- Belt and braces: reset again outside the pcall, so a throw inside it
    -- can't leave the global socket timeout clamped for the rest of the session.
    pcall(function() socketutil:reset_timeout() end)

    if not ok then return nil, "request failed", nil end
    if type(code) ~= "number" then
        -- LuaSocket returns the error string in place of the code on
        -- connection failures (DNS, refused, TLS handshake).
        return nil, tostring(code or "connection failed"), nil
    end
    local body = table.concat(chunks)
    if code < 200 or code >= 300 then
        return nil, "HTTP " .. tostring(code), code
    end
    return body, code
end

--- GET returning decoded JSON. Returns table, status  or  nil, err, status.
function Http.getJson(url, headers)
    local h = { Accept = "application/json" }
    for k, v in pairs(headers or {}) do h[k] = v end
    local body, err_or_code, code = Http.request{ url = url, method = "GET", headers = h }
    if not body then return nil, err_or_code, code end
    return Http.decode(body)
end

--- POST a Lua table as JSON, returning decoded JSON.
function Http.postJson(url, tbl, headers)
    local j = json()
    if not j then return nil, "no JSON codec available" end
    -- rapidjson encodes an empty Lua table as [] (it cannot tell an empty
    -- object from an empty array), so every request body here is built with
    -- explicit string keys and is never empty.
    local ok, encoded = pcall(j.encode, tbl)
    if not ok then return nil, "JSON encode failed" end
    local h = { Accept = "application/json", ["Content-Type"] = "application/json" }
    for k, v in pairs(headers or {}) do h[k] = v end
    local body, err_or_code, code = Http.request{
        url = url, method = "POST", headers = h, body = encoded,
    }
    if not body then return nil, err_or_code, code end
    return Http.decode(body)
end

--- Decode a JSON string. Returns table  or  nil, err.
function Http.decode(body)
    local j = json()
    if not j then return nil, "no JSON codec available" end
    local ok, decoded = pcall(j.decode, body)
    if not ok or type(decoded) ~= "table" then return nil, "JSON decode failed" end
    return decoded
end

--- Stream a URL to dest_path atomically (tmp then rename). Creates the parent
-- directory if needed and overwrites any existing dest_path.
-- Returns dest_path  or  nil, err.
function Http.downloadToFile(url, headers, dest_path)
    if type(url) ~= "string" or url == "" or type(dest_path) ~= "string" then
        return nil, "bad arguments"
    end
    local parent = dest_path:match("^(.*)/[^/]+$")
    if not Http.ensureDir(parent) then return nil, "download folder unavailable" end

    local http, ltn12, socket, socketutil = sockets()
    if not http then return nil, "socket unavailable" end

    local h = {}
    for k, v in pairs(headers or {}) do h[k] = v end
    h["User-Agent"] = h["User-Agent"] or Http.USER_AGENT

    -- Write to .tmp and rename on success, so an interrupted download can
    -- never leave a truncated file that looks like a valid book.
    local tmp = dest_path .. ".tmp"
    local file = io.open(tmp, "wb")
    if not file then return nil, "cannot open temporary file" end

    local ok, code = pcall(function()
        -- Block timeout only: no wall-clock cap on the transfer as a whole.
        --
        -- FILE_TOTAL_TIMEOUT is 60 seconds, which a real book blows straight
        -- through -- a 39 MB comic would need ~650 KB/s sustained to land
        -- inside it, far beyond e-reader Wi-Fi. Passing plain ltn12.sink.file
        -- (rather than socketutil.file_sink) is what keeps that cap OFF, since
        -- socketutil only enforces total_timeout from inside its own sinks.
        --
        -- This is deliberate, not an oversight: do NOT "fix" it by switching to
        -- socketutil.file_sink, which would abort every large download at 60s.
        -- FILE_BLOCK_TIMEOUT still applies and is the protection that matters
        -- here -- it fires when 15s pass with no data at all, i.e. a genuinely
        -- dead connection, rather than merely a slow one.
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, -1)
        local c = socket.skip(1, http.request({
            url = url, method = "GET", headers = h,
            sink = ltn12.sink.file(file),  -- ltn12 closes the file itself
            redirect = true,
        }))
        socketutil:reset_timeout()
        return c
    end)
    pcall(function() socketutil:reset_timeout() end)

    if not ok or type(code) ~= "number" or code < 200 or code >= 300 then
        pcall(os.remove, tmp)
        logger.dbg("[kogrim] download failed:", url, code)
        return nil, "download failed (" .. tostring(code) .. ")"
    end
    pcall(os.remove, dest_path)
    if not os.rename(tmp, dest_path) then
        pcall(os.remove, tmp)
        return nil, "could not move file into place"
    end
    return dest_path
end

return Http
