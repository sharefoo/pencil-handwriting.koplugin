--[[--
Configuration for pencil-handwriting.

Kept in its own namespace (pencilhw/) so that it can never collide with a
module exposed by another plugin sharing the global package.loaded table.
--]]

local _ = require("gettext")

local Config = {}

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

-- Coordinates handed to the stylus callback are documented as "fully
-- processed", i.e. screen pixels. If a device hands over raw digitizer units
-- instead, "auto" notices the out-of-range values, opens the digitizer node
-- read-only to learn its axis ranges, and scales them into place.
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

-- Guard for a long stroke drawn without ever lifting the pen: one real refresh
-- every few seconds. Note that a refresh *includes* the strokes, it does not
-- replace them, so this is only about ghosting, never about data loss.
Config.REFRESH_GHOST_MS          = 8000

Config.POLL_INTERVAL_S           = 0.008

-- ============================================================================
-- Persistence
-- ============================================================================
Config.SIDECAR_FILENAME          = "pencil_handwriting.lua"
Config.STROKE_FORMAT_VERSION     = 1

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
