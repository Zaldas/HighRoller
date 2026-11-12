-- cardRail.lua
-- Quick Draw card counts: one outlined card per element on an L bracket with its own anchor, or a
-- bare row attached under the roll list.

require('common')
local gdi   = require('libs/gdifonts/include')
local draw  = require('ui/draw')
local Drag  = require('ui/drag')
local cards = require('cards')

local CardRail = {}

-- Playing-card proportions and corner marks
local CARD_W, CARD_H = 22, 32
local CARD_GAP   = 6
local CARD_ROUND = 3      -- gdifonts corner diameter
local MARK_W, MARK_H = 4, 2
local MARK_IN    = 4      -- card edge to corner mark
local CARD_LINE  = 2
local COUNT_SIZE = 12
local PAD_LEFT   = 5      -- bracket to first card
local PAD_BOTTOM = 5      -- last card to bracket
local BRK_W      = 1
local BRK_REACH  = 0.65   -- each arm ends this far into the last card along it
local BRK_FADE_V = 0.45   -- share of the upright faded toward its top
local BRK_FADE_H = 0.28   -- share of the base faded toward its end
local LOW        = 10
local EMPTY_FADE = 0.42

local COLOR_BRACKET = '#B4C4DE8C'   -- 55% alpha
local COLOR_COUNT   = '#FFFFFF'
local COLOR_LOW     = '#FFC46A'
local COLOR_EMPTY   = '#FF6A5A'

local Z_CARD, Z_COUNT = 2, 4

local engine, tex = nil, nil
local slots   = {}       -- per element: { card, marks, count, state }
local bracket = {}
local bounds  = { x = 0, y = 0, w = 0, h = 0 }
local hidden  = true
local drag    = Drag.new()
local tooltip = nil

local function newRect(z)
    return gdi:create_rect({ width = CARD_W, height = CARD_H, z_order = z, visible = false,
        fill_color = 0, outline_color = 0, outline_width = 0, corner_rounding = CARD_ROUND })
end

-- engine and textures are the HUD's: one sprite engine per addon.
function CardRail.init(spriteEngine, textures, cfg)
    engine, tex = spriteEngine, textures
    for i, e in ipairs(cards.ELEMENTS) do
        slots[i] = {
            e = e,
            card  = newRect(Z_CARD),
            -- Corner marks are sprites: gdifonts rects this small sometimes render empty
            markTL = draw.newSprite(spriteEngine, textures.white),
            markBR = draw.newSprite(spriteEngine, textures.white),
            count = draw.newText(cfg.labelFont, COUNT_SIZE, gdi.Alignment.Left, gdi.FontFlags.Bold, Z_COUNT),
            state = nil,
        }
    end
    tooltip = draw.newTooltip(cfg.labelFont)
    bracket.up      = draw.newSprite(engine, tex.white)
    bracket.upFade  = draw.newSprite(engine, tex.fadeUp)
    bracket.base    = draw.newSprite(engine, tex.white)
    bracket.baseEnd = draw.newSprite(engine, tex.fadeRight)
    bracket.baseStart = draw.newSprite(engine, tex.fadeLeft)
end

function CardRail.destroy()
    for _, sl in ipairs(slots) do
        gdi:destroy_object(sl.card)
        if engine then
            engine:destroySprite(sl.markTL)
            engine:destroySprite(sl.markBR)
        end
        gdi:destroy_object(sl.count)
    end
    slots = {}
    if tooltip then gdi:destroy_object(tooltip) end
    tooltip = nil
    if engine then
        for _, spr in pairs(bracket) do engine:destroySprite(spr) end
    end
    bracket, engine = {}, nil
end

function CardRail.setFonts(cfg)
    for _, sl in ipairs(slots) do sl.count:set_font_family(cfg.labelFont) end
    if tooltip then tooltip:set_font_family(cfg.labelFont) end
end

function CardRail.hide()
    if hidden then return end
    for _, sl in ipairs(slots) do
        sl.card:set_visible(false)
        sl.markTL.visible, sl.markBR.visible = false, false
        sl.count:set_visible(false)
    end
    for _, spr in pairs(bracket) do spr.visible = false end
    if tooltip then tooltip:set_visible(false) end
    bounds.w, bounds.h = 0, 0
    hidden = true
