--[[
* Self-check for UberMap's view math.  Run with any Lua 5.1+ / LuaJIT:
*     lua test_zoom.lua
--]]

local m = require('mapmath');

local function near(a, b)
    return math.abs(a - b) < 1e-6;
end

-- cover_zoom picks whichever axis needs the most magnification, so the map
-- always fills the viewport.  The map is wider than 16:9, so a 1920x1080
-- window is height-limited and the extra width pans.
assert(near(m.cover_zoom(5504, 3072, 1920, 1080), 1080 / 3072));
assert(near(m.cover_zoom(5504, 3072, 4000, 1080), 4000 / 5504));

-- At cover zoom neither axis is shorter than the viewport.
for _, view in ipairs({ { 1920, 1080 }, { 4000, 1080 }, { 800, 1200 } }) do
    local z = m.cover_zoom(5504, 3072, view[1], view[2]);
    assert(5504 * z >= view[1] - 1e-6 and 3072 * z >= view[2] - 1e-6);
end

-- fit_zoom keeps the whole span on screen: neither axis overflows, and the
-- tighter axis is the one that lands exactly on the viewport edge.
for _, view in ipairs({ { 1920, 1080 }, { 800, 1200 } }) do
    for _, span in ipairs({ { 600, 400 }, { 200, 900 }, { 240, 240 } }) do
        local z = m.fit_zoom(span[1], span[2], view[1], view[2]);
        assert(span[1] * z <= view[1] + 1e-6 and span[2] * z <= view[2] + 1e-6);
        assert(near(span[1] * z, view[1]) or near(span[2] * z, view[2]));
    end
end

-- The pan stays inside the image..
assert(near(m.clamp_pan(-50, 4000, 1920), 0));
assert(near(m.clamp_pan(9999, 4000, 1920), 2080));
-- ..and centers the image when it is smaller than the viewport.
assert(near(m.clamp_pan(0, 1000, 1920), -460));

-- A popup panel stays inside the viewport on each axis, wherever the marker it
-- is anchored on sits..
assert(near(m.clamp_box(200, 100, 0, 500), 200));
assert(near(m.clamp_box(-30, 100, 0, 500), 0));
assert(near(m.clamp_box(450, 100, 0, 500), 400));
-- ..measured from the viewport's own origin, not the screen's..
assert(near(m.clamp_box(0, 100, 60, 500), 60));
assert(near(m.clamp_box(9999, 100, 60, 500), 460));
-- ..and a panel taller than the viewport pins to the origin, so its header is
-- the part that stays on screen.
assert(near(m.clamp_box(9999, 900, 60, 500), 60));

-- Zooming keeps the map pixel under the cursor pinned in place.
local pan, cursor, z0, z1 = 300, 200, 0.5, 1.0;
local pinned = (pan + cursor) / z0;
assert(near((m.zoom_anchor(pan, cursor, z0, z1) + cursor) / z1, pinned));
assert(near((m.zoom_anchor(pan, cursor, z0, 0.25) + cursor) / 0.25, pinned));

-- Zooming by nothing moves nothing.
assert(near(m.zoom_anchor(300, 200, 0.5, 0.5), 300));

-- The image top-left reads 0,0 and one screen pixel is 1/zoom map pixels.
assert(near(m.to_map(60, 0, 0.5, 60), 0));
assert(near(m.to_map(60, 300, 0.5, 60), 600));

-- to_screen is the exact inverse of to_map, so an icon anchored at a map
-- coordinate lands back on the pixel that coordinate names.
for _, z in ipairs({ 0.05, 0.349, 1.0 }) do
    for _, pan in ipairs({ 0, 137, 4000 }) do
        assert(near(m.to_map(m.to_screen(1340, pan, z, 60), pan, z, 60), 1340));
    end
end

-- The coordinate under the cursor does not move when zooming about it, which
-- is what 'locked to the image' means.
local pan, cursor, origin, z0, z1 = 300, 200, 40, 0.5, 1.0;
local before = m.to_map(origin + cursor, pan, z0, origin);
local after  = m.to_map(origin + cursor, m.zoom_anchor(pan, cursor, z0, z1), z1, origin);
assert(near(before, after));

print('ok');
