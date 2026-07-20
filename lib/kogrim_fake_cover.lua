-- kogrim_fake_cover.lua
-- The stand-in drawn for a book with no cover: a bordered panel with the title
-- and author set in text.
--
-- Not decoration. A Grimmory library routinely contains books whose metadata
-- never matched, and those are exactly the books the server has no artwork for
-- -- so the no-cover case is common, not exceptional. A screen of identical
-- generic icons would be unreadable, whereas a screen of titles is merely
-- plain. Same reasoning as titleOf's filename fallback in kogrim_browser.lua,
-- and the same approach KOReader's own CoverBrowser takes (FakeCover in
-- mosaicmenu.lua) for files it has not indexed yet.

local Blitbuffer    = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font          = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom          = require("ui/geometry")
local Size          = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan  = require("ui/widget/verticalspan")
local Screen        = require("device").screen

local FakeCover = {}

-- Font sizes are picked from the panel's width rather than being fixed, so the
-- same code produces something sensible in a small grid tile and in a large
-- one. The divisors are eyeballed against a Kobo's 3-column portrait grid.
local function faceFor(width, ratio, min, max)
    local size = math.floor(width / ratio)
    if size < min then size = min end
    if size > max then size = max end
    return size
end

--- Build a placeholder sized exactly width x height.
-- opts: { width, height, title, author }
function FakeCover.new(opts)
    local width, height = opts.width, opts.height
    local border = Size.border.thin
    local padding = Size.padding.small
    -- Clamped away from zero: a very dense grid can hand this a tile only a few
    -- pixels wide, and TextBoxWidget with a width <= 0 does not fail politely.
    local inner_w = math.max(8, width - 2 * border - 2 * padding)

    local title_size  = faceFor(width, 9, 12, 22)
    local author_size = faceFor(width, 12, 10, 18)

    -- Give the title most of the panel and the author the rest, and let both
    -- ellipsize rather than overflow: a long title must not push the author out
    -- of the frame or make this panel taller than the tile it has to fill.
    local avail_h = math.max(8, height - 2 * border - 2 * padding)
    local group = VerticalGroup:new{ align = "center" }

    local title = TextBoxWidget:new{
        text      = opts.title or "",
        face      = Font:getFace("cfont", title_size),
        width     = inner_w,
        height    = math.floor(avail_h * 0.6),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "center",
        bold      = true,
    }
    group[#group + 1] = title

    if opts.author and opts.author ~= "" then
        group[#group + 1] = VerticalSpan:new{ width = Size.padding.small }
        group[#group + 1] = TextBoxWidget:new{
            text      = opts.author,
            face      = Font:getFace("cfont", author_size),
            width     = inner_w,
            height    = math.floor(avail_h * 0.25),
            height_adjust = true,
            height_overflow_show_ellipsis = true,
            alignment = "center",
        }
    end

    return FrameContainer:new{
        width       = width,
        height      = height,
        margin      = 0,
        padding     = padding,
        bordersize  = border,
        color       = Blitbuffer.COLOR_GRAY,
        background  = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = avail_h },
            group,
        },
    }
end

-- Exposed so the grid can reserve the same border allowance for real covers,
-- keeping framed covers and placeholders exactly the same size.
FakeCover.BORDER = Size.border.thin

FakeCover._test = {
    faceFor = faceFor,
    scale   = function() return Screen:scaleBySize(1) end,
}

return FakeCover
