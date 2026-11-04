-- draw.lua
-- Shared colour, text and sprite helpers. Geometry is in 1440p units; callers pass the scale.

require('common')
local d3d8 = require('d3d8')
local gdi  = require('libs/gdifonts/include')
local ffi  = require('ffi')
require('win32types')

ffi.cdef[[
    int GetCursorPos(POINT* lpPoint);
    int ScreenToClient(void* hWnd, POINT* lpPoint);
    int GetClientRect(void* hWnd, RECT* lpRect);
]]
local user32 = ffi.load('user32')

local M = {}

M.Z_TOOLTIP     = 100   -- above every other HighRoller object
M.COLOR_TOOLTIP = '#E8ECF4'

-- Automatic scale is screen height / 1440; cfg.scale > 0 overrides it.
-- The resolution is read once: the client only applies a change on restart.
local autoScaleValue = nil
function M.autoScale()
    if autoScaleValue == nil then
        autoScaleValue = AshitaCore:GetConfigurationManager():GetFloat('boot', 'ffxi.registry', '0002', 768) / 1440
    end
    return autoScaleValue
end

function M.uiScale(cfg)
    if cfg.scale > 0 then return cfg.scale end
    return M.autoScale()
end

local rgbaCache = {}   -- hex string -> { r, g, b, a }

function M.hexToRgba(hex)
    local c = rgbaCache[hex]
    if c == nil then
        local h = hex:gsub('#', '')
        c = { tonumber(h:sub(1, 2), 16) or 255, tonumber(h:sub(3, 4), 16) or 255,
            tonumber(h:sub(5, 6), 16) or 255, #h >= 8 and (tonumber(h:sub(7, 8), 16) or 255) or 255 }
        rgbaCache[hex] = c
    end
    return c[1], c[2], c[3], c[4]
end

-- ImGui colour, 0..1 per channel.
function M.float4(hex)
    local r, g, b, a = M.hexToRgba(hex)
    return { r / 255, g / 255, b / 255, a / 255 }
end

-- D3D sprite colour; sprite colour multiplies the texture.
function M.argb(hex, alpha)
    local r, g, b, a = M.hexToRgba(hex)
    return d3d8.D3DCOLOR_ARGB(math.floor(a * (alpha or 1)), r, g, b)
end

function M.gdiColor(hex, alpha)
    local r, g, b, a = M.hexToRgba(hex)
    a = math.floor(a * (alpha or 1))
    return bit.bor(bit.lshift(a, 24), bit.lshift(r, 16), bit.lshift(g, 8), b)
end

-- z orders gdifonts objects against each other (rects included); default 0.
function M.newText(font, size, align, flags, z)
    return gdi:create_object({
        z_order        = z or 0,
        font_alignment = align or gdi.Alignment.Left,
        font_family    = font,
        font_flags     = flags or gdi.FontFlags.None,
        font_height    = size,
        font_color     = 0xFFFFFFFF,
        outline_color  = 0xFF000000,
        outline_width  = 2,
        visible        = false,
        text           = '',
    }, false)
end

-- Hover tooltip text on an 80% dark rounded box. gdifonts sizes the box to the text and draws it
-- just before the text, at the text's z order.
function M.newTooltip(font)
    return gdi:create_object({
        z_order        = M.Z_TOOLTIP,
        font_alignment = gdi.Alignment.Left,
        font_family    = font,
        font_flags     = gdi.FontFlags.Bold,
        font_height    = 12,
        font_color     = 0xFFFFFFFF,
        outline_color  = 0xFF000000,
        outline_width  = 2,
        visible        = false,
        text           = '',
        bg_overlap     = 4,
        background     = { fill_color = 0xCC05080F, outline_width = 0, corner_rounding = 10, visible = true },
    }, false)
end

-- Colour changes rebuild the text texture; fade with set_opacity instead.
function M.setText(t, text, x, y, size, colorHex, outline)
    t:set_text(text)
    t:set_font_height(math.max(6, math.floor(size)))
    t:set_outline_width(outline)
    t:set_font_color(M.gdiColor(colorHex))
    t:set_position_x(math.floor(x))
    t:set_position_y(math.floor(y))
    t:set_visible(text ~= '')
end

-- First hit box ({ x, y, w, h }) under the cursor, or nil.
function M.hitAt(hits, mouse)
    if mouse == nil then return nil end
    for _, h in ipairs(hits) do
        if mouse.x >= h.x and mouse.x < h.x + h.w and mouse.y >= h.y and mouse.y < h.y + h.h then return h end
    end
    return nil
end

-- Mouse events stop when the cursor leaves the window, so the last position is checked against the client area.
local function cursorInWindow()
    local hwnd = AshitaCore:GetProperties():GetFinalFantasyHwnd()
    if hwnd == nil then return false end
    local wnd = ffi.cast('void*', hwnd)
    local pt, rect = ffi.new('POINT'), ffi.new('RECT')
    if user32.GetCursorPos(pt) == 0 or user32.ScreenToClient(wnd, pt) == 0 or user32.GetClientRect(wnd, rect) == 0 then
        return false
    end
    return pt.x >= rect.left and pt.x < rect.right and pt.y >= rect.top and pt.y < rect.bottom
end

-- Places the tooltip just right of and above the cursor; nil text, or a cursor outside the window, hides it.
function M.showTooltip(tooltip, text, mouse, s, outline)
    if text == nil or not cursorInWindow() then
        tooltip:set_visible(false)
        return
    end
    M.setText(tooltip, text, mouse.x + 14 * s, 0, 12 * s, M.COLOR_TOOLTIP, outline)
    local _, th = M.textSize(tooltip)
    tooltip:set_position_y(math.floor(mouse.y - th - 2 * s))
end

function M.textSize(t)
    local _, rect = t:get_texture()
    if rect == nil then return 0, 0 end
    return rect.right, rect.bottom
end

function M.newSprite(engine, tex)
    local spr = engine:newSprite()
    spr.visible = false
    if tex then spr.texture, spr.nativeW, spr.nativeH = tex.tex, tex.w, tex.h end
    return spr
end

function M.loadTex(engine, path)
    local tex, w, h = engine:loadImage(path)
    if tex == nil then return nil end
    return { tex = tex, w = w, h = h }
end

-- Stretches the sprite's texture over a whole-pixel rect.
function M.placeRect(spr, x, y, w, h, color)
    local px, py = math.floor(x + 0.5), math.floor(y + 0.5)
    local pw, ph = math.floor(x + w + 0.5) - px, math.floor(y + h + 0.5) - py
    if spr.texture == nil or pw <= 0 or ph <= 0 then
        spr.visible = false
        return
    end
    spr.position_x, spr.position_y = px, py
    spr.displayW, spr.displayH = pw, ph
    spr.color = color
    spr.visible = true
end

-- Draws the texture at its native size scaled by s, top-left at (x, y).
function M.placeIcon(spr, x, y, s, color)
    if spr.texture == nil then
        spr.visible = false
        return
    end
    spr.position_x, spr.position_y = math.floor(x + 0.5), math.floor(y + 0.5)
    spr.displayW = math.floor(spr.nativeW * s + 0.5)
    spr.displayH = math.floor(spr.nativeH * s + 0.5)
    spr.color = color
    spr.visible = true
end

return M
