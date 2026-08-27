--[[
* Self-check for the gamepad's warp list.  Three things have to hold: up and
* down wrap at both ends the way the favorites widget does, a list opened with
* the mouse lights no row until a button is pressed -- so the first press lands
* on the top row instead of stepping off a selection nothing on screen shows --
* and A sends only a row that can travel, the same two tests (the kind of NPC
* in reach, the destination registered) the row is coloured on.
*
* The first two are gpnav.row itself, driven here rather than copied.  The
* third is the gate nav.act puts around what gpnav answers, which needs the
* map's own warp_known and so is the one thing mirrored below.  Run with any
* Lua 5.1+:
*     lua test/test_gpwarp.lua
--]]

local gp = assert(loadfile('lib/gpnav.lua'))();

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

-- One press: gpnav says which row it leaves lit and whether it was a send, and
-- the two tests around it say whether that row travels.  Hands back the row
-- and the row it would send, or nil where it sends nothing.
local function press(row, act)
    local next_row, send = gp.row(row, #rows, act);
    if (not send) then
        return next_row, nil;
    end
    local r = rows[next_row];
    if (r ~= nil and r.type == near_kind and registered[r.label] ~= false) then
        return next_row, r;
    end
    return next_row, nil;
end

-- Opened with the mouse: the first press lights the top row and sends nothing,
-- rather than travelling somewhere nobody had picked.
local row, sent = press(nil, 'a');
check(sent == nil, 'the first press on a mouse-opened list should send nothing');
check(row == 1, ('the first press should light the top row, lit %s'):format(tostring(row)));

-- Down walks the list in order and comes back round to the top.
row = 1;
for i = 1, #rows do
    check(row == i, ('down should be on row %d, is %d'):format(i, row));
    row = press(row, 'down');
end
check(row == 1, 'down off the last row should wrap to the first');

-- Up walks it backwards, and off the first row lands on the last.
row = press(row, 'up');
check(row == #rows, 'up off the first row should wrap to the last');

-- Stood at a Home Point: the registered Home Point row travels.
local _, r1 = press(1, 'a');
check(r1 == rows[1], 'a registered row of the kind in reach should send');

-- The Survival Guide row does not, standing at a Home Point.
local _, r2 = press(2, 'a');
check(r2 == nil, 'a guide row should not send from a Home Point');

-- Nor does the Home Point nobody has ever stood at: the /uw would be turned
-- down at the NPC, and a row that looks live but does nothing reads as broken.
local _, r3 = press(3, 'a');
check(r3 == nil, 'an unregistered row should take no press');

-- A press that is neither a direction nor A leaves the row where it is.
check(press(2, 'b') == 2, 'a press that is not a direction should not step');

-- The toggles can empty rows out from under an open list, so a landing past
-- the end is pulled back inside it before it steps, and before it sends.
local stale = press(9, 'up');
check(stale == 2, ('a stale row should be pulled back in, landed on %s'):format(tostring(stale)));
check(press(9, 'a') == #rows, 'a stale row should send from the last row, not past it');

-- Emptied out entirely, there is no row to light at all: the arithmetic that
-- wraps a list of none would divide by it.
check(gp.row(2, 0, 'down') == nil, 'an empty list should light no row');

-- Y is the pad's right-click, and the favorites menu it opens sits inside even
-- the warp list: while it is up every press is its own.  Both branches are
-- nav.act's rather than gpnav's, so they are mirrored here the same way the A
-- gate above is.  The favorites themselves stand in as a set of keys.
local ctx, favs = nil, { };
local function pad(row, act)
    if (ctx ~= nil) then
        if (act == 'a') then
            favs[ctx] = not favs[ctx];
        end
        if (act == 'a' or act == 'b' or act == 'y') then
            ctx = nil;
        end
        return row;
    end
    if (act == 'y') then
        local r = (row ~= nil) and rows[row] or nil;
        if (r ~= nil) then
            ctx = 'zone|' .. r.label;
        end
        return row;
    end
    return (gp.row(row, #rows, act));
end

-- A list opened with the mouse lights no row, so Y has nothing to point at and
-- opens nothing rather than a menu on a row nobody picked.
check(pad(nil, 'y') == nil and ctx == nil,
      'Y on an unlit list should open no menu');

-- On a lit row it opens the menu on that row, and leaves the row where it is.
check(pad(2, 'y') == 2, 'Y should not step the row');
check(ctx == 'zone|Survival Guide',
      ('Y should open the menu on the lit row, opened %s'):format(tostring(ctx)));

-- With the menu up, the list underneath does not walk about behind it.
check(pad(2, 'down') == 2, 'the list should not step under an open menu');
check(ctx ~= nil, 'a direction should not dismiss the menu');

-- A picks the one item, which adds the row, and closes.
pad(2, 'a');
check(favs['zone|Survival Guide'], 'A should toggle the row into favorites');
check(ctx == nil, 'A should close the menu');

-- B closes it without picking: the row stays saved rather than coming back off.
pad(2, 'y');
pad(2, 'b');
check(favs['zone|Survival Guide'], 'B should leave the favorites alone');
check(ctx == nil, 'B should close the menu');

-- A second Y dismisses it, the way a second right-click does.
pad(2, 'y');
pad(2, 'y');
check(ctx == nil, 'a second Y should dismiss the menu');

-- On a row already saved the item removes it, so the one menu is both ways.
pad(2, 'y');
pad(2, 'a');
check(not favs['zone|Survival Guide'], 'A on a saved row should take it back off');

if (fails == 0) then
    print('ok: the row wrap, the A gate, the unlit first press and Y all hold');
else
    print(('%d check(s) failed'):format(fails));
    os.exit(1);
end
