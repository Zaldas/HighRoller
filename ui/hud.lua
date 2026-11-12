-- hud.lua
-- Stacks the roll rows from the anchor, lays the recast mast against them, and handles dragging.

require('common')
local socket   = require('socket')
local sprites  = require('libs/spui/sprites')
local draw     = require('ui/draw')
local Drag     = require('ui/drag')
local Row      = require('ui/row')
local Mast     = require('ui/mast')
local recasts  = require('recasts')
local rollData = require('rollData')
local Tracker  = require('tracker')

local Hud = {}

local POOL_SIZE = 8
local ROW_GAP   = 2

-- assets\<name>.png; icons and the ability icons (named by ability key) are in assets\icons\
local TEXTURES = { 'white', 'fadeUp', 'fadeDown', 'fadeRight', 'fadeLeft' }
local ICONS    = { 'doubleUpTag' }

local engine  = nil
local pool    = {}
local mast    = nil
local bounds  = { x = 0, y = 0, w = 0, h = 0 }
local drag    = Drag.new()
local recastBounds = { x = 0, y = 0, w = 0, h = 0 }   -- detached recasts
local recastDrag   = Drag.new()

-- Returns the sprite engine and textures for other modules to share.
function Hud.init(cfg)
    engine = sprites.newEngine()
    local tex = {}
    local function load(name, dir)
        tex[name] = draw.loadTex(engine, string.format('%s%s%s.png', addon.path, dir, name))
    end
    for _, name in ipairs(TEXTURES) do
        load(name, 'assets\\')
    end
    for _, name in ipairs(ICONS) do
        load(name, 'assets\\icons\\')
    end
    for _, a in ipairs(recasts.ABILITIES) do
        load(a.key, 'assets\\icons\\')
    end
    -- Sprites draw in creation order; the backgrounds must exist before the rows
    local backs = Mast.newBackgrounds(engine, tex)
    for i = 1, POOL_SIZE do pool[i] = Row.new(engine, tex, cfg) end
    mast = Mast.new(engine, tex, cfg, backs)
    return engine, tex
end

function Hud.destroy()
    for _, r in ipairs(pool) do r:destroy(engine) end
    pool = {}
    if mast then mast:destroy(engine) end
    mast = nil
    if engine then engine:destroy() end
    engine = nil
    sprites.Dispose()
end

function Hud.setFonts(cfg)
    for _, r in ipairs(pool) do r:setFonts(cfg) end
    if mast then mast:setFonts(cfg) end
end

function Hud.hideAll()
    for _, r in ipairs(pool) do r:hide() end
    if mast then mast:hide() end
    bounds.w, bounds.h = 0, 0
    recastBounds.w, recastBounds.h = 0, 0
end

-- views: roll rows in display order; recastList: from recasts.snapshot(); cards: { w, h } of the
-- attached card row, or nil. Returns the card row's top-left when cards is given.
function Hud.update(views, recastList, cfg, cards)
    if engine == nil then return nil end
    local s   = draw.uiScale(cfg)
    local now = socket.gettime()
    local x   = math.floor(cfg.anchor.x)
    local y   = math.floor(cfg.anchor.y)
    local rowH, gap = Row.HEIGHT * s, ROW_GAP * s
    local n = math.min(#views, POOL_SIZE)
    local listH = n > 0 and (n * rowH + (n - 1) * gap) or 0
    -- Stacking up, the anchor is the list's bottom edge and the first roll sits lowest
    local stackUp = cfg.stack == 'up'
    local top = stackUp and (y - listH) or y
    local left = x

    for i = 1, POOL_SIZE do
        local r, v = pool[i], views[i]
        if v and i <= n then
            local ry = stackUp and (y - i * rowH - (i - 1) * gap) or (y + (i - 1) * (rowH + gap))
            left = math.min(left, r:render(v, x, ry, s, cfg, now))
        else
            r:hide()
        end
    end

    local box, cardsAt, recastBox = mast:render(recastList, { x = x, y = top, w = Row.WIDTH * s, h = listH, left = left }, s, cfg, cards)
    bounds.x, bounds.y, bounds.w, bounds.h = box.x, box.y, box.w, box.h
    recastBounds.x, recastBounds.y, recastBounds.w, recastBounds.h = recastBox.x, recastBox.y, recastBox.w, recastBox.h
    return cardsAt
end

-- Returns true when a drag ended and an anchor should be saved.
function Hud.handleMouse(e, cfg)
    local recastEnded = recastDrag:handle(e, cfg.recastAnchor, recastBounds, cfg.lockPosition)
    local rollEnded = drag:handle(e, cfg.anchor, bounds, cfg.lockPosition)
    return recastEnded or rollEnded
end

-- Sample rows and recasts for positioning and styling while the settings window is open.
function Hud.previewViews()
    local t = socket.gettime()
    local function remaining(period, offset) return period - ((t + offset) % period) end
    local function view(def, statusId, owner, value, rem)
        local v = Tracker.newView(def, statusId, owner, rem, 300)
        v.value, v.level, v.plus = value, 75, 0
        return v
    end
    local chaos, hunter, evoker = rollData.byKey.chaos, rollData.byKey.hunter, rollData.byKey.evoker
    local du = view(hunter, hunter.statusId, 'mine', 6, remaining(300, 0))
    du.du, du.duRemaining = true, remaining(45, 0)
    local bust = view(chaos, rollData.STATUS_BUST, 'mine', nil, remaining(300, 200))
    bust.bust = true
    local other = view(evoker, evoker.statusId, 'other', 9, remaining(300, 120))
    other.casterName = 'Kaedra'
    return { du, view(chaos, chaos.statusId, 'mine', 4, remaining(30, 0)), bust, other }
end

function Hud.previewRecasts()
    local t = socket.gettime()
    local pr = 60 - (t % 75)
    local list = {}
    local sample = { phantomRoll = math.max(0, pr), doubleUp = 0, quickDraw = 0, randomDeal = 845,
        snakeEye = 0, fold = 212, wildCard = 2400 }
    for _, a in ipairs(recasts.ABILITIES) do
        local rem = sample[a.key] or 0
        table.insert(list, { key = a.key, remaining = rem, ready = rem <= 0 })
    end
    return list
end

return Hud
