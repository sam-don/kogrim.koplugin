-- kogrim_cover_cache.lua
-- Decoded, display-sized cover blitbuffers, cached in memory.
--
-- The detail sheet does not need this -- one cover in a dialog can go straight
-- to ImageWidget, which decodes it once and keeps it in KOReader's own
-- ImageCache. Lists are a different problem: a page is a dozen covers, every
-- repaint re-paints all of them, and a JPEG decode per cover per repaint is far
-- too slow on e-ink. So covers are decoded once, scaled once to the exact size
-- they will be drawn at, and held here.
--
-- WHY NOTHING HERE CALLS bb:free()
--
-- Blitbuffers are FFI allocations, so the obvious design -- free the buffer when
-- it falls out of the cache -- is a use-after-free waiting to happen: an evicted
-- buffer can still be referenced by a MenuItem that is mid-paint, or by a page
-- the user is about to page back to. There is no refcount to consult.
--
-- KOReader's own ImageCache settled this the same way, and says so:
-- "Rely on our FFI finalizer to free the BBs on GC" (imagewidget.lua), with
-- enable_eviction_cb = false. An evicted buffer stays alive exactly as long as
-- something still points at it, and the garbage collector frees it afterwards.
-- We follow that, which is also why every widget built from these buffers must
-- be given image_disposable = false -- see kogrim_grid_menu.lua.
--
-- Built on frontend/cache.lua rather than a hand-rolled LRU: it already does
-- byte-budgeted eviction, and using it means one fewer thing to get wrong.

local Cache       = require("cache")
local RenderImage = require("ui/renderimage")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")
local Covers      = require("lib/kogrim_covers")

local CoverCache = {}

-- 8 MiB. A grid page is about a dozen tiles at ~200x300 in 32-bit colour, so
-- roughly 3 MB -- this holds the page you are on plus the one you just came
-- from, which is what makes paging back instant.
local BUDGET = 8 * 1024 * 1024

-- Cache:init rebinds insert/check to the underlying LRU's own set/get when
-- there is no eviction callback and no disk cache, so the signatures below are
-- insert(key, value, bytes) and check(key). (Both ignore the `self` they are
-- called with -- ffi/lru.lua defines them as `function(_, key, ...)`.)
local _cache = Cache:new{
    size            = BUDGET,
    avg_itemsize    = 256 * 1024,
    enable_eviction_cb = false,
}

--- Fit img_w x img_h inside max_w x max_h, preserving aspect ratio.
-- Returns the scaled width and height.
--
-- Same arithmetic as BookInfoManager.getCachedCoverSize in KOReader's
-- coverbrowser plugin, deliberately -- it is the shape that makes a grid of
-- mixed-aspect covers look even.
--
-- Note this DOES upscale a cover smaller than the box, unlike the detail sheet
-- (see coverWidget in kogrim_browser.lua, which refuses to). The reasoning
-- differs by context: a lone cover in a dialog looks better small and sharp
-- than blown up, but a grid tile that renders at half the size of its
-- neighbours reads as a broken layout rather than as a smaller picture.
function CoverCache.fit(img_w, img_h, max_w, max_h)
    if not (img_w and img_h and max_w and max_h)
            or img_w <= 0 or img_h <= 0 or max_w <= 0 or max_h <= 0 then
        return nil
    end
    -- Try full height first, then fall back to full width.
    local width = math.floor(max_h * img_w / img_h + 0.5)
    if max_w >= width then
        return width, max_h
    end
    return max_w, math.floor(max_w * img_h / img_w + 0.5)
end

-- The cache key. The box is part of it because the same cover is wanted at
-- different sizes by the grid and the thumbnail list, and at different sizes
-- again after a rotation -- and fit() is deterministic, so the box plus the
-- file identity fully determine the result.
--
-- The file's basename is already "<id>-<coverUpdatedOn>", so replaced artwork
-- gets a new key for free and no invalidation logic is needed here.
local function keyFor(path, max_w, max_h)
    return (path:match("[^/]+$") or path) .. "|" .. max_w .. "x" .. max_h
end

--- A display-ready blitbuffer for a book's cover, or nil.
--
-- nil means "draw a placeholder": the cover has not been downloaded yet, the
-- book has no usable id, or the file will not decode. Callers must not treat
-- nil as an error -- on a cold cache it is the normal answer for most of a page.
--
-- The returned buffer is owned by this cache. Do not free it, do not modify it,
-- and hand it to ImageWidget only with image_disposable = false.
function CoverCache.get(book, max_w, max_h)
    local path = Covers.pathFor(book)
    if not path or not max_w or not max_h then return nil end

    local key = keyFor(path, max_w, max_h)
    local hit = _cache:check(key)
    if hit then return hit end

    -- Not an error: the fetch queue downloads covers after the page paints, so
    -- a miss here is simply "not arrived yet".
    if lfs.attributes(path, "mode") ~= "file" then return nil end

    local ok, natural = pcall(function()
        return RenderImage:renderImageFile(path, false)
    end)
    if not ok or not natural then
        -- The bytes passed the magic-number check when they were downloaded, so
        -- this is a truncated or corrupt file rather than an HTML error page.
        -- Decoding it ourselves is what keeps the checkerboard out of lists:
        -- ImageWidget would have substituted one, whereas here a failed decode
        -- is just a nil that becomes a placeholder tile.
        logger.dbg("[kogrim] could not decode cover:", path)
        return nil
    end

    local w, h = CoverCache.fit(natural:getWidth(), natural:getHeight(), max_w, max_h)
    if not w then
        pcall(function() natural:free() end)
        return nil
    end

    -- scaleBlitBuffer frees the source unless told otherwise, and returns it
    -- unchanged when it is already the right size -- either way `natural` must
    -- not be touched afterwards.
    local scaled = RenderImage:scaleBlitBuffer(natural, w, h)
    if not scaled then return nil end

    local bytes = tonumber(scaled.stride) * scaled.h
    -- A single cover should never be a meaningful fraction of the budget, but
    -- if one ever is, hand it back uncached rather than letting it evict the
    -- whole page around it.
    if bytes * 2 < BUDGET then
        _cache:insert(key, scaled, bytes)
    end
    return scaled
end

--- Drop everything. For the view-mode switch, where every cached buffer is the
-- wrong size anyway, and for tests.
function CoverCache.clear()
    _cache:clear()
end

CoverCache._test = {
    keyFor = keyFor,
}

return CoverCache
