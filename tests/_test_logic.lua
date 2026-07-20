-- Pure-logic tests for kogrim's lib/ modules.
--
-- KOReader is mocked just enough for the modules to LOAD -- everything under
-- lib/ that touches a widget is required at file scope, so the stubs below
-- exist to satisfy those requires, not to be exercised. What is actually
-- tested is the plumbing that has no device dependency: URL building, settings
-- defaults, base-URL normalisation, auth headers and filename derivation.
--
-- Anything that draws (kogrim_browser's rows, the dialogs) needs a real device
-- and is not covered here. Open each screen once before releasing.
--
-- Run: ./tests/run.sh   (or: luajit tests/_test_logic.lua from the plugin dir)

local PLUGIN = (debug.getinfo(1, "S").source:match("^@(.+/)") or "./") .. "../"

-- KOReader requires plugin files as "lib/kogrim_foo" (slash, no .lua).
local real_require = require
local loaded = {}

local stubs = {}

local function stub(name, tbl) stubs[name] = tbl end

-- ---- fake KOReader core modules ----
stub("logger", { dbg = function() end, info = function() end, warn = function() end })
stub("datastorage", {
    getSettingsDir = function() return "/tmp/kogrim-test/settings" end,
    getDataDir     = function() return "/tmp/kogrim-test" end,
})
local fake_fs = {}
stub("libs/libkoreader-lfs", {
    attributes = function(p, what)
        if fake_fs[p] then return what == "mode" and fake_fs[p] or fake_fs[p] end
        return nil
    end,
    mkdir = function(p) fake_fs[p] = "directory"; return true end,
    dir = function() return function() return nil end end,
    rmdir = function() return true end,
})
stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("ffi/util", { template = function(t, ...)
    local args = {...}
    return (t:gsub("%%(%d)", function(n) return tostring(args[tonumber(n)]) end))
end })
stub("luasettings", {
    open = function(_, path)
        local data = {}
        return {
            data = data,
            readSetting = function(_, k) return data[k] end,
            saveSetting = function(_, k, v) data[k] = v end,
            delSetting  = function(_, k) data[k] = nil end,
            flush = function() end,
            isTrue = function(_, k) return data[k] == true end,
            nilOrTrue = function(_, k) return data[k] == nil or data[k] == true end,
        }
    end,
})
-- UI modules: never actually invoked by the pure-logic tests, but they are
-- required at file scope, so they must resolve.
local noop_widget = setmetatable({}, { __index = function()
    return function() return setmetatable({}, { __index = function() return function() end end }) end
end })
for _, m in ipairs{
    "ui/widget/infomessage", "ui/widget/confirmbox",
    "ui/widget/menu", "ui/widget/buttondialog", "ui/widget/inputdialog",
    "ui/widget/multiinputdialog", "ui/widget/textviewer", "ui/widget/spinwidget",
    "ui/widget/pathchooser", "ui/network/manager", "ui/trapper", "device",
    "dispatcher", "ui/widget/container/widgetcontainer", "apps/reader/readerui",
    "socket/http", "ltn12", "socket", "socketutil", "rapidjson", "json",
    "ui/renderimage", "ui/widget/imagewidget", "ui/gesturerange",
    "ui/widget/textwidget", "ui/widget/textboxwidget",
    "ui/widget/horizontalgroup", "ui/widget/verticalgroup",
    "ui/widget/horizontalspan", "ui/widget/verticalspan",
    "ui/widget/container/centercontainer", "ui/widget/container/framecontainer",
    "ui/widget/container/inputcontainer", "ui/widget/container/leftcontainer",
    "ui/widget/container/rightcontainer",
} do stub(m, noop_widget) end

-- UIManager gets a working scheduler rather than a no-op, because the cover
-- queue's whole job is *when* it does things. Ticks are collected here and
-- drained explicitly by the tests, so a run can be stepped one fetch at a time.
local ticks = {}
local function drainTicks(limit)
    local n = 0
    while #ticks > 0 and (not limit or n < limit) do
        local fn = table.remove(ticks, 1)
        fn()
        n = n + 1
    end
    return n
end
stub("ui/uimanager", setmetatable({
    nextTick   = function(_s, fn) ticks[#ticks + 1] = fn end,
    scheduleIn = function(_s, _sec, fn) ticks[#ticks + 1] = fn end,
    unschedule = function(_s, fn)
        for i = #ticks, 1, -1 do
            if ticks[i] == fn then table.remove(ticks, i) end
        end
    end,
}, { __index = function() return function() end end }))

-- The view modules read real values out of these at FILE scope (font faces,
-- border sizes), so the blanket no-op stub is not enough -- indexing a function
-- raises. Given properly, requiring each view module becomes a genuine check
-- that its requires resolve and its top level runs.
stub("ui/size", {
    border  = { thin = 1, default = 2, window = 2, button = 1 },
    padding = { tiny = 1, small = 2, default = 4, large = 8, button = 2, buttontable = 2 },
    line    = { thin = 1, medium = 2, focus_indicator = 2 },
    margin  = { tiny = 1, small = 2, default = 4, title = 4 },
})
stub("ui/font", { getFace = function() return { size = 12 } end })
stub("ui/geometry", { new = function(_s, t) return t or {} end })
stub("ffi/blitbuffer", {
    COLOR_BLACK = 0, COLOR_WHITE = 1, COLOR_GRAY = 2,
})

-- cache.lua is real KOReader code that kogrim_cover_cache builds on, but it
-- pulls ffi/lru and sha2, which the test runner has no FFI for. Enough of the
-- interface to let the module load and to keep the pure fit math reachable.
stub("cache", {
    new = function(_, o)
        o = o or {}
        local store = {}
        o.check  = function(_s, k) return store[k] end
        o.insert = function(_s, k, v) store[k] = v end
        o.clear  = function() store = {} end
        return o
    end,
})

-- socket.url is real in KOReader (its OPDS plugin uses it), but luasocket is
-- not installed for the test runner. Enough of parse() to exercise the origin
-- comparison that decides whether a redirect may carry credentials.
stub("socket.url", {
    parse = function(u)
        local scheme, rest = tostring(u or ""):match("^(%a[%w+.%-]*)://(.*)$")
        if not scheme then return {} end
        local authority = rest:match("^([^/?#]*)") or ""
        local host, port = authority:match("^(.+):(%d+)$")
        return { scheme = scheme, host = host or authority, port = port }
    end,
    absolute = function(base, location)
        if location:match("^%a[%w+.%-]*://") then return location end
        return (base:match("^(%a[%w+.%-]*://[^/]+)") or "") .. location
    end,
})

_G.G_reader_settings = {
    readSetting = function(_, k)
        if k == "home_dir" then return "/mnt/us/books" end
        return nil
    end,
}

_G.require = function(name)
    if stubs[name] then return stubs[name] end
    if loaded[name] then return loaded[name] end
    if name:match("^lib/kogrim_") then
        local chunk = assert(loadfile(PLUGIN .. name .. ".lua"))
        loaded[name] = chunk()
        return loaded[name]
    end
    return real_require(name)
end

-- ---- tests ----
local failures = 0
local function eq(got, want, label)
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s\n  got:  %s\n  want: %s",
            label, tostring(got), tostring(want)))
    else
        print("ok   " .. label)
    end
end

local Http     = require("lib/kogrim_http")
local Settings = require("lib/kogrim_settings")
local Api      = require("lib/kogrim_api")
local Download = require("lib/kogrim_download")

print("== urlEncode ==")
eq(Http.urlEncode("hello world"), "hello%20world", "space")
eq(Http.urlEncode("a&b=c"), "a%26b%3Dc", "reserved chars")
eq(Http.urlEncode("Tolkien"), "Tolkien", "plain passthrough")
eq(Http.urlEncode("a-b_c.d~e"), "a-b_c.d~e", "unreserved untouched")
eq(Http.urlEncode(nil), "", "nil")

print("== buildQuery ==")
eq(Http.buildQuery{}, "", "empty")
eq(Http.buildQuery{{"page", 0}, {"size", 30}}, "?page=0&size=30", "two params")
eq(Http.buildQuery{{"page", 0}, {"libraryId", nil}}, "?page=0", "nil dropped")
eq(Http.buildQuery{{"q", "the hobbit"}}, "?q=the%20hobbit", "encoded value")
eq(Http.buildQuery{{"status","READ"},{"status","UNREAD"}}, "?status=READ&status=UNREAD",
   "repeated key")

print("== defaults ==")
eq(Settings.read("page_size"), 100, "page_size default")
eq(Settings.nilOrTrue("open_after_download"), true, "open_after_download defaults on")
eq(Settings.read("nope"), nil, "unknown key")
eq(Settings.read("nope", "fallback"), "fallback", "explicit default")

print("== baseUrl ==")
Settings.save("server_url", "grimmory.example.com")
eq(Api.baseUrl(), "https://grimmory.example.com", "scheme added")
Settings.save("server_url", "http://box.local:6060/")
eq(Api.baseUrl(), "http://box.local:6060", "trailing slash stripped, scheme kept")
Settings.save("server_url", "  https://a.b/  ")
eq(Api.baseUrl(), "https://a.b", "whitespace trimmed")
Settings.save("server_url", "")
eq(Api.baseUrl(), nil, "empty is nil")

print("== isConfigured ==")
eq(Api.isConfigured(), false, "no url, no user")
Settings.save("server_url", "https://g.example")
eq(Api.isConfigured(), false, "url but no user")
Settings.save("username", "alice")
eq(Api.isConfigured(), true, "url + user")

print("== authHeaders ==")
eq(Api.authHeaders().Authorization, nil, "no token -> no header")
Settings.save("access_token", "abc123")
eq(Api.authHeaders().Authorization, "Bearer abc123", "bearer token")

print("== download dir ==")
eq(Download.dir(), "/mnt/us/books/Grimmory", "default under home_dir")
Settings.save("download_dir", "/mnt/us/Books/Grim/")
eq(Download.dir(), "/mnt/us/Books/Grim", "configured, trailing slash stripped")

print("== fileName ==")
eq(Download.fileName{ primaryFileName = "The Hobbit.epub" }, "The Hobbit.epub",
   "server filename preferred")
eq(Download.fileName{ title = "The Hobbit", authors = {"J.R.R. Tolkien"},
                      primaryFileType = "EPUB" },
   "The Hobbit - J.R.R. Tolkien.epub", "title - author . ext")
eq(Download.fileName{ title = "A/B: C?", authors = {"X"}, primaryFileType = "pdf" },
   "A_B_ C_ - X.pdf", "illegal chars replaced")
eq(Download.fileName{ title = "Solo", primaryFileType = "epub" }, "Solo.epub",
   "no author")
eq(Download.fileName{ id = 7, primaryFileType = "epub" }, "book-7.epub",
   "no title falls back to id")
eq(Download.fileName{ primaryFileName = "  spaced  .epub  " }, "spaced .epub",
   "server filename trimmed")
local long = Download.fileName{ title = string.rep("x", 300), primaryFileType = "epub" }
eq(#long <= 105, true, "long title capped (" .. #long .. " bytes)")
eq(Download.fileName("not a table"), nil, "non-table input")

print("== pathFor ==")
eq(Download.pathFor{ primaryFileName = "x.epub" }, "/mnt/us/Books/Grim/x.epub",
   "dir + filename")

-- Grimmory's DTOs are @JsonInclude(NON_NULL) so nulls should never arrive --
-- but rapidjson decodes JSON null to a userdata sentinel rather than nil, so a
-- server that ever drops that annotation must not be able to write
-- "userdata: 0x7f..." into a filename on the user's device.
print("== null sentinels are not stringified ==")
local NULL = newproxy and newproxy(false) or setmetatable({}, {
    __tostring = function() return "userdata: 0xDEADBEEF" end,
})
eq(Download.fileName{ primaryFileName = NULL, title = "Real Title",
                      primaryFileType = "epub" },
   "Real Title.epub", "sentinel filename ignored")
eq(Download.fileName{ title = NULL, id = 42, primaryFileType = "epub" },
   "book-42.epub", "sentinel title falls back to id")
eq(Download.fileName{ title = "T", authors = { NULL }, primaryFileType = "epub" },
   "T.epub", "sentinel author dropped")
eq(Download.fileName{ title = "T", primaryFileType = NULL }, "T.epub",
   "sentinel file type falls back to epub")
eq(Download.fileName{ title = "T", id = NULL, primaryFileType = "epub" }, "T.epub",
   "sentinel id unused when there is a title")

-- The browser is required last: it pulls Download, which the tests above
-- reconfigure, and its formatting helpers are the only device-free part.
local B = require("lib/kogrim_browser")._test

-- readProgress is a 0..1 fraction despite the server-side columns being named
-- *ProgressPercent. Treating it as a percentage showed "0%" for every book in
-- progress -- the exact value below (0.249) is real data from a live server.
print("== progress scale ==")
eq(B.statusOf{ readProgress = 0.249 }, "25%", "0.249 -> 25%")
eq(B.statusOf{ readProgress = 0.5 },   "50%", "0.5 -> 50%")
eq(B.statusOf{ readProgress = 0.999, readStatus = "READING" }, "reading",
   "99.9% rounds past the cutoff, falls to status")
eq(B.statusOf{ readProgress = 1.0, readStatus = "READ" }, "read", "1.0 -> read")
eq(B.statusOf{ readProgress = 0.001, readStatus = "READING" }, "reading",
   "under 1% is noise, falls to status")
eq(B.statusOf{ readProgress = 0, readStatus = "UNREAD" }, nil, "unread shows nothing")
eq(B.statusOf{ readStatus = "READING" }, "reading", "no progress -> status")
eq(B.statusOf{}, nil, "nothing at all")
-- Defensive: if any of the five upstream sources ever sends 0..100 instead.
eq(B.statusOf{ readProgress = 42 }, "42%", "already-scaled value passes through")

print("== physical books ==")
eq(B.isDownloadable{ isPhysical = true }, false, "physical is not downloadable")
eq(B.isDownloadable{ isPhysical = false }, true, "ebook is downloadable")
eq(B.isDownloadable{}, true, "absent flag means downloadable")

-- Real row from a live library: metadata never matched, so there is no title,
-- but the filename carries the real one.
print("== untitled books fall back to the filename ==")
eq(B.titleOf{ title = "No Bad Kids" }, "No Bad Kids", "real title wins")
eq(B.titleOf{ primaryFileName = "Bleach v20 (2007) (Digital) (AnHeroGold-Em - Unknown.epub" },
   "Bleach v20 (2007) (Digital) (AnHeroGold-Em - Unknown", "filename stem, extension stripped")
eq(B.titleOf{ title = "", primaryFileName = "x.epub" }, "x", "empty title is not a title")
eq(B.titleOf{}, nil, "nothing to go on")
eq(B.bookRowText{ primaryFileName = "Dune.epub" }, "Dune", "row uses the fallback")

-- primaryFileName is server-controlled and becomes a path on the user's device.
print("== filenames cannot escape the download folder ==")
eq(Download.pathFor{ primaryFileName = "../../.adds/koreader/settings/evil.lua" },
   "/mnt/us/Books/Grim/.._.._.adds_koreader_settings_evil.lua",
   "traversal is flattened, not followed")
eq(Download.pathFor{ primaryFileName = "/etc/passwd" },
   "/mnt/us/Books/Grim/_etc_passwd", "absolute path is neutralised")
eq(Download.pathFor{ primaryFileName = "a\\..\\b.epub" },
   "/mnt/us/Books/Grim/a_.._b.epub", "backslashes too")
eq(Download.fileName{ primaryFileName = ".." }, "..",
   "bare .. survives sanitising -- see the guard in Download.pathFor")
eq(Download.pathFor{ primaryFileName = ".." }, nil, "...so pathFor refuses it")
eq(Download.pathFor{ primaryFileName = "." }, nil, "and refuses .")

-- Credentials must never be carried to another host by a redirect.
print("== redirect origin checks ==")
eq(Http.sameOrigin("https://a.example/x", "https://a.example/y"), true, "same host")
eq(Http.sameOrigin("https://a.example/x", "https://evil.example/y"), false,
   "different host")
eq(Http.sameOrigin("https://a.example/x", "http://a.example/y"), false,
   "scheme change is a different origin")
eq(Http.sameOrigin("https://a.example:8443/x", "https://a.example/y"), false,
   "port change is a different origin")
eq(Http.sameOrigin("https://a.example/x", "https://A.EXAMPLE/y"), true,
   "host comparison is case-insensitive")

-- Cover URLs are CONSTRUCTED, never taken from the server's thumbnailUrl --
-- that field is hardcoded to "/api/books/{id}/cover" by AppBookMapper, a path
-- no controller is mapped to, so it lands on the frontend's catch-all and
-- returns index.html with a 200. See the note in kogrim_covers.lua.
print("== cover URLs ==")
local Covers = require("lib/kogrim_covers")
Settings.save("server_url", "https://g.example")
local function urls(book) return table.concat(Covers.urlsFor(book), " ") end
eq(urls{ id = 799 },
   "https://g.example/api/v1/media/book/799/thumbnail "
       .. "https://g.example/api/v1/media/book/799/cover",
   "thumbnail first, full cover as fallback")
eq(urls{ id = 799, thumbnailUrl = "/api/books/799/cover" },
   "https://g.example/api/v1/media/book/799/thumbnail "
       .. "https://g.example/api/v1/media/book/799/cover",
   "the server's broken thumbnailUrl is ignored entirely")
eq(urls{ id = 799, thumbnailUrl = "https://evil.example/steal" },
   "https://g.example/api/v1/media/book/799/thumbnail "
       .. "https://g.example/api/v1/media/book/799/cover",
   "...so it cannot aim a token-bearing request at another host")
eq(#Covers.urlsFor{ id = "1/../x" }, 0, "non-integer id yields no URL")
eq(#Covers.urlsFor{}, 0, "no id at all")
eq(#Covers.urlsFor("not a table"), 0, "non-table input")

print("== cover cache paths ==")
local function coverName(book)
    local p = Covers.pathFor(book)
    return p and p:match("[^/]+$") or nil
end
eq(coverName{ id = 799, coverUpdatedOn = "2024-05-01T10:22:33.123Z" },
   "799-20240501T102233123Z.jpg", "id + coverUpdatedOn as the cache key")
eq(coverName{ id = 799 }, "799-static.jpg", "no coverUpdatedOn caches forever")
eq(coverName{ id = 799, coverUpdatedOn = NULL }, "799-static.jpg", "sentinel too")
eq(coverName{ id = 799, coverUpdatedOn = "../../evil" }, "799-evil.jpg",
   "non-alphanumerics stripped, so the key cannot shape a path")
eq(Covers.pathFor{ id = "1/../x" }, nil, "non-integer id is refused")
eq(Covers.pathFor{}, nil, "no id at all")

-- A non-image body cannot be rejected at render time: ImageWidget substitutes
-- a checkerboard for anything it fails to decode under an image-looking name,
-- and that checkerboard is indistinguishable from a real cover to its caller.
-- So the bytes are the only place to catch it. (This shipped once as a grid of
-- black and white squares in the detail sheet.)
print("== cover content sniffing ==")
local function sniff(bytes)
    local p = os.tmpname()
    local f = assert(io.open(p, "wb"))
    f:write(bytes)
    f:close()
    local ok = Covers._test.looksLikeImage(p)
    os.remove(p)
    return ok
end
eq(sniff("\xFF\xD8\xFF\xE0okay"), true, "JPEG")
eq(sniff("\x89PNG\r\n\26\n"), true, "PNG")
eq(sniff("GIF89a..."), true, "GIF")
eq(sniff("RIFF....WEBP"), true, "WebP")
eq(sniff("<svg xmlns="), true, "SVG")
eq(sniff("<!DOCTYPE html><html>"), false, "an HTML login page is not a cover")
eq(sniff("<html><body>404"), false, "bare HTML either")
eq(sniff('{"error":"unauthorized"}'), false, "a JSON error served with 200")
eq(sniff("<?xml version=\"1.0\"?><error/>"), false,
   "XML is refused even though renderImageData would try it as SVG")
eq(sniff(""), false, "empty file")
eq(Covers._test.looksLikeImage("/nonexistent/kogrim/cover.jpg"), false, "missing file")

-- Grid tiles have to line up, so the fit has to be exact rather than
-- approximately right. Same arithmetic as coverbrowser's getCachedCoverSize.
print("== cover fit ==")
local CoverCache = require("lib/kogrim_cover_cache")
local function fit(iw, ih, mw, mh)
    local w, h = CoverCache.fit(iw, ih, mw, mh)
    if not w then return "nil" end
    return w .. "x" .. h
end
-- A 250x350 server thumbnail (the cover_image_resolution default) into a tile.
-- At full height it wants 214px of width, so which axis binds is decided by
-- how wide the tile is relative to that.
eq(fit(250, 350, 250, 300), "214x300", "wide tile: height binds, width shrinks to 214")
eq(fit(250, 350, 200, 300), "200x280", "narrow tile: width binds, height shrinks to 280")
eq(fit(400, 300, 200, 300), "200x150", "landscape cover fits on width")
eq(fit(100, 100, 200, 200), "200x200", "square upscales to fill the tile")
eq(fit(250, 350, 250, 350), "250x350", "exact match is untouched")
eq(fit(0, 350, 200, 300), "nil", "zero width is refused")
eq(fit(250, 0, 200, 300), "nil", "zero height is refused")
eq(fit(nil, 350, 200, 300), "nil", "missing dimension is refused")
eq(fit(250, 350, 0, 300), "nil", "zero box is refused")

print("== cover cache keys ==")
local ck = CoverCache._test.keyFor
eq(ck("/cache/kogrim-covers/799-20240501T102233Z.jpg", 200, 300),
   "799-20240501T102233Z.jpg|200x300", "basename plus the box")
eq(ck("/c/799-A.jpg", 200, 300) == ck("/c/799-B.jpg", 200, 300), false,
   "replaced artwork is a different key, so no invalidation is needed")
eq(ck("/c/799-A.jpg", 200, 300) == ck("/c/799-A.jpg", 100, 150), false,
   "the same cover at two sizes is two entries")

-- The queue exists so a page paints before its covers arrive. What matters is
-- the scheduling: one fetch per tick, exactly one repaint at the end, and
-- nothing at all after a cancel -- a late repaint would draw onto a page the
-- user has already left.
print("== cover fetch queue ==")
local Queue = require("lib/kogrim_cover_queue")
-- Covers.fetch/isCached are stubbed so these tests are about the queue's
-- sequencing rather than about the network.
local on_disk, fetched = {}, {}
Covers.isCached = function(b) return on_disk[b.id] == true end
Covers.fetch = function(b)
    fetched[#fetched + 1] = b.id
    on_disk[b.id] = true
    return "/cache/" .. b.id .. ".jpg"
end
local function books(...)
    local t = {}
    for _i, id in ipairs{...} do t[#t + 1] = { id = id } end
    return t
end

on_disk, fetched, ticks = {}, {}, {}
eq(Queue.pending(books(1, 2, 3)) and #Queue.pending(books(1, 2, 3)), 3,
   "nothing cached: everything is pending")
on_disk[2] = true
eq(#Queue.pending(books(1, 2, 3)), 2, "cached books are skipped")

on_disk, fetched, ticks = {}, {}, {}
local repaints = 0
eq(Queue.start(books(1, 2, 3), function() repaints = repaints + 1 end), true,
   "a run starts when covers are missing")
eq(Queue.isRunning(), true, "and reports itself running")
drainTicks(1)
eq(#fetched, 1, "one fetch per tick, not a burst")
eq(repaints, 0, "no repaint mid-run")
drainTicks()
eq(table.concat(fetched, ","), "1,2,3", "all covers fetched, in order")
eq(repaints, 1, "exactly one repaint, after the whole batch")
eq(Queue.isRunning(), false, "run is over")

on_disk, fetched, ticks = { [1] = true, [2] = true }, {}, {}
eq(Queue.start(books(1, 2), function() repaints = repaints + 1 end), false,
   "no run when every cover is already on disk")

on_disk, fetched, ticks = {}, {}, {}
repaints = 0
Queue.start(books(1, 2, 3), function() repaints = repaints + 1 end)
drainTicks(1)
Queue.cancel()
drainTicks()
eq(#fetched, 1, "cancel stops further fetches")
eq(repaints, 0, "and the pending repaint never fires")
eq(Queue.isRunning(), false, "cancelled run is not running")

-- A second start must supersede the first rather than interleave with it.
on_disk, fetched, ticks = {}, {}, {}
repaints = 0
Queue.start(books(1, 2, 3), function() repaints = repaints + 1 end)
drainTicks(1)
Queue.start(books(7, 8), function() repaints = repaints + 1 end)
drainTicks()
eq(table.concat(fetched, ","), "1,7,8", "the superseded run stops where it was")
eq(repaints, 1, "and only the surviving run repaints")

-- The view modules cannot be exercised without a device, but they CAN be
-- loaded. That is worth doing on its own: a mistyped require path or a name
-- error at file scope would otherwise surface only as a blank screen on a Kobo,
-- which is a slow way to find a typo.
print("== view modules load ==")
for _i, name in ipairs{
    "lib/kogrim_fake_cover", "lib/kogrim_cover_menu",
    "lib/kogrim_grid_menu", "lib/kogrim_list_menu",
} do
    local ok, mod = pcall(require, name)
    eq(ok and type(mod) == "table", true, name .. (ok and "" or (": " .. tostring(mod))))
end
eq(type(require("lib/kogrim_grid_menu")._recalculateDimen), "function",
   "grid exports the dimen hook the menu injection needs")
eq(type(require("lib/kogrim_grid_menu")._updateItemsBuildUI), "function",
   "grid exports the build hook")
eq(type(require("lib/kogrim_list_menu")._recalculateDimen), "function",
   "list exports the dimen hook")
eq(type(require("lib/kogrim_list_menu")._updateItemsBuildUI), "function",
   "list exports the build hook")
eq(type(require("lib/kogrim_cover_menu").updateItems), "function",
   "cover menu exports the updateItems override")

print("== row text ==")
eq(B.bookRowText{ title = "No Bad Kids", authors = {"Janet Lansbury"} },
   "No Bad Kids  —  Janet Lansbury", "title and author")
eq(B.bookRowText{ title = "T", authors = {"A", "B"} }, "T  —  A et al.", "multiple authors")
eq(B.bookRowText{ title = "T", seriesName = "S", seriesNumber = 3.0 },
   "T  (S #3)", "series number loses the .0")
eq(B.bookRowText{ title = "T", seriesName = "S", seriesNumber = 2.5 },
   "T  (S #2.5)", "half numbers survive")
eq(B.bookRowText{}, "Untitled", "no title")

print("== description HTML ==")
eq(B.plainText("<p>Hello</p><p>World</p>"), "Hello\n\nWorld", "paragraphs")
eq(B.plainText("a<br/>b"), "a\nb", "line breaks")
eq(B.plainText("Salt &amp; Pepper"), "Salt & Pepper", "ampersand")
eq(B.plainText("&amp;lt; stays escaped"), "&lt; stays escaped",
   "amp decoded last, so &amp;lt; does not become <")
eq(B.plainText("<em>x</em>&nbsp;y"), "x y", "tags stripped, nbsp to space")

print("== sizes ==")
eq(B.formatSize(512), "512 KB", "kilobytes")
eq(B.formatSize(2048), "2.0 MB", "megabytes")
eq(B.formatSize(0), nil, "zero")
eq(B.formatSize(nil), nil, "nil")

print("")
if failures == 0 then
    print("all tests passed")
else
    print(failures .. " FAILURE(S)")
    os.exit(1)
end
