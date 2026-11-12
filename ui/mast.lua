-- mast.lua
-- Separator beside (or under) the roll list, with the Corsair ability recast icons past it, and a
-- crossbar or second separator over the card row when the cards are attached.

require('common')
local gdi     = require('libs/gdifonts/include')
local draw    = require('ui/draw')
local recasts = require('recasts')

local Mast = {}
Mast.__index = Mast

local SLOT_W     = 3        -- width of the strip the separator is centred in
local GAP        = 14       -- list to separator
local ICON_X     = 9        -- separator to icon column
local ICON       = 20
local ICON_GAP   = 9
local SEP_MIN    = 26       -- shortest separator
local H_TOP      = 6        -- list bottom to the horizontal separator
local H_ICONS    = 8        -- horizontal separator to the icon row
local TIME_H     = 14       -- timer label under an icon (horizontal layout)

local COLOR_COOL  = '#8FA0C0'
local COOL_ALPHA  = 0.35
local COLOR_TIME  = draw.COLOR_TEXT
local COLOR_SEP   = '#C9D2E3BF'
local SEP_W       = 1
local SEP_FADE    = 0.25    -- share of the separator's length faded at each end
local COLOR_BG    = '#05080F'
local BG_PAD      = 8       -- background overhang past the outer content
local BG_PAD_H_LEFT = 5     -- left overhang in the horizontal layout
local BG_SPLIT    = 2       -- the panels meet at the separator, this far in from its strip's leading side
local BG_MARGIN   = 5       -- vertical overhang past the separator's ends (beside layout)
local CARD_PAST_SEP = 0.25  -- share of the attached row's last card past the separator (beside layout)
local COLOR_OUTLINE = draw.COLOR_OUTLINE
local OUTLINE_ALPHA = 0.55  -- per copy; overlapping copies build up along the edges
-- Black copies of each icon at these unit offsets, drawn under it
local OUTLINE_OFFSETS = { { -1, -1 }, { 0, -1 }, { 1, -1 }, { -1, 0 }, { 1, 0 }, { -1, 1 }, { 0, 1 }, { 1, 1 } }

-- Hours, then whole minutes from the threshold, else seconds
local function recastLabel(secs, threshold)
    if secs >= 3600 then return string.format('%dh', math.floor(secs / 3600)) end
    if secs >= threshold then return string.format('%dm', math.floor(secs / 60)) end
    return tostring(math.floor(secs))
end

-- Panels fading away from the separators: toward the rolls, toward the icons, (horizontal layout)
-- down behind attached cards, and the two halves behind the detached recasts.
function Mast.newBackgrounds(engine, tex)
    return { rolls = draw.newSprite(engine, tex.fadeLeft), icons = draw.newSprite(engine, tex.fadeRight),
        cards = draw.newSprite(engine, tex.fadeDown), recasts = draw.newSprite(engine, tex.fadeRight),
        recastsLead = draw.newSprite(engine, tex.fadeLeft) }
end

-- An ability whose icon texture failed to load gets no slot.
function Mast.new(engine, tex, cfg, backs)
    local m = setmetatable({}, Mast)
    m.tex = tex
    m.backs = backs
    m.readyHex = cfg.readyColor
    m.sep   = Mast.newSeparator(engine, tex)
    m.cross = Mast.newSeparator(engine, tex)
    m.sprites = { backs.rolls, backs.icons, backs.cards, backs.recasts, backs.recastsLead }
    for _, sep in ipairs({ m.sep, m.cross }) do
        for _, spr in pairs(sep) do table.insert(m.sprites, spr) end
    end
    m.tooltip = draw.newTooltip(cfg.labelFont)
    m.texts   = { m.tooltip }
    m.names   = {}
    m.icons, m.outlines, m.times = {}, {}, {}
    for _, a in ipairs(recasts.ABILITIES) do
        local key = a.key
        m.names[key] = a.name
        if tex[key] ~= nil then
            -- Sprites draw in creation order, so the outline copies come first
            m.outlines[key] = {}
            for i = 1, #OUTLINE_OFFSETS do
                m.outlines[key][i] = draw.newSprite(engine, tex[key])
                table.insert(m.sprites, m.outlines[key][i])
            end
            m.icons[key] = draw.newSprite(engine, tex[key])
            m.times[key] = draw.newText(cfg.labelFont, 11, gdi.Alignment.Left, gdi.FontFlags.Bold)
            table.insert(m.sprites, m.icons[key])
            table.insert(m.texts, m.times[key])
        end
    end
    m.hidden = true
    return m