end

-- Colours change only with a card's state, so the rect textures rebuild only then.
local function applyState(sl, state, s)
    local key = string.format('%s|%.3f', state, s)
    if sl.state == key then return end
    sl.state = key
    local e = sl.e
    local fade = state == 'empty' and EMPTY_FADE or 1
    local w, h = math.floor(CARD_W * s + 0.5), math.floor(CARD_H * s + 0.5)
    sl.card:set_width(w)
    sl.card:set_height(h)
    sl.card:set_corner_rounding(math.floor(CARD_ROUND * s + 0.5))
    sl.card:set_outline_width(math.max(1, math.floor(CARD_LINE * s + 0.5)))
    sl.card:set_outline_color(draw.gdiColor(e.color, fade))
    sl.card:set_fill_color(draw.gdiColor(e.color, e.fill * fade))
    sl.markColor = draw.argb(e.color, fade)
end

-- Cards to draw: { sl, n } in element order.
local function shownCards(counts, cc)
    local shown = {}
    for _, sl in ipairs(slots) do
        local n = counts[sl.e.key] or 0
        if n > 0 or not cc.hideEmpty then table.insert(shown, { sl = sl, n = n }) end
    end
    return shown
end

-- Span of k cards in a row (vertical = false) or column, in screen px.
local function span(k, s, vertical)
    local run = (k * (vertical and CARD_H or CARD_W) + (k - 1) * CARD_GAP) * s
    if vertical then return CARD_W * s, run end
    return run, CARD_H * s
end

-- Size ({ w, h, card }) of the card row attached to the roll list, card being one card's width;
-- nil when no card shows.
function CardRail.measure(counts, cfg)
    local k = #shownCards(counts, cfg.cards)
    if k == 0 then return nil end
    local s = draw.uiScale(cfg)
    local w, h = span(k, s, false)
    return { w = w, h = h, card = CARD_W * s }
end

