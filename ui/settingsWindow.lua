-- settingsWindow.lua
-- ImGui configuration window. Toggle with /hr; sample rolls and recasts preview while it is open.

local imgui   = require('imgui')
local gdi     = require('libs/gdifonts/include')
local uiTheme = require('libs/uiTheme')
local draw    = require('ui/draw')
local recasts = require('recasts')

local SettingsWindow = {}
local open = false

local fontInputs   = { numeralFont = { '' }, labelFont = { '' } }
local fontReady    = false
local fontFeedback = nil

local GRADIENT_STYLES = {
    { 0, 'None' }, { 1, 'Left to right' }, { 2, 'Top-left to bottom-right' }, { 3, 'Top to bottom' },
    { 4, 'Top-right to bottom-left' }, { 5, 'Right to left' }, { 6, 'Bottom-right to top-left' },
    { 7, 'Bottom to top' }, { 8, 'Bottom-left to top-right' },
}
local STATES = { { 'normal', 'Normal' }, { 'lucky', 'Lucky' }, { 'unlucky', 'Unlucky' }, { 'bust', 'Bust' } }
local ORIENTATIONS = { { 'v', 'Vertical' }, { 'h', 'Horizontal' } }
local PLACEMENTS   = { { 'v', 'Beside' }, { 'h', 'Below' } }
local COOLING      = { { 'dim', 'Dim' }, { 'ready', 'Hide' } }
local NUMERALS     = { { true, 'Roman' }, { false, 'Arabic' } }
local ROLL_COLOURS = { { true, 'Per roll' }, { false, 'Single' } }
local SIDES        = { { 'left', 'Left' }, { 'right', 'Right' }, { 'none', 'None' } }

function SettingsWindow.toggle()
    open = not open
    if open then fontReady = false end
    return open
end

function SettingsWindow.isOpen() return open end

local function float4ToHex(f)
    local function b(v) return math.floor(math.max(0, math.min(1, v)) * 255 + 0.5) end
    return string.format('#%02X%02X%02X%02X', b(f[1]), b(f[2]), b(f[3]), b(f[4]))
end

local function colorPicker(label, tbl, key, settings)
    local col = draw.float4(tbl[key])
    if imgui.ColorEdit4(label, col, bit.bor(ImGuiColorEditFlags_AlphaBar, ImGuiColorEditFlags_NoInputs)) then
        tbl[key] = float4ToHex(col)
    end
    if imgui.IsItemDeactivatedAfterEdit() then settings.save() end
end

local function checkbox(label, tbl, key, settings)
    local v = { tbl[key] }
    if imgui.Checkbox(label, v) then
        tbl[key] = v[1]
        settings.save()
    end
end

local function styleName(style)
    for _, s in ipairs(GRADIENT_STYLES) do
        if s[1] == style then return s[2] end
    end
    return 'None'
end

local function fontRow(label, key, config, ctx)
    imgui.SetNextItemWidth(uiTheme.comboWidth())
    imgui.InputText(string.format('%s##%s', label, key), fontInputs[key], 64)
    imgui.SameLine()
    if imgui.SmallButton('Apply##' .. key) then
        local family = fontInputs[key][1]:match('^%s*(.-)%s*$')
        if family == '' then
            fontFeedback = { text = 'Font name cannot be empty', err = true }
        else
            config[key] = family
            ctx.onFontChange()
            if gdi:get_font_available(family) then
                fontFeedback = { text = family .. ' applied', err = false }
            else
                fontFeedback = { text = family .. ' is not installed; text falls back to Arial', err = true }
            end
        end
    end
end

local function optionCombo(label, key, options, tbl, settings)
    local current = options[1][2]
    for _, o in ipairs(options) do
        if o[1] == tbl[key] then current = o[2] end
    end
    imgui.SetNextItemWidth(uiTheme.comboWidth())
    if imgui.BeginCombo(label, current) then
        for _, o in ipairs(options) do
            if imgui.Selectable(o[2], o[1] == tbl[key]) then
                tbl[key] = o[1]
                settings.save()
            end
        end
        imgui.EndCombo()
    end
end

local function offsetSlider(label, key, config, settings)
    imgui.SetNextItemWidth(uiTheme.comboWidth())
    local v = { config[key] }
    if imgui.SliderInt(string.format('%s##%s', label, key), v, -12, 12, '%d px') then
        config[key] = v[1]
    end
    if imgui.IsItemDeactivatedAfterEdit() then settings.save() end
end

local function sliderInt(label, tbl, key, min, max, fmt, settings)
    imgui.SetNextItemWidth(uiTheme.comboWidth())
    local v = { tbl[key] }
    if imgui.SliderInt(label, v, min, max, fmt) then tbl[key] = v[1] end
    if imgui.IsItemDeactivatedAfterEdit() then settings.save() end
end