end

function Mast:setFonts(cfg)
    for _, t in ipairs(self.texts) do t:set_font_family(cfg.labelFont) end
end

function Mast:hide()
    if self.hidden then return end
    for _, s in ipairs(self.sprites) do s.visible = false end
    for _, t in ipairs(self.texts) do t:set_visible(false) end
    self.hidden = true
end

function Mast:destroy(engine)
    for _, s in ipairs(self.sprites) do engine:destroySprite(s) end
    for _, t in ipairs(self.texts) do gdi:destroy_object(t) end
end

-- A missing texture leaves the sprite without one; placeRect then hides it.
local function setTex(spr, tex)
    if tex == nil then
        spr.texture = nil
        return
    end
    spr.texture, spr.nativeW, spr.nativeH = tex.tex, tex.w, tex.h
end

function Mast:iconColor(ready)
    if ready then return draw.argb(self.readyHex) end
    return draw.argb(COLOR_COOL, COOL_ALPHA)
end

function Mast.newSeparator(engine, tex)
    return { head = draw.newSprite(engine, tex.fadeUp), mid = draw.newSprite(engine, tex.white),
        tail = draw.newSprite(engine, tex.fadeDown) }
end

-- Thin line fading out toward both ends. sep.headFade / sep.tailFade override an end's fade length; 0 is solid.
function Mast:renderSeparator(parts, sep)
    local color = draw.argb(COLOR_SEP)
    local len = sep.horizontal and sep.w or sep.h
    local head = math.min(sep.headFade or len * SEP_FADE, len / 2)
    local tail = math.min(sep.tailFade or len * SEP_FADE, len / 2)
    if sep.horizontal then
        setTex(parts.head, self.tex.fadeLeft)
        setTex(parts.tail, self.tex.fadeRight)
        draw.placeRect(parts.head, sep.x, sep.y, head, sep.h, color)
        draw.placeRect(parts.mid, sep.x + head, sep.y, len - head - tail, sep.h, color)
        draw.placeRect(parts.tail, sep.x + len - tail, sep.y, tail, sep.h, color)
    else
        setTex(parts.head, self.tex.fadeUp)
        setTex(parts.tail, self.tex.fadeDown)
        draw.placeRect(parts.head, sep.x, sep.y, sep.w, head, color)
        draw.placeRect(parts.mid, sep.x, sep.y + head, sep.w, len - head - tail, color)
        draw.placeRect(parts.tail, sep.x, sep.y + len - tail, sep.w, tail, color)
    end
end

function Mast:hideSeparator(parts)
    for _, spr in pairs(parts) do spr.visible = false end
end

function Mast:placeBack(spr, tex, x, y, w, h, color)
    setTex(spr, tex)
    draw.placeRect(spr, x, y, w, h, color)
end

-- Places an ability icon and its hit box. Returns its timer text object and label; the caller positions it.
function Mast:placeAbility(r, x, y, ctx)
    local d = math.max(1, math.floor(ctx.s + 0.5))
    local outlineColor = draw.argb(COLOR_OUTLINE, OUTLINE_ALPHA * (r.ready and 1 or COOL_ALPHA))
    for i, off in ipairs(OUTLINE_OFFSETS) do
        draw.placeIcon(self.outlines[r.key][i], x + off[1] * d, y + off[2] * d, ctx.s, outlineColor)
    end
    draw.placeIcon(self.icons[r.key], x, y, ctx.s, self:iconColor(r.ready))
    table.insert(ctx.hits, { key = r.key, x = x, y = y, w = ICON * ctx.s, h = ICON * ctx.s })
    local label = (ctx.showTime and not r.ready) and recastLabel(r.remaining, ctx.secThresh) or ''
    return self.times[r.key], label
end

-- Icons in a row from (x, y), timers centred under them. Returns the row's height.
function Mast:placeRow(x, y, ctx)
    local s = ctx.s
    local iconH = (ctx.showTime and (ICON + TIME_H) or ICON) * s
    for _, r in ipairs(ctx.shown) do
        local t, label = self:placeAbility(r, x, y, ctx)
        t:set_font_alignment(gdi.Alignment.Center)
        draw.setText(t, label, x + ICON * s / 2, y + (ICON + 1) * s, 11 * s, COLOR_TIME, ctx.outline)
        ctx.grow(x, y, ICON * s, iconH)
        x = x + (ICON + ICON_GAP) * s
    end
    return iconH
