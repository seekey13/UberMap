--[[
* Self-check for UberMap's view math.  Run with any Lua 5.1+ / LuaJIT:
*     lua test_zoom.lua
--]]

local m = require('mapmath');

local function near(a, b)
    return math.abs(a - b) < 1e-6;
end

-- fit_zoom picks whichever axis runs out of room first.  The map is wider
-- than 16:9, so a 1920x1080 window is width-limited.
assert(near(m.fit_zoom(5504, 3072, 1920, 1080), 1920 / 5504));
assert(near(m.fit_zoom(5504, 3072, 4000, 1080), 1080 / 3072));

-- The pan stays inside the image..
assert(near(m.clamp_pan(-50, 4000, 1920), 0));
assert(near(m.clamp_pan(9999, 4000, 1920), 2080));
-- ..and centers the image when it is smaller than the viewport.
assert(near(m.clamp_pan(0, 1000, 1920), -460));

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

-- The coordinate under the cursor does not move when zooming about it, which
-- is what 'locked to the image' means.
local pan, cursor, origin, z0, z1 = 300, 200, 40, 0.5, 1.0;
local before = m.to_map(origin + cursor, pan, z0, origin);
local after  = m.to_map(origin + cursor, m.zoom_anchor(pan, cursor, z0, z1), z1, origin);
assert(near(before, after));

print('ok');
