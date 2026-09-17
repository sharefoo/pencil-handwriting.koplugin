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
        -- Save outcome, surfaced in the diagnostics readout: a silent failure
        -- here is indistinguishable from "the plugin does not persist".
        last_save_error = nil,
        saved_count = nil,
    }, self)
end

function StrokeStore:sidecarPath()
    if not self.sidecar_dir then return nil end
    return self.sidecar_dir .. "/" .. Config.SIDECAR_FILENAME
end

function StrokeStore:load()
    local path = self:sidecarPath()
    if not path then
        self.last_save_error = "no sidecar directory"
        return false
    end

    local f = io.open(path, "r")
    if not f then return false end
    f:close()

    local ok, data = pcall(dofile, path)
    if not ok or type(data) ~= "table" then
        logger.warn("PencilHW: failed to load strokes from", path)
        self.last_save_error = "unreadable sidecar"
        return false
    end

    local version = tonumber(data.version)
    if version ~= 1 and version ~= Config.STROKE_FORMAT_VERSION then
        logger.warn("PencilHW: unsupported stroke format version, ignoring")
        self.last_save_error = "unsupported stroke format version"
        return false
    end

    if version == 1 then
        -- Version 1 stored *screen* pixels, which is the very thing that made
        -- handwriting slide over to another part of the page (or to the
        -- neighbouring page) whenever the view scrolled or zoomed. They cannot
        -- be converted faithfully -- the view they were written under is not
        -- recorded -- so they are not loaded at all rather than being drawn in
        -- the wrong place. The file is left untouched until the next write.
        self.last_save_error = "version 1 file skipped (screen coordinates)"
        self.skipped_v1 = true
        logger.warn("PencilHW: sidecar is a version 1 file: its strokes are in"
            .. " screen coordinates and cannot be placed correctly; skipping"
            .. " them. Draw them again (see README).")
        return false
    end

    -- Page keys are written with tostring(), so a table that went through a
    -- different writer can come back with string keys; normalise them or every
    -- lookup by page number would silently miss.
    local pages, normalised = data.pages or {}, 0
    self.pages = {}
    for key, strokes in pairs(pages) do
        local numeric = tonumber(key)
        if numeric then
            self.pages[numeric] = strokes
            normalised = normalised + 1
        else
            self.pages[key] = strokes
        end
    end

    logger.info("PencilHW: loaded", self:strokeCount(), "strokes from", path,
        "(", normalised, "pages )")
    return true
end

-- A page key is a number for paged documents and an xpointer string for
-- reflowable ones, so it has to be quoted when it is not a number: writing a
-- bare xpointer would produce a sidecar Lua cannot parse, and every stroke in
-- the file would be lost on the next open.
local function luaKey(page)
    if type(page) == "number" then return tostring(page) end
    return string.format("%q", tostring(page))
end

-- Page coordinates are fractional (document pixels at scale 1). One decimal is
-- far below what the screen can resolve and keeps the file from doubling in
-- size, which matters because the file is written on every pen lift.
local function coord(value)
    local n = tonumber(value)
    if not n then return "0" end
    local rounded = math.floor(n * 10 + (n >= 0 and 0.5 or -0.5)) / 10
    if rounded == math.floor(rounded) then
        return string.format("%d", rounded)
    end
    return string.format("%.1f", rounded)
end

local function pointList(points)
    local out = {}
    for i = 1, #points do
        out[i] = coord(points[i])
    end
    return table.concat(out, ",")
end