end

-- Icons in a column at x along a separator from sepY, sepH long (from its bottom when stacking up),
-- timers right of them. Returns the column's right edge.
function Mast:placeColumn(x, sepY, sepH, ctx)
    local s = ctx.s
    local step = (ICON + ICON_GAP) * s
    local y = ctx.stackUp and (sepY + sepH - ICON * s) or sepY
    local iconsRight = x + ICON * s
    for _, r in ipairs(ctx.shown) do
        local t, label = self:placeAbility(r, x, y, ctx)
        t:set_font_alignment(gdi.Alignment.Left)
        draw.setText(t, label, x + (ICON + 4) * s, 0, 11 * s, COLOR_TIME, ctx.outline)
        local timeW, timeH = draw.textSize(t)
        t:set_position_y(math.floor(y + ICON * s / 2 - timeH / 2))
        local w = ICON * s + (ctx.showTime and (4 * s + timeW) or 0)
        ctx.grow(x, y, w, ICON * s)
        iconsRight = math.max(iconsRight, x + w)
        y = ctx.stackUp and (y - step) or (y + step)
    end
    return iconsRight
end

-- Length of n icons in a line, row or column
local function iconRun(n, s)
    return n > 0 and (n * ICON + (n - 1) * ICON_GAP) * s or 0
end

-- Separator under the rolls, ability icons in a row below it.
function Mast:renderHorizontal(list, ctx)
    local s = ctx.s
    local n = #ctx.shown
    local slotY = list.y + list.h + H_TOP * s
    -- With no rolls up the separator only spans the icon row
    local sepW = list.w
    if ctx.empty then sepW = math.max(iconRun(n, s), SEP_MIN * s) end
    -- With no icons shown, attached cards sit straight under this separator
    if ctx.cards and n == 0 then sepW = math.max(sepW, ctx.cards.w) end
    self:renderSeparator(self.sep, { x = list.x, y = slotY + (SLOT_W - SEP_W) * s / 2, w = sepW, h = SEP_W * s, horizontal = true })
    ctx.grow(list.x, slotY, sepW, SLOT_W * s)

    local y = slotY + (SLOT_W + H_ICONS) * s
    local iconH = self:placeRow(list.x, y, ctx)

    -- Attached cards: a second separator under the icons, the card row below it
    local contentBottom = n > 0 and (y + iconH) or (slotY + SLOT_W * s)
    local crossSplit = nil
    if ctx.cards then
        local cardsY = y
        if n > 0 then
            local crossY = contentBottom + H_TOP * s
            local crossW = math.max(sepW, ctx.cards.w)
            self:renderSeparator(self.cross, { x = list.x, y = crossY + (SLOT_W - SEP_W) * s / 2, w = crossW, h = SEP_W * s, horizontal = true })
            ctx.grow(list.x, crossY, crossW, SLOT_W * s)
            cardsY = crossY + (SLOT_W + H_ICONS) * s
            crossSplit = math.floor(crossY + BG_SPLIT * s + 0.5)
        end
        ctx.cardsAt = { x = list.x, y = cardsY }
        ctx.grow(list.x, cardsY, ctx.cards.w, ctx.cards.h)
        contentBottom = cardsY + ctx.cards.h
    end

    -- Backgrounds fade up behind the rolls and down behind the icons (and the cards)
    local left = list.left - BG_PAD_H_LEFT * s
    local right = list.x + math.max(ctx.empty and sepW or list.w, ctx.cards and ctx.cards.w or 0) + BG_PAD * s
    local split = math.floor(slotY + BG_SPLIT * s + 0.5)
    local backTop = list.y - BG_PAD * s
    local backBottom = contentBottom + BG_PAD * s
    self:placeBack(self.backs.rolls, self.tex.fadeUp, left, backTop, right - left, split - backTop, ctx.bgColor)
    self:placeBack(self.backs.icons, self.tex.fadeDown, left, split, right - left, (crossSplit or backBottom) - split, ctx.bgColor)
    if crossSplit then
        self:placeBack(self.backs.cards, self.tex.fadeDown, left, crossSplit, right - left, backBottom - crossSplit, ctx.bgColor)
    end
end

