--[[--
Configuration for pencil-handwriting.

Kept in its own namespace (pencilhw/) so that it can never collide with a
module exposed by another plugin sharing the global package.loaded table.
--]]

local _ = require("gettext")
-- The colour names are shown in a menu, so they go through the plugin's own
-- dictionary as well. Loading it must not be able to break the plugin: on any
-- failure the plain gettext function is kept and the labels stay English.
do
    local ok, i18n = pcall(require, "pencilhw/i18n")
    if ok and type(i18n) == "table" and type(i18n.gettext) == "function" then
        _ = i18n.gettext
    end
end

local Config = {}

-- ============================================================================
-- Version
-- ============================================================================
-- Single source of truth: main.lua and _meta.lua both read this, so the build
-- reported in the diagnostics can never be a stale copy again.
Config.VERSION = "0.9.9"

-- ============================================================================
-- Input device discovery
-- ============================================================================
-- Nodes are autodetected: /proc/bus/input/devices is parsed and the node that
-- actually advertises a pen tool (BTN_TOOL_PEN / BTN_TOOL_RUBBER) wins. A
-- hardcoded path is not reliable here -- the digitizer node name and index
-- differ between Kindle models and firmware revisions.
Config.EXTRA_DEVICE_PATHS = {}
-- Tried first, in order, before autodetection. Fill this in only if
-- autodetection picks the wrong node, e.g. { "/dev/input/event3" }.

Config.TOUCH_DEVICE_CANDIDATES = {
    "/dev/input/touch",     -- Kindle Scribe / Scribe 3 / Colorsoft
    "/dev/input/event2",
    "/dev/input/event1",
    "/dev/input/event0",
}
-- Last-resort fallback, used only when nothing above matches. The pen node is
-- blind guessing at this point, so a warning is logged when it is used.

Config.PEN_NAME_HINTS    = { "wacom", "stylus", "pen", "digitizer", "elan", "scrib" }
Config.FINGER_NAME_HINTS = { "touchscreen", "cyttsp", "goodix", "ft5x06", "himax",
                             "synaptics", "atmel", "touch" }

-- BTN_TOOL_PEN / BTN_TOOL_RUBBER: decisive evidence that a node is a digitizer.
Config.PEN_KEY_BITS = { 0x140, 0x141 }

-- ============================================================================
-- evdev constants (linux/input-event-codes.h)
-- ============================================================================
Config.EV_SYN                    = 0x00
Config.EV_KEY                    = 0x01
Config.EV_ABS                    = 0x03

Config.SYN_REPORT                = 0x00

Config.BTN_TOUCH                 = 0x14a
Config.BTN_TOOL_PEN              = 0x140
Config.BTN_TOOL_RUBBER           = 0x141

Config.ABS_X                     = 0x00
Config.ABS_Y                     = 0x01
Config.ABS_PRESSURE              = 0x18
Config.ABS_MT_SLOT               = 0x2f
Config.ABS_MT_POSITION_X         = 0x35
Config.ABS_MT_POSITION_Y         = 0x36
Config.ABS_MT_TOOL_TYPE          = 0x37
Config.ABS_MT_TRACKING_ID        = 0x39
Config.ABS_MT_PRESSURE           = 0x3a

Config.TOOL_FINGER               = 0
Config.TOOL_PEN                  = 1
Config.TOOL_ERASER               = 2
Config.TOOL_HIGHLIGHTER          = 3

-- ============================================================================
-- Pen behaviour
-- ============================================================================
Config.MIN_MOVE_DISTANCE_PX      = 2

Config.DEFAULT_WIDTH             = 3
Config.MIN_WIDTH                 = 1
Config.MAX_WIDTH                 = 24
Config.WIDTH_PRESETS             = { 1, 2, 3, 5, 8, 12, 16, 24 }

Config.DEFAULT_COLOR             = "black"

-- Palette entries: { key, gettext label, 8-bit gray level (0-255) }
-- Gray levels are resolved to Blitbuffer colours at runtime in canvas.lua.
Config.COLOR_PALETTE = {
    { "black",  _("Black"),     0x00 },
    { "gray25", _("Gray 25%"),  0x40 },
    { "gray50", _("Gray 50%"),  0x80 },
    { "gray75", _("Gray 75%"),  0xc0 },
    { "white",  _("White"),     0xff },
}

