--[[--
pencil-handwriting.koplugin

Low-latency stylus handwriting for e-ink readers with a Wacom/EMR digitizer
(Kindle Scribe and friends).

Design notes
------------
* Two input sources, tried in this order:

  1. KOReader's own stylus pipeline (`Input:registerStylusCallback`). KOReader
     has already opened the right node, already knows which multitouch slot
     belongs to the pen (BTN_TOOL_PEN / BTN_TOOL_RUBBER bracketing), and --
     crucially -- a callback that returns true makes `routeStylusEvents`
     remove the slot from `self.MTSlots` before the gesture detector runs.
     That is what stops a pen stroke from being read as a page-turn swipe.

  2. Reading the digitizer node directly via evdev, for builds without the
     stylus API. Node selection is capability-driven: a node whose KEY bitmap
     advertises BTN_TOOL_PEN wins.

* Rendering only ever *adds* ink; it never blits a white sheet:

  - while writing, strokes go straight into the live framebuffer, so only the
    pixels the pen actually covers are darkened and the page underneath
    survives;
  - `ReaderView:paintTo` is hooked, so every repaint KOReader performs paints
    the current page's strokes back on top. Notes therefore survive page
    turns, menu visits, rotation and erasing.

  An earlier version kept a full-screen white canvas and blitted it over the
  framebuffer. That covered the page and every open menu (hence the white
  screen), and the notes disappeared as soon as KOReader repainted the page.

* Erasing cannot paint white, for the same reason: it deletes the strokes the
  eraser touched and asks for a repaint.

* All submodules live under the plugin-private `pencilhw/` namespace. Sharing
  KOReader's global package.loaded table with other plugins makes a generic
  name such as `core/store` unsafe: whichever plugin loads first wins, and
  the second one silently receives the wrong module.
--]]

local _ = require("gettext")
-- Plugin-local translations, layered over gettext: KOReader only auto-loads
-- l10n/<lang>/koreader.mo, so this plugin carries its own dictionary for the
-- menu text (see pencilhw/i18n.lua). A failure to load it must not take the
-- plugin down, hence the pcall -- the plain gettext function stays as fallback
-- and the menu simply stays English.
local I18n
do
    local ok, mod = pcall(require, "pencilhw/i18n")
    if ok and type(mod) == "table" and type(mod.gettext) == "function" then
        I18n = mod
        _ = mod.gettext
    end
end
local logger = require("logger")
local InputContainer = require("ui/widget/container/inputcontainer")


-- ---------------------------------------------------------------------------
-- Defensive submodule loading
-- ---------------------------------------------------------------------------
-- If anything below fails, we still return a valid plugin table so the plugin
-- keeps showing up in the plugin manager and can report what went wrong,
-- instead of vanishing from the list without a trace.
local load_error

local function loadSubmodule(name)
    local ok, mod = pcall(require, "pencilhw/" .. name)
    if not ok then
        logger.err("PencilHW: failed to load pencilhw/" .. name .. ":", mod)
        load_error = load_error or ("pencilhw/" .. name .. ": " .. tostring(mod))
        return nil
    end
    return mod
end

local Config      = loadSubmodule("config")
local Geometry    = loadSubmodule("geometry")
local EvdevReader = loadSubmodule("evdev")
local Canvas      = loadSubmodule("canvas")
local StrokeStore = loadSubmodule("store")
local ViewMap     = loadSubmodule("viewmap")

-- Read from Config so there is exactly one place to bump: a stale copy here
-- once made the diagnostics report a version two releases old.
local BUILD = (Config and Config.VERSION) or "unknown"

if load_error then
    return InputContainer:extend{
        name = "pencil_handwriting",
        is_doc_only = false,
        init = function()
            local UIManager = require("ui/uimanager")
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{
                text = _("Pencil handwriting failed to load:\n") .. load_error,
                timeout = 10,
            })
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Fully loaded plugin
-- ---------------------------------------------------------------------------
local ButtonDialog  = require("ui/widget/buttondialog")
local ConfirmBox    = require("ui/widget/confirmbox")
local Dispatcher    = require("dispatcher")
local Geom          = require("ui/geometry")
local InfoMessage   = require("ui/widget/infomessage")
local InputDialog   = require("ui/widget/inputdialog")
local SpinWidget    = require("ui/widget/spinwidget")
local TextViewer    = require("ui/widget/textviewer")
local UIManager     = require("ui/uimanager")
local T             = require("ffi/util").template

-- ---------------------------------------------------------------------------
-- Small helpers (all lazy: nothing may touch the screen at load time)
-- ---------------------------------------------------------------------------
local function getDevice()
    local ok, device = pcall(require, "device")
    if ok and device then return device end
    return nil
end

local function getInput()
    local device = getDevice()
    return device and device.input or nil
end

local TOOL_PEN, TOOL_ERASER, TOOL_HIGHLIGHTER
local function toolTypes()
    if not TOOL_PEN then
        local input = getInput()
        TOOL_PEN         = (input and input.TOOL_TYPE_PEN) or 1
        TOOL_ERASER      = (input and input.TOOL_TYPE_ERASER) or 2
        TOOL_HIGHLIGHTER = (input and input.TOOL_TYPE_HIGHLIGHTER) or 3
    end
    return TOOL_PEN, TOOL_ERASER, TOOL_HIGHLIGHTER
end

-- The framebuffer's own size is authoritative: everything we draw targets it.
-- Geometry owns the rotation maths, so this is only a convenience alias.
local function screenDims()
    return Geometry.dims()
end

local function screenBB()
    local device = getDevice()
    local screen = device and device.screen
    return screen and screen.bb or nil
end

-- Page identifiers are numbers for paged documents and strings (xpointers) for
-- reflowable ones. Declared up here on purpose: a `local function` is only in
-- scope *after* its declaration line, so a later declaration would silently
-- turn every earlier call into a global lookup (nil) -- a crash in the middle
-- of an event handler.
local function normaliseKey(value)
    if type(value) == "number" then return value end
    if type(value) == "string" and value ~= "" then return value end
    return nil
end

-- Device-level options (input mode, touch blocking) do not belong to a single
-- document, so they live in the global reader settings.
local function globalSetting(key, default)
    local settings = rawget(_G, "G_reader_settings")
    if not settings then return default end
    local ok, value = pcall(function() return settings:readSetting(key) end)
    if not ok or value == nil then return default end
    return value
end

local function saveGlobalSetting(key, value)
    local settings = rawget(_G, "G_reader_settings")
    if not settings then return end
    pcall(function()
        settings:saveSetting(key, value)
        settings:flush()
    end)
end

local PencilHandwriting = InputContainer:extend{
    -- NOT doc-only: a doc-only plugin is never instantiated in the file
    -- manager, which means it never appears in the plugin manager list there.
    -- Reader-specific setup is gated on the presence of self.ui.document.
    is_doc_only = false,

    is_reader = false,

    enabled = false,
    width = Config.DEFAULT_WIDTH,
    color = Config.DEFAULT_COLOR,

    exclusive = Config.EXCLUSIVE_GRAB_DEFAULT,
    block_touch = Config.BLOCK_TOUCH_DEFAULT,
    input_mode = Config.INPUT_SOURCE,
    full_refresh = Config.FULL_REFRESH_ON_PAGE_CHANGE,

    reader = nil,
    store = nil,

    -- "stylus" | "evdev" | nil
    input_source = nil,
    stylus_callback = nil,
    range_only = false,      -- reader opened just to learn axis ranges

    -- rendering
    paint_hook = nil,
    paint_orig = nil,
    dirty = nil,
    -- The one page identifier: written by the page/position events, read by the
    -- write, paint and erase paths. Never derived twice.
    page_key = nil,
    page_key_source = "-",
    page_from_event = nil,        -- page number carried by PageUpdate
    live_key = nil,               -- what the accessor chain reports
    live_key_source = "-",
    live_keys_unreliable = false, -- chain proven unable to track pages
    offpanel_reported = false,
    key_probe = nil,
    last_page_exit = "-",
    -- Whether anything has been drawn on the page currently on screen. Ink is
    -- put straight into the framebuffer, so leaving such a page needs a real
    -- (flashing) refresh or the strokes ghost onto the next one.
    page_has_ink = false,

    current_stroke = nil,
    last_pen_x = nil,
    last_pen_y = nil,
    last_page_x = nil,
    last_page_y = nil,
    -- Per-stroke view mapping (see pencilhw/viewmap.lua): measured when the pen
    -- goes down and reused for the whole stroke, so the stroke cannot be
    -- measured against two different views.
    stroke_viewmap = nil,
    stroke_page = nil,
    last_write = "-",

    settle_timer = nil,
    ghost_timer = nil,
    erase_timer = nil,
    key_audit_timer = nil,
    erase_last_x = nil,
    erase_last_y = nil,
    erase_last_time = nil,
    poll_timer = nil,
    poll_generation = 0,
}

-- ============================================================================
-- Lifecycle
-- ============================================================================
function PencilHandwriting:init()
    -- In ReaderUI self.ui.document exists; in the file manager it does not.
    self.is_reader = self.ui and self.ui.document ~= nil
    self.view = self.ui.view or self.ui

    self.stats = {
        stylus_slots = 0,
        pen_downs = 0,
        coord_corrections = 0,
        render_errors = 0,
        repaints = 0,
        erase_scans = 0,
        erase_removed = 0,
        live_stamps = 0,
        map_fallbacks = 0,
        pages_unmapped = 0,
        pages_relaxed = 0,
        stroke_pauses = 0,
        offpanel = 0,
        slot_errors = 0,
        coord_rejected = 0,
        coord_clamped = 0,
        erase_unmapped = 0,
        paint_mismatch = 0,
        page_exit_flashes = 0,
        page_exit_plain = 0,
        page_updates = 0,
        pos_updates = 0,
        strokes_committed = 0,
        strokes_dropped = 0,
        last_slot = "-",
        last_error = "-",
    }

    -- Page identity bookkeeping, surfaced in the diagnostics: a constant key is
    -- what puts every stroke on every page.
    self.page_key_source = "-"
    self.page_from_event = nil
    self.live_key = nil
    self.live_key_source = "-"
    self.live_keys_unreliable = false
    self.key_probe = nil
    self.live_draw_failed = false

    self:onDispatcherRegisterActions()

    if self.is_reader then
        self:initReader()
    end

    logger.info("PencilHW: plugin loaded, build", BUILD,
        "(reader context:", tostring(self.is_reader), ")")
end

