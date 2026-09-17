--[[--
Screen <-> document page coordinates, taken from the reader itself.

Ink has to stay attached to the content it was written on. Screen pixels do not
do that: whenever a page's position on the screen changes between visits -- a
scrolled view (contentwidth zoom on a PDF is one), a zoom change, a page that is
only partly on screen -- a stroke stored in screen coordinates slides over the
content underneath it. Handwriting done while looking at one part of a page then
shows up over another part, or over the neighbouring page: real ink, anchored to
the wrong thing.

The reader already knows both directions:

    ReaderView:screenToPageTransform(pos)   -- screen point -> {x, y, page}
    ReaderView:pageToScreenTransform(page, rect) -- page rect -> screen rect

The first is what KOReader itself uses to turn a touch into a page position; the
second is what it uses to draw highlights. Neither needs to know anything about
the view mode (single page or scrolled, any zoom), and both take plain tables
with x/y. So this module is a thin, defensive wrapper around them:

  * screen -> page: one call, which also answers *which page* the point is on.
  * page -> screen: one call per page to derive that page's affine map, which is
    what the drawing code wants (a transform it can apply per point).

The per-page part matters: in a scrolled view each page on screen has its own
offset and zoom, so a single "current view" map is only correct for one of them.
Deriving one affine per visible page is what makes multi-page scroll views draw
correctly instead of shifting every page but the first.

Every affine is cross-checked against a screen point the reader reported for
that same page; if the two disagree the page is dropped rather than drawn
somewhere wrong (the reader's page argument is ignored in single-page mode, so
this check is not theoretical).

No requires on purpose. An earlier version of this file did
`require("ui/geom")` -- a module that does not exist in KOReader (it is
`ui/geometry`), and a failing require in a submodule takes the entire plugin
down with it. Nothing here needs KOReader beyond the ReaderView handed in.
--]]

local ViewMap = {}
ViewMap.__index = ViewMap

-- Probe rectangles must have a non-zero area: the reader's rect helpers reject
-- zero-area rects outright (`Geom:notIntersectWith` returns true when
-- `rect_b:area() == 0`), so probing with a point would always come back nil. A
-- probe this large always covers the visible area, which makes it valid at any
-- zoom, scroll offset and page margin.
local PROBE = 1e6
local PROBE_W = 2 * PROBE

-- A derived map is accepted only if it puts a point the reader reported back
-- within this many pixels of where the reader said it was.
local CHECK_TOLERANCE_PX = 4

-- view          -- a ReaderView instance
-- sw, sh        -- framebuffer size in pixels
-- fallback_page -- used when the reader does not report a page for a point
function ViewMap.measure(view, sw, sh, fallback_page)
    if not view then return nil end
    if type(view.screenToPageTransform) ~= "function"
        or type(view.pageToScreenTransform) ~= "function" then
        return nil
    end
    if type(sw) ~= "number" or type(sh) ~= "number" or sw < 2 or sh < 2 then
        return nil
    end

    return setmetatable({
        view = view,
        sw = sw,
        sh = sh,
        page = fallback_page,
        _affines = {},
        _relaxed = {},
    }, ViewMap)
end

-- The page the reader puts under a screen point, and that point in the page's
-- own coordinates. One call into the reader: the page number is its answer
-- rather than something inferred from an event.
function ViewMap:pageAt(sx, sy)
    if type(sx) ~= "number" or type(sy) ~= "number" then return nil end

    local view = self.view
    local ok, out = pcall(view.screenToPageTransform, view, { x = sx, y = sy })
    if not ok or type(out) ~= "table" then return nil end

    local x, y = tonumber(out.x), tonumber(out.y)
    if x == nil or y == nil then
        -- Some builds return the position inside a nested object instead.
        local p = out.pos
        if type(p) == "table" then
            x, y = tonumber(p.x) or x, tonumber(p.y) or y
        end
    end
    if x == nil or y == nil then return nil end

    -- In a scrolled view the reader resolves which page the point landed on;
    -- in single-page mode it is the page being shown.
    local page = tonumber(out.page) or tonumber(self.page)
    if page == nil then return nil end

    return page, x, y
