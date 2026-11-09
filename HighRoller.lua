addon.name    = 'HighRoller'
addon.author  = 'Zaldas'
addon.version = '0.1'
addon.desc    = 'Corsair Phantom Roll list: totals, lucky/unlucky, durations, ability recasts.'
addon.link    = 'https://github.com/Zaldas/HighRoller'

require('common')
local settings       = require('settings')
local chat           = require('chat')
local gdi            = require('libs/gdifonts/include')
local Tracker        = require('tracker')
local Hud            = require('ui/hud')
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
    showOthers        = false,  -- rows for rolls from other Corsairs
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

local config      = defaults
local initialized = false

settings.register('settings', 'hr_settings_update', function(s)
    if s == nil then return end
    config = s
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
    Tracker.attachCache(settings.load(cacheDefaults, 'rollcache'), saveRollCache)
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

local function isZoning()
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    return player ~= nil and player:GetIsZoning() ~= 0
end

local function shownViews(views)
    if config.showOthers then return views end
    local out = {}
    for _, v in ipairs(views) do
        if v.mine then table.insert(out, v) end
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
        cardsAt = Hud.update(shownViews(Tracker.snapshot()), recasts.snapshot(), config, cardRow)
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
        if Sheet.draw(config, Tracker.ownCorLevel()) then settings.save() end
    end

    SettingsWindow.draw(config, settings, {
        onFontChange  = function()
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
    })
end)

ashita.events.register('mouse', 'hr_mouse', function(e)
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