local function drawPosition(config, settings)
    uiTheme.header('Position')
    imgui.Indent(uiTheme.indent)
    checkbox('Lock position', config, 'lockPosition', settings)
    local alignBottom = { config.stack == 'up' }
    if imgui.Checkbox('Align bottom', alignBottom) then
        config.stack = alignBottom[1] and 'up' or 'down'
        settings.save()
    end
    uiTheme.helpMarker('New rolls stack upward from the anchor. Vertical cards and detached recasts grow upward too.')
    local custom = { config.scale > 0 }
    if imgui.Checkbox('Custom scale', custom) then
        config.scale = custom[1] and math.floor(draw.autoScale() * 100 + 0.5) / 100 or 0
        settings.save()
    end
    uiTheme.helpMarker('Off: scale follows screen height (1440p = 1.0).')
    if custom[1] then
        imgui.Indent(uiTheme.subIndent)
        imgui.SetNextItemWidth(uiTheme.comboWidth())
        local sv = { config.scale }
        if imgui.SliderFloat('##scale', sv, 0.25, 2.5, '%.2fx') then config.scale = sv[1] end
        if imgui.IsItemDeactivatedAfterEdit() then settings.save() end
        imgui.Unindent(uiTheme.subIndent)
    end
    imgui.Unindent(uiTheme.indent)
    imgui.Spacing()
end

local function drawRolls(config, settings)
    uiTheme.header('Rolls')
    imgui.Indent(uiTheme.indent)
    optionCombo('Numerals##numerals', 'roman', NUMERALS, config, settings)
    sliderInt('Expiring at##expiring', config, 'expiringThreshold', 5, 60, '%d s', settings)
    uiTheme.helpMarker('The roll and its timer blink below this.')
    optionCombo('Roll colours##rollColours', 'perRollColor', ROLL_COLOURS, config, settings)
    if not config.perRollColor then
        imgui.SameLine()
        colorPicker('##rollColor', config, 'rollColor', settings)
    end
    imgui.SetNextItemWidth(uiTheme.comboWidth())
    local bg = { math.floor(config.backgroundOpacity * 100 + 0.5) }
    if imgui.SliderInt('Background##bg', bg, 0, 100, '%d%%') then
        config.backgroundOpacity = bg[1] / 100
    end
    if imgui.IsItemDeactivatedAfterEdit() then settings.save() end
    imgui.Unindent(uiTheme.indent)
    imgui.Spacing()
end

local function drawMisc(config, settings)
    uiTheme.header('Misc')
    imgui.Indent(uiTheme.indent)
    checkbox('Other Corsairs', config, 'showOthers', settings)
    uiTheme.helpMarker('Also list rolls other Corsairs put on you.')
    checkbox('Reference key', config.sheet, 'enabled', settings)
    uiTheme.helpMarker('Rolls, cards and recasts at a glance; also /hr key.')
    imgui.Unindent(uiTheme.indent)
    imgui.Spacing()
end

local function drawGeneral(config, settings, ctx)
    drawPosition(config, settings)
    drawRolls(config, settings)
    drawMisc(config, settings)
    imgui.Separator()
    imgui.Spacing()
    if uiTheme.centeredButton('Reset position', 'primary') then ctx.onResetAnchor() end
end

local function drawRecasts(config, settings, ctx)
    uiTheme.header('Recasts')
    imgui.Indent(uiTheme.indent)
    checkbox('Detach', config, 'recastsDetached', settings)
    uiTheme.helpMarker('Own position, dragged apart from the rolls.')
    if config.recastsDetached then
        optionCombo('Orientation##mast', 'mast', ORIENTATIONS, config, settings)
    else
        optionCombo('Placement##mast', 'mast', PLACEMENTS, config, settings)
    end
    optionCombo('Cooling##cooling', 'abilityDisplay', COOLING, config, settings)
    checkbox('Timers', config, 'showTimers', settings)
    if config.showTimers then
        imgui.Indent(uiTheme.subIndent)
        sliderInt('Minutes from##secThresh', config, 'secondsThreshold', 60, 99, '%d s', settings)
        uiTheme.helpMarker('Below this, timers count in seconds.')
        imgui.Unindent(uiTheme.subIndent)
    end
    colorPicker('Ready colour##readyColor', config, 'readyColor', settings)
    uiTheme.helpMarker('Ready abilities and the Double-Up tag.')
    checkbox('Names on hover##recastTooltips', config, 'recastTooltips', settings)
    imgui.Unindent(uiTheme.indent)
    imgui.Spacing()

    uiTheme.header('Abilities', 'Abilities you do not have are always hidden.')
    imgui.Indent(uiTheme.indent)
    if imgui.BeginTable('##abilities', 2) then
        for _, a in ipairs(recasts.ABILITIES) do
            imgui.TableNextColumn()
            checkbox(string.format('%s##show_%s', a.name, a.key), config.showRecasts, a.key, settings)
        end
        imgui.EndTable()
    end
    imgui.Unindent(uiTheme.indent)
    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()
    imgui.BeginDisabled(not config.recastsDetached)
    if uiTheme.centeredButton('Reset position##recasts', 'primary') then ctx.onResetRecastAnchor() end
    imgui.EndDisabled()
