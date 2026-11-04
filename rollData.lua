-- rollData.lua
-- HorizonXI Phantom Roll table. Values are level 75, main job, no Phantom Roll +N.
-- Source: horizonffxi.wiki roll pages (2026-11-02). `verified = false` marks values the
-- wiki flags as unverified or copied from LSB.

local M = {}

M.ABILITY_DOUBLE_UP = 123
M.STATUS_DOUBLE_UP_CHANCE = 308
M.STATUS_BUST = 309

-- Action messages (0x028 per-target message ids)
M.MSG_ROLL_MAIN        = 420
M.MSG_ROLL_SUB         = 421
M.MSG_DOUBLE_UP        = 424
M.MSG_DOUBLE_UP_BUST   = 426
M.MSG_DOUBLE_UP_BUST_S = 427

-- key, ability id, status id, name, short, colour, lucky, unlucky, values 1..11, bust penalty, effect label,
-- unit, verified. A nil bust penalty is one the wiki does not list.
local ROLLS = {
    { 'ninja',   110, 322, "Ninja's Roll",   'Ninja',   '#9B8CF5', 4, 8, { 10, 13, 15, 40, 18, 20, 25, 5, 27, 30, 50 },           -15,  'Evasion',     '',  true  },
    { 'hunter',  108, 320, "Hunter's Roll",  'Hunter',  '#A8BC5A', 4, 8, { 10, 13, 15, 40, 18, 20, 25, 5, 27, 30, 50 },           -15,  'Accuracy',    '',  true  },
    { 'chaos',   105, 317, 'Chaos Roll',     'Chaos',   '#C2407A', 4, 8, { 29, 36, 39, 92, 45, 54, 61, 21, 64, 71, 111 },         -15,  'Attack',      '',  true  },
    { 'magus',   113, 325, "Magus's Roll",   'Magus',   '#62B4F0', 2, 6, { 5, 20, 6, 8, 9, 3, 10, 13, 14, 15, 25 },               -5,   'M.Def',       '',  false },
    { 'healer',  100, 312, "Healer's Roll",  'Healer',  '#F2EEE2', 3, 7, { 2, 3, 10, 4, 4, 5, 1, 6, 6, 7, 12 },                   -3,   'Heal MP',     '',  true  },
    { 'puppet',  115, 327, 'Puppet Roll',    'Puppet',  '#DE9046', 3, 7, { 8, 16, 66, 20, 27, 35, 4, 43, 50, 58, 58 },            -8,   'Pet M.Atk',   '',  false },
    { 'choral',  107, 319, 'Choral Roll',    'Choral',  '#EE9AD0', 2, 6, { -13, -55, -17, -20, -25, -8, -30, -35, -40, -45, -65 }, 25,  'Interrupt',   '%', false },
    { 'monk',     99, 311, "Monk's Roll",    'Monk',    '#F4E15A', 3, 7, { 8, 10, 32, 12, 14, 16, 4, 20, 22, 24, 40 },            -11,  'Subtle Blow', '',  false },
    { 'beast',   106, 318, 'Beast Roll',     'Beast',   '#C9A06A', 4, 8, { 15, 20, 20, 45, 22, 27, 30, 11, 32, 35, 111 },         nil,  'Pet Atk',     '',  false },
    { 'samurai', 109, 321, 'Samurai Roll',   'Samurai', '#F07494', 2, 6, { 8, 32, 10, 12, 14, 4, 16, 20, 22, 24, 40 },            -10,  'Store TP',    '',  false },
    { 'gallant', 104, 316, "Gallant's Roll", 'Gallant', '#BCC8DA', 3, 7, { 48, 60, 200, 72, 88, 104, 32, 120, 140, 160, 240 },    -120, 'Defense',     '',  true  },
    { 'evoker',  112, 324, "Evoker's Roll",  'Evoker',  '#4FD8CA', 5, 9, { 1, 1, 1, 1, 3, 2, 2, 2, 1, 2, 4 },                     -1,   'Refresh',     '',  true  },
    { 'rogue',   103, 315, "Rogue's Roll",   'Rogue',   '#C06CE8', 5, 9, { 2, 2, 3, 4, 12, 5, 6, 6, 1, 8, 19 },                   -6,   'Crit',        '%', false },
    { 'warlock', 102, 314, "Warlock's Roll", 'Warlock', '#D45AB0', 4, 8, { 2, 3, 4, 12, 5, 6, 7, 1, 8, 9, 15 },                   -5,   'M.Acc',       '',  false },
    { 'fighter',  98, 310, "Fighter's Roll", 'Fighter', '#FF9145', 5, 9, { 2, 2, 3, 4, 12, 5, 6, 6, 1, 9, 18 },                   -6,   'Dbl Atk',     '%', false },
    { 'drachen', 111, 323, 'Drachen Roll',   'Drachen', '#8EC4AE', 4, 8, { 5, 6, 7, 13, 8, 9, 10, 3, 11, 12, 15 },               nil,  'Pet Acc',     '',  false },
    { 'wizard',  101, 313, "Wizard's Roll",  'Wizard',  '#7A9CFF', 5, 9, { 7, 10, 14, 14, 35, 17, 21, 25, 3, 25, 42 },            -15,  'M.Atk',       '',  true  },
    { 'corsair', 114, 326, "Corsair's Roll", 'Corsair', '#E0AE4C', 5, 9, { 10, 11, 11, 12, 20, 13, 15, 16, 8, 17, 24 },           -6,   'EXP',         '%', false },
}

