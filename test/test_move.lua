--[[
* Self-check for the close-on-movement rule.  The map is meant to shut once the
* player has walked MOVE_CLOSE from where it was opened, measured against that
* spot rather than the last frame so a slow walk still adds up.  Mirrors
* player_moved in ubermap.lua against a stubbed position.  Run with any Lua 5.1+:
*     lua test/test_move.lua
--]]

local MOVE_CLOSE = 1.0;

local ui  = { open_x = nil, open_z = nil };
local pos = { x = 0.0, z = 0.0 };  -- stands in for the entity manager

local function player_moved()
    local x, z = pos.x, pos.z;
    if (ui.open_x == nil) then
        ui.open_x, ui.open_z = x, z;
        return false;
    end
    local dx, dz = x - ui.open_x, z - ui.open_z;
    return dx * dx + dz * dz > MOVE_CLOSE * MOVE_CLOSE;
end

-- Opening re-anchors, so the walk taken before the map went up does not count.
local function show()
    ui.open_x, ui.open_z = nil, nil;
end

local function check(want, msg)
    local got = player_moved();
    assert(got == want, ('%s: wanted %s, got %s'):format(msg, tostring(want), tostring(got)));
end

-- The first frame after opening only records the spot, even mid-run.
pos.x, pos.z = 100.0, 200.0;
show();
check(false, 'first frame after opening');

-- Standing still, and the jitter of a step short of the radius, keep it up.
check(false, 'standing still');
pos.x = 100.5;
check(false, 'half a yalm');
pos.x, pos.z = 100.6, 200.6;  -- 0.849 away, still inside
check(false, 'diagonal nudge inside the radius');

-- A walk past the radius closes it, whether taken in one frame or several.
pos.x, pos.z = 101.5, 200.0;
check(true, 'a yalm and a half out');
pos.x, pos.z = 100.0, 198.0;
check(true, 'two yalms back the other way');

-- Re-opening at the new spot starts the count over.
show();
check(false, 're-opened at the spot walked to');
pos.z = 197.5;
check(false, 'half a yalm from the new spot');

-- A zone line jumps the position, which reads as movement and shuts the map.
pos.x, pos.z = -400.0, 12.0;
check(true, 'zoned');

print('test_move: ok');
