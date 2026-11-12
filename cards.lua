-- cards.lua
-- Quick Draw elemental cards: display order, colours, and counts from the main inventory.

require('common')
local socket = require('socket')

local M = {}

-- Quick Draw only takes cards from the main inventory (LSB corsair.lua quick draw check)
local INVENTORY  = 0
local REFRESH    = 0.25   -- seconds between inventory scans

-- `shot` is the Quick Draw effect and the target effects it boosts (LSB corsair.lua quickDrawDataTable
-- and quickDrawEffectBoostTable; base LSB, not confirmed on Horizon).
M.ELEMENTS = {
    { key = 'light',   name = 'Light',   itemId = 2182, color = '#F4F2EA', fill = 0.20, shot = 'Sleep, boosts Dia' },
    { key = 'dark',    name = 'Dark',    itemId = 2183, color = '#9A8FB8', fill = 0.32, shot = 'Dispel, boosts Bio and Blind' },
    { key = 'fire',    name = 'Fire',    itemId = 2176, color = '#FF5A3C', fill = 0.20, shot = 'Damage, boosts Burn' },
    { key = 'ice',     name = 'Ice',     itemId = 2177, color = '#7FD4FF', fill = 0.20, shot = 'Damage, boosts Frost and Paralysis' },
    { key = 'wind',    name = 'Wind',    itemId = 2178, color = '#6BE07A', fill = 0.20, shot = 'Damage, boosts Choke' },
    { key = 'earth',   name = 'Earth',   itemId = 2179, color = '#E8C04A', fill = 0.20, shot = 'Damage, boosts Rasp and Slow' },
    { key = 'thunder', name = 'Thunder', itemId = 2180, color = '#B57BFF', fill = 0.20, shot = 'Damage, boosts Shock' },
    { key = 'water',   name = 'Water',   itemId = 2181, color = '#4F8BFF', fill = 0.20, shot = 'Damage, boosts Drown' },
}

local byItem = {}
for _, e in ipairs(M.ELEMENTS) do byItem[e.itemId] = e.key end

local counts   = {}
local lastScan = 0

-- key -> count, rescanned at most every REFRESH seconds.
function M.counts()
    local now = socket.gettime()
    if now - lastScan < REFRESH then return counts end
    lastScan = now

    local fresh = {}
    for _, e in ipairs(M.ELEMENTS) do fresh[e.key] = 0 end
    local inv = AshitaCore:GetMemoryManager():GetInventory()
    if inv ~= nil then
        -- CountMax is bag size + 1 (index 0 is gil), so items sit at 1..CountMax-1.
        for i = 1, inv:GetContainerCountMax(INVENTORY) - 1 do
            local item = inv:GetContainerItem(INVENTORY, i)
            local key = item and byItem[item.Id]
            if key then fresh[key] = fresh[key] + item.Count end
        end
    end
    counts = fresh
    return counts
end

-- Sample counts for the settings preview: full, low, empty and mid stacks.
M.PREVIEW = { light = 99, dark = 42, fire = 17, ice = 8, wind = 0, earth = 63, thunder = 99, water = 3 }

return M
