-- kogrim_browser.lua
-- The browse UI: a hub of entry points, paginated book lists under it, and a
-- detail sheet per book.
--
-- Built on a stock full-screen Menu with a self-managed navigation stack. The
-- stack/paths/page-preservation mechanics follow
-- bookshelf.koplugin/lib/bookshelf_menu_host.lua, including its two hard-won
-- notes, reproduced at their call sites below:
--   * close_callback fires after EVERY leaf tap (menu.lua:1360), so it is
--     deliberately not set here -- closing is gated through Browser.close;
--   * switchItemTable resets to page 1, so the page is saved and restored.
--
-- Book lists are fetched from the server in batches but presented as ONE
-- continuous list: Menu paginates it locally, and reaching the end quietly
-- appends the next batch. See showPagedList for why the obvious alternative
-- (one server page per screen) reads so badly.

local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Api         = require("lib/kogrim_api")
local Http        = require("lib/kogrim_http")
local Settings    = require("lib/kogrim_settings")
local Download    = require("lib/kogrim_download")
local _           = require("lib/kogrim_i18n").gettext
local T           = require("ffi/util").template

local Browser = {}

-- The live browser, if any. Module-local rather than an instance field: the
-- plugin is instantiated twice (FileManager and Reader) and both must find the
-- same window rather than stacking two browsers.
local _self = nil

-- ---------------------------------------------------------------------------
-- Formatting helpers
-- ---------------------------------------------------------------------------

-- Coerce a field to a non-empty string, or nil.
--
-- Grimmory's DTOs are annotated @JsonInclude(NON_NULL), so null fields are
-- omitted from the response rather than sent as JSON null -- which matters
-- because rapidjson decodes null to a userdata sentinel, not to nil, and
-- concatenating that raises. Relying on a server-side annotation for a
-- client-side invariant is exactly the kind of thing that breaks on an
-- upgrade, so every optional string goes through here.
local function str(v)
    if type(v) ~= "string" or v == "" then return nil end
    return v
end

local function num(v)
    return (type(v) == "number") and v or nil
end

local function authorsOf(book)
    local a = book.authors
    if type(a) ~= "table" or #a == 0 then return nil end
    local first = str(a[1])
    if not first then return nil end
    if #a == 1 then return first end
    return first .. " " .. _("et al.")
end

local function formatSize(kb)
    kb = num(kb)
    if not kb or kb <= 0 then return nil end
    if kb < 1024 then return string.format("%d KB", kb) end
    return string.format("%.1f MB", kb / 1024)
end

-- Series numbers arrive as floats (seriesNumber is a Float), so book 3 comes
-- over the wire as 3.0. Trim the trailing ".0" but keep genuine half-numbers
-- like 2.5, which are common in series with novellas.
local function formatSeriesNumber(n)
    n = num(n)
    if not n then return nil end
    return (tostring(n):gsub("%.0$", ""))
end

