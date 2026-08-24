--[[
* Self-check for the gamepad favorites widget.  The widget is a list the D-pad
* walks and A sends, so two things have to hold: the selection wraps at both
* ends and never leaves the list however many presses it takes, and a row that
* cannot travel takes no press -- the same two tests (right kind of NPC in
* reach, destination registered) the panel colours a row on.  Mirrors
* fw_state/fw_confirm and the xinput handler in ubermap.lua.  Run with any
* Lua 5.1+:
*     lua test/test_widget.lua
--]]

local fails = 0;
local function check(ok, msg)
    if (not ok) then
        fails = fails + 1;
        print('FAIL: ' .. msg);
    end
end

-- The list under test, and what the world looks like around it.
local favs = {
    { key = 'Windurst Woods',  type = 'home',  label = 'Home Point #2 (E)' },
    { key = 'Port Bastok',     type = 'home',  label = 'Home Point #1 (E)' },
    { key = 'Qufim Island',    type = 'guide', label = 'Survival Guide' },
    { key = 'Valkurm Dunes',   type = 'unity', label = 'Unity Concord' },
};
-- Stands in for unlocks.known: everything registered but the Bastok row.
local registered = { ['Port Bastok'] = false };
local function known(f)
    return registered[f.key] ~= false;
end

local near_kind = 'home';
local sel       = 1;

local function fw_state(f)
    return (f.type == near_kind) and known(f);
end

-- The two D-pad steps, exactly as the handler writes them.
local function up()   sel = (sel - 2) % #favs + 1; end
local function down() sel = sel % #favs + 1; end

-- A returns the row it would send, or nil where it refuses.
local function confirm()
    local f = favs[sel];
    if (f == nil or not fw_state(f)) then
        return nil;
    end
    return f;
end

-- Down walks the list in order and comes back round to the top.
for i = 1, #favs do
    check(sel == i, ('down should be on row %d, is %d'):format(i, sel));
    down();
end
check(sel == 1, 'down off the last row should wrap to the first');

-- Up walks it backwards, and off the first row lands on the last.
up();
check(sel == #favs, 'up off the first row should wrap to the last');
for i = #favs, 1, -1 do
    check(sel == i, ('up should be on row %d, is %d'):format(i, sel));
    up();
end

-- However long the D-pad is held down on, the selection stays a real row: the
-- confirm indexes cfg.favs with it directly.
sel = 1;
for _ = 1, #favs * 7 + 3 do
    down();
    check(favs[sel] ~= nil, 'the selection should always name a row');
end
sel = 1;
for _ = 1, #favs * 7 + 3 do
    up();
    check(favs[sel] ~= nil, 'the selection should always name a row');
end

-- Standing at a Home Point: the registered Home Point row travels.
near_kind, sel = 'home', 1;
check(confirm() == favs[1], 'a registered row of the kind in reach should send');

-- The Home Point the player has never stood at does not, whatever colour it
-- draws: the /uw would be turned down at the NPC.
sel = 2;
check(confirm() == nil, 'an unregistered row should take no press');

-- Nor do the rows saved off a different kind of NPC, standing here.
sel = 3;
check(confirm() == nil, 'a Survival Guide row should not send from a Home Point');
sel = 4;
check(confirm() == nil, 'a Unity row should not send from a Home Point');

-- Walk to the Survival Guide and the answers swap over.
near_kind, sel = 'guide', 3;
check(confirm() == favs[3], 'the guide row should send from a Survival Guide');
sel = 1;
check(confirm() == nil, 'a Home Point row should not send from a Survival Guide');

-- Away from every warp NPC nothing sends.  near_kind is nil there, and no
-- row's type is nil, so the widget is never up with a live row under it.
near_kind = nil;
for i = 1, #favs do
    sel = i;
    check(confirm() == nil, 'nothing should send away from a warp NPC');
end

if (fails == 0) then
    print(('ok: %d rows, D-pad wrap and the A-button gate all hold'):format(#favs));
else
    print(('%d check(s) failed'):format(fails));
    os.exit(1);
end
