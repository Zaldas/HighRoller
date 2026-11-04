-- referenceKey.lua
-- Corsair key as an ImGui window: rolls (stat, lucky/unlucky and their values at your COR level, bust penalty),
-- Quick Draw cards and their effects, and the recast icons with their abilities.

require('common')
local ffi      = require('ffi')
local imgui    = require('imgui')
local uiTheme  = require('libs/uiTheme')
local draw     = require('ui/draw')
local rollData = require('rollData')
local cards    = require('cards')
local recasts  = require('recasts')

local Sheet = {}

local ICON = 16

local COLOR_TEXT    = '#C9D2E3'
local COLOR_LUCKY   = '#7BE08A'
local COLOR_UNLUCKY = '#EE5A4E'
local COLOR_DIM     = '#8E98AA'

-- What each mast icon's ability does (LSB job_utils/corsair.lua; base LSB)
local ABILITY_NOTES = {
    phantomRoll = 'Party buff set by the roll total',
    doubleUp    = 'Re-roll your latest roll',
    quickDraw   = 'Elemental shot; uses a card',
    randomDeal  = 'Resets another ability recast',
    snakeEye    = 'Next Double-Up is +1',
    fold        = 'Removes a bust or your latest roll',
    wildCard    = 'Resets recasts by its roll',
}

local tex = nil

local function colored(hex, text)
    imgui.TextColored(draw.float4(hex), text)
end

-- textures: the HUD's, for the recast icons.
function Sheet.init(textures)
    tex = textures
end

local function beginTable(id, cols)
    return imgui.BeginTable(id, cols, bit.bor(ImGuiTableFlags_SizingFixedFit, ImGuiTableFlags_RowBg))
end

local function drawRolls(cfg, level)
    colored(COLOR_DIM, level and string.format('Values at COR level %d', level) or 'Values at level 75')
    if not beginTable('##hrKeyRolls', 5) then return end
    for _, def in ipairs(rollData.ordered) do
        imgui.TableNextRow()
        imgui.TableNextColumn()
        colored(rollData.colorFor(def, cfg), def.short)
        imgui.TableNextColumn()
        colored(COLOR_TEXT, def.effect)
        imgui.TableNextColumn()
        colored(COLOR_LUCKY, string.format('%s %s', rollData.numeral(def.lucky, cfg.roman), rollData.amountText(def, def.lucky, level)))
        imgui.TableNextColumn()
        colored(COLOR_UNLUCKY, string.format('%s %s', rollData.numeral(def.unlucky, cfg.roman), rollData.amountText(def, def.unlucky, level)))
        imgui.TableNextColumn()
        local bust = rollData.bustText(def)
        colored(COLOR_DIM, bust ~= '' and ('Bust ' .. bust) or '')
    end
    imgui.EndTable()
end

local function drawCards()
    if not beginTable('##hrKeyCards', 2) then return end
    for _, e in ipairs(cards.ELEMENTS) do
        imgui.TableNextRow()
        imgui.TableNextColumn()
        colored(e.color, e.name .. ' Card')
        imgui.TableNextColumn()
        colored(COLOR_TEXT, e.shot)
    end
    imgui.EndTable()
end

local function drawRecasts()
    if not beginTable('##hrKeyRecasts', 3) then return end
    for _, a in ipairs(recasts.ABILITIES) do
        imgui.TableNextRow()
        imgui.TableNextColumn()
        local t = tex and tex[a.key]
        if t then
            local scale = ICON / math.max(t.w, t.h)
            imgui.Image(tonumber(ffi.cast('uint32_t', t.tex)), { t.w * scale, t.h * scale })
        end
        imgui.TableNextColumn()
        imgui.Text(a.name)
        imgui.TableNextColumn()
        colored(COLOR_TEXT, ABILITY_NOTES[a.key] or '')
    end
    imgui.EndTable()
end

-- Draws the key window while cfg.sheet.enabled. Returns true when its close button was used.
function Sheet.draw(cfg, level)
    if not cfg.sheet.enabled then return false end
    local n = uiTheme.push()
    local open = { true }
    local ok, err = true, nil
    if imgui.Begin('HighRoller Key', open, ImGuiWindowFlags_AlwaysAutoResize) then
        ok, err = pcall(function()
            if imgui.BeginTabBar('##hrKeyTabs') then
                if imgui.BeginTabItem('Rolls') then
                    drawRolls(cfg, level)
                    imgui.EndTabItem()
                end
                if imgui.BeginTabItem('Cards') then
                    drawCards()
                    imgui.EndTabItem()
                end
                if imgui.BeginTabItem('Recasts') then
                    drawRecasts()
                    imgui.EndTabItem()
                end
                imgui.EndTabBar()
            end
        end)
    end
    imgui.End()
    uiTheme.pop(n)
    if not ok then error(err, 0) end
    if not open[1] then
        cfg.sheet.enabled = false
        return true
    end
    return false
end

return Sheet
