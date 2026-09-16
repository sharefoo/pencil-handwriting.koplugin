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
local logger = require("logger")
local InputContainer = require("ui/widget/container/inputcontainer")

local BUILD = "0.6.0"

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
local EvdevReader = loadSubmodule("evdev")
local Canvas      = loadSubmodule("canvas")
local StrokeStore = loadSubmodule("store")

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
local function screenDims()
    local device = getDevice()
    local screen = device and device.screen
    if not screen then return 600, 800 end
    if screen.bb then
        local ok, w, h = pcall(function()
            return screen.bb:getWidth(), screen.bb:getHeight()
        end)
        if ok and tonumber(w) and tonumber(h) and w > 0 and h > 0 then
            return w, h
        end
    end
    return screen:getWidth(), screen:getHeight()
end

local function screenBB()
    local device = getDevice()
    local screen = device and device.screen
    return screen and screen.bb or nil
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
    page_key = nil,

    current_stroke = nil,
    last_pen_x = nil,
    last_pen_y = nil,

    settle_timer = nil,
    ghost_timer = nil,
    erase_timer = nil,
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
        last_slot = "-",
        last_error = "-",
    }

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

    self.store = StrokeStore:new(self:getSidecarDir())
    self.store:load()
    self.page_key = self:computePageKey()

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

    self.page_key = self:computePageKey()
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

function PencilHandwriting:onPageUpdate()
    self:endStrokeSilently()
    self:cancelSettle()
    self:cancelEraseRefresh()
    if self.store then self.store:save() end
    self.page_key = self:computePageKey()
    self:requestRepaint("ui")
end

function PencilHandwriting:onPosUpdate()
    self:onPageUpdate()
end

function PencilHandwriting:onRotationChange()
    self:endStrokeSilently()
    self:cancelSettle()
    self:cancelEraseRefresh()
    self.page_key = self:computePageKey()
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
            plugin:paintStrokes(bb, x, y)
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
function PencilHandwriting:paintStrokes(bb, ox, oy)
    if not bb or not self.store then return end

    self.stats.repaints = self.stats.repaints + 1

    local ok, err = pcall(function()
        Canvas.renderStrokes(bb, self.store:pageStrokes(self.page_key), ox, oy)
        if self.current_stroke then
            Canvas.renderStroke(bb, self.current_stroke, ox, oy)
        end
    end)

    if not ok then
        self.stats.render_errors = self.stats.render_errors + 1
        self.stats.last_error = tostring(err)
        logger.err("PencilHW: paint failed:", err)
    end
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
function PencilHandwriting:markDirty(region)
    if not region then return end

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
    if x2 <= x or y2 <= y then return end

    -- nil widget: no widget repaint is wanted here, only this screen region.
    -- That keeps the freshly stamped ink on screen instead of having KOReader
    -- paint the page back over it.
    UIManager:setDirty(nil, "fast", Geom:new{ x = x, y = y, w = x2 - x, h = y2 - y })
end

function PencilHandwriting:endStrokeSilently()
    self.current_stroke = nil
    self.last_pen_x, self.last_pen_y = nil, nil
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
function PencilHandwriting:onStylusSlot(input, slot)
    if not self.stats then return false end

    -- When the raw evdev path is forced, stay completely out of the way.
    if self.input_mode == "evdev" then return false end

    self.stats.stylus_slots = self.stats.stylus_slots + 1
    self.stats.last_slot = string.format("slot=%s id=%s tool=%s x=%s y=%s",
        tostring(slot.slot), tostring(slot.id), tostring(slot.tool),
        tostring(slot.x), tostring(slot.y))

    if not self.enabled then return false end

    local x, y = tonumber(slot.x), tonumber(slot.y)
    if not x or not y then return false end
    x, y = self:fixupStylusCoords(x, y)

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

