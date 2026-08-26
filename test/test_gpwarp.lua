--[[
* Self-check for the gamepad's warp list.  Three things have to hold: up and
* down wrap at both ends the way the favorites widget does, A sends only a row
* that can travel -- the same two tests (the kind of NPC in reach, the
* destination registered) the row is coloured on -- and a list opened with the
* mouse lights no row until a button is pressed, so the first press lands on
* the top row instead of stepping off a selection nothing on screen shows.
* Mirrors the warp tier of nav.act in ubermap.lua.  Run with any Lua 5.1+:
*     lua test/test_gpwarp.lua
--]]

local fails = 0;
local function check(ok, msg)
    if (not ok) then
        fails = fails + 1;
        print('FAIL: ' .. msg);
    end
end

-- The list under test, and what the world looks like around it.
local rows = {
    { label = 'Home Point #1',  type = 'home'  },
    { label = 'Survival Guide', type = 'guide' },
    { label = 'Home Point #2',  type = 'home'  },
};
-- Stands in for the teleport masks: everything registered but Home Point #2.
local registered = { ['Home Point #2'] = false };
local near_kind  = 'home';
local open, row  = true, nil;

local function clamp(v, lo, hi)
    return math.max(lo, math.min(v, hi));
end

-- One press, exactly as nav.act reads it.  Hands back the row it would send,
-- or nil where it sends nothing.
local function act(a)
    local n = #rows;
    if (a == 'b') then
        open = false;
        return nil;
    end
    if (row == nil) then
        row = 1;
        return nil;
    end
    row = clamp(row, 1, n);
    if (a == 'up') then
        row = (row - 2) % n + 1;
    elseif (a == 'down') then
        row = row % n + 1;
    elseif (a == 'a') then
        local r = rows[row];
        if (r ~= nil and r.type == near_kind
            and registered[r.label] ~= false) then
            return r;
        end
    end
    return nil;
end

-- Opened with the mouse: the first press lights the top row and sends nothing,
-- rather than travelling somewhere nobody had picked.
row = nil;
check(act('a') == nil, 'the first press on a mouse-opened list should send nothing');
check(row == 1, ('the first press should light the top row, lit %s'):format(tostring(row)));

-- Down walks the list in order and comes back round to the top.
row = 1;
for i = 1, #rows do
    check(row == i, ('down should be on row %d, is %d'):format(i, row));
    act('down');
end
check(row == 1, 'down off the last row should wrap to the first');

-- Up walks it backwards, and off the first row lands on the last.
act('up');
check(row == #rows, 'up off the first row should wrap to the last');

-- Stood at a Home Point: the registered Home Point row travels.
row = 1;
check(act('a') == rows[1], 'a registered row of the kind in reach should send');

-- The Survival Guide row does not, standing at a Home Point.
row = 2;
check(act('a') == nil, 'a guide row should not send from a Home Point');

-- Nor does the Home Point nobody has ever stood at: the /uw would be turned
-- down at the NPC, and a row that looks live but does nothing reads as broken.
row = 3;
check(act('a') == nil, 'an unregistered row should take no press');

-- The toggles can empty rows out from under an open list, so a landing past
-- the end is pulled back inside it before it steps.
row = 9;
act('up');
check(row == 2, ('a stale row should be pulled back in, landed on %s'):format(tostring(row)));

-- B shuts the list whatever is lit, including nothing.
row, open = nil, true;
act('b');
check(not open, 'B should shut a list with no row lit');
row, open = 2, true;
act('b');
check(not open, 'B should shut a list with a row lit');

if (fails == 0) then
    print('ok: the row wrap, the A gate and the unlit first press all hold');
else
    print(('%d check(s) failed'):format(fails));
    os.exit(1);
end
