-- kogrim_cover_menu.lua
-- The part of cover-bearing list rendering that both view modes share.
--
-- This is a bag of methods, not a widget. They are copied onto a live Menu
-- INSTANCE in kogrim_browser.lua:
--
--     menu.updateItems         = CoverMenu.updateItems
--     menu._recalculateDimen   = GridMenu._recalculateDimen
--     menu._updateItemsBuildUI = GridMenu._updateItemsBuildUI
--
-- which is exactly how KOReader's own CoverBrowser plugin extends the file
-- browser (see the injection block in coverbrowser.koplugin/main.lua). Worth
-- being explicit about why that is the chosen seam: `_updateItemsBuildUI` is
-- NOT a Menu hook -- stock menu.lua has never heard of it. It is invented by
-- covermenu.lua, which calls it from its own updateItems. So overriding
-- updateItems is not optional; it is what creates the hook the mode modules
-- fill in.
--
-- DEPENDENCE ON MENU INTERNALS: item_group, inner_dimen, item_dimen, perpage,
-- page_num, page_info, return_button and content_group are all private to
-- Menu. The bet being made is that CoverBrowser -- a plugin KOReader ships,
-- and therefore tests -- leans on precisely the same fields, so they cannot be
-- reshaped upstream without breaking that first. If a KOReader upgrade ever
-- does break this, the failure will be loud and it will be here.

local Menu      = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local Queue     = require("lib/kogrim_cover_queue")

local CoverMenu = {}

--- The books on the page about to be drawn.
-- Rows built by bookRows carry their summary as `kg_book`; rows that are not
-- books (the "No books here." placeholder) simply do not, and are skipped.
local function visibleBooks(self)
    local books = {}
    local offset = (self.page - 1) * self.perpage
    for i = 1, self.perpage do
        local entry = self.item_table[offset + i]
        if entry == nil then break end
        if entry.kg_book then books[#books + 1] = entry.kg_book end
    end
    return books
end

--- Ask the queue for whatever this page is missing, and repaint once when it
-- has it.
--
-- The completion callback is the delicate part: it fires after an arbitrary
-- number of blocking network calls, by which point the browser may have been
-- closed, the level popped, or the page turned. Everything it touches is
-- re-checked at call time rather than captured.
local function requestCovers(self)
    local page_at_request = self.page
    Queue.start(visibleBooks(self), function()
        -- Torn down while we were fetching.
        if self.kg_closed then return end
        -- Paged away: the covers are on disk and cached, so arriving back here
        -- later will draw them with no further work. Repainting now would
        -- redraw a page the user is no longer looking at.
        if self.page ~= page_at_request then return end
        self:updateItems(nil, true)
    end)
end

function CoverMenu:updateItems(select_number, no_recalculate_dimen)
    local old_dimen = self.dimen and self.dimen:copy()
    self.layout = {}
    self.item_group:clear()

    -- Order matters and is not the same as stock Menu's. Our _recalculateDimen
    -- overloads read title_bar/page_info geometry to work out how much height
    -- is left for tiles, so they have to run before those get reset -- the same
    -- ordering note covermenu.lua carries upstream.
    if not no_recalculate_dimen then
        self:_recalculateDimen()
    end
    self.page_info:resetLayout()
    self.return_button:resetLayout()
    self.content_group:resetLayout()

    self._kg_has_covers = false
    select_number = self:_updateItemsBuildUI() or select_number

    self:updatePageInfo(select_number)
    Menu.mergeTitleBarIntoLayout(self)

    -- Dithering matters once real photographic covers are on screen; text rows
    -- never needed it. Harmless on hardware without it.
    self.show_parent.dithered = self._kg_has_covers
    UIManager:setDirty(self.show_parent, function()
        local refresh_dimen = old_dimen and old_dimen:combine(self.dimen) or self.dimen
        return "ui", refresh_dimen, self.show_parent.dithered
    end)

    -- Kick this off last, so the page is already on screen before the first
    -- blocking fetch. A run that finds nothing pending is a no-op, so the
    -- repaint this schedules cannot feed back into itself.
    requestCovers(self)
end

CoverMenu._test = {
    visibleBooks = visibleBooks,
}

return CoverMenu
