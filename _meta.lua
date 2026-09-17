local _ = require("gettext")

-- Plugin-local translations, layered over gettext exactly as main.lua does: the
-- plugin manager shows this description, so it should follow the UI language
-- too. pcall'd, because a missing dictionary must never cost the plugin its
-- metadata.
do
    local ok, i18n = pcall(require, "pencilhw/i18n")
    if ok and type(i18n) == "table" and type(i18n.gettext) == "function" then
        _ = i18n.gettext
    end
end

-- The version lives in pencilhw/config.lua so that main.lua and this file can
-- never disagree; the diagnostic build string is read from there too.
local ok, Config = pcall(require, "pencilhw/config")

return {
    fullname = _("Pencil handwriting"),
    version = (ok and Config and Config.VERSION) or "0.9.9",
    description = _("Low-latency stylus handwriting for e-ink readers with a Wacom/EMR digitizer (Kindle Scribe). Uses KOReader's stylus pipeline when available and can fall back to reading the digitizer node directly."),
}