function PencilHandwriting:initReader()
    local ds = self.ui.doc_settings
    if ds then
        self.enabled = ds:readSetting("pencil_hw_enabled") == true
        self.width = ds:readSetting("pencil_hw_width") or Config.DEFAULT_WIDTH
        self.color = ds:readSetting("pencil_hw_color") or Config.DEFAULT_COLOR
    end

    self.exclusive = globalSetting("pencil_hw_exclusive", Config.EXCLUSIVE_GRAB_DEFAULT)
    self.block_touch = globalSetting("pencil_hw_block_touch", Config.BLOCK_TOUCH_DEFAULT)
    self.input_mode = globalSetting("pencil_hw_input_source", Config.INPUT_SOURCE)
    if self.input_mode ~= "auto" and self.input_mode ~= "stylus" and self.input_mode ~= "evdev" then
        self.input_mode = "auto"
    end

    -- Device-level only. The page identity has no runtime switch on purpose:
    -- the accessors were measured lagging behind the page turn on this build,
    -- and a lagging identity paints one page's strokes onto its neighbour.
    self.full_refresh = globalSetting("pencil_hw_full_refresh_on_page",
        Config.FULL_REFRESH_ON_PAGE_CHANGE) and true or false

    self.store = StrokeStore:new(self:getSidecarDir())
    self.store:load()
    self:refreshPageKey()

    self.ui.menu:registerToMainMenu(self)
    self:registerTouchZones()

    -- Register once and keep it: unregistering later could tear down a
    -- callback another plugin installed after us. While drawing is off the
    -- callback simply declines to dominate anything.
    self:installStylusCallback()

    -- Capture itself starts in onReaderReady(), once the page is on screen.
end

function PencilHandwriting:onReaderReady()
    if not self.is_reader then return end

    self:initReaderInput()
    self:installPaintHook()

    self:refreshPageKey()
    -- Strokes are drawn by the paintTo hook, so a repaint is all it takes.
    self:requestRepaint("ui")

    -- Resume drawing if it was left enabled for this document.
    if self.enabled then
        self:startCapture()
    end
end

function PencilHandwriting:initReaderInput()
    if self.reader then return end

    self.reader = EvdevReader:new()
    self.reader.onPenDown    = function(x, y, p) self:onPenDown(x, y, p) end
    self.reader.onPenMove    = function(x, y, p) self:onPenMove(x, y, p) end
    self.reader.onPenUp      = function() self:onPenUp() end
    self.reader.onEraserDown = function(x, y) self:onEraserDown(x, y) end
    self.reader.onEraserMove = function(x, y) self:onEraserMove(x, y) end
    self.reader.onEraserUp   = function() self:onEraserUp() end
end

function PencilHandwriting:onCloseDocument()
    self:stopCapture()
    self:removeStylusCallback()
    self:removePaintHook()

    if self.store then
        self.store:save()
    end
end

-- Knock on wood: flush on suspend too, so a device that goes to sleep (or out
-- of battery) cannot take the last strokes with it.
function PencilHandwriting:onSuspend()
    if self.store then self.store:save() end
end

-- A page change. KOReader hands the new page number over as the event
-- argument. For paged documents that argument *is* the page identity this
-- plugin files strokes under (see resolvePageKey): the document's own
-- accessors were measured lagging behind the turn on this build, and an
-- identity that lags the display paints one page's strokes onto its neighbour.
-- The accessors are still read on every change, but only to log what they say.
function PencilHandwriting:onPageUpdate(page)
    self.stats.page_updates = (self.stats.page_updates or 0) + 1

    local from_event = normaliseKey(page)
    if type(from_event) == "number" then
        self.page_from_event = from_event
    end

    -- refreshPageKey reports whether the identity actually changed, and hands
    -- back the previous one. It has to: the resolver used to *store* what it
    -- resolved, which made this comparison always true and silently turned the
    -- whole branch into dead code -- no commit, no save, no repaint, and not a
    -- single `page=` entry in the key log, which is what made three rounds of
    -- this bug so hard to see.
    local changed, old_key = self:refreshPageKey()
    if not changed then
        -- Same page (a redraw, a re-layout, a rotation): nothing to do.
        -- Treating every update as a page change is what used to throw away
        -- the stroke under the pen.
        self:scheduleKeyProbe()
        return
    end

    -- Commit anything in flight to the page it was drawn on before switching.
    self:finishStroke(old_key)
    self:noteKeyEvent("page", self:pageLogEntry(old_key))
    self:notePageChange(old_key)

    -- Was there ink on the page we are leaving? Then the panel needs a flashing
    -- refresh after the turn, or the strokes stay visible on the next page:
    -- KOReader's own page-turn update does not erase solid black ink, and a pen
    -- stroke ghosts far more than the text does.
    local left_had_ink = self.page_has_ink
    if not left_had_ink and self.store and old_key ~= nil then
        left_had_ink = #(self.store:pageStrokes(old_key)) > 0
    end
    self.page_has_ink = false

    self:cancelSettle()
    self:cancelEraseRefresh()
    if self.store then self.store:save() end
    self:requestRepaint("ui")
    if self.full_refresh
        or (Config.PAGE_EXIT_CLEANUP == "on_ink" and left_had_ink)
        or Config.PAGE_EXIT_CLEANUP == "always" then
        -- Queued after the repaint above: the framebuffer then holds the new
        -- page (plus its strokes) and the flash shows exactly that.
        self:refreshScreenFull(Config.PAGE_EXIT_REFRESH_MODE)
        self.stats.page_exit_flashes = (self.stats.page_exit_flashes or 0) + 1
    else
        self.stats.page_exit_plain = (self.stats.page_exit_plain or 0) + 1
    end
    self.last_page_exit = string.format("%s->%s ink=%s %s", tostring(old_key),
        tostring(self.page_key), left_had_ink and "yes" or "no",
        (self.full_refresh or left_had_ink) and "flash" or "plain")
    self:scheduleKeyProbe()
end

