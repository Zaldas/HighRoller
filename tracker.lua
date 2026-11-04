-- tracker.lua
-- Phantom Roll state. Rows follow the roll buffs on the player; values and ownership come
-- from 0x028 roll packets and survive reloads through the rollCache settings file.

require('common')
local socket   = require('socket')
local rollData = require('rollData')

local Tracker = {}

local JOB_COR       = 17
local ABILITY_FOLD  = 178
local PRUNE_GRACE   = 3      -- seconds a cached roll may lack its buff (packet arrives before the buff)
local ZONE_GRACE    = 15     -- seconds after a zone packet during which nothing is pruned
local ENTITY_MAX    = 2303   -- last entity index
local PARTY_MAX     = 17     -- party and alliance member slots 0..17; 0 is the player
local NO_STATUS     = 255    -- empty status icon slot

-- GetStatusTimers(): absolute expiry in 1/60 s since the Vana'diel epoch (Unix 0x3C307D70).
-- 0x7FFFFFFF is infinite/hidden, 0 is no timer. The uint32 wraps and is corrected on read.
local VANA_EPOCH = 0x3C307D70
local TIMER_INF  = 0x7FFFFFFF

local SUCCESS_MSG = {
    [rollData.MSG_ROLL_MAIN] = true,
    [rollData.MSG_ROLL_SUB]  = true,
    [rollData.MSG_DOUBLE_UP] = true,
}
local BUST_MSG = {
    [rollData.MSG_DOUBLE_UP_BUST]   = true,
    [rollData.MSG_DOUBLE_UP_BUST_S] = true,
}

local cache            = nil   -- settings table: rolls['s<statusId>'] = { value, casterId, casterName, mine }
local saveCache        = function() end
local lastRollByCaster = {}    -- casterId -> roll def of their latest Phantom Roll
local lastOwnStatus    = nil   -- status id of the player's latest roll (Double-Up applies to it)
local busts            = {}    -- own busts, oldest first: { key, at, total }
local missingSince     = {}    -- status id -> time its cached value was first seen without a buff
local totals           = {}    -- status id -> longest remaining time seen since the last roll event
local firstSeen        = {}    -- status id -> when its buff appeared; keeps row order stable
local zoneGraceUntil   = 0

local function cacheKey(statusId) return 's' .. statusId end

function Tracker.attachCache(cacheTable, saveFn)
    cache = cacheTable
    cache.rolls = cache.rolls or {}
    saveCache = saveFn
end

local function setRoll(statusId, entry)
    if cache == nil then return end
    cache.rolls[cacheKey(statusId)] = entry
    missingSince[statusId] = nil
    saveCache()
end

local function getRoll(statusId)
    return cache and cache.rolls[cacheKey(statusId)] or nil
end

-- 0x028 bit stream, field names and widths per XiPackets world/server/0x0028/Reversing.md.
-- The stream starts after the 4-byte header and the 1-byte size.
local function parseAction(e)
    local data    = e.data_raw
    local maxBits = e.size * 8
    local offset  = 40

    local function bits(n)
        if offset + n > maxBits then maxBits = 0; return 0 end
        local v = ashita.bits.unpack_be(data, 0, offset, n)
        offset = offset + n
        return v
    end

    local act = {}
    act.UserId      = bits(32)   -- m_uID
    act.TargetCount = bits(6)    -- trg_sum
    bits(4)                      -- res_sum
    act.Type        = bits(4)    -- cmd_no; 6 = job ability finish
    act.Param       = bits(32)   -- cmd_arg: the ability id
    bits(32)                     -- info

    act.Targets = {}
    for _ = 1, act.TargetCount do
        if maxBits == 0 then break end
        local target = { Actions = {} }
        target.Id = bits(32)                 -- m_uID
        local actionCount = bits(4)          -- result_sum
        for _ = 1, actionCount do
            if maxBits == 0 then break end
            local ab = {}
            bits(3); bits(2); bits(12)       -- miss, kind, sub_kind
            bits(5); bits(5)                 -- info, scale
            ab.Param   = bits(17)            -- value: the roll total
            ab.Message = bits(10)            -- message
            bits(31)                         -- bit
            if bits(1) == 1 then bits(6); bits(4); bits(17); bits(10) end   -- proc kind/info/value/message
            if bits(1) == 1 then bits(6); bits(4); bits(14); bits(10) end   -- react kind/info/value/message
            table.insert(target.Actions, ab)
        end
        table.insert(act.Targets, target)
    end

    if maxBits == 0 or #act.Targets == 0 then return nil end
    return act
