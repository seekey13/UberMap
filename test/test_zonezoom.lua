--[[
* Self-check for the zone map half of UberMap's view math: the quad a zone map
* is drawn in, the hand-over between it and the world map, and the glide in.
* Run with any Lua 5.1+ / LuaJIT:
*     lua test/test_zonezoom.lua
--]]

local m = assert(loadfile('lib/mapmath.lua'))();

local function near(a, b, eps)
    return math.abs(a - b) < (eps or 1e-6);
end

-- The quad is centred on the point and 'span' wide, and keeps the art's shape.
local r = m.zone_rect(1098, 1572, 120, 1);
assert(near(r.x0, 1038) and near(r.x1, 1158) and near(r.y0, 1512) and near(r.y1, 1632));
local wide = m.zone_rect(0, 0, 120, 2);
assert(near(wide.x1 - wide.x0, 120) and near(wide.y1 - wide.y0, 60));

-- u, v and world pixels are inverses, and the corners are 0 and 1.
assert(near(select(1, m.world_to_uv(r, r.x0, r.y0)), 0));
local u, v = m.world_to_uv(r, r.x1, r.y1);
assert(near(u, 1) and near(v, 1));
for _, p in ipairs({ { 0.25, 0.75 }, { 0.5, 0.5 }, { 0.03125, 0.96875 } }) do
    local wx, wy = m.uv_to_world(r, p[1], p[2]);
    local u2, v2 = m.world_to_uv(r, wx, wy);
    assert(near(u2, p[1]) and near(v2, p[2]));
end

-- A 120-wide square quad fits a 1920x1080 view at 9x: the height runs out.
local fit = m.rect_fit(r, 1920, 1080);
assert(near(fit, 9));

-- The hand-over has a dead band: on the way in it takes ZONE_ENTER of the fit,
-- and once in it holds down to ZONE_LEAVE, so resting between the two never
-- flips the image.
assert(not m.zone_hold(false, fit * 0.89, fit));
assert(m.zone_hold(false, fit * 0.9, fit));
assert(m.zone_hold(true, fit * 0.8, fit));
assert(m.zone_hold(true, fit * 0.7, fit));
assert(not m.zone_hold(true, fit * 0.69, fit));
local inside = false;
for _, k in ipairs({ 0.5, 0.95, 0.75, 0.85, 0.72, 0.8 }) do
    inside = m.zone_hold(inside, fit * k, fit);
end
assert(inside, 'wobbling inside the band let go of the zone');

-- pan_for and centre_of are inverses, and pan_for centres the coordinate.
for _, z in ipairs({ 0.3, 1, 9 }) do
    local p = m.pan_for(1098, z, 1920);
    assert(near(m.centre_of(p, z, 1920), 1098));
    assert(near(m.to_screen(1098, p, z, 0), 960));
end

-- ease is pinned at both ends, symmetric, monotonic, and clamped outside 0..1.
assert(m.ease(0) == 0 and m.ease(1) == 1 and near(m.ease(0.5), 0.5));
assert(m.ease(-1) == 0 and m.ease(2) == 1);
local last = -1;
for i = 0, 100 do
    local e = m.ease(i / 100);
    assert(e >= last);
    last = e;
    assert(near(e + m.ease(1 - i / 100), 1));
end

-- A glide lands exactly on both ends.
local a = { cx = 2048, cy = 1024, zoom = 0.3 };
local b = { cx = 1098, cy = 1572, zoom = 9 };
local cx, cy, z = m.glide(a, b, 0);
assert(near(cx, a.cx) and near(cy, a.cy) and near(z, a.zoom));
cx, cy, z = m.glide(a, b, 1);
assert(near(cx, b.cx) and near(cy, b.cy) and near(z, b.zoom));

-- The zoom climbs by a steady factor at a steady pace: halfway through the
-- glide it is at the geometric mean, not the arithmetic one.
cx, cy, z = m.glide(a, b, 0.5);
assert(near(z, math.sqrt(a.zoom * b.zoom), 1e-9));

-- Zoom and centre only ever move one way, in or out.
local lz, lx = a.zoom, a.cx;
for i = 1, 100 do
    local gx, _, gz = m.glide(a, b, i / 100);
    assert(gz >= lz - 1e-12 and gx <= lx + 1e-9);
    lz, lx = gz, gx;
end

-- The way back out is the way in, reversed.
for i = 0, 10 do
    local x1, y1, z1 = m.glide(a, b, i / 10);
    local x2, y2, z2 = m.glide(b, a, 1 - i / 10);
    assert(near(x1, x2, 1e-6) and near(y1, y2, 1e-6) and near(z1, z2, 1e-9));
end

-- A glide that does not change the zoom just pans.
cx, cy, z = m.glide({ cx = 0, cy = 0, zoom = 2 }, { cx = 100, cy = 50, zoom = 2 }, 0.5);
assert(near(z, 2) and near(cx, 50) and near(cy, 25));

-- The crossfade waits for the last stretch, then runs 0..1 across it.
assert(m.fade(0) == 0 and m.fade(0.6) == 0 and m.fade(1) == 1);
assert(near(m.fade(0.8), 0.5));
assert(near(m.fade(0.75, 0.5), 0.5));

print('test_zonezoom: ok');
