-- kogrim_grid_menu.lua
-- Grid ("mosaic") view: a page of cover tiles with the title underneath.
--
-- Exports the two methods kogrim_cover_menu.lua's updateItems calls out to --
-- _recalculateDimen (how many tiles, and how big) and _updateItemsBuildUI
-- (build them). Both are injected onto a Menu instance; see the header of
-- kogrim_cover_menu.lua for why that is the seam.
--
-- Layout follows MosaicMenu in KOReader's coverbrowser plugin closely, because
-- its arithmetic for fitting rows of tiles between a title bar and a page
-- footer is already correct and the failure mode for getting it slightly wrong
-- is a grid that overflows the screen. What is NOT taken from it is the data
-- side: MosaicMenu reads from BookInfoManager, a SQLite store keyed by local
-- filepath that rips covers out of local ebook files. Our books are remote.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local ImageWidget     = require("ui/widget/imagewidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = require("device").screen
local CoverCache      = require("lib/kogrim_cover_cache")
local FakeCover       = require("lib/kogrim_fake_cover")
local Settings        = require("lib/kogrim_settings")

local GridMenu = {}

-- ---------------------------------------------------------------------------
-- One tile
-- ---------------------------------------------------------------------------

local GridItem = InputContainer:extend{
    entry  = nil,  -- the Menu row, mandatory
    menu   = nil,
    width  = nil,
    height = nil,
}

function GridItem:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    -- Per-instance, because the gesture range is this tile's own rectangle.
    self.ges_events = {
        TapSelect  = { GestureRange:new{ ges = "tap",  range = self.dimen } },
        HoldSelect = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    self[1] = self:build()
end

function GridItem:build()
    local entry = self.entry
    local border = FakeCover.BORDER

    -- Reserve two lines for the caption. Fixed rather than measured so that
    -- every tile on the page is the same shape -- a grid whose covers start at
    -- different heights because one title wrapped reads as broken.
    local caption_face_size = math.max(12, math.min(18, math.floor(self.width / 11)))
    local line_h = math.ceil(caption_face_size * 1.4)
    local caption_h = line_h * 2
    local gap = Size.padding.small

    local art_h = self.height - caption_h - gap
    local art_w = self.width

    local art
    local bb = entry.kg_book
        and CoverCache.get(entry.kg_book, art_w - 2 * border, art_h - 2 * border)
    if bb then
        -- image_disposable = false is mandatory: this buffer belongs to
        -- CoverCache and is very likely shared with the page the user just
        -- came from. Letting ImageWidget free it on close would leave a
        -- dangling pointer in the cache. See the header of
        -- kogrim_cover_cache.lua.
        art = FrameContainer:new{
            margin     = 0,
            padding    = 0,
            bordersize = border,
            color      = Blitbuffer.COLOR_GRAY,
            ImageWidget:new{
                image            = bb,
                image_disposable = false,
            },
        }
        self.menu._kg_has_covers = true
    else
        -- No cover yet (or none at all): a titled panel, not a blank hole.
        art = FakeCover.new{
            width  = art_w,
            height = art_h,
            title  = entry.kg_title,
            author = entry.kg_author,
        }
    end

    local caption = TextBoxWidget:new{
        text      = entry.kg_title or entry.text or "",
        face      = Font:getFace("cfont", caption_face_size),
        width     = self.width,
        height    = caption_h,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "center",
        bold      = entry.kg_is_local or false,
    }

    return VerticalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = art_h },
            art,
        },
        VerticalSpan:new{ width = gap },
        caption,
    }
end

-- Route taps back through Menu's own dispatch, so the row contract built by
-- bookRows (callback / hold_callback) works unchanged in every view mode.
function GridItem:onTapSelect()
    self.menu:onMenuSelect(self.entry)
    return true
end

function GridItem:onHoldSelect()
    self.menu:onMenuHold(self.entry)
    return true
end

-- ---------------------------------------------------------------------------
-- Menu methods (injected)
-- ---------------------------------------------------------------------------

function GridMenu:_recalculateDimen()
    local portrait = Screen:getWidth() <= Screen:getHeight()
    if portrait then
        self.nb_cols = Settings.read("grid_cols") or 3
        self.nb_rows = Settings.read("grid_rows") or 3
    else
        -- Landscape gets more columns and fewer rows; keeping the portrait
        -- numbers would produce tall thin tiles with nothing in them.
        self.nb_cols = Settings.read("grid_cols_landscape") or 4
        self.nb_rows = Settings.read("grid_rows_landscape") or 2
    end
    self.perpage = self.nb_rows * self.nb_cols
    self.page_num = math.ceil(#self.item_table / self.perpage)
    -- Changing modes or rotating can leave the current page past the end.
    if self.page_num > 0 and self.page > self.page_num then
        self.page = self.page_num
    end

    -- Height taken by everything that is not tiles.
    local others_height = 0
    if self.title_bar then -- init() has run
        if not self.is_borderless then
            others_height = others_height + 2
        end
        if not self.no_title then
            others_height = others_height + self.title_bar.dimen.h
        end
        if self.page_info then
            others_height = others_height + self.page_info:getSize().h
        end
    end

    self.item_margin = Screen:scaleBySize(10)
    self.item_height = math.floor(
        (self.inner_dimen.h - others_height - (1 + self.nb_rows) * self.item_margin)
        / self.nb_rows)
    self.item_width = math.floor(
        (self.inner_dimen.w - (1 + self.nb_cols) * self.item_margin) / self.nb_cols)
    self.item_dimen = Geom:new{ x = 0, y = 0, w = self.item_width, h = self.item_height }
end

function GridMenu:_updateItemsBuildUI()
    local idx_offset = (self.page - 1) * self.perpage
    local cur_row, line_layout
    local select_number

    for idx = 1, self.perpage do
        local index = idx_offset + idx
        local entry = self.item_table[index]
        if entry == nil then break end
        entry.idx = index
        if index == self.itemnumber then
            select_number = idx
        end

        if idx % self.nb_cols == 1 or self.nb_cols == 1 then -- start a row
            if line_layout then table.insert(self.layout, line_layout) end
            line_layout = {}
            table.insert(self.item_group, VerticalSpan:new{ width = self.item_margin })
            cur_row = HorizontalGroup:new{}
            -- A partly-filled last row is left-aligned rather than centred, so
            -- the first tile of every row lines up down the page.
            table.insert(self.item_group, LeftContainer:new{
                dimen = Geom:new{ w = self.inner_dimen.w, h = self.item_height },
                cur_row,
            })
            table.insert(cur_row, HorizontalSpan:new{ width = self.item_margin })
        end

        local item = GridItem:new{
            entry       = entry,
            menu        = self,
            width       = self.item_width,
            height      = self.item_height,
            show_parent = self.show_parent,
        }
        table.insert(cur_row, item)
        table.insert(cur_row, HorizontalSpan:new{ width = self.item_margin })
        table.insert(line_layout, item)
    end

    if line_layout then table.insert(self.layout, line_layout) end
    table.insert(self.item_group, VerticalSpan:new{ width = self.item_margin })
    return select_number
end

GridMenu._test = {
    GridItem = GridItem,
}

return GridMenu
