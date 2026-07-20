-- kogrim_covers.lua
-- Cover art: resolving the server's cover URL, and an on-disk cache of the
-- downloaded files.
--
-- This module deals in FILE PATHS, never in blitbuffers. Decoding and scaling
-- are left to KOReader's ImageWidget, which already keeps a global, bounded,
-- GC-aware cache of rendered images (frontend/ui/widget/imagewidget.lua's
-- ImageCache, 8 MiB / 128 slots) and hands out non-disposable buffers from it.
-- Rolling our own scaled-blitbuffer cache -- as bookshelf.koplugin does in
-- lib/bookshelf_scaled_cover_cache.lua -- only earns its keep when covers are
-- painted per row per repaint. One cover in a dialog does not need it, and a
-- second cache layer would mean owning bb lifetimes by hand, which is exactly
-- the part of that file that is hard to get right.
--
-- Everything here returns `value, err` and never throws.

local DataStorage = require("datastorage")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")
local Api         = require("lib/kogrim_api")
local Http        = require("lib/kogrim_http")

local Covers = {}

-- Cached files live under KOReader's cache dir, not the settings dir: they are
-- re-downloadable, so a user (or a low-space cleanup) deleting the lot loses
-- nothing but a little Wi-Fi.
local CACHE_DIR = DataStorage:getDataDir() .. "/cache/kogrim-covers"

-- Rough ceiling on the cache. Covers run 30-80 KB, so 400 files is ~20 MB --
-- comfortably under what a Kobo's data partition can spare, and more books
-- than anyone opens the detail sheet for between prunes.
local MAX_CACHED = 400

function Covers.dir() return CACHE_DIR end

-- ---------------------------------------------------------------------------
-- Cache paths
-- ---------------------------------------------------------------------------

-- Book ids are server JSON and become part of a filename, so only plain
-- integers get through -- the same guard Api applies before splicing an id
-- into a URL path.
local function idKey(id)
    if type(id) == "number" and id == math.floor(id) then
        return string.format("%d", id)
    end
    if type(id) == "string" and id:match("^%d+$") then return id end
    return nil
end

-- coverUpdatedOn is the natural cache key: the server bumps it whenever the
-- artwork is replaced, so baking it into the filename makes a re-matched book
-- pick up its new cover without any expiry policy at all.
--
-- It arrives as an ISO timestamp ("2024-05-01T10:22:33.123Z"). Everything but
-- alphanumerics is stripped -- both to keep it filename-safe and because the
-- field is server-controlled and lands on the user's filesystem. Books with no
-- coverUpdatedOn get a fixed key and simply cache forever, which is the right
-- trade for a server that isn't telling us when things change.
local function coverKey(book)
    local v = book.coverUpdatedOn
    if type(v) ~= "string" then return "static" end
    local key = v:gsub("[^%w]", "")
    if key == "" then return "static" end
    return key:sub(1, 24)
end

--- Where a book's cover is (or would be) cached. Returns path, or nil.
--
-- The extension is always .jpg, whatever the server actually sends. That is
-- not a claim about the format: ImageWidget:_loadfile refuses outright
-- ("Image file type not supported") unless DocumentRegistry:isImageFile says
-- the SUFFIX is an image one, while the decoder underneath
-- (RenderImage:renderImageData) sniffs the magic bytes and ignores the name
-- entirely. So the extension exists purely to get past that gate, and a PNG or
-- WebP cover saved under it still renders correctly.
function Covers.pathFor(book)
    if type(book) ~= "table" then return nil end
    local id = idKey(book.id)
    if not id then return nil end
    return CACHE_DIR .. "/" .. id .. "-" .. coverKey(book) .. ".jpg"
end

function Covers.isCached(book)
    local path = Covers.pathFor(book)
    return path ~= nil and lfs.attributes(path, "mode") == "file"
end

-- ---------------------------------------------------------------------------
-- URL resolution
-- ---------------------------------------------------------------------------