end

-- Screen anchors per visible page: points the reader itself confirmed are on
-- that page, used to range the visible pages and to verify the affine maps.
--
-- Two points per page are kept, as far apart as the sampling allows. One point
-- can only pin the map's translation -- a map with a transposed or mirrored
-- basis would still place that single point correctly, and the ink would then
-- come out rotated on the page. Two points pin the basis as well.
function ViewMap:anchors()
    if self._anchors then return self._anchors end

    local samples, order = {}, {}
    local xs = { 1, math.floor(self.sw / 2), self.sw - 1 }
    local ys = {
        1,
        math.floor(self.sh / 4),
        math.floor(self.sh / 2),
        math.floor(self.sh * 3 / 4),
        self.sh - 1,
    }
    for _, y in ipairs(ys) do
        for _, x in ipairs(xs) do
            local page, px, py = self:pageAt(x, y)
            if page ~= nil then
                samples[page] = samples[page] or {}
                local list = samples[page]
                if #list == 0 then order[#order + 1] = page end
                list[#list + 1] = { sx = x, sy = y, px = px, py = py }
            end
        end
    end

    local anchors = {}
    for page, list in pairs(samples) do
        local chosen = { list[1] }
        local best, best_d = nil, -1
        for i = 2, #list do
            local dx, dy = list[i].sx - list[1].sx, list[i].sy - list[1].sy
            local d = dx * dx + dy * dy
            if d > best_d then best_d, best = d, list[i] end
        end
        -- Only worth a second check point if it is far enough to mean something.
        if best and best_d > 64 then chosen[2] = best end
        anchors[page] = chosen
    end

    self._anchors, self._anchor_order = anchors, order
    return anchors
end

-- Range of pages visible on screen: one page in page mode, two or more in a
-- scrolled view.
function ViewMap:visiblePageRange(sw, sh)
    local anchors = self:anchors()
    local first, last
    for page in pairs(anchors) do
        local n = tonumber(page)
        if n then
            if first == nil or n < first then first = n end
            if last == nil or n > last then last = n end
        end
    end
    if first == nil then return nil end
    return first, last
end

-- The affine map of one page: screen = page * scale + offset.
--
-- Derived by one call to the reader, then checked against the screen points the
-- reader itself reported for that page. A map that cannot be confirmed is
-- *re-anchored* rather than thrown away: refusing it would leave the ink
-- invisible, which is the worst possible outcome (handwriting that was stored
-- correctly but never shown looks exactly like handwriting that was lost).
--
-- Re-anchoring: the probe measures the page argument on the reader side, and in
-- single-page mode the reader ignores that argument, so the probe's translation
-- can belong to a different page. Its *scale* is still the view's scale, so the
-- translation is rebuilt from the point the reader confirmed:
--
--     offset = anchor_screen - anchor_page * scale
--
-- which is right by construction at that anchor, and still checked at the other
-- one. Maps built this way are flagged (ViewMap:isRelaxed) so the diagnostics
-- can say how often it happened.
function ViewMap:affineForPage(page)
    page = tonumber(page)
    if page == nil then return nil end

    local cached = self._affines[page]
    if cached ~= nil then
        return cached or nil
    end

    local affine = self:probeAffine(page)
    local anchors = self:anchors()[page] or {}

    if affine and not self:checkAffine(affine, anchors) then
        local anchor = anchors[1]
        if anchor and anchor.px ~= nil then
            local reanchored = {
                scale = affine.scale,
                ox = anchor.sx - anchor.px * affine.scale,
                oy = anchor.sy - anchor.py * affine.scale,
                relaxed = true,
            }
            if self:checkAffine(reanchored, anchors) then
                affine = reanchored
                self._relaxed = self._relaxed or {}
                self._relaxed[page] = true
            else
                affine = nil
            end
        else
            affine = nil
        end
    end

    self._affines[page] = affine or false
    return affine
end

-- Every anchor the reader reported for this page has to land where the reader
-- said it was. Two of them when the sampling allows, which pins the basis as
-- well as the translation.
function ViewMap:checkAffine(affine, anchors)
    for _, anchor in ipairs(anchors) do
        local sx = affine.ox + anchor.px * affine.scale
        local sy = affine.oy + anchor.py * affine.scale
        if math.abs(sx - anchor.sx) > CHECK_TOLERANCE_PX
            or math.abs(sy - anchor.sy) > CHECK_TOLERANCE_PX then
            return false
        end
    end
    return true
end

-- True when this page's map had to be re-anchored (the reader's own map for it
-- could not be confirmed). The ink is still placed from the reader's own
-- coordinates, but it is worth knowing.
function ViewMap:isRelaxed(page)
    page = tonumber(page)
    return (self._relaxed and page ~= nil and self._relaxed[page]) and true or false
