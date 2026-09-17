--[[--
Stroke rasteriser for pencil-handwriting.

This module is deliberately *stateless*: it owns no bitmap of its own and it
never blits a whole screen anywhere. It only knows how to paint a stroke onto
a caller-supplied Blitbuffer, and to report which rectangle it touched.

Why that matters
----------------
An earlier design kept a full-screen white canvas and blitted it over the
framebuffer. That is destructive on two counts:

* the white background of that canvas covers the page (and every open menu)
  wherever it is blitted -- including on the periodic full refresh, which
  turned the whole screen white;
* any repaint KOReader performs afterwards paints the page back *without* the
  strokes, so the notes vanished.

Instead, strokes are now drawn straight into whatever Blitbuffer the caller
owns:

* while writing, that is the live framebuffer, so only the pixels the pen
  actually covers are darkened and the page underneath survives;
* whenever KOReader repaints, a paintTo hook hands us the same buffer after
  the page has been drawn, so the strokes are simply painted again on top.

Because ink is only ever *added*, an eraser cannot work by painting white.
Erasing deletes whole strokes from the store and then asks for a repaint.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Config = require("pencilhw/config")

local Canvas = {}

-- ---------------------------------------------------------------------------
-- Colour resolution
-- ---------------------------------------------------------------------------
local color_cache = {}

local function colorForLevel(level)
    if level == 0x00 then return Blitbuffer.COLOR_BLACK end
    if level == 0xff then return Blitbuffer.COLOR_WHITE end
    -- Single-argument Color8 is the documented form; the four-argument form is
    -- accepted by some builds. Anything else degrades to black rather than
    -- breaking the draw call.
    local ok, color = pcall(Blitbuffer.Color8, level)
    if ok and color then return color end
    ok, color = pcall(Blitbuffer.Color8, level, level, level, 0xff)
    if ok and color then return color end
    return Blitbuffer.COLOR_BLACK
end

function Canvas.colorFor(key)
    local cached = color_cache[key]
    if cached then return cached end

    local level = 0x00
    for _, entry in ipairs(Config.COLOR_PALETTE) do
        if entry[1] == key then level = entry[3] break end
    end

    local color = colorForLevel(level)
    color_cache[key] = color
    return color
end

-- ---------------------------------------------------------------------------
-- Primitives
-- ---------------------------------------------------------------------------
local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Nothing but a finite number may reach the blitbuffer or a dirty region.
--
-- A NaN coordinate does not raise an error anywhere: clamp() passes it through
-- (both comparisons are false), the paint loop decides no row is worth painting,
-- and the function returns a region of NaN width -- which then goes into the
-- refresh queue. Infinity is worse: it can turn a line into an unbounded loop.
-- "v == v" is the cheapest NaN test there is.
local function isFinite(v)
    return type(v) == "number" and v == v
        and v ~= math.huge and v ~= -math.huge
end

local function bbSize(bb)
    local ok, w, h = pcall(function() return bb:getWidth(), bb:getHeight() end)
    if ok and tonumber(w) and tonumber(h) then return w, h end
    return nil, nil
end

-- Fill a disc row by row. Returns the rectangle that was touched, or nil when
-- nothing landed inside the buffer.
function Canvas.stampDisc(bb, x, y, radius, color, ox, oy)
    if not bb then return nil end
    ox, oy = ox or 0, oy or 0
    if not (isFinite(x) and isFinite(y) and isFinite(radius)
        and isFinite(ox) and isFinite(oy)) then
        return nil
    end

    local bw, bh = bbSize(bb)
    if not bw then return nil end

    x = clamp(math.floor(x + ox + 0.5), 0, bw - 1)
    y = clamp(math.floor(y + oy + 0.5), 0, bh - 1)
    radius = math.max(1, math.floor(radius + 0.5))

    local r2 = radius * radius
    local x0, x1 = x - radius, x + radius
    local y0, y1 = y - radius, y + radius

    for dy = -radius, radius do
        local dx_max = math.floor(math.sqrt(math.max(0, r2 - dy * dy)))
        local px = x - dx_max
        local pw = 2 * dx_max + 1

        if px < 0 then
            pw = pw + px
            px = 0
        end
        if px + pw > bw then
            pw = bw - px
        end

        local py = y + dy
        if pw > 0 and py >= 0 and py < bh then
            bb:paintRect(px, py, pw, 1, color)
        end
    end

    return { x = x0, y = y0, w = 2 * radius + 1, h = 2 * radius + 1 }
end

function Canvas.drawLine(bb, x0, y0, x1, y1, radius, color, ox, oy)
    if not bb then return nil end
    if not (isFinite(x0) and isFinite(y0) and isFinite(x1) and isFinite(y1)
        and isFinite(radius)) then
        return nil
    end

    local dx, dy = x1 - x0, y1 - y0
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 1 then
        return Canvas.stampDisc(bb, x1, y1, radius, color, ox, oy)
    end

    -- Stamps are spaced at half a radius so the line stays continuous without
    -- stamping the same pixels dozens of times.
    local step = math.max(1, math.floor(radius * 0.5))
    local steps = math.ceil(dist / step)

    local min_x, min_y, max_x, max_y
    for i = 0, steps do
        local t = i / steps
        local region = Canvas.stampDisc(bb, x0 + dx * t, y0 + dy * t,
            radius, color, ox, oy)
        if region then
            min_x = math.min(min_x or region.x, region.x)
            min_y = math.min(min_y or region.y, region.y)
            max_x = math.max(max_x or (region.x + region.w), region.x + region.w)
            max_y = math.max(max_y or (region.y + region.h), region.y + region.h)
        end
    end

    if not min_x then return nil end
    return { x = min_x, y = min_y, w = max_x - min_x, h = max_y - min_y }
end

-- ---------------------------------------------------------------------------
-- Strokes
-- ---------------------------------------------------------------------------
-- Strokes are stored in native (portrait) space, so a `tf` is supplied to map
-- each point into the current screen frame. A 90 degree rotation maps a
-- straight line onto a straight line, so transforming the endpoints is exact.
-- Eraser strokes are recorded only so an old sidecar file still loads; in the
-- current model the strokes an eraser removed are already gone from the store,
-- so there is nothing left to paint for them.
function Canvas.renderStroke(bb, stroke, ox, oy, tf)
    if not bb or not stroke or stroke.tool == "eraser" then return nil end

    local pts = stroke.points
    if not pts or #pts < 2 then return nil end

    local color = Canvas.colorFor(stroke.color or Config.DEFAULT_COLOR)
    local radius = (stroke.width or Config.DEFAULT_WIDTH) / 2

    local function point(i)
        local x, y = pts[i], pts[i + 1]
        if tf then
            local tx, ty = tf(x, y)
            if tonumber(tx) and tonumber(ty) then x, y = tx, ty end
        end
        return x, y
    end

    local x0, y0 = point(1)
    local region = Canvas.stampDisc(bb, x0, y0, radius, color, ox, oy)

    for i = 3, #pts - 1, 2 do
        local x1, y1 = point(i)
        local line = Canvas.drawLine(bb, x0, y0, x1, y1, radius, color, ox, oy)
        if line then
            if not region then
                region = line
            else
                local x = math.min(region.x, line.x)
                local y = math.min(region.y, line.y)
                local x2 = math.max(region.x + region.w, line.x + line.w)
                local y2 = math.max(region.y + region.h, line.y + line.h)
                region = { x = x, y = y, w = x2 - x, h = y2 - y }
            end
        end
        x0, y0 = x1, y1
    end
    return region
end

function Canvas.renderStrokes(bb, strokes, ox, oy, tf)
    if not bb or not strokes then return end
    for _, stroke in ipairs(strokes) do
        Canvas.renderStroke(bb, stroke, ox, oy, tf)
    end
end

return Canvas
