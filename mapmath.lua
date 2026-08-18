--[[
* UberMap - map view math.
*
* Kept free of Ashita/D3D dependencies so it can be exercised outside the game
* by test_zoom.lua.  All values are in screen pixels unless noted.
--]]

local M = { };

--[[
* Returns the zoom at which the whole map fits inside the viewport.  This is
* also the minimum zoom, so the map can never shrink away from the frame.
--]]
function M.fit_zoom(map_w, map_h, view_w, view_h)
    return math.min(view_w / map_w, view_h / map_h);
end

function M.clamp(v, lo, hi)
    return math.max(lo, math.min(v, hi));
end

--[[
* Keeps the pan inside the drawn image.  When the image is smaller than the
* viewport on this axis the pan goes negative, which centers it.
--]]
function M.clamp_pan(pan, content, view)
    if (content <= view) then
        return (content - view) / 2;
    end
    return M.clamp(pan, 0, content - view);
end

--[[
* Returns the pan that keeps the map pixel under the cursor pinned in place
* across a zoom change.  'cursor' is relative to the viewport's top-left.
--]]
function M.zoom_anchor(pan, cursor, old_zoom, new_zoom)
    return ((pan + cursor) / old_zoom) * new_zoom - cursor;
end

return M;
