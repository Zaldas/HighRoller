-- drag.lua
-- Click-and-drag repositioning of an overlay's anchor.

local draw = require('ui/draw')

local Drag = {}
Drag.__index = Drag

function Drag.new()
    return setmetatable({ active = false, moved = false, offX = 0, offY = 0 }, Drag)
end

-- bounds: the overlay's box; w == 0 while it is hidden. Returns true when a drag that moved the
-- anchor ended and the anchor should be saved. A started drag blocks its button-up even if the
-- overlay hides or locks mid-drag, so the game never sees an unpaired release. A button-down
-- during a drag means the release was missed (outside the window); the stale drag ends and the
-- press is handled afresh.
function Drag:handle(e, anchor, bounds, locked)
    if e.message == 514 then
        if not self.active then return false end
        self.active = false
        e.blocked = true
        return self.moved
    end
    if self.active and e.message == 512 then
        local x, y = e.x - self.offX, e.y - self.offY
        if not locked and bounds.w > 0 and (x ~= anchor.x or y ~= anchor.y) then
            anchor.x, anchor.y = x, y
            self.moved = true
        end
        e.blocked = true
        return false
    end
    if e.message ~= 513 then return false end
    local ended = self.active and self.moved
    self.active = false
    -- Another overlay or an ImGui window took the press
    if e.blocked or locked or bounds.w == 0 or draw.uiHasMouse() then return ended end
    if draw.hitAt({ bounds }, e) then
        self.active = true
        self.moved = false
        self.offX = e.x - anchor.x
        self.offY = e.y - anchor.y
        e.blocked = true
    end
    return ended
end

return Drag
