local _ = require("gettext")
return {
    fullname = _("Pencil handwriting"),
    version = "0.6.0",
    description = _("Low-latency stylus handwriting for e-ink readers with a Wacom/EMR digitizer (Kindle Scribe). Uses KOReader's stylus pipeline when available and can fall back to reading the digitizer node directly."),
}
