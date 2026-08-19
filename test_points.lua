--[[
* Self-check for the map data.  Every marker's 'time' names a map that exists
* and sits inside that map's image, so a point placed on the wrong one or tagged
* by hand with a typo fails here instead of vanishing in game.  Run with any
* Lua 5.1+:
*     lua test_points.lua
--]]

-- Kept in step with TIMES in ubermap.lua.
local TIMES = {
    present = { w = 5504, h = 3072 },
    past    = { w = 4096, h = 4096 },
};

local data = assert(loadfile('points.lua'))();

local n = 0;
local function check(ic)
    -- An untagged row is a present-day one, which is how ubermap.lua reads it.
    local m = TIMES[ic.time or 'present'];
    assert(m ~= nil, ('%s: unknown time %q'):format(ic.label, tostring(ic.time)));
    assert(ic.x >= 0 and ic.x <= m.w and ic.y >= 0 and ic.y <= m.h,
           ('%s: %d,%d is outside the %s map'):format(ic.label, ic.x, ic.y, ic.time or 'present'));
    n = n + 1;
end

for _, g in ipairs(data.groups) do
    for _, ic in ipairs(g.icons) do
        check(ic);
    end
end
for _, ic in ipairs(data.points) do
    check(ic);
end

print(('points OK: %d markers'):format(n));