end

local function localServerId()
    return AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0)
end

-- COR level of a caster: main job level if COR main, else support job level; nil when unknown.
local function corLevel(mainJob, mainLevel, subJob, subLevel)
    if mainJob == JOB_COR then return mainLevel end
    if subJob == JOB_COR then return subLevel end
    return nil
end

function Tracker.ownCorLevel()
    local p = AshitaCore:GetMemoryManager():GetPlayer()
    if p == nil then return nil end
    return corLevel(p:GetMainJob(), p:GetMainJobLevel(), p:GetSubJob(), p:GetSubJobLevel())
end

-- Other CORs are looked up in the party/alliance; outside it their level is unknown (shown as 75).
local function casterCorLevel(serverId)
    if serverId == nil then return nil end
    local party = AshitaCore:GetMemoryManager():GetParty()
    for i = 1, PARTY_MAX do
        if party:GetMemberServerId(i) == serverId then
            return corLevel(party:GetMemberMainJob(i), party:GetMemberMainJobLevel(i),
                party:GetMemberSubJob(i), party:GetMemberSubJobLevel(i))
        end
    end
    return nil
end

local function nameForServerId(serverId)
    local party = AshitaCore:GetMemoryManager():GetParty()
    for i = 0, PARTY_MAX do
        if party:GetMemberServerId(i) == serverId then
            return party:GetMemberName(i)
        end
    end
    local ent = AshitaCore:GetMemoryManager():GetEntity()
    for i = 0, ENTITY_MAX do
        if ent:GetServerId(i) == serverId then
            return ent:GetName(i)
        end
    end
    return '?'
end

function Tracker.onAction(e)
    local act = parseAction(e)
    if act == nil or act.Type ~= 6 then return end

    local me = localServerId()
    if me == 0 then return end

    local abilityId = act.Param
    local actor     = act.UserId

    if abilityId == ABILITY_FOLD and actor == me then
        table.remove(busts)  -- Fold clears the bust with the longest remaining time: the newest
        return
    end

    local def = rollData.byAbility[abilityId]
    if abilityId == rollData.ABILITY_DOUBLE_UP then
        def = lastRollByCaster[actor]
    end
    if def == nil then return end

    local myAction, anySuccess, anyBust = nil, false, false
    for _, t in ipairs(act.Targets) do
        local a = t.Actions[1]
        if a then
            if t.Id == me then myAction = a end
            if SUCCESS_MSG[a.Message] then anySuccess = true end
            if BUST_MSG[a.Message] then anyBust = true end
        end
    end

    if abilityId ~= rollData.ABILITY_DOUBLE_UP and anySuccess then
        lastRollByCaster[actor] = def
    end

    if actor == me then
        lastOwnStatus = def.statusId
        if anyBust then
            table.insert(busts, { key = def.key, at = socket.gettime() })
        end
    end

    if myAction then
        if SUCCESS_MSG[myAction.Message] then
            setRoll(def.statusId, {
                value      = myAction.Param,
                casterId   = actor,
                casterName = actor == me and '' or nameForServerId(actor),
                mine       = actor == me,
            })
        elseif BUST_MSG[myAction.Message] then
            setRoll(def.statusId, nil)
        end
    end
end

function Tracker.onZone()
    zoneGraceUntil = os.time() + ZONE_GRACE
end

function Tracker.isCorsair()
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    return player ~= nil and (player:GetMainJob() == JOB_COR or player:GetSubJob() == JOB_COR)
end

-- Player buffs with their remaining seconds: { [statusId] = { remaining, ... } }.
local function readPlayerBuffs(now)
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    local icons  = player:GetStatusIcons()
    local timers = player:GetStatusTimers()
    local out = {}
    if not icons or not timers then return out end
    local comparand = (now - VANA_EPOCH) * 60
    for j = 1, 32 do
        local id = icons[j]
        if id and id > 0 and id ~= NO_STATUS then
            local raw = timers[j]
            local seconds = nil
            if raw and raw ~= 0 and raw ~= TIMER_INF then
                local ticks = raw - comparand
                while ticks < -2147483648 do ticks = ticks + 0x100000000 end
                seconds = math.max(0, ticks / 60)
            end
            out[id] = out[id] or {}
            table.insert(out[id], seconds or 0)
        end
    end
    return out
