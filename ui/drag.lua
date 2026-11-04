-- drag.lua
-- Click-and-drag repositioning of an overlay's anchor.

local imgui = require('imgui')
local draw  = require('ui/draw')

local Drag = {}
Drag.__index = Drag

function Drag.new()
    return setmetatable({ active = false, offX = 0, offY = 0 }, Drag)
end

-- bounds: the overlay's box; w == 0 while it is hidden. Returns true when a drag ended and the
-- anchor should be saved. A started drag blocks its button-up even if the overlay hides or locks
-- mid-drag, so the game never sees an unpaired release. A button-down during a drag means the
-- release was missed (outside the window); the stale drag ends and the press is handled afresh.
function Drag:handle(e, anchor, bounds, locked)
    if e.message == 514 then
        if not self.active then return false end
        self.active = false
        e.blocked = true
        return true
    end
    if self.active and e.message == 512 then
        if not locked and bounds.w > 0 then
            anchor.x = e.x - self.offX
            anchor.y = e.y - self.offY
        end
        e.blocked = true
        return false
    end
    if e.message ~= 513 then return false end
    local ended = self.active
    self.active = false
    -- Another overlay or an ImGui window took the press
    if e.blocked or locked or bounds.w == 0 then return ended end
    local io = imgui.GetIO()
    if io ~= nil and io.WantCaptureMouse then return ended end
    if draw.hitAt({ bounds }, e) then
        self.active = true
        self.offX = e.x - anchor.x
        self.offY = e.y - anchor.y
        e.blocked = true
    end
    return ended
end

return Drag