end

local function drawCards(config, settings, ctx)
    local cc = config.cards
    uiTheme.header('Quick Draw cards', 'Counts from your main inventory, shown while you have Quick Draw.')
    imgui.Indent(uiTheme.indent)
    checkbox('Show cards', cc, 'enabled', settings)
    checkbox('Attach to rolls', cc, 'attached', settings)
    uiTheme.helpMarker('A row under the roll list that moves with it.')
    imgui.BeginDisabled(cc.attached)
    optionCombo('Orientation##cardsOrientation', 'orientation', ORIENTATIONS, cc, settings)
    optionCombo('Frame##cardsSide', 'side', SIDES, cc, settings)
    imgui.EndDisabled()
    checkbox('Hide empty', cc, 'hideEmpty', settings)
    uiTheme.helpMarker('Off: empty cards stay in place, faded, so the order never shifts.')
    checkbox('Names on hover##cardTooltips', cc, 'tooltips', settings)
    imgui.Unindent(uiTheme.indent)
    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()
    imgui.BeginDisabled(cc.attached)
    if uiTheme.centeredButton('Reset position##cards', 'primary') then ctx.onResetCardsAnchor() end
    imgui.EndDisabled()
end

local function drawFonts(config, settings, ctx)
    uiTheme.header('Fonts', 'Any installed Windows font, by family name.')
    imgui.Indent(uiTheme.indent)
    fontRow('Numerals', 'numeralFont', config, ctx)
    offsetSlider('Numeral offset', 'numeralOffset', config, settings)
    uiTheme.helpMarker('Nudges the text up (negative) or down (positive) to suit the font.')
    fontRow('Labels', 'labelFont', config, ctx)
    offsetSlider('Label offset', 'labelOffset', config, settings)
    if fontFeedback then
        if fontFeedback.err then
            imgui.TextColored({ 1.0, 0.45, 0.4, 1.0 }, fontFeedback.text)
        else
            imgui.TextColored({ 0.5, 0.88, 0.55, 1.0 }, fontFeedback.text)
        end
    end
    imgui.Unindent(uiTheme.indent)
    imgui.Spacing()
end

local function drawGradient(config, settings)
    uiTheme.header('Numeral gradient', 'The numeral fades from the first colour to the second.')
    imgui.Indent(uiTheme.indent)
    imgui.SetNextItemWidth(uiTheme.comboWidth())
    if imgui.BeginCombo('Direction##gradient', styleName(config.gradient.style)) then
        for _, s in ipairs(GRADIENT_STYLES) do
            if imgui.Selectable(s[2], s[1] == config.gradient.style) then
                config.gradient.style = s[1]
                settings.save()
            end
        end
        imgui.EndCombo()
    end
    imgui.PushStyleVar(ImGuiStyleVar_CellPadding, { 16, 5 })
    if imgui.BeginTable('##gradients', 2) then
        for _, st in ipairs(STATES) do
            imgui.TableNextColumn()
            local pair = config.gradient.colors[st[1]]
            colorPicker('##from' .. st[1], pair, 'from', settings)
            imgui.SameLine(0, 8)
            colorPicker(string.format('%s##to%s', st[2], st[1]), pair, 'to', settings)
        end
        imgui.EndTable()
    end
    imgui.PopStyleVar()
    imgui.Unindent(uiTheme.indent)
end

local function drawStyle(config, settings, ctx)
    drawFonts(config, settings, ctx)
    drawGradient(config, settings)
end

local function drawBody(config, settings, ctx)
    if imgui.BeginTabBar('##hrTabs') then
        if imgui.BeginTabItem('General') then
            drawGeneral(config, settings, ctx)
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem('Recasts') then
            drawRecasts(config, settings, ctx)
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem('Cards') then
            drawCards(config, settings, ctx)
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem('Style') then
            drawStyle(config, settings, ctx)
            imgui.EndTabItem()
        end
        imgui.EndTabBar()
    end
end

-- config: live settings table; settings: the settings lib;
-- ctx: { onFontChange, onResetAnchor, onResetRecastAnchor, onResetCardsAnchor }
function SettingsWindow.draw(config, settings, ctx)
    if not open then return end

    if not fontReady then
        fontInputs.numeralFont[1] = config.numeralFont
        fontInputs.labelFont[1]   = config.labelFont
        fontFeedback = nil
        fontReady = true
    end

    local n = uiTheme.push()
    imgui.SetNextWindowSize({ 300, 0 }, ImGuiCond_FirstUseEver)
    local winOpen = { true }
    local ok, err = true, nil
    if imgui.Begin('HighRoller.' .. addon.version, winOpen, ImGuiWindowFlags_AlwaysAutoResize) then
        ok, err = pcall(drawBody, config, settings, ctx)
    end
    imgui.End()
    uiTheme.pop(n)

    if not winOpen[1] then open = false end
    if not ok then error(err, 0) end
end

return SettingsWindow
