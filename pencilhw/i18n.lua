--[[--
Plugin-local translations.

KOReader only auto-loads `l10n/<lang>/koreader.mo`, so a plugin that ships on
its own cannot contribute strings to it -- and building a .mo would need gettext
tooling on the machine that packages the plugin. A dictionary keyed by the
English source text does the same job with no build step:

    local _ = require("pencilhw/i18n").gettext

Anything not in the dictionary falls through to the English source text, so an
untranslated string is never an error -- and a language with no dictionary at
all (every language but Chinese here) behaves exactly as before.

Objects and keyboard-visible text such as "Pencil handwriting" are deliberately
left untranslated: they are the plugin's name, not menu prose.
--]]

local I18n = {}

-- Simplified Chinese, keyed by the English source string. Full-width colons
-- and punctuation, matching the rest of the Chinese UI in KOReader.
local ZH = {
    [" (KOReader stylus API)"] = "（KOReader 手写笔 API）",
    [" (evdev)"] = "（evdev）",
    ["%1 - %2 (current: %3)"] = "%1 - %2（当前：%3）",
    ["Active source: %1"] = "当前输入源：%1",
    ["Auto"] = "自动",
    ["Auto (recommended)"] = "自动（推荐）",
    ["Block touch while drawing"] = "书写时屏蔽触摸",
    ["Build %1"] = "版本 %1",
    ["Cancel"] = "取消",
    ["Capture the digitizer node exclusively?\n\nThis only applies to the evdev input path. If the pen shares one node with the touch screen, finger input stops working until this is switched off again."] = "要独占数字笔设备节点吗？\n\n此设置仅对 evdev 输入方式生效。如果数字笔与触屏共用同一个节点，开启后手指输入会失效，直到再次关闭此项。",
    ["Clear"] = "清除",
    ["Clear %1 strokes on this page?"] = "要清除本页的 %1 条笔迹吗？",
    ["Clear all"] = "全部清除",
    ["Clear all %1 strokes in this document?"] = "要清除本文档的全部 %1 条笔迹吗？",
    ["Clear all strokes in document"] = "清除本文档所有笔迹",
    ["Clear strokes on this page"] = "清除本页笔迹",
    ["Color: %1"] = "颜色：%1",
    ["Custom width"] = "自定义笔宽",
    ["Custom..."] = "自定义…",
    ["Diagnostics failed:"] = "诊断失败：",
    ["Drawing: %1"] = "书写：%1",
    ["Enable"] = "启用",
    ["Enable drawing"] = "启用手写",
    ["Exclusive pen capture (evdev only)"] = "独占笔输入（仅 evdev）",
    ["Exclusive pen capture: off"] = "独占笔输入：已关闭",
    ["Exclusive pen capture: on"] = "独占笔输入：已开启",
    ["Full refresh on every page turn: OFF."] = "每次翻页均整屏刷新：已关闭。",
    ["Full refresh on every page turn: ON.\nIf the ink stops following you now, the panel was not being cleared; if it still follows you, the page identity is wrong."] = "每次翻页均整屏刷新：已开启。\n如果笔迹不再跟着翻页出现，说明是面板没有刷新干净；如果仍然跟着出现，说明页标识有误。",
    ["Full refresh on page turn (test)"] = "翻页整屏刷新（测试）",
    ["Input devices on this reader:"] = "本机输入设备：",
    ["Input diagnostics"] = "输入诊断",
    ["Input mode: %1"] = "输入方式：%1",
    ["Input source: %1"] = "输入源：%1",
    ["Invalid width (%1 - %2)"] = "笔宽无效（%1 - %2）",
    ["KOReader stylus API"] = "KOReader 手写笔 API",
    ["KOReader stylus API: %1"] = "KOReader 手写笔 API：%1",
    ["Key log: %1"] = "页键日志：%1",
    ["Last error: %1"] = "最近错误：%1",
    ["Last event: %1"] = "最近事件：%1",
    ["Last page exit: %1"] = "最近离开页面：%1",
    ["Last slot: %1"] = "最近槽位：%1",
    ["Last stroke: %1"] = "最近笔迹：%1",
    ["MISSING"] = "缺失",
    ["No strokes on this page."] = "本页没有笔迹。",
    ["No strokes to clear."] = "没有可清除的笔迹。",
    ["OK"] = "确定",
    ["Page accessors: %1"] = "页号来源：%1",
    ["Page changes: %1"] = "翻页记录：%1",
    ["Page identity: %1"] = "页标识：%1",
    ["Page key: %1  (%2)"] = "页键：%1（%2）",
    ["Pen color"] = "笔迹颜色",
    ["Pen width"] = "笔迹宽度",
    -- The plugin's own name stays as it is, in every language.
    ["Pencil handwriting"] = "Pencil handwriting",
    ["Low-latency stylus handwriting for e-ink readers with a Wacom/EMR digitizer (Kindle Scribe). Uses KOReader's stylus pipeline when available and can fall back to reading the digitizer node directly."] = "为带 Wacom/EMR 数字笔的墨水屏设备（如 Kindle Scribe）提供低延迟手写批注。优先使用 KOReader 的手写笔管线，若该版本不支持，则改为直接读取数字笔设备节点。",
    ["Pencil handwriting failed to load:\n"] = "Pencil handwriting 加载失败：\n",
    ["Pencil handwriting: %1"] = "Pencil handwriting：%1",
    ["Pencil handwriting: no digitizer node found.\nOpen \"Input diagnostics\" in this menu to see the input devices of this reader."] = "Pencil handwriting：未找到数字笔设备节点。\n请打开本菜单中的“输入诊断”查看本机的输入设备。",
    ["Pencil handwriting: this KOReader build has no stylus API.\nSwitch \"Input source\" to \"evdev (direct)\" instead."] = "Pencil handwriting：此 KOReader 版本没有手写笔 API。\n请把“输入源”改为“evdev（直读）”。",
    ["Pencil handwriting: toggle"] = "Pencil handwriting：开 / 关",
    ["Redraw strokes"] = "重绘笔迹",
    ["Repaint hook: %1"] = "重绘钩子：%1",
    ["Rotation sources: %1"] = "旋转来源：%1",
    ["Stored notes stay visible either way."] = "无论哪种情况，已保存的笔迹都会显示。",
    ["Strokes repainted from stored data."] = "已按已保存的数据重绘笔迹。",
    ["Touches are now ignored while drawing, so a resting hand cannot turn pages. The top strip still opens the menu."] = "书写时将忽略触摸，手掌搁在屏幕上不会翻页。顶部条带仍可打开菜单。",
    ["Touches work normally again while drawing."] = "书写时触摸已恢复正常。",
    ["Width: %1"] = "笔宽：%1",
    ["available"] = "可用",
    ["evdev (direct)"] = "evdev（直读）",
    ["evdev node: %1 (%2)"] = "evdev 节点：%1（%2）",
    ["evdev node: not opened"] = "evdev 节点：未打开",
    ["installed"] = "已安装",
    ["missing"] = "缺失",
    ["none"] = "无",
    ["off"] = "关",
    ["on"] = "开",
    ["registered (idle)"] = "已注册（空闲）",
    ["Black"] = "黑色",
    ["Gray 25%"] = "灰 25%",
    ["Gray 50%"] = "灰 50%",
    ["Gray 75%"] = "灰 75%",
    ["White"] = "白色",
}