-- The stylus callback is documented to hand over fully processed (screen
-- space) coordinates. If a build hands over raw digitizer units instead, the
-- values fall far outside the panel and we scale them using the digitizer's
-- own axis ranges, obtained by opening the node read-only.
function PencilHandwriting:fixupStylusCoords(x, y)
    if Config.STYLUS_COORD_CORRECTION ~= "auto" then return x, y end

    local w, h = screenDims()
    if x >= -w * 0.25 and x <= w * 1.25 and y >= -h * 0.25 and y <= h * 1.25 then
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
        if self.reader:isOpen() then
            self.stats.coord_corrections = self.stats.coord_corrections + 1
            return self.reader:transform(x, y)
        end
    end

    self.stats.coord_corrections = self.stats.coord_corrections + 1
    if x < 0 then x = 0 elseif x > w - 1 then x = w - 1 end
    if y < 0 then y = 0 elseif y > h - 1 then y = h - 1 end
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
    self:endStrokeSilently()
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
function PencilHandwriting:onPenDown(x, y, pressure)
    if self:isOverlayActive() then return end

    self:cancelSettle()

    self.current_stroke = {
        tool = "pen",
        width = self.width,
        color = self.color,
        points = { x, y },
    }
    self.last_pen_x, self.last_pen_y = x, y

    local bb = screenBB()
    if not bb then return end

    self:markDirty(Canvas.stampDisc(bb, x, y, self.width / 2,
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

    table.insert(self.current_stroke.points, x)
    table.insert(self.current_stroke.points, y)

    local bb = screenBB()
    if not bb then return end

    self:markDirty(Canvas.drawLine(bb, self.last_pen_x, self.last_pen_y, x, y,
        self.width / 2, Canvas.colorFor(self.color)))
    self:flushDirtyFast()

    self.last_pen_x, self.last_pen_y = x, y
    self:scheduleGhostRefresh()
end

function PencilHandwriting:onPenUp()
    if not self.current_stroke or self.current_stroke.tool ~= "pen" then return end

    self.store:addStroke(self.page_key, self.current_stroke)
    self.current_stroke = nil
    self.last_pen_x, self.last_pen_y = nil, nil

    self:cancelGhostRefresh()
    self:scheduleSettleRefresh()
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

    local strokes = self.store:pageStrokes(self.page_key)
    local radius = Config.ERASER_RADIUS_PX
    local r2 = radius * radius

    local removed = 0
    local keep = {}
    for _, s in ipairs(strokes) do
        if s.tool ~= "eraser" then
            local hit = false
            local box = strokeBBox(s)
            -- Cheap reject first: the disc cannot touch a stroke whose bounding
            -- box is entirely outside it.
            if box and x + radius >= box[1] and x - radius <= box[3]
                and y + radius >= box[2] and y - radius <= box[4] then
                local pts = s.points
                for i = 1, #pts - 1, 2 do
                    local dx, dy = pts[i] - x, pts[i + 1] - y
                    if dx * dx + dy * dy <= r2 then
                        hit = true
                        break
                    end
                end
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
        self.store.pages[self.page_key] = keep
        self.stats.erase_removed = self.stats.erase_removed + removed
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

-- Cached page key, recomputed only on page/position/rotation changes -- never
-- from inside a repaint, where querying the document can be expensive.
function PencilHandwriting:computePageKey()
    if self.ui.paging and self.ui.paging.current_page then
        return self.ui.paging.current_page
    end

    local pos = 0
    if self.ui.document and self.ui.document.getCurrentPos then
        local ok, res = pcall(function() return self.ui.document:getCurrentPos() end)
        if ok and res then pos = res end
    end
    return pos
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
function PencilHandwriting:showDiagnostics()
    local lines = {}

    local input = getInput()
    lines[#lines + 1] = T(_("Build %1"), BUILD)
    lines[#lines + 1] = T(_("Drawing: %1"), self.enabled and _("on") or _("off"))
    lines[#lines + 1] = T(_("Input mode: %1"), self.inputModeLabel())
    lines[#lines + 1] = T(_("Active source: %1"),
        self.input_source or (self.stylus_callback and _("registered (idle)") or _("none")))
    lines[#lines + 1] = T(_("KOReader stylus API: %1"),
        (input and input.registerStylusCallback) and _("available") or _("missing"))
    if input then
        lines[#lines + 1] = string.format("input.pen_slot = %s", tostring(input.pen_slot))
    end

    lines[#lines + 1] = T(_("Repaint hook: %1"),
        self.paint_hook and _("installed") or _("MISSING"))
    lines[#lines + 1] = T(_("Page key: %1"), tostring(self.page_key))

    if self.store then
        lines[#lines + 1] = string.format("strokes on page = %d, in document = %d",
            #self.store:pageStrokes(self.page_key), self.store:strokeCount())
        lines[#lines + 1] = T(_("Sidecar: %1"), self.store:sidecarPath() or _("unknown"))
    end

    local s = self.stats or {}
    lines[#lines + 1] = string.format("stylus slots=%d, pen downs=%d, coord fixes=%d",
        s.stylus_slots or 0, s.pen_downs or 0, s.coord_corrections or 0)
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

    local text = table.concat(lines, "\n")
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
    local count = #self.store:pageStrokes(self.page_key)

    if count == 0 then
        UIManager:show(InfoMessage:new{ text = _("No strokes on this page."), timeout = 2 })
        return
    end

    UIManager:show(ConfirmBox:new{
        text = T(_("Clear %1 strokes on this page?"), count),
        ok_text = _("Clear"),
        ok_callback = function()
            self.store:removePageStrokes(self.page_key)
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
