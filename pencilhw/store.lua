--[[--
Stroke persistence for pencil-handwriting.

Strokes are grouped by page and serialized into the document's sidecar
directory (the same directory KOReader creates for reading position and
highlights), using a plain Lua table:

    return {
      version = 1,
      pages = {
        [12] = {
          { tool="pen", width=3, color="black", points={x1,y1,x2,y2,...} },
          { tool="eraser", points={...} },
        },
      },
    }
--]]

local logger = require("logger")
local util = require("util")
local Config = require("pencilhw/config")

local StrokeStore = {}
StrokeStore.__index = StrokeStore

function StrokeStore:new(sidecar_dir)
    return setmetatable({
        sidecar_dir = sidecar_dir,
        pages = {},
    }, self)
end

function StrokeStore:sidecarPath()
    if not self.sidecar_dir then return nil end
    return self.sidecar_dir .. "/" .. Config.SIDECAR_FILENAME
end

function StrokeStore:load()
    local path = self:sidecarPath()
    if not path then return false end

    local f = io.open(path, "r")
    if not f then return false end
    f:close()

    local ok, data = pcall(dofile, path)
    if not ok or type(data) ~= "table" then
        logger.warn("PencilHW: failed to load strokes from", path)
        return false
    end

    if data.version ~= Config.STROKE_FORMAT_VERSION then
        logger.warn("PencilHW: unsupported stroke format version, ignoring")
        return false
    end

    self.pages = data.pages or {}
    logger.info("PencilHW: loaded", self:strokeCount(), "strokes from", path)
    return true
end

function StrokeStore:save()
    local path = self:sidecarPath()
    if not path then return false end

    if self.sidecar_dir then
        util.makePath(self.sidecar_dir)
    end

    local f = io.open(path, "w")
    if not f then
        logger.warn("PencilHW: cannot write", path)
        return false
    end

    f:write("-- pencil-handwriting.koplugin stroke data\n")
    f:write("return {\n")
    f:write("  version = ", Config.STROKE_FORMAT_VERSION, ",\n")
    f:write("  pages = {\n")

    for page, strokes in pairs(self.pages) do
        f:write("    [", tostring(page), "] = {\n")
        for _, s in ipairs(strokes) do
            f:write("      { tool=", string.format("%q", s.tool or "pen"),
                    ", width=", tostring(s.width or Config.DEFAULT_WIDTH),
                    ", color=", string.format("%q", s.color or Config.DEFAULT_COLOR),
                    ", points={", table.concat(s.points, ","), "} },\n")
        end
        f:write("    },\n")
    end

    f:write("  },\n")
    f:write("}\n")
    f:close()

    logger.dbg("PencilHW: saved", self:strokeCount(), "strokes to", path)
    return true
end

-- Note: writing the sidecar on every single stroke would rewrite the whole
-- file once per stroke (quadratic I/O) for no benefit, because the file is
-- flushed shortly after the pen lifts and on every page change.
function StrokeStore:addStroke(page, stroke)
    self.pages[page] = self.pages[page] or {}
    table.insert(self.pages[page], stroke)
end

function StrokeStore:addEraseStroke(page, x, y)
    self.pages[page] = self.pages[page] or {}
    table.insert(self.pages[page], {
        tool = "eraser",
        width = 0,
        color = Config.DEFAULT_COLOR,
        points = { x, y },
    })
end

function StrokeStore:pageStrokes(page)
    return self.pages[page] or {}
end

function StrokeStore:strokeCount()
    local n = 0
    for _, strokes in pairs(self.pages) do
        n = n + #strokes
    end
    return n
end

function StrokeStore:removePageStrokes(page)
    local n = #(self.pages[page] or {})
    if n > 0 then
        self.pages[page] = nil
        self:save()
    end
    return n
end

function StrokeStore:removeAll()
    local n = self:strokeCount()
    self.pages = {}
    self:save()
    return n
end

return StrokeStore