M.byKey     = {}
M.byAbility = {}
M.byStatus  = {}
M.ordered   = {}

for _, r in ipairs(ROLLS) do
    local def = {
        key = r[1], abilityId = r[2], statusId = r[3], name = r[4], short = r[5], color = r[6],
        lucky = r[7], unlucky = r[8], values = r[9], bust = r[10], effect = r[11], unit = r[12],
        verified = r[13],
    }
    M.byKey[def.key]           = def
    M.byAbility[def.abilityId] = def
    M.byStatus[def.statusId]   = def
    table.insert(M.ordered, def)
end

local ROMAN = { 'I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X', 'XI', 'XII' }

function M.numeral(value, roman)
    if value == nil then return '?' end
    if roman then return ROMAN[math.min(value, 12)] or '?' end
    return tostring(value)
end

-- The roll's own colour, or the unified colour when per-roll colours are off.
function M.colorFor(def, cfg)
    if cfg.perRollColor == false then return cfg.rollColor end
    return def.color
end

-- The roll's bonus for a total at the caster's COR level (main or support job). The tables are
-- level 75; Horizon scales them as floor(v75 * level / 75), which also gives the Support Job column.
function M.amount(def, value, level)
    local v = def and value and def.values[value]
    if v == nil then return nil end
    level = math.min(75, level or 75)
    local scaled = math.floor(math.abs(v) * level / 75)
    return v < 0 and -scaled or scaled
end

-- The bonus alone, e.g. '+92' or '+12%'.
function M.amountText(def, value, level)
    local amount = M.amount(def, value, level)
    if amount == nil then return '' end
    return string.format('%s%d%s', amount >= 0 and '+' or '', amount, def.unit)
end

function M.effectText(def, value, level)
    if def == nil or value == nil or value < 1 or value > 11 then return '' end
    local amount = M.amount(def, value, level)
    if amount == nil then return '' end
    local sign = amount >= 0 and '+' or ''
    return string.format('%s %s%d%s', def.effect, sign, amount, def.unit)
end

-- The bust penalty, e.g. '-15' or '+25%'; '' when not listed.
function M.bustText(def)
    if def == nil or def.bust == nil then return '' end
    return string.format('%s%d%s', def.bust >= 0 and '+' or '', def.bust, def.unit)
end

return M