-- DO NOT use AppBookSummary.thumbnailUrl. It is broken upstream and always has
-- been: AppBookMapper.mapThumbnailUrl is a hardcoded string,
--
--     return "/api/books/" + book.getId() + "/cover";
--
-- and there is no controller mapped anywhere near that path. The nearest thing
-- is BookCoverController, which is @RequestMapping("/api/v1/books") and exposes
-- only POST routes for *uploading* a cover. So the field names a route that
-- does not exist, the request falls through to the Angular frontend's
-- catch-all, and the server answers 200 with index.html. Downloading that and
-- handing it to a decoder is what put a black-and-white checkerboard in the
-- detail sheet -- every cached "cover" was the same 2.3 KB of HTML.
--
-- The real images are on BookMediaController, @RequestMapping("/api/v1/media"):
--     /book/{id}/thumbnail  -- sized by the cover_image_resolution setting,
--                              250x350 by default (V4__Insert_Cover_Image_Settings)
--     /book/{id}/cover      -- the full-size original
--
-- The thumbnail is preferred: 250x350 is already close to how big this gets
-- drawn, so the full cover would be bytes over Wi-Fi that get thrown away in
-- scaling. `cover` is kept as a fallback for books whose thumbnail was never
-- generated.
--
-- A happy side effect of constructing these: there is no longer any
-- server-controlled URL involved, so nothing can point a token-bearing request
-- at another host, and no origin check is needed. The only variable part is
-- the id, and idKey has already proved that is an integer.
local MEDIA_PATHS = {
    "/api/v1/media/book/%s/thumbnail",
    "/api/v1/media/book/%s/cover",
}

