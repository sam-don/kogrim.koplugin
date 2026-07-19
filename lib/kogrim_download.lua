-- kogrim_download.lua
-- Where downloaded books land, what they get called, and the download UX.
--
-- Flat directory, no server structure mirrored: KOReader's own file browser is
-- how users organise books, and a nested Grimmory/<library>/<series>/ tree
-- would fight the collections and favourites they already keep.

local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local DataStorage = require("datastorage")
local lfs         = require("libs/libkoreader-lfs")
local Api         = require("lib/kogrim_api")
local Http        = require("lib/kogrim_http")
local Settings    = require("lib/kogrim_settings")
local _           = require("lib/kogrim_i18n").gettext
local T           = require("ffi/util").template

local Download = {}

--- The configured download folder, or a sensible default beside the user's
-- other books. Not created here -- Http.downloadToFile does that lazily, so a
-- user who never downloads never gets a stray empty folder.
function Download.dir()
    local dir = Settings.read("download_dir")
    if type(dir) == "string" and dir ~= "" then return (dir:gsub("/+$", "")) end
    local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
    if type(home) ~= "string" or home == "" then
        home = DataStorage:getDataDir()
    end
    return home:gsub("/+$", "") .. "/Grimmory"
end

-- Characters that are illegal in a filename on at least one of the platforms
-- KOReader runs on (FAT-formatted Kindles are the strictest), plus control
-- characters and the path separator.
--
-- Anything that isn't a string becomes "" rather than being tostring'd: a
-- rapidjson null sentinel would otherwise stringify to "userdata: 0x..." and
-- become part of a real filename on disk.
local function sanitise(name)
    if type(name) ~= "string" then return "" end
    return (name
        :gsub("[/\\%z\n\r\t:%*%?\"<>|]", "_")
        :gsub("%s+", " ")
        :gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Filename for a book summary/detail. Prefers the server's own filename so a
-- book downloaded twice (or already synced by other means) collides rather
-- than duplicating under a different name.
function Download.fileName(book)
    if type(book) ~= "table" then return nil end
    local from_server = sanitise(book.primaryFileName)
    if from_server ~= "" then return from_server end

    local title = sanitise(book.title)
    if title == "" then
        title = "book-" .. ((type(book.id) == "number") and tostring(book.id) or "unknown")
    end
    local author = (type(book.authors) == "table") and sanitise(book.authors[1]) or ""
    local ext = sanitise(book.primaryFileType):lower():gsub("^%.", "")
    if ext == "" then ext = "epub" end

    local stem = (author ~= "") and (title .. " - " .. author) or title
    -- 100 bytes leaves room for the extension and a ".tmp" suffix inside the
    -- 255-byte limit that every filesystem here shares. Cutting on bytes can
    -- split a UTF-8 sequence, so trim any trailing continuation bytes.
    if #stem > 100 then
        stem = stem:sub(1, 100):gsub("[\128-\191]*$", "")
    end
    return stem .. "." .. ext
end

--- Absolute destination path for a book, or nil if it can't be safely named.
function Download.pathFor(book)
    local name = Download.fileName(book)
    if not name then return nil end
    -- sanitise() replaces every separator, so "../../x" collapses to a single
    -- harmless "..\_..\_x" filename. What it cannot fix is a name that is
    -- ENTIRELY dots: "." and ".." survive intact and would resolve to the
    -- download folder itself or its parent. Server-controlled input must never
    -- be able to name a directory.
    if name:match("^%.+$") then return nil end
    return Download.dir() .. "/" .. name
end

--- True when the book is already sitting in the download folder.
function Download.isLocal(book)
    local path = Download.pathFor(book)
    return path ~= nil and lfs.attributes(path, "mode") == "file"
end

local function openInReader(path)
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok or not ReaderUI then return end
    -- nextTick so the InfoMessage that triggered this has painted and the
    -- current widget stack has settled before the reader tears it down.
    UIManager:nextTick(function() ReaderUI:showReader(path) end)
end

Download.open = openInReader

--- Fetch a book, reporting progress and errors. on_done(path) is optional.
-- Re-download of an existing file is the caller's decision (see start()).
local function fetch(book, on_done)
    local dest = Download.pathFor(book)
    if not dest then
        UIManager:show(InfoMessage:new{ text = _("Could not work out a filename for this book.") })
        return
    end

    local info = InfoMessage:new{
        text = T(_("Downloading %1…"), sanitise(book.title) ~= "" and book.title or _("book")),
    }
    UIManager:show(info)
    -- Yield so the message paints before the blocking transfer.
    UIManager:scheduleIn(0.1, function()
        Http.runWhenOnline(function()
            local path, err = Api.downloadBook(book.id, dest)
            UIManager:close(info)
            if not path then
                UIManager:show(InfoMessage:new{
                    text = T(_("Download failed: %1"), tostring(err)),
                })
                return
            end
            if Settings.nilOrTrue("open_after_download") then
                openInReader(path)
            else
                UIManager:show(InfoMessage:new{
                    text = T(_("Saved to %1"), path),
                    timeout = 3,
                })
            end
            if on_done then on_done(path) end
        end, function(e)
            UIManager:close(info)
            UIManager:show(InfoMessage:new{ text = tostring(e) })
        end)
    end)
end

--- Download a book, asking first if it is already present locally.
function Download.start(book, on_done)
    local path = Download.pathFor(book)
    if path and lfs.attributes(path, "mode") == "file" then
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = T(_("%1 is already downloaded."),
                sanitise(book.title) ~= "" and book.title or _("This book")),
            ok_text = _("Open"),
            ok_callback = function() openInReader(path) end,
            other_buttons = {{
                {
                    text = _("Download again"),
                    callback = function() fetch(book, on_done) end,
                },
            }},
        })
        return
    end
    fetch(book, on_done)
end

return Download