-- counts: element key -> count. Draws the rail with its top-left at cfg.cards.anchor, or, given
-- `at` ({ x, y }), as a bare row there: attached to the roll list, which places and drags it.
function CardRail.update(counts, cfg, at)
    if engine == nil then return end
    hidden = false
    local cc = cfg.cards
    local s  = draw.uiScale(cfg)
    local vertical = at == nil and cc.orientation == 'v'
    local outline = draw.outlineWidth(s)
    -- Rounded to nearest, as draw.placeRect places the mast's crossbar
    local x0, y0
    if at then
        x0, y0 = math.floor(at.x + 0.5), math.floor(at.y + 0.5)
    else
        x0, y0 = math.floor(cc.anchor.x), math.floor(cc.anchor.y)
    end

    local hits = {}
    local shown = shownCards(counts, cc)
    local isShown = {}
    for _, it in ipairs(shown) do isShown[it.sl] = true end
    for _, sl in ipairs(slots) do
        if not isShown[sl] then
            sl.card:set_visible(false)
            sl.markTL.visible, sl.markBR.visible = false, false
            sl.count:set_visible(false)
        end
    end

    local cw, ch, gap = CARD_W * s, CARD_H * s, CARD_GAP * s
    local k = #shown
    if k == 0 then
        for _, spr in pairs(bracket) do spr.visible = false end
        tooltip:set_visible(false)
        bounds.w, bounds.h = 0, 0
        return
    end
    local spanW, spanH = span(k, s, vertical)
    local frameRight = cc.side == 'right'
    local frameless = at ~= nil or cc.side == 'none'
    local cardsX = (frameless or frameRight) and x0 or (x0 + (BRK_W + PAD_LEFT) * s)
    local bw = math.max(1, math.floor(BRK_W * s + 0.5))
    -- Align bottom: a vertical rail's anchor is its bottom-left and the column grows upward
    local railH = frameless and spanH or (spanH + PAD_BOTTOM * s + bw)
    local top = (vertical and cfg.stack == 'up') and (y0 - railH) or y0
    local cardsY = top

    for i, it in ipairs(shown) do
        local sl, n = it.sl, it.n
        local state = n == 0 and 'empty' or (n < LOW and 'low' or 'normal')
        applyState(sl, state, s)
        local cx = vertical and cardsX or (cardsX + (i - 1) * (cw + gap))
        local cy = vertical and (cardsY + (i - 1) * (ch + gap)) or cardsY
        cx, cy = math.floor(cx + 0.5), math.floor(cy + 0.5)
        local w, h = math.floor(cw + 0.5), math.floor(ch + 0.5)
        sl.card:set_position_x(cx)
        sl.card:set_position_y(cy)
        sl.card:set_visible(true)

        local inset = math.floor(MARK_IN * s + 0.5)
        local mw, mh = math.max(1, math.floor(MARK_W * s + 0.5)), math.max(1, math.floor(MARK_H * s + 0.5))
        draw.placeRect(sl.markTL, cx + inset, cy + inset, mw, mh, sl.markColor)
        draw.placeRect(sl.markBR, cx + w - inset - mw, cy + h - inset - mh, mw, mh, sl.markColor)

        local color = state == 'empty' and COLOR_EMPTY or (state == 'low' and COLOR_LOW or COLOR_COUNT)
        -- Centred from the measured width; gdifonts centring floors odd half-widths a pixel left
        draw.setText(sl.count, tostring(n), cx, 0, COUNT_SIZE * s, color, outline)
        local tw, th = draw.textSize(sl.count)
        sl.count:set_position_x(math.floor(cx + (w - tw) / 2 + 0.5))
        sl.count:set_position_y(math.floor(cy + (h - th) / 2 + 0.5))
        table.insert(hits, { x = cx, y = cy, w = w, h = h, e = sl.e })
        sl.count:set_opacity(state == 'empty' and EMPTY_FADE or 1)
    end

    -- Card name and its Quick Draw effect under the cursor
    local mouse = draw.hoverMouse()
    local hit = cc.tooltips and draw.hitAt(hits, mouse) or nil
    draw.showTooltip(tooltip, hit and string.format('%s Card - %s', hit.e.name, hit.e.shot), mouse, s, outline)

    if frameless then
        for _, spr in pairs(bracket) do spr.visible = false end
        -- Attached, the roll list drags the row
        bounds.x, bounds.y = x0, top
        bounds.w, bounds.h = at and 0 or spanW, at and 0 or spanH
        return
    end

    -- L bracket: upright on the frame side fading toward its top, base along the bottom fading toward
    -- its far end. Each arm stops part way into the last card along it: the top card, and the far card.
    local padX = PAD_LEFT * s + bw
    local upX = frameRight and (cardsX + spanW + PAD_LEFT * s) or x0
    local baseY = cardsY + spanH + PAD_BOTTOM * s
    local upTop = cardsY + ch * (1 - BRK_REACH)
    local upH = baseY - upTop
    local baseW = padX + math.max(0, spanW - cw) + cw * BRK_REACH
    local color = draw.argb(COLOR_BRACKET)
    local upFade, baseFade = upH * BRK_FADE_V, baseW * BRK_FADE_H
    draw.placeRect(bracket.upFade, upX, upTop, bw, upFade, color)
    draw.placeRect(bracket.up, upX, upTop + upFade, bw, upH - upFade, color)
    if frameRight then
        local baseX = upX + bw - baseW
        draw.placeRect(bracket.baseStart, baseX, baseY, baseFade, bw, color)
        draw.placeRect(bracket.base, baseX + baseFade, baseY, baseW - baseFade, bw, color)
        bracket.baseEnd.visible = false
    else
        draw.placeRect(bracket.base, x0, baseY, baseW - baseFade, bw, color)
        draw.placeRect(bracket.baseEnd, x0 + baseW - baseFade, baseY, baseFade, bw, color)
        bracket.baseStart.visible = false
    end

    bounds.x, bounds.y = x0, top
    bounds.w = math.max(baseW, padX + spanW)
    bounds.h = railH
end

-- Returns true when a drag ended and the anchor should be saved.
function CardRail.handleMouse(e, cfg)
    return drag:handle(e, cfg.cards.anchor, bounds, cfg.lockPosition)
end

return CardRail