--- Candidate cover URLs for a book, best first. Returns a (possibly empty) list.
function Covers.urlsFor(book)
    if type(book) ~= "table" then return {} end
    local id = idKey(book.id)
    if not id then return {} end
    local base = Api.baseUrl()
    if not base then return {} end
    local urls = {}
    for _i, path in ipairs(MEDIA_PATHS) do
        urls[#urls + 1] = base .. path:format(id)
    end
    return urls
end

-- ---------------------------------------------------------------------------
-- Cache maintenance
-- ---------------------------------------------------------------------------

-- Drop this book's other cached covers. Called after a successful download, so
-- a book whose artwork was replaced leaves behind one file, not one per
-- coverUpdatedOn it has ever had.
local function dropStale(id, keep_name)
    local ok, iter, dir_obj = pcall(lfs.dir, CACHE_DIR)
    if not ok then return end
    local doomed = {}
    for name in iter, dir_obj do
        if name ~= keep_name and name:match("^" .. id .. "%-") then
            doomed[#doomed + 1] = name
        end
    end
    for _i, name in ipairs(doomed) do
        pcall(os.remove, CACHE_DIR .. "/" .. name)
    end
end

--- Trim the cache to MAX_CACHED files, oldest first.
--
-- Sorted by modification time rather than access time: e-readers routinely
-- mount with noatime (and FAT has no atime worth the name), so atime would
-- silently degrade to "insertion order" anyway. Least-recently-FETCHED is a
-- slightly worse eviction policy than least-recently-used, and it is the one
-- the filesystem can actually support.
function Covers.prune()
    local ok, iter, dir_obj = pcall(lfs.dir, CACHE_DIR)
    if not ok then return end
    local files = {}
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." then
            local path = CACHE_DIR .. "/" .. name
            local mtime = lfs.attributes(path, "modification")
            if mtime then files[#files + 1] = { path = path, mtime = mtime } end
        end
    end
    if #files <= MAX_CACHED then return end
    table.sort(files, function(a, b) return a.mtime < b.mtime end)
    for i = 1, #files - MAX_CACHED do
        pcall(os.remove, files[i].path)
    end
    logger.dbg("[kogrim] pruned", #files - MAX_CACHED, "cached covers")
end

-- ---------------------------------------------------------------------------
-- Fetch
-- ---------------------------------------------------------------------------

-- Magic bytes for every format the renderer can actually handle:
-- RenderImage:renderImageData sniffs GIF/WebP/SVG/JPEG itself and hands
-- everything else to MuPDF, which covers PNG, BMP and TIFF.
--
-- XML's "<?xm" is deliberately NOT here even though renderImageData treats it
-- as SVG: an XML *error document* starts the same way, and a server returning
-- one should be caught by this check, not sent to the SVG renderer.
local MAGIC = {
    "\xFF\xD8",                  -- JPEG
    "\x89PNG",                   -- PNG
    "GIF8",                      -- GIF
    "RIFF",                      -- WebP (libwebp re-checks what follows)
    "BM",                        -- BMP
    "II\x2A\x00", "MM\x00\x2A",  -- TIFF, both byte orders
    "<svg",                      -- SVG
}

-- Whether a downloaded file is an image at all.
--
-- This check is the difference between a missing cover and a visible bug. A
-- non-image body cannot be refused later on: ImageWidget:_loadfile only raises
-- when the FILENAME SUFFIX is not an image one -- which ours always is, by
-- construction (see Covers.pathFor) -- and when the decode of a well-named file
-- fails it substitutes RenderImage:renderCheckerboard, so the user gets a
-- black-and-white checkerboard square in the detail sheet rather than nothing.
-- There is no flag on the widget afterwards to distinguish that from a real
-- image, so the only place to catch it is here, on the bytes.
--
-- The head is logged on rejection, because the overwhelmingly likely cause is
-- the server answering with something that is not a cover at all -- an HTML
-- login page or a JSON error with a 200 status -- and the first few bytes say
-- immediately which.
local function looksLikeImage(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local head = f:read(8) or ""
    f:close()
    for _i, magic in ipairs(MAGIC) do
        if head:sub(1, #magic) == magic then return true end
    end
    logger.warn("[kogrim] cover is not an image; first bytes:",
        (head:gsub("[^%g ]", ".")), "=", (head:gsub(".", function(c)
            return string.format("%02X ", string.byte(c))
        end)))
    return false
end

--- The local path to a book's cover, downloading it if it isn't cached yet.
-- BLOCKING -- call it from inside a withSpinner worker, never on the UI path.
-- Returns path, or nil, err.
function Covers.fetch(book)
    local path = Covers.pathFor(book)
    if not path then return nil, "no usable book id" end
    if lfs.attributes(path, "mode") == "file" then
        if looksLikeImage(path) then return path end
        -- A junk file already in the cache is deleted rather than merely
        -- ignored, so a user who was served one bad response is not stuck
        -- looking at a checkerboard until they clear the cache by hand.
        pcall(os.remove, path)
    end

    local urls = Covers.urlsFor(book)
    if #urls == 0 then return nil, "no cover" end

    -- Covers sit behind the same auth as everything else, so the bearer token
    -- goes along. Api.authHeaders is used rather than Api.call because this is
    -- a binary stream, not JSON -- which does mean the 401-refresh dance in
    -- Api.call does not apply here. That is deliberate: a cover is decoration.
    -- Failing it silently and letting the user read the sheet without a
    -- picture beats interrupting them to re-authenticate for an image.
    local headers = Api.authHeaders()
    local last_err
    for _i, url in ipairs(urls) do
        local got, err = Http.downloadToFile(url, headers, path)
        if got then
            -- A 2xx is not enough. This server answers unrouted /api/* paths
            -- with its frontend's index.html and a 200, so "the download
            -- succeeded" says nothing about whether an image arrived.
            if looksLikeImage(path) then
                dropStale(idKey(book.id), path:match("[^/]+$"))
                Covers.prune()
                return got
            end
            pcall(os.remove, path)
            last_err = "not an image"
        else
            last_err = err
        end
        logger.dbg("[kogrim] no cover at", url, "--", tostring(last_err))
    end
    return nil, last_err
end

-- Exposed for tests/_test_logic.lua.
Covers._test = {
    idKey          = idKey,
    coverKey       = coverKey,
    looksLikeImage = looksLikeImage,
}

return Covers