-- Separator beside the rolls, ability icons in a column right of it.
function Mast:renderVertical(list, ctx)
    local s = ctx.s
    local n = #ctx.shown
    local slotX = list.x + list.w + GAP * s
    -- As long as the rolls or the icon column, whichever is longer. Attached cards size the column
    -- for every icon that can show, so the card row holds still as abilities come ready.
    local rows = ctx.cards and ctx.slots or n
    local sepH = math.max(list.h, iconRun(rows, s), SEP_MIN * s)
    local sepY = ctx.stackUp and (list.y + list.h - sepH) or list.y
    local sepX = slotX + (SLOT_W - SEP_W) * s / 2

    local x = slotX + (SLOT_W + ICON_X) * s
    local iconsRight = self:placeColumn(x, sepY, sepH, ctx)

    local left = list.left - BG_PAD * s
    local backY = sepY - BG_MARGIN * s
    local backBottom = sepY + sepH + BG_MARGIN * s
    local split = math.floor(slotX + BG_SPLIT * s + 0.5)

    if ctx.cards then
        -- Attached cards: the separator runs down into a crossbar, the card row below it
        local crossY = sepY + sepH + H_TOP * s
        local lineY = crossY + (SLOT_W - SEP_W) * s / 2
        -- The row grows left from the separator, which runs through its last card a quarter of the way in
        local cardsX = sepX + SEP_W * s / 2 + ctx.cards.card * CARD_PAST_SEP - ctx.cards.w
        -- Ends at the icon column, not its timer labels, so the bar holds still while they count down
        local crossX = math.min(list.x, cardsX)
        local crossW = math.max(x + ICON * s, cardsX + ctx.cards.w) - crossX
        -- Neither crossbar fade reaches the junction
        local junction = sepX - crossX
        local fade = crossW * SEP_FADE
        self:renderSeparator(self.sep, { x = sepX, y = sepY, w = SEP_W * s, h = lineY - sepY, tailFade = 0 })
        self:renderSeparator(self.cross, { x = crossX, y = lineY, w = crossW, h = SEP_W * s, horizontal = true,
            headFade = math.min(fade, junction - SLOT_W * s), tailFade = math.min(fade, crossW - junction - SLOT_W * s) })
        ctx.grow(slotX, sepY, SLOT_W * s, crossY - sepY)
        ctx.grow(crossX, crossY, crossW, SLOT_W * s)
        ctx.cardsAt = { x = cardsX, y = crossY + (SLOT_W + H_ICONS) * s }
        ctx.grow(ctx.cardsAt.x, ctx.cardsAt.y, ctx.cards.w, ctx.cards.h)

        -- Rolls and icons panels run on down behind the cards
        left = math.min(left, cardsX - BG_PAD * s)
        local right = math.max(iconsRight, cardsX + ctx.cards.w) + BG_PAD * s
        local bottom = ctx.cardsAt.y + ctx.cards.h + BG_PAD * s
        self:placeBack(self.backs.rolls, self.tex.fadeLeft, left, backY, split - left, bottom - backY, ctx.bgColor)
        self:placeBack(self.backs.icons, self.tex.fadeRight, split, backY, right - split, bottom - backY, ctx.bgColor)
        return
    end

    self:renderSeparator(self.sep, { x = sepX, y = sepY, w = SEP_W * s, h = sepH })
    ctx.grow(slotX, sepY, SLOT_W * s, sepH)

    -- Backgrounds fade left behind the rolls and right behind the icons
    self:placeBack(self.backs.rolls, self.tex.fadeLeft, left, backY, split - left, backBottom - backY, ctx.bgColor)
    self:placeBack(self.backs.icons, self.tex.fadeRight, split, backY, iconsRight + BG_PAD * s - split, backBottom - backY, ctx.bgColor)
end

-- Detached recasts at `at` ({ x, y }): the icons alone in a row (horizontal) or column, on a panel
-- split along the icons' centre line that fades out both ways. Hidden while no icon shows.
function Mast:renderDetached(at, horizontal, ctx)
    local s = ctx.s
    local n = #ctx.shown
    local back, lead = self.backs.recasts, self.backs.recastsLead
    if n == 0 then
        back.visible, lead.visible = false, false
        return
    end
    local pad = BG_PAD * s
    if horizontal then
        local iconH = self:placeRow(at.x, at.y, ctx)
        local x, w = at.x - pad, iconRun(n, s) + 2 * pad
        local mid = math.floor(at.y + ICON * s / 2 + 0.5)
        self:placeBack(lead, self.tex.fadeUp, x, at.y - pad, w, mid - (at.y - pad), ctx.bgColor)
        self:placeBack(back, self.tex.fadeDown, x, mid, w, at.y + iconH + pad - mid, ctx.bgColor)
        return
    end
    -- Align bottom: the anchor is the column's bottom-left
    local colH = iconRun(n, s)
    local colY = ctx.stackUp and (at.y - colH) or at.y
    local iconsRight = self:placeColumn(at.x, colY, colH, ctx)
    local y, h = colY - pad, colH + 2 * pad
    local mid = math.floor(at.x + ICON * s / 2 + 0.5)
    self:placeBack(lead, self.tex.fadeLeft, at.x - pad, y, mid - (at.x - pad), h, ctx.bgColor)
    self:placeBack(back, self.tex.fadeRight, mid, y, iconsRight + pad - mid, h, ctx.bgColor)
