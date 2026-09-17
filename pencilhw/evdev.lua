--[[--
evdev pen reader for pencil-handwriting.

Opens the digitizer node directly and parses the Linux input event stream,
bypassing KOReader's gesture pipeline entirely for minimal latency.

Which node is opened is decided by capability, not by a hardcoded path:
/proc/bus/input/devices is parsed and the node whose EV_KEY bitmap contains
BTN_TOOL_PEN / BTN_TOOL_RUBBER wins. A name heuristic and finally a static
path list are used only as fallbacks.

Callback contract (coordinates are native/portrait panel pixels, NOT screen
pixels -- the screen rotation is applied at draw time by pencilhw/geometry):

    onPenDown(x, y, pressure)
    onPenMove(x, y, pressure)
    onPenUp()
    onEraserDown(x, y)
    onEraserMove(x, y)
    onEraserUp()
--]]

local ffi = require("ffi")
local logger = require("logger")
local Config = require("pencilhw/config")
local Geometry = require("pencilhw/geometry")

local C = ffi.C

-- ---------------------------------------------------------------------------
-- FFI declarations
-- ---------------------------------------------------------------------------
-- Declared one by one: ffi.cdef aborts at the first error, so a single
-- duplicate declaration in a combined block would silently drop everything
-- that follows it. KOReader declares some libc symbols itself, so duplicates
-- are expected here.
local function safeCdef(decl)
    local ok, err = pcall(ffi.cdef, decl)
    if not ok then
        logger.dbg("PencilHW: cdef skipped:", tostring(err))
    end
    return ok
end

safeCdef("int open(const char *pathname, int flags)")
safeCdef("int close(int fd)")
safeCdef("ssize_t read(int fd, void *buf, size_t count)")
safeCdef("int ioctl(int fd, unsigned long request, ...)")
safeCdef("struct input_event { struct timeval time; uint16_t type; uint16_t code; int32_t value; }")
safeCdef("struct input_absinfo { int32_t value; int32_t minimum; int32_t maximum; int32_t fuzz; int32_t flat; int32_t resolution; }")

local HAS_LIBC = (function()
    local ok, res = pcall(function()
        return C.open ~= nil and C.ioctl ~= nil and C.read ~= nil
    end)
    return ok and res == true
end)()

local EV_SIZE = (function()
    local ok, size = pcall(ffi.sizeof, "struct input_event")
    if ok and tonumber(size) then return tonumber(size) end
    return 16 -- 32-bit timeval: 8 + 2 + 2 + 4
end)()

local HAS_ABSINFO = (function()
    local ok, size = pcall(ffi.sizeof, "struct input_absinfo")
    return ok and tonumber(size) == 24
end)()

local O_RDONLY   = 0
local O_NONBLOCK = 0x800

local EVIOCGRAB  = 0x40044590          -- _IOW('E', 0x90, int)
local EVIOCGABS  = 0x80184500          -- _IOR('E', 0x40 + abs_code, struct input_absinfo)

