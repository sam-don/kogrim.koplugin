-- kogrim_cover_queue.lua
-- Downloads the covers for the page currently on screen, without blocking it.
--
-- Covers.fetch blocks -- it is a synchronous HTTP request. A dozen of them in a
-- row is several seconds, and doing that while building a page would mean the
-- list did not appear until every cover had landed. On e-ink that reads as a
-- dropped tap, and it makes paging through a large library unusable on a slow
-- connection.
--
-- So: the page paints immediately with placeholders for whatever is missing,
-- and this queue fills the gaps behind it.
--
--   * one fetch per UIManager tick, so the UI stays responsive between them and
--     the user can page on or close the browser mid-run;
--   * ONE repaint when the batch finishes, not one per cover. Twelve full-page
--     e-ink refreshes would be far more disruptive than waiting for the set --
--     this is the main reason the queue is batched rather than streaming;
--   * cancellable, and cancelled on every page turn, level change and close.
--
-- Same shape as the items_to_update / items_update_action pattern in KOReader's
-- coverbrowser plugin (covermenu.lua), minus the subprocess -- our work is
-- network I/O, so it does not need one.

local UIManager = require("ui/uimanager")
local logger    = require("logger")
local Covers    = require("lib/kogrim_covers")
local Settings  = require("lib/kogrim_settings")

local Queue = {}

-- The run in flight, if any. Module-local for the same reason the browser's
-- `_self` is: the plugin is instantiated twice (FileManager and Reader) and
-- there must only ever be one queue.
local _run = nil

-- A run is identified by a token rather than by a boolean flag. Every scheduled
-- step re-checks that the run it belongs to is still the current one, so a
-- cancelled run's in-flight step cannot repaint a page that has moved on --
-- clearing a flag would not be enough, because the blocking fetch inside a step
-- can outlive the cancel that happened while it was running.
local _token = 0

--- Stop the current run, if any. Safe to call at any time, including from
-- inside a completion callback.
function Queue.cancel()
    if not _run then return end
    if _run.scheduled then
        UIManager:unschedule(_run.scheduled)
    end
    _run = nil
    _token = _token + 1
end

--- True while a run is in progress. For tests and for the browser's decision
-- about whether a repaint is already coming.
function Queue.isRunning()
    return _run ~= nil
end

-- Books whose cover could not be fetched this session, keyed by cache path.
--
-- Without this the queue is a request loop: a book the server has no artwork
-- for never becomes cached, so it is pending on every single repaint, and every
-- repaint asks for it again. Physical books and unmatched files -- of which a
-- real library has many -- would each cost two failed round trips per page
-- draw.
--
-- Deliberately session-scoped rather than persisted: a cover added on the
-- server should appear after a restart without the user having to clear
-- anything, and forgetting is cheap.
local _failed = {}

--- Forget past failures, so a retry is possible without a restart. Called when
-- the browser reopens.
function Queue.forgetFailures()
    _failed = {}
end

--- Which of these books still need downloading. Pure apart from the disk check,
-- so it is worth having separately: it is what decides whether a run is needed
-- at all, and a page whose covers are all cached must not schedule one.
function Queue.pending(books)
    local out = {}
    if not Settings.nilOrTrue("show_covers") then return out end
    for _i, book in ipairs(books or {}) do
        local path = Covers.pathFor(book)
        -- isCached is a stat(), not a read -- cheap enough per page.
        if path and not _failed[path] and not Covers.isCached(book) then
            out[#out + 1] = book
        end
    end
    return out
end

--- Fetch the missing covers for `books`, then call on_complete() once.
--
-- Returns true if a run was started. on_complete is NOT called when nothing
-- needed fetching (there is nothing new to draw) or when the run is cancelled
-- (the page it would have refreshed is gone).
--
-- The caller is responsible for on_complete being safe to run later -- it fires
-- after an arbitrary number of blocking network calls, by which time the menu
-- may have been torn down. See the guards in kogrim_browser.lua.
function Queue.start(books, on_complete)
    Queue.cancel()

    local todo = Queue.pending(books)
    if #todo == 0 then return false end

    _token = _token + 1
    local my_token = _token
    local run = { index = 1, fetched = 0 }
    _run = run

    local function step()
        -- The run this step belongs to may have been cancelled or replaced
        -- while the previous step's fetch was blocking.
        if _run ~= run or _token ~= my_token then return end
        run.scheduled = nil

        local book = todo[run.index]
        if not book then
            _run = nil
            -- The single repaint the whole batch has been building towards.
            if run.fetched > 0 and on_complete then on_complete() end
            return
        end
        run.index = run.index + 1

        -- Covers.fetch never throws, but it does reach the network, and a
        -- failure here is unremarkable -- a book with no cover on the server
        -- fails every time and simply keeps its placeholder.
        local ok, path = pcall(Covers.fetch, book)
        if ok and path then
            run.fetched = run.fetched + 1
        else
            -- Remember the miss so this book is not asked for again on every
            -- subsequent repaint. See the note on _failed.
            local dest = Covers.pathFor(book)
            if dest then _failed[dest] = true end
        end

        -- Re-check before scheduling: the fetch above just blocked, and the
        -- user may have paged away during it.
        if _run ~= run or _token ~= my_token then return end
        run.scheduled = step
        UIManager:nextTick(step)
    end

    logger.dbg("[kogrim] fetching", #todo, "covers")
    run.scheduled = step
    UIManager:nextTick(step)
    return true
end

Queue._test = {
    -- Lets a test drive the run without a UIManager.
    reset = function() _run = nil; _token = 0; _failed = {} end,
    failed = function() return _failed end,
}

return Queue