-- One entry per real page change, on a line of its own in the diagnostics: the
-- combined key log is dominated by repaints and pushes the page changes out of
-- its ring buffer, which is how a whole session once looked as if the page
-- never changed.
function PencilHandwriting:notePageChange(old_key)
    self.page_log = self.page_log or {}
    self.page_log[#self.page_log + 1] = self:pageLogEntry(old_key)
    while #self.page_log > 6 do
        table.remove(self.page_log, 1)
    end
end

function PencilHandwriting:pageLogEntry(old_key)
    return tostring(old_key) .. "->" .. tostring(self.page_key)
end

function PencilHandwriting:describePageLog()
    if not self.page_log or #self.page_log == 0 then return "-" end
    return table.concat(self.page_log, " ")
end

-- The probe runs a moment later on purpose: at the instant a page-change event
-- fires, the document's own fields may not have caught up yet, and calling a
-- healthy accessor stuck because of that would be worse than the bug it fixes.
function PencilHandwriting:scheduleKeyProbe()
    if self.key_audit_timer then return end
    self.key_audit_timer = function()
        self.key_audit_timer = nil
        self:probeLiveKey()
    end
    UIManager:scheduleIn(Config.KEY_AUDIT_DELAY_S, self.key_audit_timer)
end

-- Position updates arrive constantly (scrolling, progress ticks). They must
-- never disturb a stroke that is being drawn; all they do here is keep the page
-- identity of reflowable documents current. Paged documents do not need them.
function PencilHandwriting:onPosUpdate(pos)
    self.stats.pos_updates = (self.stats.pos_updates or 0) + 1

    if self.ui and self.ui.paging then return end
    if self.current_stroke then return end

    if self:refreshPageKey() then
        self:noteKeyEvent("pos", self.page_key)
        self:requestRepaint("ui")
    end
end

-- The page does not change when the screen is rotated, and native coordinates
-- stay valid across a rotation, so an in-flight stroke is committed rather than
-- dropped.
function PencilHandwriting:onRotationChange()
    self:finishStroke(self.page_key)
    self:cancelSettle()
    self:cancelEraseRefresh()
    self:requestRepaint("ui")
end

-- ============================================================================
-- Rendering: hook ReaderView:paintTo
-- ============================================================================
-- Everything we draw is additive. The hook runs after KOReader has drawn the
-- page, so strokes simply land on top of it, and any repaint KOReader does for
-- its own reasons (page turn, menu, rotation) brings the notes back.
function PencilHandwriting:installPaintHook()
    if self.paint_hook then return true end

    local ok, ReaderView = pcall(require, "apps/reader/modules/readerview")
    if not ok or type(ReaderView) ~= "table" or type(ReaderView.paintTo) ~= "function" then
        logger.warn("PencilHW: ReaderView.paintTo unavailable; strokes cannot be repainted")
        self.stats.last_error = "no ReaderView.paintTo"
        return false
    end

    local orig = ReaderView.paintTo
    local function hooked(view, bb, x, y)
        orig(view, bb, x, y)
        local plugin = PencilHandwriting.instance
        if plugin then
            -- Belt and braces: paintStrokes already guards its own body, but an
            -- exception that escapes from here would break KOReader's entire
            -- repaint, which looks exactly like a dead device.
            local ok, err = pcall(plugin.paintStrokes, plugin, bb, x, y)
            if not ok then
                logger.err("PencilHW: paint hook failed:", err)
            end
        end
    end

    ReaderView.paintTo = hooked
    self.paint_hook = hooked
    self.paint_orig = orig
    PencilHandwriting.instance = self
    return true
end

function PencilHandwriting:removePaintHook()
    local ok, ReaderView = pcall(require, "apps/reader/modules/readerview")
    if ok and type(ReaderView) == "table" and self.paint_hook
        and ReaderView.paintTo == self.paint_hook then
        ReaderView.paintTo = self.paint_orig
    end
    if PencilHandwriting.instance == self then
        PencilHandwriting.instance = nil
    end
    self.paint_hook = nil
end

-- Runs inside KOReader's repaint. It must never throw: an exception here would
-- break the whole UI refresh, which looks exactly like a frozen device.
--
-- Two coordinate spaces can be present in the store:
--   "page"   -- document page pixels, measured with the reader's own
--               screenToPageTransform. Ink follows the content it was written
--               on, whatever the scroll position or zoom does to the screen.
--   "native" -- the older panel-pixel space, kept so files written by an
--               earlier build still draw (see pencilhw/store.lua).
function PencilHandwriting:paintStrokes(bb, ox, oy)
    if not bb or not self.store then return end

    self.stats.repaints = self.stats.repaints + 1

    local ok, err = pcall(function()
        local sw, sh = screenDims()
        local viewmap = self:viewMap()

        local native_map = self:screenMapper()
        local painted = 0

        if viewmap then
            -- Paint what is actually on screen: every page whose content is
            -- visible right now, which in a scrolled view can be more than one.
            -- Each page gets its own map: in a scrolled view every page has its
            -- own offset and zoom, so one shared map would be right for the
            -- first page only and shifted for the rest.
            local first, last = viewmap:visiblePageRange(sw, sh)
            if first ~= nil then
                for key, strokes in pairs(self.store.pages) do
                    local page_no = tonumber(key)
                    if page_no and page_no >= first and page_no <= last then
                        local page_map = viewmap:mapForPage(page_no)
                        if page_map then
                            if viewmap:isRelaxed(page_no) then
                                -- The reader's own map for this page could not
                                -- be confirmed and had to be re-anchored; worth
                                -- counting, since it is how a rotated view can
                                -- still place ink slightly differently.
                                self.stats.pages_relaxed =
                                    (self.stats.pages_relaxed or 0) + 1
                            end
                            painted = painted + self:paintPageStrokes(bb, strokes,
                                ox, oy, page_map, "page")
                        else
                            -- The reader could not place this page (or the map
                            -- failed its check): draw nothing rather than ink
                            -- somewhere wrong.
                            self.stats.pages_unmapped =
                                (self.stats.pages_unmapped or 0) + 1
                        end
                    end
                end
                self:noteKeyEvent("paint", first .. ".." .. last
                    .. "(" .. tostring(painted) .. ")")
            end
        end

        -- Legacy strokes (and everything for reflowable documents, where the
        -- reader offers no page space) keep the old screen mapping.
        local key = self.page_key or self:currentPageKey()
        local native_strokes = self.store:pageStrokes(key)
        painted = painted + self:paintPageStrokes(bb, native_strokes, ox, oy,
            native_map, "native")
        if not viewmap then
            self:noteKeyEvent("paint", tostring(key) .. "(" .. tostring(painted) .. ")")
        end

        -- Fingerprint of ink landing on the wrong page: a repaint that used an
        -- identity other than the page the reader announced. Should stay 0.
        if self:isPaged() and self.page_from_event ~= nil
            and tostring(key) ~= tostring(self.page_from_event) then
            self.stats.paint_mismatch = (self.stats.paint_mismatch or 0) + 1
        end

        if self.current_stroke then
            -- The stroke under the pen lives in the space it was started in,
            -- and in the page it was started on.
            local map = native_map
            if self.current_stroke.space == "page" and viewmap then
                map = viewmap:mapForPage(self.stroke_page or self.page_key)
            end
            if map then
                Canvas.renderStroke(bb, self.current_stroke, ox, oy, map)
            end
        end
    end)

    if not ok then
        self.stats.render_errors = self.stats.render_errors + 1
        self.stats.last_error = tostring(err)
        logger.err("PencilHW: paint failed:", err)
    end
end

-- Paints the strokes of one page that live in the given space, and returns how
-- many it drew. Splitting by space costs one pass and keeps a mixed store (old
-- files plus new strokes) drawing correctly.
function PencilHandwriting:paintPageStrokes(bb, strokes, ox, oy, map, space)
    local drawn = 0
    if not strokes or not map then return 0 end

    local matching = {}
    for _, stroke in ipairs(strokes) do
        if (stroke.space or "native") == space then
            matching[#matching + 1] = stroke
            drawn = drawn + 1
        end
    end
    if drawn > 0 then
        Canvas.renderStrokes(bb, matching, ox, oy, map)
    end
    return drawn
end

-- The view mapping, instantiated once per repaint / per stroke.
function PencilHandwriting:viewMap()
    -- ViewMap is a submodule: if it failed to load, fall back to the old
    -- screen-anchored path instead of erroring inside a pen event.
    if not ViewMap or not Config.STORE_IN_PAGE_SPACE or not self:isPaged() then
        return nil
    end
    local view = self.ui and self.ui.view
    if not view then return nil end
    local sw, sh = screenDims()
    return ViewMap.measure(view, sw, sh, self.ui.paging and self.ui.paging.current_page)
end

-- Ask KOReader to repaint the reader. The paintTo hook then draws the strokes
-- on top of the freshly painted page.
--
-- The widget passed here matters a lot: `UIManager:setDirty` only marks
-- widgets that are present in its *window stack*, and ReaderView is a child
-- widget of ReaderUI, not a window. Passing ReaderView therefore marks nothing
-- dirty and merely enqueues a screen refresh of stale pixels -- which is why
-- an erase stayed invisible until the next page turn. ReaderUI itself is the
-- window (the same thing KOReader's own readerhighlight module passes).
function PencilHandwriting:requestRepaint(mode)
    local target = self.ui or self.view
    if target then
        UIManager:setDirty(target, mode or "ui")
    end
end

-- Full-screen refresh without a repaint. Used after writing: the framebuffer
-- is already correct because the ink was drawn into it directly, it only needs
-- a proper refresh to clear the residue left by the fast DU updates. Skipping
-- the repaint keeps this cheap (no page re-rasterisation).
function PencilHandwriting:refreshScreenFull(mode)
    local w, h = screenDims()
    UIManager:setDirty(nil, mode or "ui", Geom:new{ x = 0, y = 0, w = w, h = h })
end

-- ============================================================================
-- Rendering: direct, low-latency path while writing
-- ============================================================================
-- A region with a NaN or infinite coordinate must never reach the refresh
-- queue: setDirty() would take it, and a NaN rectangle can wedge the screen
-- updates (the reader looks frozen, and only a suspend/resume clears it).
-- NaN is the one value not equal to itself, so that is the test.
local function finite(v)
    return type(v) == "number" and v == v
        and v ~= math.huge and v ~= -math.huge
end

function PencilHandwriting:markDirty(region)
    if not region then return end
    if not (finite(region.x) and finite(region.y)
        and finite(region.w) and finite(region.h)) then
        return
    end

    local d = self.dirty
    if not d then
        self.dirty = { x = region.x, y = region.y, w = region.w, h = region.h }
        return
    end

    local x = math.min(d.x, region.x)
    local y = math.min(d.y, region.y)
    local x2 = math.max(d.x + d.w, region.x + region.w)
    local y2 = math.max(d.y + d.h, region.y + region.h)
    d.x, d.y, d.w, d.h = x, y, x2 - x, y2 - y
end

function PencilHandwriting:flushDirtyFast()
    local d = self.dirty
    self.dirty = nil
    if not d then return end

    local w, h = screenDims()
    local x  = math.max(0, math.floor(d.x))
    local y  = math.max(0, math.floor(d.y))
    local x2 = math.min(w, math.ceil(d.x + d.w))
    local y2 = math.min(h, math.ceil(d.y + d.h))
    if not (finite(x) and finite(y) and finite(x2) and finite(y2)) then return end
    if x2 <= x or y2 <= y then return end

    -- nil widget: no widget repaint is wanted here, only this screen region.
    -- That keeps the freshly stamped ink on screen instead of having KOReader
    -- paint the page back over it.
    UIManager:setDirty(nil, "fast", Geom:new{ x = x, y = y, w = x2 - x, h = y2 - y })
end

-- Commits a stroke that is still in flight when the document moves under the
-- pen. The stroke belongs to the page it was started on, hence the explicit
-- key: by the time a page-change event is delivered, the document may already
-- report the new page. When the pen position gave us a page directly (the
-- page-space case), that answer wins -- it is the page the ink is over.
function PencilHandwriting:finishStroke(page_key)
    local stroke = self.current_stroke
    local started_on = self.stroke_page

    self.current_stroke = nil
    self.last_pen_x, self.last_pen_y = nil, nil
    self.last_page_x, self.last_page_y = nil, nil
    self.stroke_page = nil
    self.stroke_viewmap = nil
    self:cancelGhostRefresh()

    if not stroke or stroke.tool ~= "pen" then return end
    if not stroke.points or #stroke.points < 2 then
        self.stats.strokes_dropped = (self.stats.strokes_dropped or 0) + 1
        return
    end

    self.stats.strokes_committed = (self.stats.strokes_committed or 0) + 1
    self.store:addStroke(started_on or page_key or self.page_key, stroke)
end

-- ============================================================================
-- Input source 1: KOReader's stylus callback
-- ============================================================================
function PencilHandwriting:installStylusCallback()
    if self.stylus_callback then return true end

    local input = getInput()
    if not (input and input.registerStylusCallback) then
        logger.info("PencilHW: stylus API not available in this KOReader build")
        return false
    end

    -- Chain onto any previously registered callback so another stylus plugin
    -- keeps working; if it dominates the slot, we stay out of the way.
    local previous = input.stylus_callback
    self.previous_stylus_callback = previous

    self.stylus_callback = function(inner_input, slot)
        if previous then
            local ok, dominated = pcall(previous, inner_input, slot)
            if ok and dominated then return true end
        end
        return self:onStylusSlot(inner_input, slot)
    end

    input:registerStylusCallback(self.stylus_callback)
    logger.info("PencilHW: stylus callback installed (previous:",
        tostring(previous ~= nil), ")")
    return true
end

function PencilHandwriting:removeStylusCallback()
    local input = getInput()
    if not (input and self.stylus_callback) then return end

    -- Only remove it if it is still ours; another plugin may have replaced it.
    if input.stylus_callback == self.stylus_callback and input.unregisterStylusCallback then
        input:unregisterStylusCallback()
    end
    self.stylus_callback = nil
end

-- Called by KOReader before gesture detection, once per SYN_REPORT, for slots
-- that belong to the pen. Returning true dominates the event: the slot is
-- removed from self.MTSlots and never reaches the gesture detector, so a
-- stroke can never be turned into a page turn.
-- The stylus callback, wrapped so that nothing it does can escape.
--
-- Two things depend on this function returning normally:
--
--   * KOReader removes the pen from the gesture pipeline *only* when the
--     callback returns true. If it throws instead, the pen starts driving
--     gestures: a stroke becomes a swipe, and a stroke that starts near the
--     top of the screen becomes a menu/corner tap -- which is how a bookmark
--     list ends up open, blocking page turns.
--   * The error is invisible otherwise. The reader simply drops the event.
--
-- So the real handler runs under pcall, and the pen is dominated either way
-- while drawing is enabled.
function PencilHandwriting:onStylusSlot(input, slot)
    local ok, dominated = pcall(self.handleStylusSlot, self, input, slot)
    if ok then return dominated == true end

    self.stats.slot_errors = (self.stats.slot_errors or 0) + 1
    self.stats.last_error = tostring(dominated)
    logger.err("PencilHW: stylus handler failed:", dominated)

    -- Drop the half-built stroke instead of leaving it to be committed by the
    -- next event.
    self.current_stroke = nil
    self.last_pen_x, self.last_pen_y = nil, nil
    self.last_page_x, self.last_page_y = nil, nil
    return self.enabled == true
end

function PencilHandwriting:handleStylusSlot(input, slot)
    if not self.stats then return false end

    -- When the raw evdev path is forced, stay completely out of the way.
    if self.input_mode == "evdev" then return false end

    self.stats.stylus_slots = self.stats.stylus_slots + 1
    self.stats.last_slot = string.format("slot=%s id=%s tool=%s x=%s y=%s",
        tostring(slot.slot), tostring(slot.id), tostring(slot.tool),
        tostring(slot.x), tostring(slot.y))

    if not self.enabled then return false end

    local x, y = tonumber(slot.x), tonumber(slot.y)
    -- A pen slot without usable coordinates is still a pen slot: dominate it so
    -- it cannot turn into a gesture, but draw nothing.
    if not x or not y then return true end
    x, y = self:toNativeCoords(x, y)
    if not x or not y then
        if self.current_stroke then
            if self.current_stroke.tool == "eraser" then
                self:onEraserUp()
            else
                self:onPenUp()
            end
        end
        return true
    end

    -- A dialog is on screen: swallow the event but draw nothing into it.
    if self:isOverlayActive() then return true end

    local pen_tool, eraser_tool, highlighter_tool = toolTypes()
    local tool = slot.tool
    local in_contact = slot.id ~= nil and slot.id >= 0

    if not in_contact then
        -- Lift or hover. Hover is bracketed by BTN_TOOL_PEN and carries
        -- id = -1, so it must never start or extend a stroke.
        if self.current_stroke then
            if self.current_stroke.tool == "eraser" then
                self:onEraserUp()
            else
                self:onPenUp()
            end
        end
        -- Dominate pen slots while drawing so the pen can never drive a
        -- gesture. Fingers use a different slot and stay fully functional.
        return true
    end

    if tool == eraser_tool then
        if self.current_stroke and self.current_stroke.tool == "eraser" then
            self:onEraserMove(x, y)
        else
            self:onEraserDown(x, y)
        end
    elseif tool == pen_tool or tool == highlighter_tool then
        if self.current_stroke and self.current_stroke.tool == "eraser" then
            -- Tool switched mid-gesture; close the eraser pass first.
            self:onEraserUp()
        end
        if self.current_stroke then
            self:onPenMove(x, y, 0)
        else
            self:onPenDown(x, y, 0)
            self.stats.pen_downs = self.stats.pen_downs + 1
        end
    end

    return true
end

-- Coordinates arrive in the digitizer's raw frame, which is normally the
-- native (portrait) panel frame -- the space strokes are stored in -- so
-- usually there is nothing to do here. KOReader applies the screen rotation
-- only *after* this point, on its way to gesture matching, which is why the
-- rotation is handled at draw time instead (see Geometry).
--
-- Some panels report in their own units; those values fall far outside the
-- panel and are scaled with the digitizer's axis ranges, read via EVIOCGABS
-- after opening the node read-only (which neither consumes events nor takes
-- the node exclusively).
function PencilHandwriting:toNativeCoords(x, y)
    if Config.STYLUS_COORD_CORRECTION ~= "auto" then return x, y end

    -- Reject non-finite values outright: a NaN reaching the rasteriser is not a
    -- visible misplacement, it is an entirely unclamped coordinate, and the
    -- blitbuffer calls behind it take integers.
    if not (x == x and y == y) then
        self.stats.coord_rejected = (self.stats.coord_rejected or 0) + 1
        return nil
    end

    -- The pen reports in the panel's own frame, which does NOT change when the
    -- screen is rotated. Testing against the *rotated* dimensions therefore
    -- misfires in landscape: a point near the bottom edge looks far outside and
    -- is mistaken for raw digitizer units. The bound uses the longer edge for
    -- both axes -- generous enough never to reject a real pen position, tight
    -- enough to catch a panel that reports its own units.
    local fw, fh = Geometry.dims()
    local big = math.max(fw, fh)
    if x >= -big * 0.25 and x <= big * 1.25
        and y >= -big * 0.25 and y <= big * 1.25 then
        return x, y
    end

    if self.reader then
        if not self.reader:isOpen() then
            -- Read-only open: EVIOCGABS does not consume events and is not
            -- exclusive, so KOReader keeps working untouched.
            if self.reader:open(false) then
                self.range_only = true
                logger.warn("PencilHW: raw stylus coordinates detected,",
                    "axis ranges queried for scaling")
            end
        end
        if self.reader:isOpen() and self.reader:hasUsableRanges() then
            self.stats.coord_corrections = self.stats.coord_corrections + 1
            return self.reader:transform(x, y)
        end
        -- No usable axis range (this device answers EVIOCGABS with 0..0), so
        -- there is nothing to scale with. Scaling anyway would divide by zero.
        self.stats.coord_rejected = (self.stats.coord_rejected or 0) + 1
        logger.warn("PencilHW: out-of-range stylus coordinates and no axis range to scale with; keeping them on the panel")
    end

    self.stats.coord_corrections = self.stats.coord_corrections + 1
    self.stats.coord_clamped = (self.stats.coord_clamped or 0) + 1
    local nw, nh = Geometry.nativeDims()
    if x < 0 then x = 0 elseif x > nw - 1 then x = nw - 1 end
    if y < 0 then y = 0 elseif y > nh - 1 then y = nh - 1 end
    return x, y
end

-- ============================================================================
-- Input source 2: our own evdev reader
-- ============================================================================
-- The fallback for KOReader builds without the stylus API. This path cannot
-- suppress gestures by itself: KOReader reads the same node and sees the same
-- events, so a stroke may still be read as a swipe. "Exclusive pen capture" is
-- the way around that, and it is only safe when the pen has its own node --
-- which it does on the Kindle Scribe.
function PencilHandwriting:startCapture()
    self:cancelPoll()

    local mode = self.input_mode or Config.INPUT_SOURCE

    if mode ~= "evdev" and self.stylus_callback then
        self.input_source = "stylus"
        logger.info("PencilHW: capturing via KOReader stylus API")
        return
    end

    if not self.reader then return end

    if mode == "stylus" then
        self.input_source = nil
        logger.err("PencilHW: input source is \"stylus\" but the stylus API is missing")
        UIManager:show(InfoMessage:new{
            text = _("Pencil handwriting: this KOReader build has no stylus API.\nSwitch \"Input source\" to \"evdev (direct)\" instead."),
            timeout = 6,
        })
        return
    end

    if not self.reader:open(self.exclusive) then
        self.input_source = nil
        UIManager:show(InfoMessage:new{
            text = _("Pencil handwriting: no digitizer node found.\nOpen \"Input diagnostics\" in this menu to see the input devices of this reader."),
            timeout = 5,
        })
        return
    end

    self.input_source = "evdev"
    self:startPolling()
end

-- UIManager:scheduleIn is one-shot: the callback has to re-arm itself on every
-- tick, otherwise reading stops right after the first one.
function PencilHandwriting:startPolling()
    self:cancelPoll()

    local generation = self.poll_generation
    local function tick()
        if self.poll_generation ~= generation then return end
        if self.reader and self.reader:isOpen() then
            self.reader:poll()
        end
        if self.poll_generation ~= generation then return end
        UIManager:scheduleIn(Config.POLL_INTERVAL_S, tick)
    end

    self.poll_timer = tick
    UIManager:scheduleIn(Config.POLL_INTERVAL_S, tick)
end

function PencilHandwriting:cancelPoll()
    -- Bumping the generation invalidates a tick that is already in flight.
    self.poll_generation = (self.poll_generation or 0) + 1
    if self.poll_timer then
        UIManager:unschedule(self.poll_timer)
        self.poll_timer = nil
    end
end

function PencilHandwriting:stopCapture()
    self:cancelPoll()
    -- Commit rather than discard: the user may have lifted the pen just as
    -- drawing was switched off.
    self:finishStroke(self.page_key)
    self:cancelGhostRefresh()
    self:cancelEraseRefresh()
    self.erase_last_x, self.erase_last_y, self.erase_last_time = nil, nil, nil

    if self.reader then
        self.reader:close()
    end
    self.range_only = false
    self.input_source = nil
end

-- ============================================================================
-- Pen callbacks (shared by both input sources)
-- ============================================================================
-- Maps a native (portrait panel) point into the current screen frame.
--
-- The rotation mapping is refused when it would push the point off the panel
-- while the untransformed value is inside it: that means the mapping does not
-- fit this device, and invisible ink is the one outcome that cannot be
-- diagnosed from the outside. The fallback is counted, so the diagnostics
-- shows it instead of hiding it.
-- Maps a native (portrait panel) point into the current screen frame.
--
-- Returns the screen point and whether it is actually on the panel. Three
-- outcomes are possible, and the third one used to be invisible:
--
--   * it maps inside the frame -- normal;
--   * it maps outside but the untransformed point is inside -- the rotation
--     mapping does not fit this device, so the untransformed value is used and
--     counted as a fallback;
--   * neither is inside -- the pen point cannot be placed at all. Stamping it
--     anyway would paint a blob at the nearest edge, and nothing in the
--     diagnostics would say why, so this case reports itself once with the
--     geometry.
function PencilHandwriting:toScreen(x, y)
    local sx, sy = Geometry.nativeToScreen(x, y)

    local w, h = screenDims()
    if sx >= 0 and sx < w and sy >= 0 and sy < h then
        return sx, sy, true
    end

    if x >= 0 and x < w and y >= 0 and y < h then
        self.stats.map_fallbacks = (self.stats.map_fallbacks or 0) + 1
        return x, y, true
    end

    self.stats.offpanel = (self.stats.offpanel or 0) + 1
    if not self.offpanel_reported then
        self.offpanel_reported = true
        logger.warn(string.format(
            "PencilHW: pen point (%d, %d) maps outside the %dx%d frame; rotation=%s (%s)",
            x, y, w, h, Geometry.rotationKind(), Geometry.rotationReport()))
    end
    return sx, sy, false
end

-- mapper handed to the rasteriser: lets stored strokes go through exactly the
-- same mapping as the live ones.
function PencilHandwriting:screenMapper()
    return function(x, y) return self:toScreen(x, y) end
end

-- x and y are in native (portrait panel) coordinates. Strokes are stored in
-- that space and mapped to the current screen only when drawn, so a rotation
-- does not invalidate them.
function PencilHandwriting:onPenDown(x, y, pressure)
    if self:isOverlayActive() then return end

    self:cancelSettle()
    -- Ink is about to appear on this page, and ink in the framebuffer is what
    -- makes a later page turn need a real (flashing) refresh.
    self.page_has_ink = true

    -- Where the pen is, in the document's own coordinates. This is what keeps
    -- the ink attached to the content: a stroke stored in page coordinates
    -- follows the page when the view scrolls or zooms, so handwriting cannot
    -- slide over the neighbouring page. The map is measured once per stroke
    -- (the view cannot move while the pen is down) and reused for its points.
    local sx, sy = self:toScreen(x, y)
    local viewmap = self:viewMap()
    self.stroke_viewmap = viewmap
    self.stroke_page = nil

    local px, py
    if viewmap then
        local page, gx, gy = viewmap:pageAt(sx, sy)
        if page ~= nil and gx ~= nil then
            self.stroke_page = page
            px, py = gx, gy
        end
    end

    if px ~= nil then
        self.current_stroke = {
            tool = "pen",
            space = "page",
            page = self.stroke_page,
            width = self.width,
            color = self.color,
            points = { px, py },
        }
    else
        -- No page mapping available (reflowable document, or a reader without
        -- screenToPageTransform): keep the previous panel-pixel behaviour.
        self.current_stroke = {
            tool = "pen",
            space = "native",
            width = self.width,
            color = self.color,
            points = { x, y },
        }
    end
    self.last_pen_x, self.last_pen_y = x, y
    self.last_page_x, self.last_page_y = px, py
    self.live_draw_failed = false

    local sx, sy, on_panel = self:toScreen(x, y)
    local bb = screenBB()
    if not bb or not on_panel then
        -- No framebuffer to draw into, or the point is not on the panel at
        -- all: fall back to letting the paint hook render the stroke once it is
        -- committed, instead of stamping a blob at the edge of the screen.
        self.live_draw_failed = true
        return
    end

    self.stats.live_stamps = (self.stats.live_stamps or 0) + 1
    self:markDirty(Canvas.stampDisc(bb, sx, sy, self.width / 2,
        Canvas.colorFor(self.color)))
    self:flushDirtyFast()
end

function PencilHandwriting:onPenMove(x, y, pressure)
    if not self.current_stroke or self.current_stroke.tool ~= "pen" then return end
    if self:isOverlayActive() then return end

    local dx = x - self.last_pen_x
    local dy = y - self.last_pen_y
    local min_dist = Config.MIN_MOVE_DISTANCE_PX
    if dx * dx + dy * dy < min_dist * min_dist then return end

    local sx0, sy0 = self:toScreen(self.last_pen_x, self.last_pen_y)
    local sx1, sy1, on_panel = self:toScreen(x, y)

    if self.current_stroke.space == "page" and self.stroke_viewmap then
        -- Page coordinates come from the same map the stroke was started with,
        -- so one stroke can never be measured against two different views.
        local ax, ay = self.stroke_viewmap:toPage(self.stroke_page, sx1, sy1)
        if ax == nil then
            -- The map went away (or the page checks failed): hold the stroke
            -- rather than mixing two coordinate spaces inside one stroke.
            self.stats.stroke_pauses = (self.stats.stroke_pauses or 0) + 1
            ax, ay = self.last_page_x, self.last_page_y
        end
        if ax ~= nil then
            table.insert(self.current_stroke.points, ax)
            table.insert(self.current_stroke.points, ay)
            self.last_page_x, self.last_page_y = ax, ay
        end
    else
        table.insert(self.current_stroke.points, x)
        table.insert(self.current_stroke.points, y)
    end

    local bb = screenBB()
    if not bb or not on_panel then
        self.live_draw_failed = true
        self.last_pen_x, self.last_pen_y = x, y
        return
    end

    self.stats.live_stamps = (self.stats.live_stamps or 0) + 1
    self:markDirty(Canvas.drawLine(bb, sx0, sy0, sx1, sy1,
        self.width / 2, Canvas.colorFor(self.color)))
    self:flushDirtyFast()

    self.last_pen_x, self.last_pen_y = x, y
    self:scheduleGhostRefresh()
end

function PencilHandwriting:onPenUp()
    if not self.current_stroke or self.current_stroke.tool ~= "pen" then return end

    -- Filed under the page whose content the pen was actually over, which the
    -- reader itself reported when the stroke started -- not under whatever page
    -- number an event mentioned last. In a scrolled view those differ, and the
    -- difference is exactly what puts ink on the neighbouring page.
    local key = self.stroke_page or self.page_key or self:currentPageKey()
    self:noteKeyEvent("write", key)
    self.store:addStroke(key, self.current_stroke)
    self.store:save()
    self.last_write = string.format("page=%s space=%s", tostring(key),
        tostring(self.current_stroke.space or "native"))
    -- Counted here as well as in finishStroke: this is the normal path, and a
    -- diagnostics readout of "8 pen downs, 0 committed" looked like data loss
    -- when it only meant the counter was blind to pen-up writes.
    self.stats.strokes_committed = (self.stats.strokes_committed or 0) + 1

    local live_failed = self.live_draw_failed
    self.current_stroke = nil
    self.last_pen_x, self.last_pen_y = nil, nil
    self.last_page_x, self.last_page_y = nil, nil
    self.live_draw_failed = false
    self.stroke_page = nil
    self.stroke_viewmap = nil

    self:cancelGhostRefresh()
    self:scheduleSettleRefresh()

    -- Safety net: if the direct framebuffer path could not draw this stroke,
    -- ask for a repaint so the paint hook renders it instead. Without this the
    -- ink would sit in the store, invisible until something else forces a
    -- repaint (a page turn, for instance).
    if live_failed then
        self:requestRepaint("ui")
    end
end


function PencilHandwriting:onEraserDown(x, y)
    if self:isOverlayActive() then return end

    self:cancelSettle()
    self:cancelEraseRefresh()
    -- Force the first sample to be scanned, and let the first removal repaint
    -- immediately.
    self.erase_last_x, self.erase_last_y, self.erase_last_time = nil, nil, nil
    self.erase_repainted = false
    self.current_stroke = { tool = "eraser", width = 0, color = self.color, points = {} }
    self:eraseAt(x, y)
end

function PencilHandwriting:onEraserMove(x, y)
    if not self.current_stroke or self.current_stroke.tool ~= "eraser" then return end
    if self:isOverlayActive() then return end
    self:eraseAt(x, y)
end

function PencilHandwriting:onEraserUp()
    self.current_stroke = nil
    self.erase_last_x, self.erase_last_y, self.erase_last_time = nil, nil, nil
    -- Whatever was coalesced while dragging must land on screen now.
    self:cancelEraseRefresh()
    self:requestRepaint("ui")
    if self.store then self.store:save() end
end

-- Cached bounding box, used to reject strokes cheaply before testing every
-- point against the eraser disc. Cached on the stroke table, recomputed after
-- a reload.
local function strokeBBox(stroke)
    if stroke.bbox then return stroke.bbox end

    local pts = stroke.points
    if not pts or #pts < 2 then return nil end

    local minx, miny, maxx, maxy = pts[1], pts[2], pts[1], pts[2]
    for i = 3, #pts - 1, 2 do
        local x, y = pts[i], pts[i + 1]
        if x < minx then minx = x elseif x > maxx then maxx = x end
        if y < miny then miny = y elseif y > maxy then maxy = y end
    end

    local pad = (stroke.width or Config.DEFAULT_WIDTH) / 2 + 1
    stroke.bbox = { minx - pad, miny - pad, maxx + pad, maxy + pad }
    return stroke.bbox
end

-- True when the disc (cx, cy, r) touches any *segment* of the stroke, not just
-- its recorded vertices.
--
-- Testing only the vertices is what makes an eraser feel broken: the points a
-- stroke keeps are the ones the digitizer reported, and a fast swipe can leave
-- them tens of pixels apart, so a disc can sit right on the ink and still miss
-- every stored point. Distance to the segment is what "the ink is under the
-- eraser" actually means.
local function discHitsStroke(stroke, cx, cy, r2)
    local pts = stroke.points
    if not pts or #pts < 2 then return false end

    if #pts == 2 then
        local dx, dy = pts[1] - cx, pts[2] - cy
        return dx * dx + dy * dy <= r2
    end

    for i = 1, #pts - 3, 2 do
        local ax, ay = pts[i], pts[i + 1]
        local vx, vy = pts[i + 2] - ax, pts[i + 3] - ay
        local wx, wy = cx - ax, cy - ay

        local len2 = vx * vx + vy * vy
        local t = 0
        if len2 > 0 then
            t = (wx * vx + wy * vy) / len2
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
        end

        local dx, dy = cx - (ax + t * vx), cy - (ay + t * vy)
        if dx * dx + dy * dy <= r2 then return true end
    end
    return false
end

-- Erasing removes whole strokes and then repaints: painting white would cover
-- the page text instead of removing ink.
function PencilHandwriting:eraseAt(x, y)
    if not self.store then return end

    -- The scan below is linear in the number of points stored for this page and
    -- erase events arrive at the digitizer rate, so throttle both by distance
    -- and by time. The eraser disc is ERASER_RADIUS_PX wide, so skipping
    -- samples a few pixels apart loses nothing.
    local last_x, last_y = self.erase_last_x, self.erase_last_y
    if last_x then
        local dx, dy = x - last_x, y - last_y
        local min_move = Config.ERASE_MIN_MOVE_PX
        if dx * dx + dy * dy < min_move * min_move then return end
    end

    local now = os.clock()
    if self.erase_last_time and (now - self.erase_last_time) < Config.ERASE_MIN_INTERVAL_S then
        return
    end
    self.erase_last_time = now
    self.erase_last_x, self.erase_last_y = x, y

    self.stats.erase_scans = self.stats.erase_scans + 1

    -- The pen position, resolved in each space a stroke may be stored in: page
    -- coordinates, measured through the reader, and the older panel-pixel space.
    --
    -- A page-space stroke can only be tested in page coordinates. When the
    -- reader cannot say which page a point is on, the current page's own map is
    -- the fallback -- comparing page pixels against panel pixels could never
    -- produce a hit, which is one of the reasons the eraser went dead.
    local sx, sy = self:toScreen(x, y)
    local viewmap = self:viewMap()
    local target
    if viewmap then
        local page, px, py = viewmap:pageAt(sx, sy)
        if page == nil then
            page = self.page_key or self:currentPageKey()
            if page ~= nil then
                px, py = viewmap:toPage(page, sx, sy)
            end
        end
        if page ~= nil and px ~= nil then
            -- A radius given in screen pixels becomes a radius in page pixels by
            -- multiplying with page pixels per screen pixel, so the disc keeps
            -- its size on screen whatever the zoom is.
            local radius = Config.ERASER_RADIUS_PX * viewmap:pagePerScreen(page)
            target = { page = page, x = px, y = py, r2 = radius * radius }
        else
            self.stats.erase_unmapped = (self.stats.erase_unmapped or 0) + 1
        end
    end
    local nx, ny = Geometry.screenToNative(sx, sy)
    local legacy = { x = nx, y = ny,
        r2 = Config.ERASER_RADIUS_PX * Config.ERASER_RADIUS_PX }

    -- Which page's strokes to look at. With a page mapping, the page under the
    -- eraser; otherwise the page the reader reports.
    local page = (target and target.page) or self.page_key or self:currentPageKey()
    if page == nil then return end
    local strokes = self.store:pageStrokes(page)

    local removed = 0
    local keep = {}
    for _, s in ipairs(strokes) do
        if s.tool ~= "eraser" then
            local space = s.space or "native"
            local at = (space == "page") and target or legacy
            -- A page-space stroke with no page mapping cannot be tested at all:
            -- keep it (never silently discard ink) and count it.
            local hit = false
            if at then
                local px, py, r2 = at.x, at.y, at.r2
                -- The disc has to reach the *ink*, not just the centre line, so
                -- the stroke's own half-width counts.
                local radius = math.sqrt(r2) + (s.width or Config.DEFAULT_WIDTH) / 2
                local r2w = radius * radius
                local box = strokeBBox(s)
                -- Cheap reject first: the disc cannot touch a stroke whose
                -- bounding box is entirely outside it.
                if box and px + radius >= box[1] and px - radius <= box[3]
                    and py + radius >= box[2] and py - radius <= box[4] then
                    hit = discHitsStroke(s, px, py, r2w)
                end
            elseif space == "page" then
                self.stats.erase_unmapped = (self.stats.erase_unmapped or 0) + 1
            end
            if hit then
                removed = removed + 1
            else
                keep[#keep + 1] = s
            end
        end
        -- Legacy eraser strokes from an older format carry no ink; dropping
        -- them is the correct thing to do.
    end

    if removed > 0 then
        self.store.pages[page] = keep
        self.stats.erase_removed = self.stats.erase_removed + removed
        -- The page's appearance changed, so leaving it needs the same panel
        -- clean-up as a page that was written on.
        self.page_has_ink = true
        -- One repaint per window: the page has to be repainted (only KOReader
        -- can draw what is underneath the removed ink), and repaint is the
        -- expensive part, so the requests are coalesced instead of being
        -- queued per hit.
        self:scheduleEraseRefresh()
    end
end

function PencilHandwriting:scheduleEraseRefresh()
    -- The first stroke removed in a gesture repaints straight away, so erasing
    -- feels immediate. Everything after that coalesces into one repaint per
    -- window: a repaint is expensive, hit events arrive in bursts, and queuing
    -- one refresh per hit is what made the reader appear to freeze.
    if not self.erase_repainted then
        self.erase_repainted = true
        self:requestRepaint("ui")
        return
    end

    if self.erase_timer then return end
    self.erase_timer = function()
        self.erase_timer = nil
        self:requestRepaint("ui")
    end
    UIManager:scheduleIn(Config.ERASE_REFRESH_MS / 1000, self.erase_timer)
end

function PencilHandwriting:cancelEraseRefresh()
    if self.erase_timer then
        UIManager:unschedule(self.erase_timer)
        self.erase_timer = nil
    end
end

-- ============================================================================
-- Refresh pacing
-- ============================================================================
-- Once the pen lifts: persist, then one proper refresh that also clears the
-- ghosting the fast partial refreshes leave behind. Ink is already in the
-- framebuffer, so this deliberately does *not* repaint the page: a repaint is
-- the expensive part and there is nothing to recompose.
function PencilHandwriting:scheduleSettleRefresh()
    self:cancelSettle()
    self.settle_timer = function()
        self.settle_timer = nil
        if self.store then self.store:save() end
        self:refreshScreenFull("ui")
    end
    UIManager:scheduleIn(Config.REFRESH_SETTLE_MS / 1000, self.settle_timer)
end

function PencilHandwriting:cancelSettle()
    if self.settle_timer then
        UIManager:unschedule(self.settle_timer)
        self.settle_timer = nil
    end
end

-- A long unbroken stroke accumulates residue from the fast refreshes, so one
-- real refresh is inserted every few seconds, and only while the pen is down.
-- No repaint: the framebuffer already holds the page plus the ink drawn into
-- it, so a stronger refresh of the frame is enough and costs far less.
function PencilHandwriting:scheduleGhostRefresh()
    if self.ghost_timer then return end
    self.ghost_timer = function()
        self.ghost_timer = nil
        if self.current_stroke then
            self:refreshScreenFull("ui")
        end
    end
    UIManager:scheduleIn(Config.REFRESH_GHOST_MS / 1000, self.ghost_timer)
end

function PencilHandwriting:cancelGhostRefresh()
    if self.ghost_timer then
        UIManager:unschedule(self.ghost_timer)
        self.ghost_timer = nil
    end
end

-- ============================================================================
-- Document helpers
-- ============================================================================
function PencilHandwriting:getSidecarDir()
    local ds = self.ui.doc_settings
    if ds and ds.doc_sidecar_dir then
        return ds.doc_sidecar_dir
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Page identity accessors
-- ---------------------------------------------------------------------------
-- One chain per document kind. Paged documents want a page number; reflowable
-- ones want crengine's xpointer, which is the identity KOReader itself stores
-- for bookmarks and -- unlike a page number, or a scroll offset -- does not
-- move when the text is re-laid-out.
--
-- Every accessor here has been seen to be missing, non-numeric, or simply
-- constant on some KOReader build or document type. A page identity that never
-- changes is not a small bug, so what each of them reports is logged and shown
-- in the diagnostics (probeLiveKey / describeKeyResolvers).
local function numberResolvers()
    return {
        {
            -- KOReader's own accessor, which itself falls back from the paging
            -- module to the document for reflowable files.
            name = "ui:getCurrentPage()",
            get = function(ui)
                if type(ui.getCurrentPage) == "function" then
                    local ok, value = pcall(ui.getCurrentPage, ui)
                    if ok then return value end
                end
            end,
        },
        {
            name = "ui.paging.current_page",
            get = function(ui)
                return ui.paging and ui.paging.current_page
            end,
        },
        {
            -- The reflow counterpart: ReaderRolling derives a page number from
            -- the current position, and this is what the footer displays.
            name = "ui.rolling.current_page",
            get = function(ui)
                return ui.rolling and ui.rolling.current_page
            end,
        },
        {
            name = "document:getCurrentPage()",
            get = function(ui)
                local doc = ui.document
                if doc and type(doc.getCurrentPage) == "function" then
                    local ok, value = pcall(doc.getCurrentPage, doc)
                    if ok then return value end
                end
            end,
        },
    }
end

local function positionResolvers()
    return {
        {
            name = "document:getXPointer()",
            get = function(ui)
                local doc = ui.document
                if doc and type(doc.getXPointer) == "function" then
                    local ok, value = pcall(doc.getXPointer, doc)
                    if ok and type(value) == "string" and value ~= "" then
                        return value
                    end
                end
            end,
        },
        {
            name = "document:getCurrentPos()",
            get = function(ui)
                local doc = ui.document
                if doc and type(doc.getCurrentPos) == "function" then
                    local ok, value = pcall(doc.getCurrentPos, doc)
                    if ok then return value end
                end
            end,
        },
    }
end

local function buildKeyResolvers(paged)
    local chain = {}
    local first, second
    if paged then
        first, second = numberResolvers(), positionResolvers()
    else
        first, second = positionResolvers(), numberResolvers()
    end
    for _, resolver in ipairs(first) do chain[#chain + 1] = resolver end
    for _, resolver in ipairs(second) do chain[#chain + 1] = resolver end
    return chain
end

function PencilHandwriting:isPaged()
    return (self.ui and self.ui.paging ~= nil) and true or false
end

-- The first value the accessor chain can produce, and the name of the accessor
-- that produced it. nil when nothing in the document can identify a page.
function PencilHandwriting:readLiveKey()
    local ui = self.ui
    if not ui then return nil end
    if not self.key_resolvers then
        self.key_resolvers = buildKeyResolvers(self:isPaged())
    end

    -- Page numbers are 1-based, but ReaderPaging holds 0 until the saved reading
    -- position has been applied. Treating that 0 as an identity files strokes
    -- under a page that does not exist (and it showed up as `0->41` in the first
    -- page change of a session).
    local paged = self:isPaged()

    for _, resolver in ipairs(self.key_resolvers) do
        local key = normaliseKey(resolver.get(ui))
        if key ~= nil and not (paged and key == 0) then
            self.live_key_source = resolver.name
            return key
        end
    end
    self.live_key_source = "none"
    return nil
end

-- Resolves the page identity *without touching any state*, and returns
-- (key, source). Keeping this pure matters: a resolver that also stores what it
-- resolved makes "the page changed" undecidable for its caller -- the caller
-- compares against a value that has already been overwritten and concludes
-- nothing ever changes.
function PencilHandwriting:resolvePageKey()
    if not self.ui then return self.page_key, "cached" end

    local live = self:readLiveKey()
    self.live_key = live

    local event_page = self.page_from_event
    local paged = self:isPaged()

    -- Forced accessor mode: source-level debugging only (see config.lua). The
    -- accessors were measured lagging behind the page turn on this build, so
    -- this can put ink on the neighbouring page -- never a menu option.
    if Config.PAGE_KEY_SOURCE == "live" then
        if live ~= nil then return live, self.live_key_source end
        if event_page ~= nil then return event_page, "PageUpdate event" end
        return self.page_key, "cached"
    end

    -- Reflowable documents: crengine's xpointer is a *position*, not a page
    -- number, so it survives re-layout -- and the page-change event carries no
    -- such identity for them.
    if not paged then
        if live ~= nil then return live, self.live_key_source end
        if event_page ~= nil then return event_page, "PageUpdate event" end
        return self.page_key, "cached"
    end

    -- Paged documents: the page-change event carries the page that is being put
    -- on screen, and it is the only source observed to be updated *with* the
    -- turn. The accessors lag behind it (measured in crash.log), which is
    -- precisely what paints one page's strokes onto its neighbour.
    if event_page ~= nil then
        if live == nil then
            return event_page, "PageUpdate event"
        elseif tostring(live) == tostring(event_page) then
            return event_page, self.live_key_source .. " (=event)"
        else
            return event_page, string.format("PageUpdate event (live %s=%s)",
                tostring(self.live_key_source), tostring(live))
        end
    end

    if live ~= nil then return live, self.live_key_source end
    return self.page_key, "cached (no live source!)"
end

-- Applies the resolver to the single page-identity variable. Returns whether it
-- changed, plus the previous key (so a stroke that is still under the pen can
-- be filed under the page it was drawn on).
function PencilHandwriting:refreshPageKey()
    local key, source = self:resolvePageKey()
    if key == nil then return false end

    if key == self.page_key then
        self.page_key_source = source
        return false
    end

    local old = self.page_key
    self.page_key = key
    self.page_key_source = source
    return true, old
end

-- The identity used by the write, paint and erase paths. It resolves once and
-- is then kept current by the page/position handlers; every path reads this one
-- value, so no two of them can disagree about which page a stroke belongs to.
function PencilHandwriting:currentPageKey()
    if self.page_key == nil then
        self:refreshPageKey()
    end
    return self.page_key
end

-- Re-reads the accessor chain shortly after a page change and records whether
-- it moved at all. Two *different* pages that leave the live value unchanged
-- prove the chain cannot identify pages on this build; that is logged loudly
-- and flagged in the diagnostics, because it is the explanation for "the same
-- strokes on every page" whenever an accessor is what feeds the write path.
function PencilHandwriting:probeLiveKey()
    local ui = self.ui
    if not ui then return end
    self.key_resolvers = self.key_resolvers or buildKeyResolvers(self:isPaged())

    local value = self:readLiveKey()
    self.live_key = value

    local page = self.page_from_event
    local previous = self.key_probe

    if value ~= nil and page ~= nil and previous and previous.page ~= nil
        and previous.value == value and previous.page ~= page then
        if not self.live_keys_unreliable then
            self.live_keys_unreliable = true
            logger.warn("PencilHW: live page accessor '" .. tostring(self.live_key_source)
                .. "' stayed at " .. tostring(value) .. " from page "
                .. tostring(previous.page) .. " to page " .. tostring(page)
                .. "; the page-change event is used for the page identity")
        end
    end

    -- Log the disagreement every time, in both directions: which of the two
    -- sources lags is the whole question, and this is the evidence. (Gating this
    -- on the identity in use made it silent exactly when it mattered -- it never
    -- fired once in a whole session.)
    if value ~= nil and page ~= nil and tostring(value) ~= tostring(page) then
        logger.info("PencilHW: page identity disagreement: event=" .. tostring(page)
            .. ", " .. tostring(self.live_key_source) .. "=" .. tostring(value)
            .. ", using " .. tostring(self.page_key) .. " ["
            .. tostring(self.page_key_source) .. "]")
    end

    self.key_probe = { value = value, page = page, source = self.live_key_source }
end

-- Value of every accessor plus the event page, for the diagnostics readout.
function PencilHandwriting:describeKeyResolvers()
    local ui = self.ui
    if not ui then return "no ui" end
    self.key_resolvers = self.key_resolvers or buildKeyResolvers(self:isPaged())

    local parts = { "event=" .. tostring(self.page_from_event) }
    parts[#parts + 1] = "used=" .. tostring(self.page_key)
        .. " [" .. tostring(self.page_key_source) .. "]"
    for _, resolver in ipairs(self.key_resolvers) do
        local value
        local ok, res = pcall(resolver.get, ui)
        if ok then value = normaliseKey(res) end
        parts[#parts + 1] = resolver.name .. "=" .. tostring(value)
    end
    if self.live_keys_unreliable then
        parts[#parts + 1] = "NOTE: live accessors do not follow the page"
    elseif self.live_key ~= nil and self.page_from_event ~= nil
        and tostring(self.live_key) ~= tostring(self.page_from_event) then
        parts[#parts + 1] = "NOTE: live accessor lags the page; the event is used"
    end
    return table.concat(parts, "   ")
end

-- Ring buffer of the identifiers involved in the last few operations. When the
-- page association goes wrong, this shows it directly: `write=12 paint=12
-- paint=13` is healthy, `write=0 paint=0` means the identity never moves.
function PencilHandwriting:noteKeyEvent(kind, key)
    self.key_log = self.key_log or {}
    local entry = kind .. "=" .. tostring(key)
    -- Repaints repeat themselves; without this the ring buffer fills up with
    -- identical `paint=` entries and pushes the page changes out of it.
    if self.key_log[#self.key_log] == entry then return end

    self.key_log[#self.key_log + 1] = entry
    while #self.key_log > 10 do
        table.remove(self.key_log, 1)
    end
end

function PencilHandwriting:describeKeyLog()
    if not self.key_log or #self.key_log == 0 then return "-" end
    return table.concat(self.key_log, " ")
end

function PencilHandwriting:isOverlayActive()
    local top = UIManager:getTopmostVisibleWidget()
    if not top then return false end
    return (top.name or top.id) ~= "ReaderUI"
end

-- ============================================================================
-- Settings
-- ============================================================================
function PencilHandwriting:saveSettings()
    local ds = self.ui.doc_settings
    if not ds then return end
    ds:saveSetting("pencil_hw_enabled", self.enabled)
    ds:saveSetting("pencil_hw_width", self.width)
    ds:saveSetting("pencil_hw_color", self.color)
end

-- ============================================================================
-- Touch zones
-- ============================================================================
-- Taps inside the top strip must keep reaching the reader menu, otherwise
-- enabling touch blocking would make the plugin impossible to switch off
-- again. The real strip height is taken from the reader's own tap zone when
-- that setting is available.
local function menuStripRatio()
    local ratio = Config.MENU_STRIP_RATIO
    local ok, G_defaults = pcall(require, "luadefaults")
    if ok and G_defaults then
        local ok2, zone = pcall(function() return G_defaults:readSetting("DTAP_ZONE_MENU") end)
        if ok2 and type(zone) == "table" and tonumber(zone.h) and zone.h > ratio then
            ratio = zone.h
        end
    end
    if ratio <= 0 or ratio >= 0.5 then return Config.MENU_STRIP_RATIO end
    return ratio
end

function PencilHandwriting:registerTouchZones()
    if self.touch_zones_registered then return end
    self.touch_zones_registered = true

    local top = menuStripRatio()

    self.ui:registerTouchZones({
        {
            id = "pencil_hw_touch_block",
            ges = "tap",
            -- The top strip is excluded geometrically, so it is not even
            -- considered by this zone while the menu has to stay reachable.
            screen_zone = {
                ratio_x = 0, ratio_y = top,
                ratio_w = 1, ratio_h = 1 - top,
            },
            overrides = {
                "readerfooter_tap", "readerconfigmenu_tap",
                "tap_forward", "tap_backward",
                "readermenu_tap", "readermenu_ext_tap",
            },
            handler = function()
                -- Returning false hands the gesture back to the normal
                -- handlers, which is what we want whenever blocking is off.
                if not (self.enabled and self.block_touch) then return false end
                if self:isOverlayActive() then return false end
                return true
            end,
        },
    })
end

-- ============================================================================
-- Menu
-- ============================================================================
function PencilHandwriting:addToMainMenu(menu_items)
    -- Only meaningful inside a document.
    if not self.is_reader then return end

    menu_items.pencil_handwriting = {
        text = _("Pencil handwriting"),
        sorting_hint = "typeset",
        sub_item_table = {
            {
                text = _("Enable drawing"),
                checked_func = function() return self.enabled end,
                callback = function() self:toggleEnabled() end,
            },
            {
                text_func = function() return T(_("Width: %1"), self.width) end,
                callback = function() self:chooseWidth() end,
            },
            {
                text_func = function() return T(_("Color: %1"), self:colorLabel()) end,
                callback = function() self:chooseColor() end,
            },
            { separator = true },
            {
                text_func = function() return T(_("Input source: %1"), self:inputModeLabel()) end,
                sub_item_table_func = function() return self:inputSourceMenu() end,
            },
            {
                text = _("Block touch while drawing"),
                checked_func = function() return self.block_touch end,
                callback = function() self:toggleBlockTouch() end,
            },
            {
                text = _("Exclusive pen capture (evdev only)"),
                checked_func = function() return self.exclusive end,
                callback = function() self:toggleExclusiveCapture() end,
            },
            { separator = true },
            {
                text = _("Redraw strokes"),
                callback = function()
                    self:requestRepaint("ui")
                    UIManager:show(InfoMessage:new{
                        text = _("Strokes repainted from stored data."), timeout = 2 })
                end,
            },
            {
                text = _("Clear strokes on this page"),
                callback = function() self:confirmClearPage() end,
            },
            {
                text = _("Clear all strokes in document"),
                callback = function() self:confirmClearAll() end,
            },
            {
                text = _("Full refresh on page turn (test)"),
                checked_func = function() return self.full_refresh end,
                callback = function() self:toggleFullRefresh() end,
            },
            { separator = true },
            {
                text = _("Input diagnostics"),
                callback = function() self:showDiagnostics() end,
            },
        },
    }
end

function PencilHandwriting:colorLabel()
    for _, entry in ipairs(Config.COLOR_PALETTE) do
        if entry[1] == self.color then return entry[2] end
    end
    return self.color
end

function PencilHandwriting:inputModeLabel()
    local labels = {
        auto   = _("Auto"),
        stylus = _("KOReader stylus API"),
        evdev  = _("evdev (direct)"),
    }
    return labels[self.input_mode] or tostring(self.input_mode)
end

-- Which source decides what page a stroke belongs to used to be a menu switch.
-- It is not one any more: the document accessors were measured lagging behind
-- the page turn on this build, and a lagging identity paints one page's strokes
-- onto its neighbour -- so the switch was a way to break the plugin by
-- accident. The identity is chosen automatically (see resolvePageKey) and the
-- choice, plus what every accessor reports, is printed by the diagnostics.
-- `Config.PAGE_KEY_SOURCE = "live"` remains as a source-level debug knob.
function PencilHandwriting:toggleFullRefresh()
    self.full_refresh = not self.full_refresh
    saveGlobalSetting("pencil_hw_full_refresh_on_page", self.full_refresh)
    UIManager:show(InfoMessage:new{
        text = self.full_refresh
            and _("Full refresh on every page turn: ON.\nIf the ink stops following you now, the panel was not being cleared; if it still follows you, the page identity is wrong.")
            or _("Full refresh on every page turn: OFF."),
        timeout = 3,
    })
end

function PencilHandwriting:inputSourceMenu()
    local modes = {
        { "auto",   _("Auto (recommended)") },
        { "stylus", _("KOReader stylus API") },
        { "evdev",  _("evdev (direct)") },
    }

    local items = {}
    for _, entry in ipairs(modes) do
        local key = entry[1]
        items[#items + 1] = {
            text = entry[2],
            checked_func = function() return self.input_mode == key end,
            callback = function() self:setInputMode(key) end,
        }
    end
    return items
end

function PencilHandwriting:setInputMode(mode)
    self.input_mode = mode
    saveGlobalSetting("pencil_hw_input_source", mode)

    if self.enabled then
        self:stopCapture()
        self:startCapture()
    end

    UIManager:show(InfoMessage:new{
        text = T(_("Input source: %1"), self:inputModeLabel()),
        timeout = 2,
    })
end

function PencilHandwriting:onDispatcherRegisterActions()
    Dispatcher:registerAction("pencil_hw_toggle", {
        category = "none",
        event = "PencilHandwritingToggle",
        title = _("Pencil handwriting: toggle"),
        reader = true,
    })
end

function PencilHandwriting:onPencilHandwritingToggle()
    if not self.is_reader then return false end
    self:toggleEnabled()
    return true
end

function PencilHandwriting:toggleEnabled()
    self.enabled = not self.enabled
    self:saveSettings()

    if self.enabled then
        self:startCapture()
    else
        self:stopCapture()
    end

    local source = ""
    if self.enabled and self.input_source then
        source = self.input_source == "stylus"
            and _(" (KOReader stylus API)") or _(" (evdev)")
    end

    UIManager:show(InfoMessage:new{
        text = T(_("Pencil handwriting: %1"), self.enabled and _("on") or _("off"))
            .. source .. "\n" .. _("Stored notes stay visible either way."),
        timeout = 3,
    })
end

function PencilHandwriting:toggleBlockTouch()
    self.block_touch = not self.block_touch
    saveGlobalSetting("pencil_hw_block_touch", self.block_touch)

    UIManager:show(InfoMessage:new{
        text = self.block_touch
            and _("Touches are now ignored while drawing, so a resting hand cannot turn pages. The top strip still opens the menu.")
            or _("Touches work normally again while drawing."),
        timeout = 3,
    })
end

function PencilHandwriting:toggleExclusiveCapture()
    if self.exclusive then
        self:setExclusive(false)
        return
    end

    UIManager:show(ConfirmBox:new{
        text = _("Capture the digitizer node exclusively?\n\nThis only applies to the evdev input path. If the pen shares one node with the touch screen, finger input stops working until this is switched off again."),
        ok_text = _("Enable"),
        ok_callback = function() self:setExclusive(true) end,
    })
end

function PencilHandwriting:setExclusive(value)
    self.exclusive = value
    saveGlobalSetting("pencil_hw_exclusive", value)

    if self.enabled then
        self:stopCapture()
        self:startCapture()
    end

    UIManager:show(InfoMessage:new{
        text = value and _("Exclusive pen capture: on") or _("Exclusive pen capture: off"),
        timeout = 2,
    })
end

-- ============================================================================
-- Diagnostics
-- ============================================================================
function PencilHandwriting:collectDiagnostics()
    local lines = {}

    local input = getInput()
    lines[#lines + 1] = T(_("Build %1"), BUILD)
    -- Which language the menu text is actually in, so "it is still English" has
    -- a visible cause rather than being a guess.
    if I18n and type(I18n.describe) == "function" then
        lines[#lines + 1] = string.format("language: %s", I18n.describe())
    end
    lines[#lines + 1] = T(_("Drawing: %1"), self.enabled and _("on") or _("off"))
    lines[#lines + 1] = T(_("Input mode: %1"), self:inputModeLabel())
    lines[#lines + 1] = T(_("Page identity: %1"), tostring(self.page_key_source))
    lines[#lines + 1] = T(_("Active source: %1"),
        self.input_source or (self.stylus_callback and _("registered (idle)") or _("none")))
    lines[#lines + 1] = T(_("KOReader stylus API: %1"),
        (input and input.registerStylusCallback) and _("available") or _("missing"))
    if input then
        lines[#lines + 1] = string.format("input.pen_slot = %s", tostring(input.pen_slot))
    end

    lines[#lines + 1] = T(_("Repaint hook: %1"),
        self.paint_hook and _("installed") or _("MISSING"))
    lines[#lines + 1] = string.format("page-exit cleanup: %s (mode %s), always-on: %s",
        tostring(Config.PAGE_EXIT_CLEANUP), tostring(Config.PAGE_EXIT_REFRESH_MODE),
        self.full_refresh and "yes" or "no")
    lines[#lines + 1] = T(_("Last page exit: %1"), tostring(self.last_page_exit))
    -- Strokes are stored in native space and rotated at draw time, so both
    -- frames are worth showing: a wrong mapping shows up here first.
    --
    -- The two multi-value helpers are expanded explicitly. Lua only spreads
    -- the *last* argument of a call, so passing screenDims() in the middle
    -- would silently drop its height and `string.format` would then fail on a
    -- missing argument -- which is exactly what took the diagnostics down.
    local sw, sh = screenDims()
    local nw, nh = Geometry.nativeDims()
    lines[#lines + 1] = string.format("rotation=%s, screen=%dx%d, native=%dx%d",
        Geometry.rotationKind(), sw, sh, nw, nh)
    -- Both rotation sources, because a build that rotates the framebuffer
    -- without updating the input rotation is exactly the case where ink lands
    -- in the wrong place in landscape.
    lines[#lines + 1] = T(_("Rotation sources: %1"), Geometry.rotationReport())

    -- The tool values the input layer reports, and the ones we compare against.
    -- "Last slot" shows the raw value: if the eraser reports a tool this map does
    -- not call the eraser, that is visible here rather than guessed at.
    local pen_t, eraser_t, hi_t = toolTypes()
    lines[#lines + 1] = string.format("toolmap: pen=%s eraser=%s highlighter=%s",
        tostring(pen_t), tostring(eraser_t), tostring(hi_t))

    -- Which coordinate space strokes are stored in, and what the view maps to
    -- right now. This is the line that says whether ink is anchored to the
    -- content (page space) or to the screen (native space).
    local viewmap = self:viewMap()
    if viewmap then
        local first, last = viewmap:visiblePageRange(sw, sh)
        lines[#lines + 1] = string.format(
            "stroke space: page (%.3f page px per screen px), pages on screen: %s..%s",
            viewmap:pagePerScreen(first or self.page_key), tostring(first), tostring(last))
    else
        lines[#lines + 1] = string.format("stroke space: native (%s)",
            self:isPaged() and "no page mapping available" or "reflowable document")
    end
    lines[#lines + 1] = T(_("Last stroke: %1"), tostring(self.last_write))

    if self.store then
        local page = self.page_key or self:currentPageKey()
        lines[#lines + 1] = T(_("Page key: %1  (%2)"),
            tostring(page), tostring(self.page_key_source))
        lines[#lines + 1] = string.format("strokes on page = %d, in document = %d, pages stored = %d",
            #self.store:pageStrokes(page), self.store:strokeCount(), self.store:pageCount())
        lines[#lines + 1] = self.store:describe()
        lines[#lines + 1] = T(_("Page accessors: %1"), self:describeKeyResolvers())
        lines[#lines + 1] = T(_("Page changes: %1"), self:describePageLog())
        lines[#lines + 1] = T(_("Key log: %1"), self:describeKeyLog())
    end

    local s = self.stats or {}
    lines[#lines + 1] = string.format("stylus slots=%d, pen downs=%d, coord fixes=%d",
        s.stylus_slots or 0, s.pen_downs or 0, s.coord_corrections or 0)
    lines[#lines + 1] = string.format("live stamps=%d, map fallbacks=%d, key mismatches=%d",
        s.live_stamps or 0, s.map_fallbacks or 0, s.paint_mismatch or 0)
    -- pages whose map the reader could not confirm (ink deliberately not drawn
    -- for them) and strokes that had to hold because their map went away.
    lines[#lines + 1] = string.format(
        "unmapped pages=%d, re-anchored pages=%d, stroke pauses=%d, off-panel=%d",
        s.pages_unmapped or 0, s.pages_relaxed or 0, s.stroke_pauses or 0,
        s.offpanel or 0)
    lines[#lines + 1] = string.format(
        "stylus handler errors=%d, coord rejected=%d, coord clamped=%d, erase unmapped=%d",
        s.slot_errors or 0, s.coord_rejected or 0, s.coord_clamped or 0,
        s.erase_unmapped or 0)
    -- Proof that the panel clean-up actually ran: a page turn away from a page
    -- with ink must be counted here, otherwise the policy is only a promise.
    lines[#lines + 1] = string.format(
        "page-exit: %d flashed, %d plain (over %d page turns)",
        s.page_exit_flashes or 0, s.page_exit_plain or 0, s.page_updates or 0)
    -- Event counters: page_updates/pos_updates firing constantly while writing,
    -- together with strokes_dropped, is the signature of strokes being
    -- discarded under the pen.
    lines[#lines + 1] = string.format(
        "page updates=%d, pos updates=%d, strokes committed=%d, dropped=%d",
        s.page_updates or 0, s.pos_updates or 0,
        s.strokes_committed or 0, s.strokes_dropped or 0)
    lines[#lines + 1] = string.format("erase scans=%d, strokes erased=%d",
        s.erase_scans or 0, s.erase_removed or 0)
    lines[#lines + 1] = string.format("repaints=%d, render errors=%d",
        s.repaints or 0, s.render_errors or 0)
    lines[#lines + 1] = T(_("Last slot: %1"), s.last_slot or "-")
    lines[#lines + 1] = T(_("Last error: %1"), s.last_error or "-")

    local reader = self.reader
    if reader and reader.device_path then
        lines[#lines + 1] = T(_("evdev node: %1 (%2)"),
            reader.device_path, (reader.device_info and reader.device_info.name) or "?")
        lines[#lines + 1] = string.format("grab=%s events=%d pen_downs=%d",
            tostring(reader.grabbed), reader.event_count or 0, reader.pen_down_count or 0)
        lines[#lines + 1] = string.format("raw range: x %d..%d  y %d..%d",
            reader.range_x_min, reader.range_x_max,
            reader.range_y_min, reader.range_y_max)
        lines[#lines + 1] = T(_("Last event: %1"), reader.last_event or "-")
    else
        lines[#lines + 1] = _("evdev node: not opened")
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = _("Input devices on this reader:")
    local ok, device_lines = pcall(EvdevReader.describeDevices)
    if ok then
        for _, line in ipairs(device_lines) do
            lines[#lines + 1] = line
        end
    else
        lines[#lines + 1] = tostring(device_lines)
    end

    return table.concat(lines, "\n")
end

-- The diagnostics is a debugging tool, so it must not be able to take the
-- reader down with it: an error inside it is reported on screen instead of
-- propagating into the menu event and killing KOReader.
function PencilHandwriting:showDiagnostics()
    local ok, text = pcall(function() return self:collectDiagnostics() end)
    if not ok then
        text = _("Diagnostics failed:") .. "\n" .. tostring(text)
        logger.err("PencilHW: diagnostics failed:", text)
    end

    logger.info("PencilHW: diagnostics\n" .. text)

    UIManager:show(TextViewer:new{
        title = _("Input diagnostics"),
        text = text,
    })
end

-- ============================================================================
-- Width and colour
-- ============================================================================
function PencilHandwriting:chooseWidth()
    local spin
    spin = SpinWidget:new{
        title_text = _("Pen width"),
        wrap = true,
        value_table = Config.WIDTH_PRESETS,
        value = self.width,
        value_min = Config.MIN_WIDTH,
        value_max = Config.MAX_WIDTH,
        value_step = 1,
        value_hold_step = 2,
        precision = "%d",
        ok_always_enabled = true,
        extra_text = _("Custom..."),
        extra_callback = function()
            local input_dialog
            input_dialog = InputDialog:new{
                title = _("Custom width"),
                input_type = "number",
                input_hint = T(_("%1 - %2 (current: %3)"),
                    Config.MIN_WIDTH, Config.MAX_WIDTH, self.width),
                buttons = {
                    {
                        {
                            text = _("Cancel"),
                            id = "close",
                            callback = function() UIManager:close(input_dialog) end,
                        },
                        {
                            text = _("OK"),
                            is_enter_default = true,
                            callback = function()
                                local v = tonumber(input_dialog:getInputText())
                                if v and v >= Config.MIN_WIDTH and v <= Config.MAX_WIDTH then
                                    self.width = math.floor(v + 0.5)
                                    self:saveSettings()
                                    UIManager:close(input_dialog)
                                else
                                    UIManager:show(InfoMessage:new{
                                        text = T(_("Invalid width (%1 - %2)"),
                                            Config.MIN_WIDTH, Config.MAX_WIDTH),
                                        timeout = 2,
                                    })
                                end
                            end,
                        },
                    },
                },
            }
            UIManager:show(input_dialog)
        end,
        callback = function()
            if spin.value_widget then
                self.width = spin.value_widget:getValue()
                self:saveSettings()
            end
        end,
    }
    UIManager:show(spin)
end

function PencilHandwriting:chooseColor()
    local dialog
    local buttons = {}
    for _, entry in ipairs(Config.COLOR_PALETTE) do
        table.insert(buttons, {
            {
                text = entry[2],
                callback = function()
                    self.color = entry[1]
                    self:saveSettings()
                    UIManager:close(dialog)
                end,
            },
        })
    end

    dialog = ButtonDialog:new{
        title = _("Pen color"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- ============================================================================
-- Clearing
-- ============================================================================
function PencilHandwriting:confirmClearPage()
    local page = self:currentPageKey()
    local count = #self.store:pageStrokes(page)

    if count == 0 then
        UIManager:show(InfoMessage:new{ text = _("No strokes on this page."), timeout = 2 })
        return
    end

    UIManager:show(ConfirmBox:new{
        text = T(_("Clear %1 strokes on this page?"), count),
        ok_text = _("Clear"),
        ok_callback = function()
            self.store:removePageStrokes(page)
            self:requestRepaint("ui")
        end,
    })
end

function PencilHandwriting:confirmClearAll()
    local total = self.store:strokeCount()

    if total == 0 then
        UIManager:show(InfoMessage:new{ text = _("No strokes to clear."), timeout = 2 })
        return
    end

    UIManager:show(ConfirmBox:new{
        text = T(_("Clear all %1 strokes in this document?"), total),
        ok_text = _("Clear all"),
        ok_callback = function()
            self.store:removeAll()
            self:requestRepaint("ui")
        end,
    })
end

return PencilHandwriting