-- ============================================================================
-- Input source
-- ============================================================================
-- Default only: the effective value is stored in the global reader settings
-- and can be switched at runtime from "Pencil handwriting -> Input source".
--   "auto"    -- prefer KOReader's stylus API, fall back to evdev
--   "stylus"  -- only the KOReader stylus callback (>= 2026.07.2-60 nightly)
--   "evdev"   -- only read the digitizer node ourselves
-- The stylus API is strongly preferred: KOReader has already parsed the node,
-- knows which slot belongs to the pen, and lets the callback *dominate* the
-- event so a pen stroke can never be interpreted as a page-turn swipe.
Config.INPUT_SOURCE = "auto"

-- Coordinates handed to the stylus callback are raw digitizer values, which
-- normally already are native (portrait) panel pixels -- the space strokes are
-- stored in. If a device reports in its own units instead, "auto" notices the
-- out-of-range values, opens the digitizer node read-only to learn its axis
-- ranges, and scales them into place. The screen rotation is applied
-- separately, at draw time, by pencilhw/geometry.
Config.STYLUS_COORD_CORRECTION = "auto"     -- "auto" | "none"

-- ============================================================================
-- Coordinate handling
-- ============================================================================
-- The digitizer reports absolute coordinates in its own units, which do not
-- have to match the panel resolution. When the node exposes ABS_X/ABS_Y or
-- the multitouch equivalents, their min/max are read with EVIOCGABS and the
-- values are scaled into screen pixels. Set to false if the ranges are
-- reported wrongly and strokes end up scaled.
Config.AUTO_SCALE_RAW            = true

-- ============================================================================
-- Input interception
-- ============================================================================
-- Grabbing the node exclusively means KOReader's own gesture detector never
-- sees the pen. It only matters when the pen shares one node with the
-- capacitive layer; if it does not, grabbing is unnecessary. It is dangerous
-- on a shared node (finger input would die), so it stays opt-in.
Config.EXCLUSIVE_GRAB_DEFAULT    = false

-- Swallow touch gestures while drawing so a resting palm or wrist does not
-- turn pages. Off by default: the pen is filtered out of touch handling
-- anyway, and blocking all touches would also block the menus.
Config.BLOCK_TOUCH_DEFAULT       = false

-- Taps inside the top strip must keep opening the reader menu, otherwise
-- touch blocking would make the menu unreachable. Ratio of screen height.
Config.MENU_STRIP_RATIO          = 0.12

-- ============================================================================
-- Eraser
-- ============================================================================
Config.ERASER_RADIUS_PX          = 24

-- An erase pass only rescans when the eraser has moved this far, and no more
-- often than the given interval. The scan is linear in the number of points
-- stored for the page, and erase events arrive at the digitizer rate, so
-- without throttling a heavily annotated page stalls the input loop.
-- The interval is kept short enough that consecutive scans stay closer
-- together than the eraser disc's diameter, so coverage has no holes.
Config.ERASE_MIN_MOVE_PX         = 4
Config.ERASE_MIN_INTERVAL_S      = 0.02

-- Repainting the page is expensive, so erases coalesce into at most one
-- repaint per window. Lifting the eraser always forces a final repaint.
-- Flooding the refresh queue instead is what made the device appear frozen.
Config.ERASE_REFRESH_MS          = 400

-- ============================================================================
-- Refresh strategy
-- ============================================================================
-- After the pen lifts: persist, then one proper refresh that also clears the
-- ghosting the fast partial refreshes leave behind.
Config.REFRESH_SETTLE_MS         = 600

-- How long after a page change the page-identity accessors are re-read, to
-- find out whether they track pages at all. Delayed on purpose: the document's
-- own fields can still hold the old page at the instant the page-change event
-- fires, so probing immediately would blame a healthy accessor.
Config.KEY_AUDIT_DELAY_S         = 0.4

