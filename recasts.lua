-- recasts.lua
-- COR ability recasts from the client recast list, and which of them the player has.

require('common')
local socket = require('socket')

local M = {}

-- `probe` is a concrete ability under the menu entry; Phantom Roll and Quick Draw are categories.
-- Ninja Roll is Horizon's level-5 roll (Corsair's Roll moved to 75).
-- timerId is the LSB recastId (sql/abilities.sql), used when the resource lookup fails.
-- base is the unmerited recast in seconds, the bar length until a full recast has been seen.
M.ABILITIES = {
    { key = 'phantomRoll', name = 'Phantom Roll', probe = 'Ninja Roll',     timerId = 193, base = 60 },
    { key = 'doubleUp',    name = 'Double-Up',    probe = 'Double-Up',      timerId = 194, base = 5 },
    { key = 'quickDraw',   name = 'Quick Draw',   probe = 'Fire Shot',      timerId = 195, base = 60 },
    { key = 'randomDeal',  name = 'Random Deal',  probe = 'Random Deal',    timerId = 196, base = 1200 },
    { key = 'snakeEye',    name = 'Snake Eye',    probe = 'Snake Eye',      timerId = 197, base = 300 },
    { key = 'fold',        name = 'Fold',         probe = 'Fold',           timerId = 198, base = 300 },
    -- Wild Card is a one-hour ability: it shares the SP timer in recast slot 0 (timer id 0)
    { key = 'wildCard',    name = 'Wild Card',    probe = 'Wild Card',      timerId = 0,   base = 3600 },
}

local POLL_GAP = 1.0   -- seconds without a snapshot after which the next reading counts as the first

local resolved = false
local lastPoll = 0
local resId    = {}   -- key -> ability resource id for HasAbility
local byTimer  = {}   -- timer id -> key
local state    = {}   -- key -> { remaining, total, last }

local function resolve()
    local resMgr = AshitaCore:GetResourceManager()
    for _, a in ipairs(M.ABILITIES) do
        local res = resMgr:GetAbilityByName(a.probe, 0)
        local timerId = a.timerId
        if res ~= nil then
            resId[a.key] = res.Id
            if a.timerId ~= 0 and res.RecastTimerId > 0 then timerId = res.RecastTimerId end
        end
        if timerId ~= 0 then byTimer[timerId] = a.key end
        state[a.key] = { remaining = 0, total = a.base, last = 0, seen = false }
    end
    resolved = true
end

local function track(a, remaining)
    local st = state[a.key]
    -- The first reading may be mid-recast (load, zone), so it only extends base.
    -- After that, a jump up means a new recast started and its starting value is the full length.
    if not st.seen then
        st.seen = true
        st.total = math.max(a.base, remaining)
    elseif remaining > st.last + 0.5 then
        st.total = math.max(remaining, 1)
    elseif remaining > st.total then
        st.total = remaining
    end
    st.remaining, st.last = remaining, remaining
end

-- True when the player currently has the ability (job, level and merits).
function M.has(key)
    if not resolved then resolve() end
    local id = resId[key]
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    return id ~= nil and player ~= nil and player:HasAbility(id)
end

-- Returns an ordered list of { key, remaining, total, ready } for abilities the player has.
function M.snapshot()
    if not resolved then resolve() end
    local mm     = AshitaCore:GetMemoryManager()
    local recast = mm:GetRecast()
    local player = mm:GetPlayer()
    if recast == nil or player == nil then return {} end

    local found = {}
    for slot = 0, 31 do
        local id = recast:GetAbilityTimerId(slot)
        local key = byTimer[id]
        if slot == 0 and id == 0 then key = 'wildCard' end
        if key ~= nil then found[key] = recast:GetAbilityTimer(slot) / 60 end
    end

    local now = socket.gettime()
    if now - lastPoll > POLL_GAP then
        for _, st in pairs(state) do st.seen = false end
    end
    lastPoll = now

    local list = {}
    for _, a in ipairs(M.ABILITIES) do
        local id = resId[a.key]
        if id ~= nil and player:HasAbility(id) then
            track(a, found[a.key] or 0)
            local st = state[a.key]
            table.insert(list, { key = a.key, remaining = st.remaining, total = st.total, ready = st.remaining <= 0 })
        end
    end
    return list
end

return M