-- Which reader language is in force, as a lowercase string like "zh_cn", or nil
-- when it cannot be determined.
local function currentLanguage()
    -- The reader's own setting is the authoritative one. Read straight off the
    -- global rather than through a pcall wrapper: a plain global read is nil
    -- when unset, so there is nothing to protect against.
    local settings = G_reader_settings
    if type(settings) == "table" and type(settings.readSetting) == "function" then
        local ok, value = pcall(settings.readSetting, settings, "language")
        if ok and type(value) == "string" and value ~= "" then
            return value:lower()
        end
    end

    -- ...and the value gettext itself derived from the environment is the
    -- fallback, in case the setting is not reachable from a plugin.
    local ok2, GetText = pcall(require, "gettext")
    if ok2 and type(GetText) == "table" and type(GetText.current_lang) == "string"
        and GetText.current_lang ~= "" then
        return GetText.current_lang:lower()
    end

    return nil
end

-- True when the UI language wants the Chinese dictionary. Matched by prefix so
-- that zh, zh_CN, zh_CN.UTF-8 and zh_Hans all work.
local function isChinese(lang)
    return type(lang) == "string" and lang:match("^zh") ~= nil
end

-- The function used as `_`. Missing entries return the msgid untouched.
function I18n.gettext(msgid)
    if type(msgid) ~= "string" or msgid == "" then return msgid end

    local lang = currentLanguage()
    if not isChinese(lang) then return msgid end

    return ZH[msgid] or msgid
end

-- For the diagnostics: one line saying which language was seen and how much of
-- the dictionary is in play, so "the menu is still English" has a cause.
function I18n.describe()
    local lang = currentLanguage() or "unknown"
    local n = 0
    for _ in pairs(ZH) do n = n + 1 end
    return string.format("%s (%d strings%s)", lang, n,
        isChinese(lang) and ", Chinese active" or ", English fallback")
end

return I18n
