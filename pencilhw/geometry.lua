--[[--
Coordinate handling for pencil-handwriting.

Two frames, made explicit because getting this wrong is invisible in portrait:

  native space -- portrait-oriented panel pixels. This is what strokes are
                  *stored* in, so they survive a screen rotation.
  screen space -- the current, possibly rotated, framebuffer. This is where
                  ink has to be drawn.

The coordinates handed to KOReader's stylus callback are RAW digitizer values:
KOReader only applies the screen rotation later, on its way to gesture
matching (`GestureDetector:adjustGesCoordinate` -> `translateCoordinates`).
In portrait the raw frame and the screen frame coincide, so a plugin that
ignores the rotation appears to work -- and then lands ink in the wrong place
as soon as the reader is turned sideways.

`nativeToScreen` mirrors KOReader's own rotation arithmetic so ink lands
exactly where the gesture layer would have placed the same touch.
--]]

local Geometry = {}

local function getScreen()
    local ok, device = pcall(require, "device")
    if ok and device and device.screen then return device.screen end
    return nil
end

-- Framebuffer dimensions: the framebuffer is what we draw into, so its own
-- size is authoritative.
function Geometry.dims()
    local screen = getScreen()
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

-- The rotation value that maps the fixed panel frame onto the *current*
-- framebuffer -- which is what ink has to agree with.
--
-- `getTouchRotation` is KOReader's own answer for input coordinates and is used
-- first. Some builds (and some custom reader builds, where rotation is driven
-- by a separate geometry pipeline) never update it, and then it reports 0 while
-- the framebuffer is clearly rotated. Falling back to the screen rotation mode
-- in that case is the correct inference: whatever the input layer believes, the
-- ink must land in the framebuffer's orientation.
Geometry.rotation_source = "none"

function Geometry.rotation()
    local screen = getScreen()
    if not screen then
        Geometry.rotation_source = "no screen"
        return 0
    end

    -- 1. the input rotation, when this build maintains it
    if type(screen.getTouchRotation) == "function" then
        local ok, mode = pcall(screen.getTouchRotation, screen)
        if ok and tonumber(mode) and tonumber(mode) ~= 0 then
            Geometry.rotation_source = "getTouchRotation"
            return tonumber(mode)
        end
    end

    -- 2. the screen rotation, which is what the framebuffer itself follows
    if type(screen.getRotationMode) == "function" then
        local ok, mode = pcall(screen.getRotationMode, screen)
        if ok and tonumber(mode) and tonumber(mode) ~= 0 then
            Geometry.rotation_source = "getRotationMode (input rotation unset!)"
            return tonumber(mode)
        end
    end

    Geometry.rotation_source = "upright"
    return 0
end

-- Both values, for the diagnostics: when they disagree, the reader's input
-- rotation and the framebuffer orientation disagree, and that is worth seeing.
function Geometry.rotationReport()
    local screen = getScreen()
    local touch, screen_mode = "n/a", "n/a"
    if screen then
        if type(screen.getTouchRotation) == "function" then
            local ok, v = pcall(screen.getTouchRotation, screen)
            if ok then touch = tostring(v) end
        end
        if type(screen.getRotationMode) == "function" then
            local ok, v = pcall(screen.getRotationMode, screen)
            if ok then screen_mode = tostring(v) end
        end
    end
    return string.format("touch=%s, screen=%s, source=%s",
        touch, screen_mode, Geometry.rotation_source)
end

-- The rotation enum values are read off the Screen class when it exposes them,
-- and fall back to KOReader's documented mode order otherwise. Getting this
-- wrong is not subtle: a mis-mapped rotation mirrors the ink.
function Geometry.rotationKind()
    local mode = Geometry.rotation()
    if mode == 0 then return "none" end

    local screen = getScreen()
    if screen then
        if mode == screen.DEVICE_ROTATED_CLOCKWISE then return "cw" end
        if mode == screen.DEVICE_ROTATED_UPSIDE_DOWN then return "ud" end
        if mode == screen.DEVICE_ROTATED_COUNTER_CLOCKWISE then return "ccw" end
    end

    -- Constants unavailable: 1 = clockwise, 2 = upside down, 3 = counter
    -- clockwise is KOReader's rotation mode ordering.
    if mode == 1 then return "cw" end
    if mode == 2 then return "ud" end
    if mode == 3 then return "ccw" end
    return "none"
end

-- Portrait-oriented panel size: with a 90/270 degree rotation the framebuffer
-- reports swapped dimensions.
function Geometry.nativeDims()
    local w, h = Geometry.dims()
    local kind = Geometry.rotationKind()
    if kind == "cw" or kind == "ccw" then return h, w end
    return w, h
end

-- native (portrait panel) -> current screen.
function Geometry.nativeToScreen(x, y)
    local kind = Geometry.rotationKind()
    if kind == "none" then return x, y end

    local w, h = Geometry.dims()
    if kind == "cw" then
        return w - y, x
    elseif kind == "ud" then
        return w - x, h - y
    elseif kind == "ccw" then
        return y, h - x
    end
    return x, y
end

-- Inverse of the above. Not used while drawing; kept because normalising a
-- screen-space value back to native is exactly what is needed when diagnosing
-- a misplaced stroke.
function Geometry.screenToNative(x, y)
    local kind = Geometry.rotationKind()
    if kind == "none" then return x, y end

    local w, h = Geometry.dims()
    if kind == "cw" then
        return y, w - x
    elseif kind == "ud" then
        return w - x, h - y
    elseif kind == "ccw" then
        return h - y, x
    end
    return x, y
end

-- Returns an (x, y) -> (x, y) function for the current rotation, or nil when
-- no transform is needed. Handed to the rasteriser so stored native strokes
-- can be painted onto the rotated framebuffer.
function Geometry.transform()
    if Geometry.rotationKind() == "none" then return nil end
    return Geometry.nativeToScreen
end

return Geometry