-- ---------------------------------------------------------------------------
-- /proc/bus/input/devices parsing
-- ---------------------------------------------------------------------------
-- The kernel prints each bitmap most-significant word first. Bit N of the
-- bitmap therefore always sits `N / 4` nibbles from the *right* of the printed
-- string, regardless of whether it was printed as 32- or 64-bit words.
local function normaliseBitmap(phrase)
    local words, width = {}, 8
    for word in phrase:gmatch("%x+") do
        if #word > width then width = #word end
        words[#words + 1] = word
    end
    if #words == 0 then return "" end
    for i = 1, #words do
        if #words[i] < width then
            words[i] = string.rep("0", width - #words[i]) .. words[i]
        end
    end
    return table.concat(words)
end

local function bitmapHasBit(bitmap, bit)
    if bitmap == "" then return false end
    local pos = #bitmap - math.floor(bit / 4)
    if pos < 1 then return false end
    local digit = tonumber(bitmap:sub(pos, pos), 16)
    if not digit then return false end
    local mask = ({ 1, 2, 4, 8 })[(bit % 4) + 1]
    return math.floor(digit / mask) % 2 == 1
end

local function scanInputDevices()
    local devices = {}
    local f = io.open("/proc/bus/input/devices", "r")
    if not f then
        logger.warn("PencilHW: /proc/bus/input/devices is not readable")
        return devices
    end

    local cur
    local function finish()
        if cur then
            if cur.event then cur.path = "/dev/input/" .. cur.event end
            devices[#devices + 1] = cur
        end
        cur = nil
    end

    for line in f:lines() do
        if line:sub(1, 2) == "I:" then
            finish()
            cur = { name = "", keybits = "" }
        elseif cur then
            local name = line:match('^N: Name="(.-)"')
            if name then
                cur.name = name
            else
                local handlers = line:match("^H: Handlers=(.*)$")
                if handlers then
                    cur.event = handlers:match("(event%d+)")
                else
                    local key = line:match("^B: KEY=(.*)$")
                    if key then cur.keybits = key end
                end
            end
        end
    end
    finish()
    f:close()

    for _, d in ipairs(devices) do
        local bitmap = normaliseBitmap(d.keybits or "")
        d.pen_capable = false
        for _, bit in ipairs(Config.PEN_KEY_BITS) do
            if bitmapHasBit(bitmap, bit) then
                d.pen_capable = true
                break
            end
        end

        local lname = (d.name or ""):lower()
        d.name_pen, d.name_finger = false, false
        for _, hint in ipairs(Config.PEN_NAME_HINTS) do
            if lname:find(hint, 1, true) then d.name_pen = true break end
        end
        for _, hint in ipairs(Config.FINGER_NAME_HINTS) do
            if lname:find(hint, 1, true) then d.name_finger = true break end
        end
    end

    return devices
end

local function deviceScore(d)
    local score = 0
    if d.pen_capable then score = score + 100 end
    if d.name_pen then score = score + 50 end
    if d.name_finger and not d.pen_capable then score = score - 40 end
    return score
end

-- ---------------------------------------------------------------------------
-- Coordinate handling
-- ---------------------------------------------------------------------------
-- Rotation is deliberately *not* applied here. This module produces native
-- (portrait panel) pixels, which is the space strokes are stored in; the
-- screen rotation is applied at draw time by pencilhw/geometry.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- EvdevReader
-- ---------------------------------------------------------------------------
local EvdevReader = {}
EvdevReader.__index = EvdevReader

function EvdevReader:new()
    return setmetatable({
        fd = nil,
        device_path = nil,
        device_info = nil,
        grabbed = false,

        slot = 0,
        pen_slot = nil,
        tracking_id = -1,
        tool = Config.TOOL_FINGER,

        x = 0,
        y = 0,
        pressure = 0,

        pen_down = false,
        eraser_down = false,

        -- Diagnostics, updated even when no callbacks are wired up.
        event_count = 0,
        pen_down_count = 0,
        last_event = "-",

        -- Raw axis ranges, filled in from EVIOCGABS when the node supports it.
        range_x_min = 0,
        range_x_max = 0,
        range_y_min = 0,
        range_y_max = 0,

        ev = HAS_LIBC and ffi.new("struct input_event") or nil,
    }, self)
end

-- ---------------------------------------------------------------------------
-- Device discovery
-- ---------------------------------------------------------------------------
local function canOpen(path)
    if HAS_LIBC then
        local fd = C.open(path, O_RDONLY)
        if fd < 0 then return false end
        C.close(fd)
        return true
    end
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

function EvdevReader:pickDevice()
    for _, path in ipairs(Config.EXTRA_DEVICE_PATHS) do
        if canOpen(path) then
            return path, { path = path, name = "configured", pen_capable = true }
        end
    end

    local best, best_score
    for _, d in ipairs(scanInputDevices()) do
        if d.path and canOpen(d.path) then
            local score = deviceScore(d)
            if score > 0 and (not best_score or score > best_score) then
                best, best_score = d, score
            end
        end
    end
    if best then return best.path, best end

    for _, path in ipairs(Config.TOUCH_DEVICE_CANDIDATES) do
        if canOpen(path) then
            logger.warn("PencilHW: no pen-capable node detected, falling back to", path)
            return path, { path = path, name = "fallback candidate" }
        end
    end

    return nil
end

function EvdevReader:queryAxisRanges(fd)
    if not (HAS_LIBC and HAS_ABSINFO) then return end

    local info = ffi.new("struct input_absinfo[1]")
    local axes = {
        { Config.ABS_MT_POSITION_X, "x", true },
        { Config.ABS_MT_POSITION_Y, "y", true },
        { Config.ABS_X,             "x", false },
        { Config.ABS_Y,             "y", false },
    }

    for _, axis in ipairs(axes) do
        local code, key, is_mt = axis[1], axis[2], axis[3]
        local ok = pcall(function() return C.ioctl(fd, EVIOCGABS + code, info) end)
        if ok then
            local mn, mx = tonumber(info[0].minimum), tonumber(info[0].maximum)
            if mn and mx and mx > mn then
                if key == "x" then
                    if self.range_x_max == 0 or is_mt then
                        self.range_x_min, self.range_x_max = mn, mx
                    end
                else
                    if self.range_y_max == 0 or is_mt then
                        self.range_y_min, self.range_y_max = mn, mx
                    end
                end
            end
        end
    end
end

-- Human-readable node list, used by the "Digitizer info" menu entry.
function EvdevReader.describeDevices()
    local lines = {}
    local devices = scanInputDevices()
    if #devices == 0 then
        return { "no entries in /proc/bus/input/devices" }
    end

    for _, d in ipairs(devices) do
        local tags = {}
        if d.pen_capable then tags[#tags + 1] = "pen-tool" end
        if d.name_pen then tags[#tags + 1] = "name" end
        if d.name_finger and not d.pen_capable then tags[#tags + 1] = "touch" end
        lines[#lines + 1] = string.format("%-8s %s%s",
            d.event or "(none)",
            (d.name ~= "" and d.name) or "?",
            #tags > 0 and ("  [" .. table.concat(tags, ",") .. "]") or "")
    end
    return lines
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function EvdevReader:open(exclusive)
    if self.fd then return true end

    if not HAS_LIBC then
        logger.err("PencilHW: libc ffi symbols unavailable, cannot read evdev")
        return false
    end

    local path, info = self:pickDevice()
    if not path then
        logger.warn("PencilHW: no input device found")
        return false
    end

    local fd = C.open(path, O_RDONLY + O_NONBLOCK)
    if fd < 0 then
        logger.warn("PencilHW: failed to open", path)
        return false
    end

    self.fd = fd
    self.device_path = path
    self.device_info = info

    self:queryAxisRanges(fd)

    if exclusive and C.ioctl(fd, EVIOCGRAB, 1) == 0 then
        self.grabbed = true
    elseif exclusive then
        logger.warn("PencilHW: exclusive grab refused on", path)
    end

    logger.info(string.format(
        "PencilHW: capture on %s (%s) grab=%s raw_x=%d..%d raw_y=%d..%d",
        path, (info and info.name) or "?", tostring(self.grabbed),
        self.range_x_min, self.range_x_max, self.range_y_min, self.range_y_max))
    return true
end

function EvdevReader:close()
    if not self.fd then return end
    if self.grabbed and HAS_LIBC then
        C.ioctl(self.fd, EVIOCGRAB, 0)
        self.grabbed = false
    end
    if HAS_LIBC then C.close(self.fd) end
    self.fd = nil
    self.device_path = nil
end

function EvdevReader:isOpen()
    return self.fd ~= nil
end

-- ---------------------------------------------------------------------------
-- Coordinate transform (raw digitizer units -> native panel pixels)
-- ---------------------------------------------------------------------------
-- Only the scaling is done here. The screen rotation is applied at draw time
-- (see pencilhw/geometry), which keeps the stored strokes valid across a
-- rotation instead of baking the current orientation into them.
-- True when the node reported axis ranges that are usable for scaling.
--
-- This has to be checked before dividing by a span: several devices answer
-- EVIOCGABS with a zero range (the Kindle Scribe's digitizer does), and a zero
-- span turns scaled coordinates into infinities rather than raising an error.
function EvdevReader:hasUsableRanges()
    local rw = self.range_x_max - self.range_x_min
    local rh = self.range_y_max - self.range_y_min
    return rw > 0 and rh > 0
end

function EvdevReader:transform(x, y)
    local native_w, native_h = Geometry.nativeDims()

    local rw = self.range_x_max - self.range_x_min
    local rh = self.range_y_max - self.range_y_min
    if Config.AUTO_SCALE_RAW and rw > 0 and rh > 0 then
        x = (x - self.range_x_min) * native_w / rw
        y = (y - self.range_y_min) * native_h / rh
    end

    return x, y
end

-- ---------------------------------------------------------------------------
-- Event parsing
-- ---------------------------------------------------------------------------
function EvdevReader:poll()
    if not self.fd then return end

    while true do
        local n = tonumber(C.read(self.fd, self.ev, EV_SIZE))
        if not n or n <= 0 then break end
        if n ~= EV_SIZE then
            logger.warn("PencilHW: short read", n)
            break
        end
        self:handleEvent(tonumber(self.ev.type), tonumber(self.ev.code), tonumber(self.ev.value))
    end
end

function EvdevReader:handleEvent(etype, ecode, value)
    self.event_count = self.event_count + 1
    self.last_event = string.format("t=%d c=0x%x v=%d", etype, ecode, value)

    if etype == Config.EV_SYN then
        if ecode == Config.SYN_REPORT then
            self:flushFrame()
        end
    elseif etype == Config.EV_ABS then
        self:handleAbs(ecode, value)
    elseif etype == Config.EV_KEY then
        self:handleKey(ecode, value)
    end
end

function EvdevReader:handleAbs(code, value)
    if code == Config.ABS_MT_SLOT then
        self.slot = value
    elseif code == Config.ABS_MT_TRACKING_ID then
        self.tracking_id = value
        if value < 0 and self.pen_slot == self.slot then
            self.pen_slot = nil
        end
    elseif code == Config.ABS_MT_POSITION_X or code == Config.ABS_X then
        self.x = value
    elseif code == Config.ABS_MT_POSITION_Y or code == Config.ABS_Y then
        self.y = value
    elseif code == Config.ABS_MT_PRESSURE or code == Config.ABS_PRESSURE then
        self.pressure = value
    elseif code == Config.ABS_MT_TOOL_TYPE then
        self.tool = value
        if value == Config.TOOL_PEN or value == Config.TOOL_ERASER then
            self.pen_slot = self.slot
        end
    end
end

function EvdevReader:handleKey(code, value)
    if code == Config.BTN_TOOL_PEN then
        if value == 1 then
            self.tool = Config.TOOL_PEN
            self.pen_slot = self.slot
        else
            self.tool = Config.TOOL_FINGER
        end

    elseif code == Config.BTN_TOOL_RUBBER then
        if value == 1 then
            self.tool = Config.TOOL_ERASER
            self.pen_slot = self.slot
        else
            self.tool = Config.TOOL_FINGER
        end

    elseif code == Config.BTN_TOUCH then
        if self.tool == Config.TOOL_PEN then
            local sx, sy = self:transform(self.x, self.y)
            if value == 1 then
                self.pen_down = true
                self.pen_down_count = self.pen_down_count + 1
                if self.onPenDown then self.onPenDown(sx, sy, self.pressure) end
            elseif self.pen_down then
                self.pen_down = false
                if self.onPenUp then self.onPenUp() end
            end

        elseif self.tool == Config.TOOL_ERASER then
            local sx, sy = self:transform(self.x, self.y)
            if value == 1 then
                self.eraser_down = true
                if self.onEraserDown then self.onEraserDown(sx, sy) end
            elseif self.eraser_down then
                self.eraser_down = false
                if self.onEraserUp then self.onEraserUp() end
            end
        end
    end
end

-- Emitted once per SYN_REPORT while a tool is in contact.
function EvdevReader:flushFrame()
    if self.pen_down and self.onPenMove then
        local sx, sy = self:transform(self.x, self.y)
        self.onPenMove(sx, sy, self.pressure)
    elseif self.eraser_down and self.onEraserMove then
        local sx, sy = self:transform(self.x, self.y)
        self.onEraserMove(sx, sy)
    end
end

return EvdevReader