-- Grimmory pulls descriptions from Google Books, Open Library and Amazon, and
-- they routinely arrive as HTML. TextViewer renders plain text, so without
-- this the user reads raw <p> markup.
--
-- &amp; is decoded LAST: doing it first would turn the literal "&amp;lt;" into
-- "<" instead of "&lt;".
local function plainText(html)
    local s = html
        :gsub("<br%s*/?>", "\n")
        :gsub("</p%s*>", "\n\n")
        :gsub("<[^>]->", "")
        :gsub("&nbsp;", " ")
        :gsub("&#39;", "'")
        :gsub("&quot;", '"')
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
        :gsub("&amp;", "&")
    -- Collapse the runs of blank lines the </p> substitution leaves behind.
    return (s:gsub("\n\n\n+", "\n\n"):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- A short trailing marker: reading progress if there is any, else read status.
-- Progress wins because "34%" tells the user strictly more than "READING".
--
-- readProgress is a 0..1 FRACTION, despite every backing column being named
-- *ProgressPercent (AppBookMapper.mapReadProgress passes koreader/kobo/epub/
-- pdf/cbx progress straight through). Confirmed by the server's own tests,
-- which assert 0.5f and 0.75f, and by live data: a quarter-read book reports
-- 0.249. Treating that as a percentage displayed "0%" for everything in
-- progress.
--
-- Values above 1 are passed through as an already-scaled percentage: the field
-- is a pass-through from five different sources, so one of them disagreeing on
-- scale in a future release should degrade to a plausible number rather than
-- to 9900%.
local function statusOf(book)
    local p = num(book.readProgress)
    if p and p > 0 then
        local pct = (p <= 1) and (p * 100) or p
        -- Below 1% reads as noise, and 100% is better said as "read".
        if pct >= 1 and pct < 99.5 then
            return string.format("%d%%", math.floor(pct + 0.5))
        end
    end
    local s = str(book.readStatus)
    if s == "READ" then return _("read") end
    if s == "READING" then return _("reading") end
    return nil
end

-- Books whose metadata never matched have no title at all, but their filename
-- usually carries the real one ("Bleach v20 (2007) (Digital)...epub"). Showing
-- a screen of identical "Untitled" rows would make an unmatched library
-- unusable, so fall back to the filename stem.
local function titleOf(book)
    local t = str(book.title)
    if t then return t end
    local name = str(book.primaryFileName)
    if name then
        -- Strip the extension; keep everything else, since the interesting
        -- part (volume numbers, years) is usually at the end.
        return (name:gsub("%.[%w]+$", ""))
    end
    return nil
end

local function bookRowText(book)
    local parts = { titleOf(book) or _("Untitled") }
    local author = authorsOf(book)
    if author then parts[#parts + 1] = author end
    local line = table.concat(parts, "  —  ")
    local series = str(book.seriesName)
    if series then
        local n = formatSeriesNumber(book.seriesNumber)
        line = line .. "  (" .. series .. (n and (" #" .. n) or "") .. ")"
    end
    return line
end

-- Grimmory tracks physical (paper) books alongside files, so a library can
-- contain entries with nothing to download. Offering a Download button on
-- those would just produce a confusing server error.
local function isDownloadable(book)
    return book.isPhysical ~= true
end

-- Right-hand column: local-copy marker, status, file type. Kept terse -- Menu
-- gives the mandatory column only as much width as it needs and steals it from
-- the title.
local function bookRowMandatory(book)
    local bits = {}
    if Download.isLocal(book) then bits[#bits + 1] = "\xE2\x9C\x93" end  -- ✓
    local st = statusOf(book)
    if st then bits[#bits + 1] = st end
    if not isDownloadable(book) then
        bits[#bits + 1] = _("paper")
    else
        local ftype = str(book.primaryFileType)
        if ftype then bits[#bits + 1] = ftype:upper() end
    end
    if #bits == 0 then return nil end
    return table.concat(bits, " · ")
end

-- ---------------------------------------------------------------------------
-- Async plumbing
-- ---------------------------------------------------------------------------

--- Run a blocking API call behind a progress message.
-- work() returns (data, err); on_ok(data) runs only on success.
-- The InfoMessage is shown and the work scheduled a tick later so the message
-- actually paints first -- on e-ink an unyielded blocking call leaves the old
-- screen up for the whole request and reads as a dropped tap.
local function withSpinner(message, work, on_ok, on_fail)
    local info = InfoMessage:new{ text = message or _("Loading…") }
    UIManager:show(info)
    UIManager:scheduleIn(0.1, function()
        Http.runWhenOnline(function()
            local data, err = work()
            UIManager:close(info)
            if not data then
                if on_fail then on_fail() end
                UIManager:show(InfoMessage:new{ text = tostring(err) })
                return
            end
            on_ok(data)
        end, function(e)
            UIManager:close(info)
            if on_fail then on_fail() end
            UIManager:show(InfoMessage:new{ text = tostring(e) })
        end)
    end)
end

-- ---------------------------------------------------------------------------
-- Navigation stack
-- ---------------------------------------------------------------------------
-- A level is { title, rows, menu_page } -- rows are already-materialised Menu
-- items, so re-rendering a level never re-hits the network. `menu_page` is the
-- Menu page the user was on when they descended, restored on the way back up.
--
-- Paginated lists keep one flat, growing item_table and let Menu paginate it,
-- so paging forward never touches this stack -- backing out of a list returns
-- to its parent, not to the previous screenful.

local function currentLevel()
    if not _self or _self.closed then return nil end
    return _self.stack[#_self.stack]
end

local function renderCurrent()
    if not _self or _self.closed then return end
    local lvl = currentLevel()
    if not lvl then return end
    -- switchItemTable resets to page 1, so save the Menu page and put it back.
    local saved = _self.menu.page
    _self.menu:switchItemTable(lvl.title, lvl.rows)
    if saved and saved > 1 and _self.menu.page_num and saved <= _self.menu.page_num then
        _self.menu:onGotoPage(saved)
    end
end

local function push(level)
    -- The browser can be closed while a fetch is still in flight; the response
    -- must not resurrect a torn-down Menu.
    if not _self or _self.closed then return end
    local parent = currentLevel()
    if parent then parent.menu_page = _self.menu.page end
    _self.stack[#_self.stack + 1] = level
    -- paths drives the title bar's return-arrow enabled state (menu.lua:1040).
    _self.menu.paths[#_self.menu.paths + 1] = { title = level.title }
    _self.menu:switchItemTable(level.title, level.rows)
end

local function pop()
    if not _self or _self.closed then return end
    -- Backing out of the root is how the user closes the browser.
    if #_self.stack <= 1 then Browser.close() return end
    table.remove(_self.stack)
    table.remove(_self.menu.paths)
    local parent = currentLevel()
    renderCurrent()
    if parent and parent.menu_page and parent.menu_page > 1
            and _self.menu.page_num and parent.menu_page <= _self.menu.page_num then
        _self.menu:onGotoPage(parent.menu_page)
    end
end

--- Replace the current level's rows in place (used by pagination and by
-- refreshing a list after a download changes a book's ✓ marker).
local function replaceCurrent(title, rows)
    local lvl = currentLevel()
    if not lvl then return end
    lvl.title = title or lvl.title
    lvl.rows  = rows
    if _self.menu.paths[#_self.menu.paths] then
        _self.menu.paths[#_self.menu.paths].title = lvl.title
    end
    _self.menu:switchItemTable(lvl.title, lvl.rows)
end

-- ---------------------------------------------------------------------------
-- Book detail sheet
-- ---------------------------------------------------------------------------

local function showBookDetail(summary)
    withSpinner(_("Loading book…"),
        function() return Api.getBookDetail(summary.id) end,
        function(book)
            local ButtonDialog = require("ui/widget/buttondialog")
            local lines = {}
            local author = authorsOf(book) or authorsOf(summary)
            if author then lines[#lines + 1] = author end
            local series = str(book.seriesName)
            if series then
                local n = formatSeriesNumber(book.seriesNumber)
                lines[#lines + 1] = series .. (n and (" #" .. n) or "")
            end
            local meta = {}
            local ftype = str(book.primaryFileType) or str(summary.primaryFileType)
            if ftype then meta[#meta + 1] = ftype:upper() end
            local pages = num(book.pageCount)
            if pages then meta[#meta + 1] = T(_("%1 pages"), pages) end
            -- fileSizeKb is on AppBookSummary but not AppBookDetail, so the
            -- list row we came from is the only source for it.
            local size = formatSize(book.fileSizeKb or summary.fileSizeKb)
            if size then meta[#meta + 1] = size end
            if #meta > 0 then lines[#lines + 1] = table.concat(meta, " · ") end
            local st = statusOf(book) or statusOf(summary)
            if st then lines[#lines + 1] = T(_("Progress: %1"), st) end

            local is_local = Download.isLocal(book) or Download.isLocal(summary)
            local dialog
            local buttons = {}

            if not isDownloadable(book) then
                -- A physical book: there is no file, so say so plainly rather
                -- than offering a Download that can only fail.
                lines[#lines + 1] = _("Physical book — nothing to download.")
            elseif is_local then
                buttons[#buttons + 1] = {{
                    text = _("Open"),
                    callback = function()
                        UIManager:close(dialog)
                        Browser.close()
                        Download.open(Download.pathFor(book) or Download.pathFor(summary))
                    end,
                }}
                buttons[#buttons + 1] = {{
                    text = _("Download again"),
                    callback = function()
                        UIManager:close(dialog)
                        Download.start(book)
                    end,
                }}
            else
                buttons[#buttons + 1] = {{
                    text = _("Download"),
                    callback = function()
                        UIManager:close(dialog)
                        Download.start(book)
                    end,
                }}
            end

            local description = str(book.description)
            if description then
                buttons[#buttons + 1] = {{
                    text = _("Description"),
                    callback = function()
                        local TextViewer = require("ui/widget/textviewer")
                        UIManager:show(TextViewer:new{
                            title = titleOf(book) or titleOf(summary) or _("Description"),
                            text = plainText(description),
                        })
                    end,
                }}
            end

            buttons[#buttons + 1] = {{
                text = _("Close"),
                callback = function() UIManager:close(dialog) end,
            }}

            local heading = titleOf(book) or titleOf(summary) or _("Book")
            dialog = ButtonDialog:new{
                title = (#lines > 0)
                    and (heading .. "\n\n" .. table.concat(lines, "\n"))
                    or heading,
                title_align = "center",
                buttons = buttons,
            }
            UIManager:show(dialog)
        end)
end

-- ---------------------------------------------------------------------------
-- Book lists
-- ---------------------------------------------------------------------------

-- Turn a list of book summaries into Menu rows.
--
-- `rebuild` is called after a long-press download completes. It must REBUILD
-- the rows, not merely re-render them: the ✓ marker is baked into the row's
-- mandatory string by bookRowMandatory at build time, so re-rendering the same
-- row tables would show the pre-download state forever.
local function bookRows(books, rebuild)
    local rows = {}
    for _i, book in ipairs(books) do
        rows[#rows + 1] = {
            text      = bookRowText(book),
            mandatory = bookRowMandatory(book),
            callback  = function() showBookDetail(book) end,
            -- Long-press skips the detail sheet: the common case is "I know I
            -- want this one", and the sheet costs an extra API round trip.
            hold_callback = function()
                if not isDownloadable(book) then
                    UIManager:show(InfoMessage:new{
                        text = _("That is a physical book — there is no file to download."),
                        timeout = 2,
                    })
                    return
                end
                Download.start(book, function() if rebuild then rebuild() end end)
            end,
        }
    end
    return rows
end

--- A list backed by a server-paginated endpoint, presented as ONE continuous
-- list that extends as the user reaches the end of it.
--
-- The obvious implementation -- one server page per screenful, with "Next page"
-- rows -- is wrong here, and was how this first shipped. KOReader's Menu does
-- its OWN pagination: it slices item_table into screens of `perpage` rows
-- (user-configurable, ~14 on a Kobo) and gives you native chevrons, swipes and
-- a "Page 3 of 90" footer for them. Handing it a 30-book batch therefore
-- produced THREE native pages followed by a synthetic "Next page ›" row --
-- two competing pagination models stacked on top of each other, with the
-- server's page boundary showing through as an arbitrary interruption every
-- third screen.
--
-- So: keep one flat `books` list, let Menu paginate it however it likes, and
-- append the next batch when the user pages off the end (see the onNextPage
-- hook in Browser.show). The batch boundary becomes invisible; the only thing
-- the user ever sees is a brief "Loading more…" at the point where it happens.
--
-- fetch(page) must return an AppPageResponse {content, hasNext, page,
-- totalElements} or nil, err.
local function showPagedList(title, fetch)
    local state = {
        books     = {},
        next_page = 0,
        has_more  = true,
        total     = nil,
        loading   = false,
    }
    local level  -- this list's entry on the nav stack; set on first render

    local function heading()
        if state.total then return T(_("%1 (%2)"), title, state.total) end
        return title
    end

    -- target_index: which item to keep in view. nil means "keep the user on
    -- the page they are already looking at", which is what a post-download
    -- refresh wants -- switchItemTable would otherwise snap back to page 1.
    local function render(target_index)
        local rows = bookRows(state.books, function() render(nil) end)
        if #rows == 0 then
            rows[1] = { text = _("No books here."), select_enabled = false }
        end
        if level then
            level.title = heading()
            level.rows  = rows
        end
        if not _self or _self.closed or currentLevel() ~= level then return end
        if target_index == nil then
            target_index = (_self.menu.page - 1) * (_self.menu.perpage or 1) + 1
        end
        if _self.menu.paths[#_self.menu.paths] then
            _self.menu.paths[#_self.menu.paths].title = level.title
        end
        _self.menu:switchItemTable(level.title, rows, target_index)
    end

    -- Fetch the next batch and append it.
    --
    -- advance=false keeps the user on the page they are looking at and simply
    -- makes more pages exist after it. That is what prefetching wants: being
    -- yanked forward a page for arriving at the end of the loaded set would be
    -- baffling.
    local function loadMore(advance)
        if state.loading or not state.has_more then return false end
        state.loading = true
        local first_new = #state.books + 1
        withSpinner(_("Loading more…"),
            function() return fetch(state.next_page) end,
            function(resp)
                state.loading = false
                local batch = resp.content or {}
                for _i, b in ipairs(batch) do
                    state.books[#state.books + 1] = b
                end
                state.total     = resp.totalElements or state.total
                -- Trust an empty batch over hasNext. A server that keeps
                -- claiming there is more while returning nothing would
                -- otherwise have us refetch on every single page arrival.
                state.has_more  = resp.hasNext == true and #batch > 0
                state.next_page = (resp.page or state.next_page) + 1
                render(advance and first_new or nil)
            end,
            function() state.loading = false end)
        return true
    end

    withSpinner(_("Loading…"),
        function() return fetch(0) end,
        function(resp)
            state.books     = resp.content or {}
            state.total     = resp.totalElements
            state.has_more  = resp.hasNext == true
            state.next_page = (resp.page or 0) + 1
            local rows = bookRows(state.books, function() render(nil) end)
            if #rows == 0 then
                rows[1] = { text = _("No books here."), select_enabled = false }
            end
            level = { title = heading(), rows = rows, load_more = loadMore }
            push(level)
            -- If the whole first batch fits on one screen there is no page to
            -- turn, so the prefetch hook would never get a chance to fire.
            Browser.maybeLoadMore()
        end)
end

--- A non-paginated list (the API's continue-reading / recently-added endpoints
-- return a bare array, not an AppPageResponse).
local function showSimpleList(title, fetch)
    withSpinner(_("Loading…"), fetch, function(books)
        if type(books) ~= "table" then books = {} end
        local render
        render = function(mode)
            local rows = bookRows(books, function() render("replace") end)
            if #rows == 0 then
                rows[1] = { text = _("Nothing here yet."), select_enabled = false }
            end
            if mode == "replace" then
                replaceCurrent(title, rows)
            else
                push{ title = title, rows = rows }
            end
        end
        render()
    end)
end

-- ---------------------------------------------------------------------------
-- Libraries and shelves
-- ---------------------------------------------------------------------------

local function showLibraries()
    withSpinner(_("Loading libraries…"), Api.getLibraries, function(libs)
        local rows = {}
        for _i, lib in ipairs(libs or {}) do
            rows[#rows + 1] = {
                text      = lib.name or _("Untitled library"),
                mandatory = lib.bookCount and tostring(lib.bookCount) or nil,
                callback  = function()
                    showPagedList(lib.name or _("Library"), function(page)
                        return Api.getBooks{ page = page, libraryId = lib.id }
                    end)
                end,
            }
        end
        if #rows == 0 then
            rows[1] = { text = _("No libraries on this server."), select_enabled = false }
        end
        push{ title = _("Libraries"), rows = rows }
    end)
end

local function showShelves()
    withSpinner(_("Loading shelves…"), Api.getShelves, function(shelves)
        local rows = {}
        for _i, shelf in ipairs(shelves or {}) do
            rows[#rows + 1] = {
                text      = shelf.name or _("Untitled shelf"),
                mandatory = shelf.bookCount and tostring(shelf.bookCount) or nil,
                callback  = function()
                    showPagedList(shelf.name or _("Shelf"), function(page)
                        return Api.getBooks{ page = page, shelfId = shelf.id }
                    end)
                end,
            }
        end
        if #rows == 0 then
            rows[1] = { text = _("No shelves on this server."), select_enabled = false }
        end
        push{ title = _("Shelves"), rows = rows }
    end)
end

-- ---------------------------------------------------------------------------
-- Search
-- ---------------------------------------------------------------------------

--- Prompt for a query, then show the results. Usable standalone (the Dispatcher
-- action and the menu both jump straight here) -- it opens the browser first if
-- it isn't already up, so results have somewhere to land.
function Browser.search()
    if not Api.isConfigured() then
        UIManager:show(InfoMessage:new{
            text = _("Set up your Grimmory server first: Tools ▸ Grimmory ▸ Server and account."),
        })
        return
    end
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = _("Search Grimmory"),
        input = "",
        input_hint = _("Title, author, series…"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dlg) end,
            },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local q = (dlg:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    UIManager:close(dlg)
                    if q == "" then return end
                    if not _self or _self.closed then Browser.show() end
                    showPagedList(T(_("Search: %1"), q), function(page)
                        return Api.searchBooks(q, page)
                    end)
                end,
            },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- ---------------------------------------------------------------------------
-- Hub
-- ---------------------------------------------------------------------------

local function hubRows()
    return {
        {
            text = _("Continue reading"),
            callback = function()
                showSimpleList(_("Continue reading"),
                    function() return Api.getContinueReading(30) end)
            end,
        },
        {
            text = _("Recently added"),
            callback = function()
                showSimpleList(_("Recently added"),
                    function() return Api.getRecentlyAdded(30) end)
            end,
        },
        { text = _("Libraries"), callback = showLibraries },
        { text = _("Shelves"),   callback = showShelves },
        {
            text = _("All books"),
            callback = function()
                showPagedList(_("All books"), function(page)
                    return Api.getBooks{ page = page }
                end)
            end,
        },
        { text = _("Search…"), callback = function() Browser.search() end },
    }
end

--- Open the browser. A second call while it is already open is a no-op rather
-- than a second window.
function Browser.show()
    if _self and not _self.closed then return _self end
    if not Api.isConfigured() then
        UIManager:show(InfoMessage:new{
            text = _("Set up your Grimmory server first: Tools ▸ Grimmory ▸ Server and account."),
        })
        return nil
    end

    local Menu   = require("ui/widget/menu")
    local Screen = require("device").screen

    local root = { title = _("Grimmory"), rows = hubRows() }
    _self = { stack = { root }, closed = false }

    _self.menu = Menu:new{
        title         = root.title,
        item_table    = root.rows,
        width         = Screen:getWidth(),
        height        = Screen:getHeight(),
        is_borderless = true,
        is_popout     = false,
        onReturn      = function() pop() end,
        -- close_callback is deliberately NOT set: Menu:onMenuSelect fires it
        -- after every leaf item tap (menu.lua:1360), which would tear the
        -- browser down the moment the user opened a book. Closing is routed
        -- through Browser.close instead.
    }
    -- Extend the list when the user ARRIVES at its last loaded page.
    --
    -- The obvious hook -- onNextPage, i.e. "they tried to page past the end" --
    -- does not work, and this is why: updateItems does
    --     page_info_right_chev:enableDisable(self.page < self.page_num)
    -- so on the last page the forward chevron is DISABLED and tapping it
    -- dispatches nothing at all. onNextPage never fires, and the user just
    -- gets a dead button. (This shipped, and it is exactly what it felt like.)
    --
    -- Hooking onGotoPage instead means the fetch happens when they land on the
    -- last page, so by the time they reach for the chevron there are more pages
    -- and it is live. Paging then feels continuous: every turn is native, and
    -- the only sign of a batch boundary is a brief "Loading more…".
    local menu_goto_page = Menu.onGotoPage
    _self.menu.onGotoPage = function(menu, page)
        local ret = menu_goto_page(menu, page)
        Browser.maybeLoadMore()
        return ret
    end

    -- Every close route (tap-outside, back-out past the root, the Home
    -- gesture) funnels into the one close path.
    _self.menu.onCloseAllMenus = function() Browser.close() return true end
    -- Menu's MenuItem:onHoldSelect calls menu:onMenuHold(entry) with the row.
    _self.menu.onMenuHold = function(_menu, row)
        if row and row.hold_callback then row.hold_callback() end
        return true
    end

    UIManager:show(_self.menu)
    return _self
end

--- If the current level paginates and the user is sitting on its last loaded
-- page, pull in the next batch. Safe to call at any time: it no-ops for levels
-- that don't paginate, while a fetch is already in flight, or once the server
-- has no more to give.
function Browser.maybeLoadMore()
    if not _self or _self.closed then return end
    local lvl = currentLevel()
    if not (lvl and lvl.load_more) then return end
    if _self.menu.page >= (_self.menu.page_num or 1) then
        lvl.load_more(false)
    end
end

--- Single authoritative close path.
function Browser.close()
    if not _self or _self.closed then return end
    _self.closed = true
    UIManager:close(_self.menu)
    _self = nil
end

function Browser.isShowing()
    return _self ~= nil and not _self.closed
end

-- Pure formatting helpers, exposed for tests/_test_logic.lua. These are the
-- parts of this module that can run without a device, and the progress-scale
-- logic in particular earned its coverage the hard way.
Browser._test = {
    statusOf           = statusOf,
    titleOf            = titleOf,
    bookRowText        = bookRowText,
    isDownloadable     = isDownloadable,
    plainText          = plainText,
    formatSeriesNumber = formatSeriesNumber,
    formatSize         = formatSize,
}

return Browser