function StrokeStore:save()
    local path = self:sidecarPath()
    if not path then
        self.last_save_error = "no sidecar directory"
        logger.warn("PencilHW: no sidecar directory, strokes stay in memory only")
        return false
    end

    if self.sidecar_dir then
        util.makePath(self.sidecar_dir)
    end

    local f = io.open(path, "w")
    if not f then
        self.last_save_error = "cannot write " .. path
        logger.warn("PencilHW: cannot write", path)
        return false
    end

    f:write("-- pencil-handwriting.koplugin stroke data\n")
    f:write("return {\n")
    f:write("  version = ", Config.STROKE_FORMAT_VERSION, ",\n")
    f:write("  pages = {\n")

    for page, strokes in pairs(self.pages) do
        f:write("    [", luaKey(page), "] = {\n")
        for _, s in ipairs(strokes) do
            f:write("      { tool=", string.format("%q", s.tool or "pen"),
                    ", space=", string.format("%q", s.space or "native"),
                    ", width=", tostring(s.width or Config.DEFAULT_WIDTH),
                    ", color=", string.format("%q", s.color or Config.DEFAULT_COLOR),
                    ", points={", pointList(s.points), "} },\n")
        end
        f:write("    },\n")
    end

    f:write("  },\n")
    f:write("}\n")
    f:close()

    self.saved_count = self:strokeCount()
    self.last_save_error = nil
    if self.saved_count == 0 then
        -- Writing an empty set is a destructive event worth seeing in the log:
        -- otherwise "the strokes are gone" cannot be told apart from "the
        -- strokes were never written".
        logger.info("PencilHW: wrote an EMPTY stroke set to", path)
    else
        logger.dbg("PencilHW: saved", self.saved_count, "strokes to", path)
    end
    return true
end

-- How many strokes are in each coordinate space. A file that mixes them is
-- expected right after an upgrade, not a bug (see STORE_IN_PAGE_SPACE).
function StrokeStore:spaceCounts()
    local counts = {}
    for _, strokes in pairs(self.pages) do
        for _, s in ipairs(strokes) do
            local space = s.space or "native"
            counts[space] = (counts[space] or 0) + 1
        end
    end

    local parts = {}
    for space, n in pairs(counts) do
        parts[#parts + 1] = space .. "=" .. n
    end
    table.sort(parts)
    return table.concat(parts, " ")
end

-- One-line state summary for the diagnostics dialog.
function StrokeStore:describe()
    local path = self:sidecarPath()
    if not path then
        return "sidecar: NONE (doc_settings has no sidecar dir!)"
    end
    local size = "missing"
    local f = io.open(path, "r")
    if f then
        local content = f:read("*a")
        f:close()
        size = tostring(#(content or "")) .. " bytes"
    end
    local spaces = self:spaceCounts()
    return string.format("sidecar: %s\nfile: %s, saved strokes: %s, last error: %s%s",
        path, size, tostring(self.saved_count or "-"),
        tostring(self.last_save_error or "none"),
        spaces ~= "" and ("\nstroke space: " .. spaces) or "")
end

-- Note: writing the sidecar on every single stroke would rewrite the whole
-- file once per stroke (quadratic I/O) for no benefit, because the file is
-- flushed shortly after the pen lifts and on every page change.
function StrokeStore:addStroke(page, stroke)
    if page == nil then
        -- Nothing to file it under: say so instead of raising "table index is
        -- nil" inside an input callback.
        logger.warn("PencilHW: stroke dropped, no page identity yet")
        return false
    end
    self.pages[page] = self.pages[page] or {}
    table.insert(self.pages[page], stroke)
    return true
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

-- A nil page key would raise "table index is nil" rather than simply finding
-- nothing, and it can reach here before the reader has announced its first
-- page. Returning an empty set keeps a missing identity from turning into an
-- error inside the repaint (where it would be swallowed by the pcall).
function StrokeStore:pageStrokes(page)
    if page == nil then return {} end
    return self.pages[page] or {}
end

function StrokeStore:strokeCount()
    local n = 0
    for _, strokes in pairs(self.pages) do
        n = n + #strokes
    end
    return n
end

-- Distinct page keys. A document that keeps reporting one key no matter which
-- page is on screen shows up here as 1, which is the signature of strokes
-- landing on every page.
function StrokeStore:pageCount()
    local n = 0
    for _ in pairs(self.pages) do
        n = n + 1
    end
    return n
end

function StrokeStore:removePageStrokes(page)
    if page == nil then return 0 end
    local n = #(self.pages[page] or {})
    if n > 0 then
        self.pages[page] = nil
        self:save()
        -- Logged because "the strokes are gone" has two very different causes:
        -- this, or a write that never happened. Without the line, the two look
        -- identical in a report.
        logger.info("PencilHW: cleared", n, "strokes on page", tostring(page))
    end
    return n
end

function StrokeStore:removeAll()
    local n = self:strokeCount()
    self.pages = {}
    self:save()
    logger.info("PencilHW: cleared all", n, "strokes in the document")
    return n
end

return StrokeStore
