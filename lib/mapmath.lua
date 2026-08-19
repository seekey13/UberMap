--[[
* UberMap - map view math.
*
* Kept free of Ashita/D3D dependencies so it can be exercised outside the game
* by test_zoom.lua.  All values are in screen pixels unless noted.
--]]

local M = { };

--[[
* Returns the zoom at which the map covers the whole viewport.  This is also
* the minimum zoom, so the frame is never letterboxed: the short side is what
* runs out of room first, and the long side overflows and pans.
--]]
function M.cover_zoom(map_w, map_h, view_w, view_h)
    return math.max(view_w / map_w, view_h / map_h);
end

--[[
* Returns the zoom at which a map_w x map_h span fits inside the viewport.  The
* opposite of cover_zoom: the long side is what runs out of room first, so the
* whole span stays visible and the short side gets slack.
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
* Keeps a panel of 'size' inside the 'view' long span that starts at 'origin',
* on one axis.  A panel too big for the span pins to the origin, so its head
* stays on screen and its tail is what runs off.
--]]
function M.clamp_box(v, size, origin, view)
    return math.max(origin, math.min(v, origin + view - size));
end

--[[
* Returns the pan that keeps the map pixel under the cursor pinned in place
* across a zoom change.  'cursor' is relative to the viewport's top-left.
--]]
function M.zoom_anchor(pan, cursor, old_zoom, new_zoom)
    return ((pan + cursor) / old_zoom) * new_zoom - cursor;
end

--[[
* Source-image pixel -> screen pixel.  The inverse of to_map.
--]]
function M.to_screen(map_v, pan, zoom, origin)
    return origin - pan + map_v * zoom;
end

--[[
* Screen pixel -> source-image pixel.  'origin' is the viewport's top-left.
* The result is locked to the image: the same spot on the map returns the same
* coordinate at any zoom or pan.
--]]
function M.to_map(screen_v, pan, zoom, origin)
    return (screen_v - origin + pan) / zoom;
end

return M;
