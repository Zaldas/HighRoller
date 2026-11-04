-- row.lua
-- One roll: big numeral, name line (Double-Up tag, lucky/unlucky, caster), effect + timer, time-left underline.

require('common')
local gdi      = require('libs/gdifonts/include')
local draw     = require('ui/draw')
local rollData = require('rollData')

local Row = {}
Row.__index = Row

Row.WIDTH  = 206
Row.HEIGHT = 38

local BIG_W     = 58
local SIDE_X    = 65
local NAME_Y    = 2
local FX_Y      = 18
local LINE_Y    = 35
local BIG_SIZE  = 32
local RECV_BIG  = 22
local RECV_FADE = 0.82
local DU_EXPIRING = 10   -- seconds left in the Double-Up window when its tag starts pulsing
-- Vertical nudges for the default font (Arial); the offset settings add to these
local NUMERAL_NUDGE = -2
local LABEL_NUDGE   = 5

local COLOR_LUCKY   = '#7BE08A'
local COLOR_UNLUCKY = '#EE5A4E'
local COLOR_BUST    = '#FF5A4A'
local COLOR_BUST_OUTLINE = '#4A0806'
local COLOR_OUTLINE = '#000000'
local COLOR_NEUTRAL = '#C9D2E3'   -- rolls without a definition
local COLOR_FROM    = '#A9B8D4'
local COLOR_FX      = '#E8ECF4'
local COLOR_TIMER   = '#B9C4D8'
local COLOR_EXPIRE  = '#FF7A6A'
local COLOR_LINE    = '#FFFFFF1F'

function Row.new(engine, tex, cfg)
    local r = setmetatable({}, Row)
    local nf, lf = cfg.numeralFont, cfg.labelFont
    local bold = gdi.FontFlags.Bold
    r.big      = draw.newText(nf, BIG_SIZE, gdi.Alignment.Right, bold)
    r.name     = draw.newText(lf, 13, gdi.Alignment.Left, bold)
    r.lucky    = draw.newText(nf, 11, gdi.Alignment.Left, bold)
    r.unlucky  = draw.newText(nf, 11, gdi.Alignment.Left, bold)
    r.from     = draw.newText(lf, 11, gdi.Alignment.Left, gdi.FontFlags.Italic)
    r.effect   = draw.newText(lf, 12, gdi.Alignment.Left, gdi.FontFlags.None)
    r.timer    = draw.newText(lf, 12, gdi.Alignment.Right, gdi.FontFlags.None)
    r.numeralTexts = { r.big, r.lucky, r.unlucky }
    r.labelTexts   = { r.name, r.from, r.effect, r.timer }
    r.texts = { r.big, r.lucky, r.unlucky, r.name, r.from, r.effect, r.timer }

    r.duTag    = draw.newSprite(engine, tex.doubleUpTag)
    r.lineBg   = draw.newSprite(engine, tex.white)
    r.lineFill = draw.newSprite(engine, tex.white)
    r.sprites = { r.duTag, r.lineBg, r.lineFill }
    r.hidden = true
    return r
end

function Row:setFonts(cfg)
    for _, t in ipairs(self.labelTexts) do t:set_font_family(cfg.labelFont) end
    for _, t in ipairs(self.numeralTexts) do t:set_font_family(cfg.numeralFont) end
end

function Row:hide()
    if self.hidden then return end
    for _, t in ipairs(self.texts) do t:set_visible(false) end
    for _, s in ipairs(self.sprites) do s.visible = false end
    self.hidden = true
end

function Row:destroy(engine)
    for _, t in ipairs(self.texts) do gdi:destroy_object(t) end
    for _, s in ipairs(self.sprites) do engine:destroySprite(s) end
end