end

-- Builds the row list for this frame: own rolls, own busts, then rolls from other CORs.
function Tracker.snapshot()
    local now   = socket.gettime()
    local buffs = readPlayerBuffs(now)
    local own, received, bustViews = {}, {}, {}
    local duTimers  = buffs[rollData.STATUS_DOUBLE_UP_CHANCE]
    local duOpen    = duTimers ~= nil
    local zoning    = now < zoneGraceUntil

    -- Double-Up keeps a roll's expiry, so without a recorded latest roll (after a reload) it is the own roll expiring last
    local duStatus = lastOwnStatus
    if duOpen and duStatus == nil then
        local latest = -1
        for statusId, list in pairs(buffs) do
            local known = rollData.byStatus[statusId] and getRoll(statusId)
            if known and known.mine and list[1] > latest then
                duStatus, latest = statusId, list[1]
            end
        end
    end

    for statusId, list in pairs(buffs) do
        local def = rollData.byStatus[statusId]
        if def then
            firstSeen[statusId] = firstSeen[statusId] or now
            local remaining = list[1]
            local known = getRoll(statusId)
            local total = totals[statusId]
            if total == nil or remaining > total then
                total = remaining
                totals[statusId] = total
            end
            local view = {
                def        = def,
                statusId   = statusId,
                value      = known and known.value or nil,
                mine       = known == nil or known.mine == true,
                casterName = known and known.casterName or '',
                remaining  = remaining,
                total      = math.max(total, 1),
            }
            view.level = view.mine and Tracker.ownCorLevel() or casterCorLevel(known and known.casterId)
            view.du = duOpen and view.mine and statusId == duStatus and view.value ~= nil
            view.duRemaining = view.du and duTimers[1] or nil
            if view.mine then table.insert(own, view) else table.insert(received, view) end
        end
    end

    -- Busts: pair Bust buffs (longest remaining = newest) with recorded busts, oldest first.
    -- A record younger than PRUNE_GRACE may still be waiting for its buff.
    local bustTimers = buffs[rollData.STATUS_BUST] or {}
    table.sort(bustTimers)
    while #busts > #bustTimers and not zoning and now - busts[1].at >= PRUNE_GRACE do
        table.remove(busts, 1)
    end
    for i, remaining in ipairs(bustTimers) do
        local rec = busts[i]
        local def = rec and rollData.byKey[rec.key] or nil
        local total = remaining
        if rec then
            if rec.total == nil or remaining > rec.total then rec.total = remaining end
            total = rec.total
        end
        table.insert(bustViews, {
            def = def, statusId = rollData.STATUS_BUST, bust = true, mine = true,
            remaining = remaining, total = math.max(total, 1),
        })
    end

    -- Drop cached values whose buff has been gone past the grace period
    if cache and not zoning then
        local dirty = false
        for key, _ in pairs(cache.rolls) do
            local statusId = tonumber(key:sub(2))
            if statusId == nil then
                cache.rolls[key] = nil
                dirty = true
            elseif buffs[statusId] == nil then
                missingSince[statusId] = missingSince[statusId] or now
                if now - missingSince[statusId] >= PRUNE_GRACE then
                    cache.rolls[key] = nil
                    missingSince[statusId] = nil
                    totals[statusId] = nil
                    dirty = true
                end
            else
                missingSince[statusId] = nil
            end
        end
        if dirty then saveCache() end
    end

    if not zoning then
        for statusId, _ in pairs(firstSeen) do
            if buffs[statusId] == nil then firstSeen[statusId] = nil end
        end
    end

    local function byFirstSeen(a, b) return (firstSeen[a.statusId] or 0) < (firstSeen[b.statusId] or 0) end
    table.sort(own, byFirstSeen)
    table.sort(received, byFirstSeen)
    local views = {}
    for _, v in ipairs(own) do table.insert(views, v) end
    for _, v in ipairs(bustViews) do table.insert(views, v) end
    for _, v in ipairs(received) do table.insert(views, v) end
    return views
end

return Tracker
