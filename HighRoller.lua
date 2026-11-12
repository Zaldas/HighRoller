addon.name    = 'HighRoller'
addon.author  = 'Zaldas'
addon.version = '0.1'
addon.desc    = 'Corsair HUD: Phantom Rolls with their bonuses and timers, ability recasts, Quick Draw card counts and a reference key.'
addon.link    = 'https://github.com/Zaldas/HighRoller'

require('common')
local socket         = require('socket')
local settings       = require('settings')
local chat           = require('chat')
local gdi            = require('libs/gdifonts/include')
local Tracker        = require('tracker')
local Hud            = require('ui/hud')
local draw           = require('ui/draw')
local recasts        = require('recasts')
local cards          = require('cards')
local CardRail       = require('ui/cardRail')
local Sheet          = require('ui/referenceKey')
local SettingsWindow = require('ui/settingsWindow')

local defaults = T{
    anchor            = T{ x = 600, y = 500 },
    lockPosition      = false,
    scale             = 0,      -- 0 = auto (screen height / 1440)
    roman             = true,
    expiringThreshold = 15,
    stack             = 'down', -- 'down': anchor is the top, new rolls below; 'up': anchor is the bottom
    mast              = 'v',    -- recast icons beside ('v') or under ('h') the rolls; detached, a column or row
    recastsDetached   = false,
    recastAnchor      = T{ x = 900, y = 500 },
    showOthers        = false,  -- rows for rolls known to be from other Corsairs
    abilityDisplay    = 'dim',  -- 'dim': cooling icons dimmed; 'ready': only ready icons shown
    showTimers        = false,
    recastTooltips    = true,
    secondsThreshold  = 60,     -- recast timers show raw seconds below this
    cards = T{
        enabled     = true,
        anchor      = T{ x = 600, y = 760 },
        attached    = false,    -- a row under the roll list and recasts, moved with them
        orientation = 'h',      -- 'h' row or 'v' column; detached only
        side        = 'left',   -- 'left', 'right' (the L frame's upright) or 'none'; detached only
        hideEmpty   = false,
        tooltips    = true,
    },
    sheet = T{
        enabled = true,       -- key window shown while COR; ImGui keeps its position and collapse
    },
    backgroundOpacity = 0.3,
    readyColor        = '#78AEFFFF', -- ready abilities, the Double-Up tag
    perRollColor      = true,   -- each roll in its own colour; off uses rollColor for all
    rollColor         = '#C9D2E3FF',
    showRecasts       = T{ phantomRoll = true, doubleUp = true, quickDraw = true, randomDeal = true,
        snakeEye = true, fold = true, wildCard = true },
    numeralFont       = 'Arial',
    labelFont         = 'Arial',
    numeralOffset     = 0,      -- vertical nudge in 1440p px, per-font baseline differences
    labelOffset       = 0,
    gradient = T{
        style  = 2,             -- gdifonts TopLeftToBottomRight
        colors = T{
            normal  = T{ from = '#FFFFFFFF', to = '#8A93A3FF' },
            lucky   = T{ from = '#F1FFF3FF', to = '#2C8A42FF' },
            unlucky = T{ from = '#FFF0EEFF', to = '#9E2419FF' },
            bust    = T{ from = '#FFF0EEFF', to = '#9E2419FF' },
        },
    },
}

local cacheDefaults = T{ rolls = T{} }

local STACKS   = { down = true, up = true }
local MASTS    = { v = true, h = true }
local DISPLAYS = { dim = true, ready = true }
local SIDES    = { left = true, right = true, none = true }

local function isBool(v)
    return type(v) == 'boolean'
end

local function isText(v)
    return type(v) == 'string' and v ~= ''
end

-- '#RRGGBB' or '#RRGGBBAA'
local function isColor(v)
    return type(v) == 'string' and (#v == 7 or #v == 9) and v:match('^#%x+$') ~= nil
end

local function inSet(set)
    return function(v)
        return set[v] == true
    end
end

-- t[key] takes the default's value when check(t[key]) fails.
local function fix(t, def, key, check)
    if not check(t[key]) then
        t[key] = def[key]
    end
end

-- t[key] as a number clamped to lo..hi; the default when it is not a number.
local function clampField(t, def, key, lo, hi, integer)
    local v = tonumber(t[key])
    if v == nil then
        t[key] = def[key]
        return
    end
    if integer then
        v = math.floor(v + 0.5)
    end
    t[key] = math.max(lo, math.min(hi, v))
end

-- A nested table that is missing or not a table becomes a copy of the default's.
local function subTable(t, def, key)
    if type(t[key]) ~= 'table' then
        t[key] = def[key]:copy(true)
    end
    return t[key], def[key]
end

local function anchorField(t, def, key)
    local a, d = subTable(t, def, key)
    a.x = tonumber(a.x) or d.x
    a.y = tonumber(a.y) or d.y
end

-- Type-checks a loaded settings table in place; ranges match the settings window's sliders.
local function sanitize(c)
    local d = defaults
    anchorField(c, d, 'anchor')
    anchorField(c, d, 'recastAnchor')
    for _, k in ipairs({ 'lockPosition', 'roman', 'recastsDetached', 'showOthers', 'showTimers', 'recastTooltips', 'perRollColor' }) do
        fix(c, d, k, isBool)
    end
    -- 0 is automatic scale
    local scale = tonumber(c.scale)
    if scale == nil or scale <= 0 then
        c.scale = 0
    else
        c.scale = math.max(0.25, math.min(2.5, scale))
    end
    clampField(c, d, 'expiringThreshold', 5, 60, true)
    clampField(c, d, 'secondsThreshold', 60, 99, true)
    clampField(c, d, 'backgroundOpacity', 0, 1, false)
    clampField(c, d, 'numeralOffset', -12, 12, true)
    clampField(c, d, 'labelOffset', -12, 12, true)
    fix(c, d, 'stack', inSet(STACKS))
    fix(c, d, 'mast', inSet(MASTS))
    fix(c, d, 'abilityDisplay', inSet(DISPLAYS))
    fix(c, d, 'readyColor', isColor)
    fix(c, d, 'rollColor', isColor)
    fix(c, d, 'numeralFont', isText)
    fix(c, d, 'labelFont', isText)

    local cc, dc = subTable(c, d, 'cards')
    anchorField(cc, dc, 'anchor')
    for _, k in ipairs({ 'enabled', 'attached', 'hideEmpty', 'tooltips' }) do
        fix(cc, dc, k, isBool)
    end
    fix(cc, dc, 'orientation', inSet(MASTS))
    fix(cc, dc, 'side', inSet(SIDES))

    local sc, ds = subTable(c, d, 'sheet')
    fix(sc, ds, 'enabled', isBool)

    local shown, dshown = subTable(c, d, 'showRecasts')
    for k in pairs(dshown) do
        fix(shown, dshown, k, isBool)
    end

    local g, dg = subTable(c, d, 'gradient')
    clampField(g, dg, 'style', 0, 8, true)
    local colors, dcolors = subTable(g, dg, 'colors')
    for state in pairs(dcolors) do
        local pair, dpair = subTable(colors, dcolors, state)
        fix(pair, dpair, 'from', isColor)
        fix(pair, dpair, 'to', isColor)
    end
end

local config      = defaults
local initialized = false

settings.register('settings', 'hr_settings_update', function(s)
    if s == nil then return end
    config = s
    sanitize(config)
    if initialized then
        Hud.setFonts(config)
        CardRail.setFonts(config)
    end
end)

-- The settings lib loads a new table on character change; the tracker must write to it.
-- register() lowercases its alias while load()/save() do not; a mixed-case alias splits into two cache entries.
local function saveRollCache() settings.save('rollcache') end
settings.register('rollcache', 'hr_cache_update', function(s)
    if s ~= nil then Tracker.attachCache(s, saveRollCache) end
end)

ashita.events.register('load', 'hr_load', function()
    -- The settings lib links missing nested tables to the defaults it is given; a copy keeps
    -- `defaults` intact for the reset buttons
    config = settings.load(defaults:copy(true))
    sanitize(config)
    Tracker.attachCache(settings.load(cacheDefaults:copy(true), 'rollcache'), saveRollCache)
    local engine, tex = Hud.init(config)
    CardRail.init(engine, tex, config)
    Sheet.init(tex)
    initialized = true
end)

ashita.events.register('unload', 'hr_unload', function()
    CardRail.destroy()
    Hud.destroy()
    gdi:destroy_interface()
    settings.save()
    settings.save('rollcache')

    ashita.events.unregister('load', 'hr_load')
    ashita.events.unregister('unload', 'hr_unload')
    ashita.events.unregister('packet_in', 'hr_packet_in')
    ashita.events.unregister('d3d_present', 'hr_d3d_present')
    ashita.events.unregister('mouse', 'hr_mouse')
    ashita.events.unregister('command', 'hr_command')
end)

ashita.events.register('packet_in', 'hr_packet_in', function(e)
    if e.id == 0x0028 then
        Tracker.onAction(e)
    elseif e.id == 0x000A or e.id == 0x000B then
        Tracker.onZone()
    end
end)

local settingsCtx = {
    onFontChange = function()
        Hud.setFonts(config)
        CardRail.setFonts(config)
        settings.save()
    end,
    onResetAnchor = function()
        config.anchor.x = defaults.anchor.x
        config.anchor.y = defaults.anchor.y
        settings.save()
    end,
    onResetRecastAnchor = function()
        config.recastAnchor.x = defaults.recastAnchor.x
        config.recastAnchor.y = defaults.recastAnchor.y
        settings.save()
    end,
    onResetCardsAnchor = function()
        config.cards.anchor.x = defaults.cards.anchor.x
        config.cards.anchor.y = defaults.cards.anchor.y
        settings.save()
    end,
}

local function isZoning()
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    return player ~= nil and player:GetIsZoning() ~= 0
end

-- Own rolls, busts and rolls of unknown origin; with showOthers, also rolls from other Corsairs.
local function shownViews(views)
    if config.showOthers then return views end
    local out = {}
    for _, v in ipairs(views) do
        if v.owner ~= 'other' then table.insert(out, v) end
    end
    return out
end

ashita.events.register('d3d_present', 'hr_d3d_present', function()
    if not initialized then return end
    local zoning = isZoning()
    local preview = SettingsWindow.isOpen()

    local cardCounts = nil
    if not zoning and config.cards.enabled and (preview or recasts.has('quickDraw')) then
        cardCounts = preview and cards.PREVIEW or cards.counts()
    end
    local attached = cardCounts ~= nil and config.cards.attached
    local cardRow = attached and CardRail.measure(cardCounts, config) or nil

    local cardsAt = nil
    if not zoning and preview then
        cardsAt = Hud.update(shownViews(Hud.previewViews()), Hud.previewRecasts(), config, cardRow)
    elseif not zoning and Tracker.isCorsair() then
        Tracker.update(socket.gettime())
        cardsAt = Hud.update(shownViews(Tracker.views()), recasts.snapshot(), config, cardRow)
    else
        Hud.hideAll()
    end

    if cardCounts ~= nil and not attached then
        CardRail.update(cardCounts, config)
    elseif cardsAt ~= nil then
        CardRail.update(cardCounts, config, cardsAt)
    else
        CardRail.hide()
    end

    if not zoning and (preview or Tracker.isCorsair()) then
        if Sheet.draw(config, Tracker.ownCorLevel(), Tracker.lastOwnPlus()) then settings.save() end
    end

    SettingsWindow.draw(config, settings, settingsCtx)
end)

ashita.events.register('mouse', 'hr_mouse', function(e)
    draw.trackMouse(e)
    if CardRail.handleMouse(e, config) then settings.save() end
    if Hud.handleMouse(e, config) then settings.save() end
end)

ashita.events.register('command', 'hr_command', function(e)
    local args = e.command:args()
    if #args == 0 or (args[1] ~= '/hr' and args[1] ~= '/highroller') then return end
    e.blocked = true

    local sub = args[2]
    if sub == nil then
        SettingsWindow.toggle()
    elseif sub == 'key' then
        config.sheet.enabled = not config.sheet.enabled
        settings.save()
    elseif sub == 'help' then
        print(chat.header(addon.name) .. chat.message('/hr        - Toggle settings (preview while open)'))
        print(chat.header(addon.name) .. chat.message('/hr key    - Toggle the reference key window'))
    else
        print(chat.header(addon.name) .. chat.warning('Unknown subcommand: ' .. tostring(sub)))
    end
end)