-- ============================================================================
-- Page identity
-- ============================================================================
-- A stroke is filed under a page identifier and the same identifier decides
-- which strokes are painted. Deriving it two different ways in the write path
-- and in the paint path is exactly what makes one stroke show up on two pages
-- -- so main.lua keeps a single value (self.page_key), resolved in one place
-- and updated the moment a page-change event arrives.
--
-- There is deliberately no menu switch for this. The document accessors were
-- measured *lagging behind* the page turn on this build (crash.log: a page
-- change to 40, and `ui.paging.current_page` still reporting 39 four tenths of
-- a second later), and a lagging identity paints one page's strokes onto its
-- neighbour -- so a switch was a way to break the plugin by accident. The
-- identity is chosen automatically:
--
--   paged documents (PDF, DjVu, CBZ) -> the PageUpdate event page
--   reflowable documents (EPUB, FB2) -> the accessor chain, xpointer first
--
-- The values are:
--   "auto" -- as described above (the only supported setting)
--   "live" -- source-level debug: always the accessor chain, even for paged
--             documents. Expect ink on the neighbouring page; used only to
--             compare what the accessors report against the event.
-- Whatever is chosen, the diagnostics print the event page, the identity in
-- use, and what every accessor returns.
Config.PAGE_KEY_SOURCE           = "auto"

-- Menu switch: force the panel clean-up on *every* page turn, not only the
-- pages that have ink on them. Only useful as a test -- the diagnostics show
-- whether it is on.
Config.FULL_REFRESH_ON_PAGE_CHANGE = false

-- What happens to the panel when a page has been written on and is then left.
--
-- Ink is drawn straight into the framebuffer, so it is not part of KOReader's
-- page image. A page turn repaints the framebuffer correctly, but the *panel*
-- is only given a non-flashing update, and that does not erase solid black ink:
-- the strokes from the page you just left stay visible as a ghost on the next
-- one. Text ghosts far less than a pen stroke, which is why only the ink
-- follows you.
--
--   "on_ink" -- one flashing full refresh after a turn, only when the page
--               being left has ink on it (default). Pages you have not written
--               on keep KOReader's normal, fast, flash-free turn.
--   "always" -- flash on every page turn
--   "off"    -- never; KOReader's own refresh decision stands
Config.PAGE_EXIT_CLEANUP = "on_ink"

-- The refresh mode used for that clean-up. "full" flashes the whole screen,
-- which is what actually removes the ghost; "flashui" and "ui" are gentler and
-- may leave a trace of heavy ink.
Config.PAGE_EXIT_REFRESH_MODE = "full"

-- Guard for a long stroke drawn without ever lifting the pen: one real refresh
-- every few seconds. Note that a refresh *includes* the strokes, it does not
-- replace them, so this is only about ghosting, never about data loss.
Config.REFRESH_GHOST_MS          = 8000

Config.POLL_INTERVAL_S           = 0.008

-- ============================================================================
-- Persistence
-- ============================================================================
Config.SIDECAR_FILENAME          = "pencil_handwriting.lua"
Config.STROKE_FORMAT_VERSION     = 2

-- Stroke coordinates are stored in document *page* space (document pixels at
-- scale 1, measured with the reader's own screenToPageTransform) so the ink
-- stays attached to the content it was written on: scrolling, zooming or a page
-- that only occupies part of the screen then cannot slide the handwriting over
-- to another part of the page -- or over the neighbouring page.
--
-- Files written by version 1 are still read: their strokes are panel pixels and
-- are tagged "native" on load, so they keep being drawn the old way.
Config.STORE_IN_PAGE_SPACE       = true

-- ============================================================================
-- Helpers
-- ============================================================================
-- Kept lazy on purpose: a failure here must never break plugin load.
function Config.isKindleScribe()
    local ok, device = pcall(require, "device")
    if not ok or not device or not device.model then return false end
    return device.model:match("^KindleScribe") ~= nil
end

function Config.colorKeyForLevel(level)
    for _, entry in ipairs(Config.COLOR_PALETTE) do
        if entry[3] == level then return entry[1] end
    end
    return "black"
end

return Config
