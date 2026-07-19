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
    "ui/uimanager", "ui/widget/infomessage", "ui/widget/confirmbox",
    "ui/widget/menu", "ui/widget/buttondialog", "ui/widget/inputdialog",
    "ui/widget/multiinputdialog", "ui/widget/textviewer", "ui/widget/spinwidget",
    "ui/widget/pathchooser", "ui/network/manager", "ui/trapper", "device",
    "dispatcher", "ui/widget/container/widgetcontainer", "apps/reader/readerui",
    "socket/http", "ltn12", "socket", "socketutil", "rapidjson", "json",
} do stub(m, noop_widget) end

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
