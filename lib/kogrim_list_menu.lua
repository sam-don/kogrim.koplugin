-- kogrim_list_menu.lua
-- List view: one book per row, with a small cover at the left.
--
-- The middle setting between text rows and the grid. It keeps everything the
-- text list shows -- title, author, series, and the right-hand column carrying
-- the local-copy tick, reading progress and file type -- and adds a thumbnail.
-- The grid trades that column away for size; this does not, which is why both
-- exist.
--
-- Same injection contract as kogrim_grid_menu.lua: exports _recalculateDimen
-- and _updateItemsBuildUI for kogrim_cover_menu.lua's updateItems to call.

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
local RightContainer  = require("ui/widget/container/rightcontainer")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = require("device").screen
local CoverCache      = require("lib/kogrim_cover_cache")
local FakeCover       = require("lib/kogrim_fake_cover")
local Settings        = require("lib/kogrim_settings")

local ListMenu = {}

-- ---------------------------------------------------------------------------
-- One row
-- ---------------------------------------------------------------------------

local ListItem = InputContainer:extend{
    entry  = nil,
    menu   = nil,
    width  = nil,
    height = nil,
}

function ListItem:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events = {
        TapSelect  = { GestureRange:new{ ges = "tap",  range = self.dimen } },
        HoldSelect = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    self[1] = self:build()
end

function ListItem:build()
    local entry = self.entry
    local border = FakeCover.BORDER
    local pad = Size.padding.default

    -- The cover gets the row's full height minus a little breathing room, and a
    -- width derived from the usual 2:3 book proportion. Rows must all be the
    -- same height, so this is fixed rather than measured from the artwork.
    local art_h = self.height - 2 * Size.padding.small
    local art_w = math.floor(art_h * 2 / 3)

    local art
    local bb = entry.kg_book
        and CoverCache.get(entry.kg_book, art_w - 2 * border, art_h - 2 * border)
    if bb then
        -- image_disposable = false: the buffer is CoverCache's, not ours.
        art = FrameContainer:new{
            margin = 0, padding = 0,
            bordersize = border,
            color = Blitbuffer.COLOR_GRAY,
            ImageWidget:new{ image = bb, image_disposable = false },
        }
        self.menu._kg_has_covers = true
    else
        art = FakeCover.new{
            width  = art_w,
            height = art_h,
            title  = entry.kg_title,
            author = entry.kg_author,
        }
    end

    -- The right-hand column keeps its natural width and the title gets what is
    -- left -- the same bargain stock Menu strikes with its `mandatory` column.
    local mandatory = entry.mandatory
    local mand_widget, mand_w = nil, 0
    if mandatory and mandatory ~= "" then
        mand_widget = TextWidget:new{
            text = mandatory,
            face = Font:getFace("infont", math.max(12, math.floor(self.height / 5))),
        }
        mand_w = mand_widget:getSize().w + pad
    end

    -- Clamped: a narrow screen with a long right-hand column ("✓ · 34% · EPUB")
    -- can leave nothing for the title, and TextBoxWidget given a width <= 0
    -- does not degrade gracefully. A squeezed title is recoverable; a crash on
    -- a device we cannot reproduce on is not.
    local text_w = math.max(Screen:scaleBySize(40),
        self.width - art_w - mand_w - 3 * pad)
    local title_size  = math.max(14, math.min(22, math.floor(self.height / 4)))
    local author_size = math.max(12, title_size - 4)

    local text_group = VerticalGroup:new{ align = "left" }
    text_group[#text_group + 1] = TextBoxWidget:new{
        text   = entry.kg_title or entry.text or "",
        face   = Font:getFace("cfont", title_size),
        width  = text_w,
        height = math.floor(self.height * 0.55),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        -- Books already downloaded are set bold, matching the ✓ in the
        -- right-hand column rather than replacing it.
        bold   = entry.kg_is_local or false,
    }
    if entry.kg_author then
        text_group[#text_group + 1] = VerticalSpan:new{ width = Size.padding.tiny }
        text_group[#text_group + 1] = TextBoxWidget:new{
            text   = entry.kg_author,
            face   = Font:getFace("cfont", author_size),
            width  = text_w,
            height = math.floor(self.height * 0.3),
            height_adjust = true,
            height_overflow_show_ellipsis = true,
        }
    end

    local row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = pad },
        CenterContainer:new{
            dimen = Geom:new{ w = art_w, h = self.height },
            art,
        },
        HorizontalSpan:new{ width = pad },
        LeftContainer:new{
            dimen = Geom:new{ w = text_w, h = self.height },
            text_group,
        },
    }
    if mand_widget then
        row[#row + 1] = RightContainer:new{
            dimen = Geom:new{ w = mand_w, h = self.height },
            mand_widget,
        }
    end
    row[#row + 1] = HorizontalSpan:new{ width = pad }
    return row
end

function ListItem:onTapSelect()
    self.menu:onMenuSelect(self.entry)
    return true
end

function ListItem:onHoldSelect()
    self.menu:onMenuHold(self.entry)
    return true
end

-- ---------------------------------------------------------------------------
-- Menu methods (injected)
-- ---------------------------------------------------------------------------

function ListMenu:_recalculateDimen()
    self.perpage = Settings.read("list_rows") or 6
    self.page_num = math.ceil(#self.item_table / self.perpage)
    if self.page_num > 0 and self.page > self.page_num then
        self.page = self.page_num
    end

    local others_height = 0
    if self.title_bar then
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

    self.item_margin = Screen:scaleBySize(2)
    self.item_height = math.floor(
        (self.inner_dimen.h - others_height - (1 + self.perpage) * self.item_margin)
        / self.perpage)
    self.item_width = self.inner_dimen.w
    self.item_dimen = Geom:new{ x = 0, y = 0, w = self.item_width, h = self.item_height }
end

function ListMenu:_updateItemsBuildUI()
    local idx_offset = (self.page - 1) * self.perpage
    local select_number

    for idx = 1, self.perpage do
        local index = idx_offset + idx
        local entry = self.item_table[index]
        if entry == nil then break end
        entry.idx = index
        if index == self.itemnumber then
            select_number = idx
        end

        table.insert(self.item_group, VerticalSpan:new{ width = self.item_margin })
        local item = ListItem:new{
            entry       = entry,
            menu        = self,
            width       = self.item_width,
            height      = self.item_height,
            show_parent = self.show_parent,
        }
        table.insert(self.item_group, item)
        table.insert(self.layout, { item })
    end

    table.insert(self.item_group, VerticalSpan:new{ width = self.item_margin })
    return select_number
end

ListMenu._test = {
    ListItem = ListItem,
}

return ListMenu