-- Draws the row with its top-left at (x, y). Returns the left edge of what was drawn; a wide
-- numeral overflows its right-aligned column.
function Row:render(v, x, y, s, cfg, now)
    self.hidden = false
    local def       = v.def
    local value     = v.value
    local isLucky   = def ~= nil and value == def.lucky and not v.bust
    local isUnlucky = def ~= nil and value == def.unlucky and not v.bust
    local expiring  = v.remaining <= cfg.expiringThreshold
    local pulse     = 0.35 + 0.65 * (0.5 + 0.5 * math.cos(now * math.pi * 2))
    local blink     = expiring and pulse or 1
    local fade      = v.mine and 1 or RECV_FADE
    local outline   = math.max(1, math.floor(2 * s + 0.5))
    local rollColor = v.bust and COLOR_BUST or (def and rollData.colorFor(def, cfg) or COLOR_NEUTRAL)
    local numOff    = (cfg.numeralOffset + NUMERAL_NUDGE) * s
    local labelOff  = (cfg.labelOffset + LABEL_NUDGE) * s
    local sideX     = x + SIDE_X * s

    -- Big numeral, right-aligned in its column and centred on the row
    local grad  = cfg.gradient
    local state = v.bust and 'bust' or (isLucky and 'lucky' or (isUnlucky and 'unlucky' or 'normal'))
    local pair  = grad.colors[state]
    local size  = (v.mine and BIG_SIZE or RECV_BIG) * s
    self.big:set_font_flags(v.bust and bit.bor(gdi.FontFlags.Bold, gdi.FontFlags.Strikeout) or gdi.FontFlags.Bold)
    self.big:set_gradient_style(grad.style)
    self.big:set_gradient_color(draw.gdiColor(pair.to))
    draw.setText(self.big, rollData.numeral(v.bust and 12 or value, cfg.roman), x + BIG_W * s, 0, size, pair.from, outline)
    local bw, bh = draw.textSize(self.big)
    self.big:set_position_y(math.floor(y + (Row.HEIGHT / 2 + 2) * s - bh / 2 + numOff))
    self.big:set_opacity(blink * fade)

    -- Name line
    local label = def and def.short or 'Bust'
    draw.setText(self.name, label, sideX, y + NAME_Y * s + labelOff, 13 * s,
        def and rollData.colorFor(def, cfg) or COLOR_NEUTRAL, outline)
    self.name:set_opacity(blink * fade)
    local nw, nh = draw.textSize(self.name)
    local cursor = sideX + nw
    local nameMid = y + NAME_Y * s + labelOff + nh / 2

    if v.du and def then
        cursor = cursor + 6 * s
        draw.placeIcon(self.duTag, cursor, nameMid - self.duTag.nativeH * s / 2, s, draw.argb(cfg.readyColor,
            (v.duRemaining and v.duRemaining <= DU_EXPIRING) and pulse or 1))
        cursor = cursor + self.duTag.nativeW * s + 6 * s
        draw.setText(self.lucky, rollData.numeral(def.lucky, cfg.roman), cursor, 0, 11 * s, COLOR_LUCKY, outline)
        local lw, lh = draw.textSize(self.lucky)
        self.lucky:set_position_y(math.floor(nameMid - lh / 2))
        cursor = cursor + lw + 4 * s
        draw.setText(self.unlucky, rollData.numeral(def.unlucky, cfg.roman), cursor, 0, 11 * s, COLOR_UNLUCKY, outline)
        local uw, uh = draw.textSize(self.unlucky)
        self.unlucky:set_position_y(math.floor(nameMid - uh / 2))
        cursor = cursor + uw
    else
        self.duTag.visible = false
        self.lucky:set_visible(false)
        self.unlucky:set_visible(false)
    end

    if not v.mine and v.casterName ~= '' then
        draw.setText(self.from, v.casterName, cursor + 4 * s, 0, 11 * s, COLOR_FROM, outline)
        local _, fh = draw.textSize(self.from)
        self.from:set_position_y(math.floor(nameMid - fh / 2))
        self.from:set_opacity(fade)
    else
        self.from:set_visible(false)
    end

    -- Effect and timer
    local fxY = y + FX_Y * s + labelOff
    if v.bust then
        self.effect:set_font_flags(gdi.FontFlags.Bold)
        self.effect:set_outline_color(draw.gdiColor(COLOR_BUST_OUTLINE))
        draw.setText(self.effect, 'BUST!', sideX, fxY, 12 * s, COLOR_BUST, outline)
    else
        self.effect:set_font_flags(gdi.FontFlags.None)
        self.effect:set_outline_color(draw.gdiColor(COLOR_OUTLINE))
        draw.setText(self.effect, rollData.effectText(def, value, v.level, v.plus), sideX, fxY, 12 * s, COLOR_FX, outline)
    end
    self.effect:set_opacity(fade)

    local secs = math.max(0, math.floor(v.remaining))
    self.timer:set_font_flags(expiring and gdi.FontFlags.Bold or gdi.FontFlags.None)
    draw.setText(self.timer, string.format('%d:%02d', math.floor(secs / 60), secs % 60), x + Row.WIDTH * s, fxY,
        12 * s, expiring and COLOR_EXPIRE or COLOR_TIMER, outline)
    self.timer:set_opacity(fade)

    -- Time-left underline
    local lineX, lineY, lineW = sideX, y + LINE_Y * s, (Row.WIDTH - SIDE_X) * s
    local lineH = math.max(1, math.floor(s + 0.5))
    draw.placeRect(self.lineBg, lineX, lineY, lineW, lineH, draw.argb(COLOR_LINE, fade))
    local frac = math.max(0, math.min(1, v.remaining / math.max(1, v.total)))
    draw.placeRect(self.lineFill, lineX, lineY, lineW * frac, lineH, draw.argb(rollColor, fade))
    return math.min(x, x + BIG_W * s - bw)
end

return Row