end

-- Accumulates a bounding box; box() is { x, y, w, h }, zero-sized while nothing grew it.
local function newBox()
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    return {
        grow = function(x, y, w, h)
            minX, minY = math.min(minX, x), math.min(minY, y)
            maxX, maxY = math.max(maxX, x + w), math.max(maxY, y + h)
        end,
        box = function()
            if minX == math.huge then return { x = 0, y = 0, w = 0, h = 0 } end
            return { x = minX, y = minY, w = maxX - minX, h = maxY - minY }
        end,
    }
end

-- Lays the mast out against the roll list's box: { x, y, w, h, left }, where left is the leftmost
-- drawn numeral. `cards` ({ w, h }) reserves the attached card row, or nil. With cfg.recastsDetached the rolls keep a bare separator and the icons
-- render at cfg.recastAnchor. Returns the bounding box of the rolls' side, the card row's top-left
-- (or nil), and the detached recasts' bounding box (zero-sized when attached).
function Mast:render(recastList, list, s, cfg, cards)
    self.hidden = false
    self.readyHex = cfg.readyColor
    local enabled = cfg.showRecasts
    local dimMode = cfg.abilityDisplay ~= 'ready'

    local shown, slots = {}, 0
    for _, r in ipairs(recastList) do
        if self.icons[r.key] and enabled[r.key] ~= false then
            slots = slots + 1
            if r.ready or dimMode then table.insert(shown, r) end
        end
    end
    for key, spr in pairs(self.icons) do
        spr.visible = false
        for _, o in ipairs(self.outlines[key]) do o.visible = false end
        self.times[key]:set_visible(false)
    end
    -- Placed by the layouts only when cards are attached
    self:hideSeparator(self.cross)
    self.backs.cards.visible = false

    -- No rolls up: the box is the mast alone
    local empty = list.h == 0
    local detached = cfg.recastsDetached == true
    local rollBox = newBox()
    if not empty then rollBox.grow(list.left, list.y, list.x + list.w - list.left, list.h) end
    local ctx = {
        s         = s,
        outline   = draw.outlineWidth(s),
        stackUp   = cfg.stack == 'up',
        empty     = empty,
        showTime  = cfg.showTimers == true,
        secThresh = cfg.secondsThreshold,
        shown     = detached and {} or shown,
        slots     = detached and 0 or slots,
        cards     = cards,
        hits      = {},
        bgColor   = draw.argb(COLOR_BG, cfg.backgroundOpacity),
        grow      = rollBox.grow,
    }

    if detached and empty and cards == nil then
        -- Nothing left on the rolls' side to separate
        self:hideSeparator(self.sep)
    elseif cfg.mast == 'h' then
        self:renderHorizontal(list, ctx)
    else
        self:renderVertical(list, ctx)
    end
    if empty then
        -- No rolls: only the panels past the separator show, behind the icons and cards
        self.backs.rolls.visible = false
        if #ctx.shown == 0 and cards == nil then self.backs.icons.visible = false end
    elseif detached and cards == nil then
        -- Detached, the panel past the separator only backs attached cards
        self.backs.icons.visible = false
    end

    local detachedBox = newBox()
    if detached then
        ctx.shown, ctx.slots, ctx.grow = shown, slots, detachedBox.grow
        self:renderDetached({ x = math.floor(cfg.recastAnchor.x), y = math.floor(cfg.recastAnchor.y) },
            cfg.mast == 'h', ctx)
    else
        self.backs.recasts.visible = false
        self.backs.recastsLead.visible = false
    end

    local mouse = draw.hoverMouse()
    local hit = cfg.recastTooltips and draw.hitAt(ctx.hits, mouse) or nil
    draw.showTooltip(self.tooltip, hit and self.names[hit.key], mouse, s, ctx.outline)
    return rollBox.box(), ctx.cardsAt, detachedBox.box()
end

return Mast