end

function ViewMap:probeAffine(page)
    local view = self.view
    local probe = { x = -PROBE, y = -PROBE, w = PROBE_W, h = PROBE_W }

    local ok, r = pcall(view.pageToScreenTransform, view, page, probe)
    if not ok or type(r) ~= "table" then return nil end

    local w, x, y = tonumber(r.w), tonumber(r.x), tonumber(r.y)
    if w == nil or x == nil or y == nil or w <= 0 then return nil end

    -- The probe rect is PROBE_W page pixels wide, so the width it comes back
    -- with is that many screen pixels: the scale. Its origin then tells us
    -- where page coordinate (0, 0) sits.
    local scale = w / PROBE_W
    -- A sane zoom is a small number around 1. Anything else (0, NaN, infinity,
    -- or a wildly large value) means the probe did not measure what we think it
    -- measured, and drawing with it would plaster the page.
    if not (scale > 0 and scale < 1000) then return nil end
    if not (x == x and y == y) then return nil end

    return {
        scale = scale,
        ox = x + PROBE * scale,
        oy = y + PROBE * scale,
    }
end

-- A plain function(x, y) the rasteriser can call per point, or nil when this
-- page cannot be placed. Returning nil (rather than a function that passes
-- coordinates through) is deliberate: the caller then draws nothing for that
-- page, instead of drawing page pixels as screen pixels.
function ViewMap:mapForPage(page)
    local affine = self:affineForPage(page)
    if not affine then return nil end

    local scale, ox, oy = affine.scale, affine.ox, affine.oy
    return function(x, y)
        return ox + x * scale, oy + y * scale
    end
end

-- Inverse of the above, for turning a pen position into a page coordinate.
function ViewMap:toPage(page, sx, sy)
    local affine = self:affineForPage(page)
    if not affine or type(sx) ~= "number" or type(sy) ~= "number" then return nil end
    return (sx - affine.ox) / affine.scale, (sy - affine.oy) / affine.scale
end

-- Screen pixels per page pixel: the zoom of the affine above. A page 1.5x
-- magnified on screen gives 1.5.
function ViewMap:screenPerPage(page)
    local affine = self:affineForPage(page)
    if not affine then return 1 end
    return affine.scale
end

-- Page pixels per screen pixel -- the reciprocal, and the one a distance
-- measured on screen has to be multiplied by. Getting this the wrong way round
-- is not harmless: a radius scaled by the zoom instead of divided by it shrinks
-- by the square of the zoom, which is why the eraser used to do nothing at all
-- on a zoomed-out view (a 24 px disc became a few pixels and missed every
-- stroke).
function ViewMap:pagePerScreen(page)
    local affine = self:affineForPage(page)
    if not affine or affine.scale == 0 then return 1 end
    return 1 / affine.scale
end

return ViewMap
