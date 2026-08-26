--[[
* UberMap - gamepad map navigation math.
*
* Which marker a direction press lands on, and which one a fresh selection
* starts at.  Kept free of Ashita/ImGui dependencies so it can be exercised
* outside the game by test_gpnav.lua, the same way lib/mapmath.lua is.  All
* coordinates are source-map pixels, y growing downwards, so 'up' is towards
* the smaller y.
--]]

local M = { };

-- How far off to the side of the pressed direction a marker is allowed to be,
-- priced as a multiple of how far off it is.  Anything above 1 prefers the
-- marker straight ahead over a nearer one to the side, which is what makes a
-- column of zone points walk like a column; too high and the far side of the
-- map stops being reachable at all.  test_gpnav.lua walks the real data at
-- this weight and finds nothing stranded on either map.
local SIDE_WEIGHT = 2;

-- Offset from the current marker -> how far ahead it is in the pressed
-- direction, and how far off to the side.  Only the first decides whether a
-- marker is a candidate, so a press never lands behind where it started.
local AXIS = {
    up    = function(dx, dy) return -dy,  dx; end,
    down  = function(dx, dy) return  dy,  dx; end,
    left  = function(dx, dy) return -dx,  dy; end,
    right = function(dx, dy) return  dx,  dy; end,
};

--[[
* The index of the marker nearest (cx, cy), or nil for an empty list.  Ties go
* to the earlier entry, so the same list and the same centre always answer the
* same way rather than picking between two by table order luck.
--]]
function M.nearest(list, cx, cy)
    local best, best_d;
    for i, ic in ipairs(list) do
        local dx, dy = ic.x - cx, ic.y - cy;
        -- Squared: the ordering is the same and there is no root to take.
        local d = dx * dx + dy * dy;
        if (best_d == nil or d < best_d) then
            best, best_d = i, d;
        end
    end
    return best;
end

--[[
* The index a press of 'dir' from list[i] lands on, or nil when nothing lies
* that way -- which leaves the selection where it is rather than wrapping round
* to the far side of the world.  A direction that is not one of the four, and
* an index that is not in the list, answer nil as well.
--]]
function M.step(list, i, dir)
    local axis = AXIS[dir];
    local cur  = list[i];
    if (axis == nil or cur == nil) then
        return nil;
    end
    local best, best_s;
    for j, ic in ipairs(list) do
        if (j ~= i) then
            local fwd, side = axis(ic.x - cur.x, ic.y - cur.y);
            if (fwd > 0) then
                local s = fwd + SIDE_WEIGHT * math.abs(side);
                if (best_s == nil or s < best_s) then
                    best, best_s = j, s;
                end
            end
        end
    end
    return best;
end

return M;
