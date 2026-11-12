-- tracker.lua
-- Phantom Roll state. Rows follow the roll buffs on the player; values and ownership come
-- from 0x028 roll packets and survive reloads through the rollcache settings file.

require('common')
local socket   = require('socket')
local rollData = require('rollData')

local Tracker = {}

local JOB_COR       = 17
local ABILITY_FOLD  = 178
local PRUNE_GRACE   = 3      -- seconds a cached roll may lack its buff (packet arrives before the buff)
local STAMP_EPSILON = 0.5    -- seconds a buff's expiry must move by to count as refreshed by a roll
local EXPIRY_SLACK  = 5      -- seconds a cached expiry may differ from its buff's before the entry is dropped
local ZONE_GRACE    = 15     -- seconds after a zone packet during which nothing is pruned
local ENTITY_MAX    = 2303   -- last entity index
local PARTY_MAX     = 17     -- party and alliance member slots 0..17; 0 is the player
local NO_STATUS     = 255    -- empty status icon slot
local EQUIP_SLOTS   = 16

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

-- Settings table: rolls['s<statusId>'] = { value, plus, casterId, casterName, mine, rolledAt, expiry, prevExpiry }.
-- rolledAt is the packet time and expiry the roll buff's absolute expiry (Unix seconds); an entry
-- whose buff expires at a different time belongs to an earlier roll and is dropped. An entry
-- without expiry is pending: it takes the first buff expiry that differs from prevExpiry (the
-- buff's expiry before the packet), or the first one when prevExpiry is nil.
local cache     = nil
local saveCache = function() end

local lastRollByCaster -- casterId -> roll def of their latest Phantom Roll; the cache answers when absent
local lastRollAt       -- casterId -> time of their latest Phantom Roll packet
local lastOwnStatus    -- status id of the player's latest roll (Double-Up applies to it)
local busts            -- own busts, oldest first: { key, at, total }
local missingSince     -- status id -> time its cached value was first seen without a buff
local totals           -- status id -> longest remaining time seen; cleared with its entry
local firstSeen        -- status id -> when its buff appeared; keeps row order stable
local zoneGraceUntil
-- Read by update(), built into rows by views()
local buffs            -- status id -> { remaining seconds, ... }
local expiries         -- status id -> absolute expiry of its first timed buff
local ownLevel         -- the player's COR level, nil when not COR
local casterLevels     -- casterId -> COR level of another caster in the party

local function cacheKey(statusId) return 's' .. statusId end

-- Clears all state but the cache table itself.
function Tracker.reset()
    lastRollByCaster = {}
    lastRollAt       = {}
    lastOwnStatus    = nil
    busts            = {}
    missingSince     = {}
    totals           = {}
    firstSeen        = {}
    zoneGraceUntil   = 0
    buffs            = {}
    expiries         = {}
    ownLevel         = nil
    casterLevels     = {}
end
Tracker.reset()

-- Item ids in equipment slots 0..15, 0 for empty.
local function equippedItemIds()
    local inv = AshitaCore:GetMemoryManager():GetInventory()
    local ids = {}
    for slot = 0, EQUIP_SLOTS - 1 do
        local id = 0
        local eq = inv:GetEquippedItem(slot)
        local index = eq and bit.band(eq.Index, 0x00FF) or 0
        if index > 0 then
            local item = inv:GetContainerItem(bit.rshift(bit.band(eq.Index, 0xFF00), 8), index)
            if item ~= nil then id = item.Id end
        end
        ids[slot + 1] = id
    end
    return ids
end

-- Phantom Roll +N from the gear worn now.
function Tracker.ownPlus()
    return rollData.gearPlus(equippedItemIds())
end

-- Entries without an expiry (an older cache format) stay pending until their buff is seen.
function Tracker.attachCache(cacheTable, saveFn)
    Tracker.reset()
    cache = cacheTable
    saveCache = saveFn
    if type(cache.rolls) ~= 'table' then
        cache.rolls = {}
    end
    local dirty = false
    for key, entry in pairs(cache.rolls) do
        if type(entry) ~= 'table' then
            cache.rolls[key] = nil
            dirty = true
        elseif type(entry.expiry) ~= 'number' then
            entry.expiry = nil
        end
    end
    if dirty then
        saveCache()
    end
end

local function getRoll(statusId)
    return cache and cache.rolls[cacheKey(statusId)] or nil
end

local function dropRoll(statusId)
    cache.rolls[cacheKey(statusId)] = nil
    missingSince[statusId] = nil
    totals[statusId] = nil
end

-- Entries from an older cache format have no rolledAt and rank below every timed entry.
local function rolledAt(entry)
    return type(entry.rolledAt) == 'number' and entry.rolledAt or -math.huge
end

-- The caster's most recently rolled cached roll, for a Double-Up whose roll no packet showed this
-- session. An entry older than the caster's latest roll packet belongs to an earlier roll and is skipped.
local function latestRollOf(casterId)
    if cache == nil then return nil end
    local since = lastRollAt[casterId]
    local best, latest = nil, nil
    for key, entry in pairs(cache.rolls) do
        local statusId = tonumber(key:sub(2))
        local def = statusId and rollData.byStatus[statusId]
        local at = rolledAt(entry)
        if def and entry.casterId == casterId and (since == nil or at >= since) and (latest == nil or at > latest) then
            best, latest = def, at
        end
    end
    return best
end

-- Phantom Roll +N recorded on the player's most recently rolled cached roll; 0 without one.
-- Gear-swap sets wear +N only while the roll resolves, so worn gear is not used.
function Tracker.lastOwnPlus()
    if cache == nil then return 0 end
    local plus, latest = 0, nil
    for _, entry in pairs(cache.rolls) do
        local at = rolledAt(entry)
        if entry.mine == true and (latest == nil or at > latest) then
            plus, latest = tonumber(entry.plus) or 0, at
        end
    end
    return plus
end

-- Player buffs with their remaining seconds ({ [statusId] = { remaining, ... } }) and the
-- absolute expiry of each status's first timed buff.
local function readPlayerBuffs(now)
    local player = AshitaCore:GetMemoryManager():GetPlayer()
    local icons  = player:GetStatusIcons()
    local timers = player:GetStatusTimers()
    local out, ends = {}, {}
    if not icons or not timers then return out, ends end
    local comparand = (now - VANA_EPOCH) * 60
    for j = 1, 32 do
        local id = icons[j]
        if id and id > 0 and id ~= NO_STATUS then
            local raw = timers[j]
            local seconds = nil
            if raw and raw ~= 0 and raw ~= TIMER_INF then
                -- The wrap count puts the expiry less than 2^31 ticks before now; the expiry itself
                -- depends on raw alone, so it stays constant across frames
                local wraps = math.ceil((comparand - 2147483648 - raw) / 0x100000000)
                local expiry = VANA_EPOCH + (raw + wraps * 0x100000000) / 60
                seconds = expiry - now
                ends[id] = ends[id] or expiry
            end
            out[id] = out[id] or {}
            table.insert(out[id], seconds and math.max(0, seconds) or 0)
        end
    end
    return out, ends
end

-- Stores a pending entry; reconcileCache stamps its expiry once the buff shows the new roll.
local function setRoll(statusId, entry, now)
    if cache == nil then return end
    local _, ends = readPlayerBuffs(now)
    entry.rolledAt   = now
    entry.expiry     = nil
    entry.prevExpiry = ends[statusId]
    cache.rolls[cacheKey(statusId)] = entry
    missingSince[statusId] = nil
    saveCache()
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
        def = lastRollByCaster[actor] or latestRollOf(actor)
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

    local now = socket.gettime()
    if abilityId ~= rollData.ABILITY_DOUBLE_UP then
        lastRollAt[actor] = now
        if anySuccess then
            lastRollByCaster[actor] = def
        end
    end

    -- The server applies Phantom Roll +N from the gear worn when the roll or Double-Up resolves;
    -- luashitacast's swap back follows this packet
    local plus = 0
    if actor == me then
        lastOwnStatus = def.statusId
        if anyBust then
            table.insert(busts, { key = def.key, at = now })
        end
        if myAction and SUCCESS_MSG[myAction.Message] then
            plus = Tracker.ownPlus()
        end
    end

    if myAction then
        if SUCCESS_MSG[myAction.Message] then
            setRoll(def.statusId, {
                value      = myAction.Param,
                casterId   = actor,
                casterName = actor == me and '' or nameForServerId(actor),
                mine       = actor == me,
                plus       = plus,
            }, now)
        elseif BUST_MSG[myAction.Message] and cache ~= nil then
            dropRoll(def.statusId)
            saveCache()
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

-- Stamps pending entries from their buff; outside the zone grace, drops entries whose buff is
-- gone past the grace period or expires at a different time. Returns true when it removed entries.
-- A stamp is not saved: prevExpiry reproduces it after a reload.
local function reconcileCache(now, zoning)
    local dirty = false
    for key, entry in pairs(cache.rolls) do
        local statusId = tonumber(key:sub(2))
        local live = statusId and expiries[statusId]
        if statusId == nil then
            cache.rolls[key] = nil
            dirty = true
        elseif buffs[statusId] == nil then
            if zoning then
                missingSince[statusId] = nil
            else
                missingSince[statusId] = missingSince[statusId] or now
                if now - missingSince[statusId] >= PRUNE_GRACE then
                    dropRoll(statusId)
                    dirty = true
                end
            end
        else
            missingSince[statusId] = nil
            -- A buff without a timer cannot be checked
            if live ~= nil and entry.expiry == nil then
                if entry.prevExpiry == nil or math.abs(live - entry.prevExpiry) > STAMP_EPSILON then
                    entry.expiry, entry.prevExpiry = live, nil
                end
            elseif live ~= nil and not zoning and math.abs(entry.expiry - live) > EXPIRY_SLACK then
                dropRoll(statusId)
                dirty = true
            end
        end
    end
    return dirty
end

-- Pairs Bust buffs with recorded busts and drops records whose buff is gone. A record younger than
-- PRUNE_GRACE may still be waiting for its buff.
local function pairBusts(now, zoning)
    local bustTimers = buffs[rollData.STATUS_BUST] or {}
    table.sort(bustTimers)
    while #busts > #bustTimers and not zoning and now - busts[1].at >= PRUNE_GRACE do
        table.remove(busts, 1)
    end
    for i, remaining in ipairs(bustTimers) do
        local rec = busts[i]
        if rec and (rec.total == nil or remaining > rec.total) then rec.total = remaining end
    end
end

-- Reads the player's buffs and levels for this frame, prunes and checks the cache, pairs busts.
function Tracker.update(now)
    buffs, expiries = readPlayerBuffs(now)
    local zoning = now < zoneGraceUntil

    ownLevel = Tracker.ownCorLevel()
    casterLevels = {}
    for statusId, list in pairs(buffs) do
        if rollData.byStatus[statusId] then
            firstSeen[statusId] = firstSeen[statusId] or now
            if totals[statusId] == nil or list[1] > totals[statusId] then totals[statusId] = list[1] end
            local known = getRoll(statusId)
            if known and not known.mine and known.casterId then
                casterLevels[known.casterId] = casterCorLevel(known.casterId)
            end
        end
    end

    pairBusts(now, zoning)
    if cache and reconcileCache(now, zoning) then
        saveCache()
    end

    if not zoning then
        for statusId, _ in pairs(firstSeen) do
            if buffs[statusId] == nil then firstSeen[statusId] = nil end
        end
    end
end

-- One HUD row. owner is 'mine', 'other' or 'unknown' (a roll buff no packet was seen for).
function Tracker.newView(def, statusId, owner, remaining, total)
    return {
        def        = def,
        statusId   = statusId,
        owner      = owner,
        value      = nil,
        plus       = 0,
        level      = nil,
        casterName = '',
        remaining  = remaining,
        total      = math.max(total or remaining, 1),
        bust       = false,
        du         = false,
        duRemaining = nil,
    }
end

-- The status the open Double-Up applies to: the player's latest roll, else (after a reload)
-- the own cached roll with the latest expiry.
local function doubleUpStatus()
    if lastOwnStatus ~= nil then return lastOwnStatus end
    local def = latestRollOf(localServerId())
    return def and def.statusId
end

-- Rows for the state update() read: own rolls, own busts, then rolls from other CORs and
-- unknown rolls. Changes no state.
function Tracker.views()
    local own, received, bustViews = {}, {}, {}
    local duTimers = buffs[rollData.STATUS_DOUBLE_UP_CHANCE]
    local duStatus = duTimers and doubleUpStatus()

    for statusId, list in pairs(buffs) do
        local def = rollData.byStatus[statusId]
        if def then
            local known = getRoll(statusId)
            local owner = known == nil and 'unknown' or (known.mine == true and 'mine' or 'other')
            local view = Tracker.newView(def, statusId, owner, list[1], totals[statusId])
            if known then
                view.value      = known.value
                view.plus       = known.plus or 0
                view.casterName = known.casterName or ''
            end
            if owner == 'mine' then
                view.level = ownLevel
            elseif owner == 'other' then
                view.level = casterLevels[known.casterId]
            end
            view.du = owner == 'mine' and statusId == duStatus and view.value ~= nil
            view.duRemaining = view.du and duTimers[1] or nil
            if owner == 'mine' then table.insert(own, view) else table.insert(received, view) end
        end
    end

    local bustTimers = buffs[rollData.STATUS_BUST] or {}
    for i, remaining in ipairs(bustTimers) do
        local rec = busts[i]
        local view = Tracker.newView(rec and rollData.byKey[rec.key] or nil, rollData.STATUS_BUST, 'mine',
            remaining, rec and rec.total or remaining)
        view.bust = true
        table.insert(bustViews, view)
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
