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

--[[
* Zone maps.
*
* A zone map is not a separate view: it is drawn inside the world map, as a
* quad centred on the zone's own marker, so going into a zone is one zoom on
* one canvas rather than a cut from one image to another.  Everything below is
* in world-map pixels except u, v, which are 0..1 across the zone image.
--]]

-- A zone map takes over at ZONE_ENTER of the zoom at which its quad fits the
-- viewport, and lets go below ZONE_LEAVE, so a wheel resting near the boundary
-- does not flicker between the two images.
M.ZONE_ENTER = 0.9;
M.ZONE_LEAVE = 0.7;

--[[
* The world-space rect of a zone map centred on (cx, cy).  'span' is how many
* world pixels wide the zone lands, and 'aspect' the image's width / height, so
* a non-square map keeps its shape.
--]]
function M.zone_rect(cx, cy, span, aspect)
    local w = span;
    local h = span / (aspect or 1);
    return { x0 = cx - w / 2, y0 = cy - h / 2, x1 = cx + w / 2, y1 = cy + h / 2 };
end

-- World pixel -> 0..1 across the rect, and back.
function M.world_to_uv(r, wx, wy)
    return (wx - r.x0) / (r.x1 - r.x0), (wy - r.y0) / (r.y1 - r.y0);
end

function M.uv_to_world(r, u, v)
    return r.x0 + u * (r.x1 - r.x0), r.y0 + v * (r.y1 - r.y0);
end

-- The zoom at which the rect just fits the viewport.
function M.rect_fit(r, view_w, view_h)
    return M.fit_zoom(r.x1 - r.x0, r.y1 - r.y0, view_w, view_h);
end

--[[
* Whether the zone map holds the view.  'inside' is the answer last frame; the
* gap between ZONE_ENTER and ZONE_LEAVE is what keeps it from flickering.
--]]
function M.zone_hold(inside, zoom, fit)
    if (inside) then
        return zoom >= fit * M.ZONE_LEAVE;
    end
    return zoom >= fit * M.ZONE_ENTER;
end

-- The pan that puts world coordinate 'c' at the middle of a 'view' long span,
-- and the world coordinate a pan leaves there.  One axis at a time, like the
-- rest of this file.
function M.pan_for(c, zoom, view)
    return c * zoom - view / 2;
end

function M.centre_of(pan, zoom, view)
    return (pan + view / 2) / zoom;
end

-- Ease in and out: slow off the mark, slow into the landing.
function M.ease(t)
    t = M.clamp(t, 0, 1);
    return t * t * (3 - 2 * t);
end

--[[
* One step of a glide between two views, each { cx, cy, zoom }.  The zoom is
* walked on a log scale so every frame magnifies by the same factor, which is
* what makes a long zoom read as steady instead of lurching at the far end.
* The centre is weighted by how far the zoom has got, not by t, so the target
* drifts into the middle at the rate it grows rather than sliding past first.
--]]
function M.glide(a, b, t)
    local e  = M.ease(t);
    local la = math.log(a.zoom);
    local lb = math.log(b.zoom);
    local zoom = math.exp(la + (lb - la) * e);
    -- How much of the way the zoom has come, 0..1, in screen terms.
    local k = e;
    if (math.abs(b.zoom - a.zoom) > 1e-9) then
        k = (1 / a.zoom - 1 / zoom) / (1 / a.zoom - 1 / b.zoom);
    end
    return a.cx + (b.cx - a.cx) * k, a.cy + (b.cy - a.cy) * k, zoom;
end

--[[
* The zone image's alpha over a glide in.  The world map carries the first
* stretch on its own; the crossfade runs over the last 'span' of t.
--]]
function M.fade(t, span)
    span = span or 0.4;
    return M.clamp((t - (1 - span)) / span, 0, 1);
end

return M;
