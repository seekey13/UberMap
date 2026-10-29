--[[
* Self-check for the gamepad favorites widget.  The widget is a list the D-pad
* walks and A sends, so two things have to hold: the selection wraps at both
* ends rather than running off either, and a row that cannot travel takes no
* press -- the same two tests (right kind of NPC in reach, destination
* registered) the panel colours a row on.  Mirrors fw.send and the xinput
* handler in ubermap.lua.  Then the widget's own list, the real fw.view: a
* Cancel row on top, and favorites that share a zone folded into one row.
* Run with any Lua 5.1+:
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

--[[
* The widget's own list, fw.view: the Cancel row and the zone groups.  Lifted
* out of ubermap.lua and run, rather than copied here, with the three things it
* reads from the addon stood in for: cfg's two checkboxes, and fav_view.
--]]
local src  = assert(io.open('ubermap.lua')):read('*a');
local body = src:match('\n(function fw%.view%(%).-\nend)\n');
check(body ~= nil, 'fw.view is no longer written as one function');

local saved = {
    { key = 'Lower Jeuno',    type = 'home', label = 'Home Point #1' },
    { key = 'Port Jeuno',     type = 'home', label = 'Home Point #1' },
    { key = 'Lower Jeuno',    type = 'home', label = 'Home Point #2' },
    { key = 'Windurst Woods', type = 'home', label = 'Home Point #1' },
    { key = 'Lower Jeuno',    type = 'home', label = 'Home Point #3' },
};
local cfg = { fw_cancel = false, fw_group = false };
local fw  = { CANCEL = { cancel = true } };
local env = { fw = fw, cfg = cfg, ipairs = ipairs,
              T = function (t) return t; end,
              -- Unnarrowed, so each row's slot is its place in the list.
              fav_view = function () return saved, nil; end };
local chunk;
if (setfenv ~= nil) then
    chunk = assert(loadstring(body or ''));
    setfenv(chunk, env);
else
    chunk = assert(load(body or '', 'fw.view', 't', env));
end
chunk();

local function reorder(i, j)
    table.insert(saved, j, table.remove(saved, i));
end

-- Both off: the list as it always was, a slot per row.
local v, slot = fw.view();
check(#v == 5, ('both off should list every row, lists %d'):format(#v));
for i = 1, 5 do
    check(v[i] == saved[i] and slot[i] == i,
          ('both off, row %d should be itself in its own slot'):format(i));
end

-- Cancel on: one row on top, with no slot to drag or drop on, and the rest
-- one further down.
cfg.fw_cancel = true;
v, slot = fw.view();
check(#v == 6, ('Cancel should add one row, lists %d'):format(#v));
check(v[1] == fw.CANCEL and slot[1] == nil, 'Cancel should head the list, slotless');
check(v[2] == saved[1] and slot[2] == 1, 'the first favorite should be second');

-- Grouping on: Lower Jeuno's three fold into one row where the first of them
-- was, and the zones with one favorite read as they always have.
cfg.fw_group = true;
v, slot = fw.view();
check(#v == 4, ('Cancel and three zones should be four rows, lists %d'):format(#v));
local g = v[2];
check(g.members ~= nil and g.key == 'Lower Jeuno' and g.type == 'home',
      'Lower Jeuno should be one group row, second');
check(#g.members == 3, ('the group should hold three, holds %d'):format(#g.members));
check(g.members[1] == saved[1] and g.members[2] == saved[3]
      and g.members[3] == saved[5], 'the group should keep the saved order');
check(g.slots[1] == 1 and g.slots[2] == 3 and g.slots[3] == 5,
      'each member should carry its own slot');
check(slot[2] == 1, 'the group should sit in its first member\'s slot');
check(v[3] == saved[2] and v[4] == saved[4], 'the lone rows should follow in order');

-- A lone row dragged up onto the group lands above it, in both lists.
reorder(slot[4], slot[2]);
v, slot = fw.view();
check(v[2].key == 'Windurst Woods' and v[3].members ~= nil,
      'a row dropped up onto the group should land above it');
-- And dragged back down onto it, below it.
reorder(slot[2], slot[3]);
v, slot = fw.view();
check(v[2].members ~= nil and v[3].key == 'Windurst Woods',
      'a row dropped down onto the group should land below it');

-- Two in a zone is a group; take them down to one and it is a plain row again.
-- The saved list is Lower Jeuno #1, Windurst, Port Jeuno, Lower Jeuno #2 and
-- #3 by now; this leaves Windurst, Port Jeuno and Lower Jeuno #2.
table.remove(saved, 5);
table.remove(saved, 1);
v = fw.view();
check(#v == 4, ('three lone rows and Cancel should be four, lists %d'):format(#v));
check(v[4] ~= nil and v[4].key == 'Lower Jeuno' and v[4].members == nil,
      'one Lower Jeuno left should be a plain row');

-- The highlight follows the zone's row.  Moving the group's first member past
-- another zone changes which row the group sits on; B reads fw_sel once the
-- panel is shut, so a stale index warps to whatever slid into it.
for i = #saved, 1, -1 do saved[i] = nil; end
local fresh = {
    { key = 'Lower Jeuno', type = 'home', label = 'Home Point #1' },
    { key = 'Port Jeuno',  type = 'home', label = 'Home Point #1' },
    { key = 'Lower Jeuno', type = 'home', label = 'Home Point #2' },
    { key = 'Lower Jeuno', type = 'home', label = 'Home Point #3' },
};
for i, f in ipairs(fresh) do saved[i] = f; end
cfg.fw_cancel, cfg.fw_group = false, true;
local ui = { fw_grp = 'Lower Jeuno', fw_sel = 4, fw_sub = 1 };
env.ui = ui;
local gbody = src:match('\n(function fw%.group_open%(%).-\nend)\n');
check(gbody ~= nil, 'fw.group_open is no longer written as one function');
local gchunk;
if (setfenv ~= nil) then
    gchunk = assert(loadstring(gbody or ''));
    setfenv(gchunk, env);
else
    gchunk = assert(load(gbody or '', 'fw.group_open', 't', env));
end
gchunk();

local open, gi = fw.group_open();
check(open ~= nil and gi == 1,
      ('the group should be row 1, is %s'):format(tostring(gi)));
check(ui.fw_sel == 1,
      ('the highlight should move onto the group, is %d'):format(ui.fw_sel));

-- The first member dragged down one row inside the panel.  It passes Port
-- Jeuno, so the group row moves from 1 to 2.
v, slot = fw.view();
reorder(slot[1], v[1].slots[2]);
open, gi = fw.group_open();
check(gi == 2,
      ('the group should follow its first member to row 2, is %s'):format(tostring(gi)));
check(ui.fw_sel == 2,
      ('the highlight should follow it, is %d'):format(ui.fw_sel));
check(open ~= nil and open.members[1].label == 'Home Point #2',
      'the panel should list the member that is now first');

-- Removed down to one favorite in the zone: the panel shuts onto that row.
table.remove(saved, 4);
table.remove(saved, 3);
open, gi = fw.group_open();
check(open == nil and ui.fw_grp == nil, 'one member left should shut the group');
check(ui.fw_sel == 2,
      ('the highlight should land on the plain row, is %d'):format(ui.fw_sel));
check(fw.view()[ui.fw_sel].key == 'Lower Jeuno',
      'that row should be the Lower Jeuno that is left');

-- Nothing of the zone left: the group shuts, and the draw's clamp is what
-- pulls a dangling index back onto the list.
table.remove(saved, 2);
ui.fw_grp, ui.fw_sel = 'Lower Jeuno', 2;
open = fw.group_open();
check(open == nil and ui.fw_grp == nil, 'a zone with nothing left should shut');
check(ui.fw_sel == 2,
      ('a missing zone should leave the index for the clamp, is %d'):format(ui.fw_sel));

--[[
* A zone group dragged in the widget's list: fw.reorder, lifted the same way,
* moves every member as one run so the group lands on the row it was dragged
* to.  drag() is draw_fav_list's branch -- the slot it lands by, fw.drop_slot's
* when it comes down onto a group, then a group by its members' slots and a
* lone row by its own.
--]]
env.table = table;
for _, name in ipairs({ 'reorder', 'drop_slot' }) do
    local rbody = src:match('\n(function fw%.' .. name .. '%(.-\nend)\n');
    check(rbody ~= nil, 'fw.' .. name .. ' is no longer written as one function');
    local rchunk;
    if (setfenv ~= nil) then
        rchunk = assert(loadstring(rbody or ''));
        setfenv(rchunk, env);
    else
        rchunk = assert(load(rbody or '', 'fw.' .. name, 't', env));
    end
    rchunk();
end

local function drag(i, j)
    local dv, ds = fw.view();
    local to = ds[j];
    if (j > i and dv[j].members ~= nil) then
        to = fw.drop_slot(dv[j], ds[j + 1]);
    end
    if (dv[i].members ~= nil) then
        fw.reorder(dv[i].slots, to);
    else
        reorder(ds[i], to);
    end
end
-- The zones the widget lists, top to bottom, a group read as its zone.
local function zones()
    local out = { };
    for i, f in ipairs(fw.view()) do
        out[i] = f.key;
    end
    return table.concat(out, ', ');
end
local function refill(list)
    for i = #saved, 1, -1 do saved[i] = nil; end
    for i, f in ipairs(list) do saved[i] = f; end
end

local LJ1 = { key = 'Lower Jeuno',    type = 'home',  label = 'Home Point #1' };
local LJ2 = { key = 'Lower Jeuno',    type = 'home',  label = 'Home Point #2' };
local LJ3 = { key = 'Lower Jeuno',    type = 'home',  label = 'Home Point #3' };
local PJ  = { key = 'Port Jeuno',     type = 'home',  label = 'Home Point #1' };
local WW1 = { key = 'Windurst Woods', type = 'home',  label = 'Home Point #1' };
local WW2 = { key = 'Windurst Woods', type = 'home',  label = 'Home Point #2' };
local PB  = { key = 'Port Bastok',    type = 'home',  label = 'Home Point #1' };
local QI  = { key = 'Qufim Island',   type = 'guide', label = 'Survival Guide' };
refill({ LJ1, PJ, LJ2, WW1, LJ3, PB, WW2 });
cfg.favs, cfg.fw_cancel, cfg.fw_group = saved, false, true;
check(zones() == 'Lower Jeuno, Port Jeuno, Windurst Woods, Port Bastok',
      'the groups should start where their first members are');

-- Down one row, past a lone row.
drag(1, 2);
check(zones() == 'Port Jeuno, Lower Jeuno, Windurst Woods, Port Bastok',
      'a group dragged down one should land one down, lists ' .. zones());
local dv = fw.view();
check(dv[2].members ~= nil and dv[2].members[1] == LJ1
      and dv[2].members[2] == LJ2 and dv[2].members[3] == LJ3,
      'the group should keep its members, in their order');
check(dv[3].members ~= nil and #dv[3].members == 2,
      'the group passed over should keep both of its members');

-- Down past another group, then on to the bottom two rows at once.
drag(2, 3);
check(zones() == 'Port Jeuno, Windurst Woods, Lower Jeuno, Port Bastok',
      'a group dragged down past a group should land below it, lists ' .. zones());
drag(2, 4);
check(zones() == 'Port Jeuno, Lower Jeuno, Port Bastok, Windurst Woods',
      'a group dragged two rows at once should land two down, lists ' .. zones());

-- And back up to the top.
drag(4, 1);
check(zones() == 'Windurst Woods, Port Jeuno, Lower Jeuno, Port Bastok',
      'a group dragged up should land above the row it was dropped on, lists '
      .. zones());
check(#saved == 7, ('a drag should keep every favorite, has %d'):format(#saved));

-- Narrowed to the NPC in reach: a favorite of another kind sits between the
-- rows the widget lists, and stays put while the group moves past it.
local all_view = env.fav_view;
env.fav_view = function ()
    local view, raw = { }, { };
    for i, f in ipairs(saved) do
        if (f.type == 'home') then
            view[#view + 1], raw[#raw + 1] = f, i;
        end
    end
    return view, raw;
end
refill({ LJ1, QI, PJ, LJ2 });
drag(1, 2);
check(zones() == 'Port Jeuno, Lower Jeuno',
      'a narrowed group should move past the row it was dropped on, lists '
      .. zones());
check(saved[1] == QI and saved[2] == PJ and saved[3] == LJ1 and saved[4] == LJ2,
      'the row of another kind should keep its place');
env.fav_view = all_view;

-- Down onto a zone group lands below the whole zone, a lone row and a group
-- alike.  Below its first member alone the widget would read the same, and
-- the heart's list, which shows the saved list row by row, the zone split.
refill({ WW1, WW2, LJ1, LJ2 });
drag(1, 2);
check(saved[1] == LJ1 and saved[2] == LJ2 and saved[3] == WW1 and saved[4] == WW2,
      'a group dropped down onto a group should land below all of it');
refill({ PJ, LJ1, LJ2 });
drag(1, 2);
check(saved[1] == LJ1 and saved[2] == LJ2 and saved[3] == PJ,
      'a row dropped down onto a group should land below all of it');
-- A member saved past the row listed under the group is in the group all the
-- same, but the drop stops short of it: below it is below that row too.
refill({ PJ, LJ1, PB, LJ2 });
drag(1, 2);
check(zones() == 'Lower Jeuno, Port Jeuno, Port Bastok',
      'a row dropped onto a split group should land right under it, lists '
      .. zones());
check(saved[1] == LJ1 and saved[2] == PJ and saved[3] == PB and saved[4] == LJ2,
      'a row dropped onto a split group should not pass the row under it');

-- The panel is drawn at the group's row, which moves when its first member
-- does.  A drag holds the panel where it started so the next frame cannot
-- reorder a different row.  ImGui is what places it; this only checks the
-- hold is still there.
check(src:find('held.anchor_y', 1, true) ~= nil,
      'a group drag no longer holds the panel where it started');

--[[
* The zone's homepoints, listed above the favorites.  fw.zone_rows is what the
* real widget asks the world for; stood in for here, the way fav_view is.
* The highlight starts where the favorites do, so Up from there is the zone
* and Down from there is the rest of the list.
--]]
local function step_up(sel, n)   return (sel - 2) % n + 1; end
local function step_down(sel, n) return sel % n + 1; end

fw.zone_rows = function ()
    return {
        { key = 'Bastok Markets', type = 'home', label = 'Home Point #1', here = true },
        { key = 'Bastok Markets', type = 'home', label = 'Home Point #2', here = true },
    };
end
refill({ LJ1, PJ });
cfg.fw_cancel, cfg.fw_group = false, false;
v, slot = fw.view();
check(#v == 4, ('two zone rows and two favorites should be four, lists %d'):format(#v));
check(v[1].here and v[1].label == 'Home Point #1'
      and v[2].here and v[2].label == 'Home Point #2',
      'the zone\'s homepoints should head the list, in their order');
check(slot[1] == nil and slot[2] == nil,
      'a zone homepoint should have no slot to drag by');
check(v[3] == LJ1 and slot[3] == 1 and v[4] == PJ and slot[4] == 2,
      'the favorites should follow, in their own slots');
check(ui.fw_home == 3 and ui.fw_zone_n == 2,
      ('the favorites should start at row 3, home %s zone %s'):format(
          tostring(ui.fw_home), tostring(ui.fw_zone_n)));
check(step_up(ui.fw_home, #v) == 2 and v[2].here,
      'Up from the first favorite should land on the last zone homepoint');
check(step_down(ui.fw_home, #v) == 4 and v[4] == PJ,
      'Down from the first favorite should walk the favorites');

-- Cancel sits on that same seam, under the zone and over the favorites, and
-- the highlight starts on it: Up is still the zone, Down is still the list.
cfg.fw_cancel = true;
v, slot = fw.view();
check(v[3] == fw.CANCEL and slot[3] == nil,
      'Cancel should sit under the zone rows');
check(ui.fw_home == 3 and v[ui.fw_home] == fw.CANCEL,
      'the highlight should start on Cancel');
check(step_up(ui.fw_home, #v) == 2 and v[2].here,
      'Up from Cancel should land on the last zone homepoint');
check(step_down(ui.fw_home, #v) == 4 and v[4] == LJ1,
      'Down from Cancel should land on the first favorite');

-- Grouping folds favorites, not the zone rows above them, even when a zone
-- row shares a favorite's name.
cfg.fw_cancel, cfg.fw_group = false, true;
refill({ LJ1, LJ2, PJ });
fw.zone_rows = function ()
    return {
        { key = 'Lower Jeuno', type = 'home', label = 'Home Point #1', here = true },
        { key = 'Lower Jeuno', type = 'home', label = 'Home Point #2', here = true },
    };
end
v = fw.view();
check(v[1].here and v[2].here and v[1].members == nil,
      'zone rows should stay plain rows, not a group');
check(v[3].members ~= nil and v[3].key == 'Lower Jeuno' and v[4] == PJ,
      'the favorites should still fold under the zone rows');
check(ui.fw_home == 3, 'the favorites should still start under the zone rows');

-- A group that collapses must not land on a zone row that shares its name:
-- that row is not the favorite that was left.
fw.zone_rows = function ()
    return {
        { key = 'Lower Jeuno', type = 'home', label = 'Home Point #2', here = true },
    };
end
refill({ LJ1 });
cfg.fw_group = false;
ui.fw_grp, ui.fw_sel = 'Lower Jeuno', 1;
open = fw.group_open();
check(open == nil and ui.fw_grp == nil, 'a zone row is not a group to keep open');
check(ui.fw_sel == 2 and fw.view()[ui.fw_sel] == LJ1,
      ('a collapsed group should land on the favorite, is %s'):format(
          tostring(ui.fw_sel)));

-- Nothing but the zone: the highlight starts on the first homepoint rather
-- than one past the end of the list.
fw.zone_rows = function ()
    return {
        { key = 'Bastok Markets', type = 'home', label = 'Home Point #1', here = true },
    };
end
refill({});
cfg.fw_cancel = false;
v = fw.view();
check(#v == 1 and v[1].here and ui.fw_home == 1,
      'a list of only homepoints should start on the first');

--[[
* Which rows of the warp list count as this zone's homepoints.  The real
* lib/warps.lua, so a marker that is not the game's name for the zone -- and
* a list shared by two markers -- is checked against the file, not a copy.
--]]
local zbody = src:match('\n(function fw%.zone_list%(.-\nend)\n');
check(zbody ~= nil, 'fw.zone_list is no longer written as one function');
local zchunk;
if (setfenv ~= nil) then
    zchunk = assert(loadstring(zbody or ''));
    setfenv(zchunk, env);
else
    zchunk = assert(load(zbody or '', 'fw.zone_list', 't', env));
end
zchunk();
local warps = assert(loadfile('lib/warps.lua'))();

local function labels(list)
    local out = { };
    for i, f in ipairs(list or { }) do
        out[i] = f.label;
    end
    return table.concat(out, ', ');
end
local mines = fw.zone_list('Bastok Mines', warps);
check(mines ~= nil and #mines == 3,
      ('Bastok Mines should list its three homepoints, lists %s'):format(labels(mines)));
check(mines ~= nil and mines[1].here and mines[1].key == 'Bastok Mines'
      and mines[1].type == 'home' and mines[3].label == 'Home Point #3',
      'a zone homepoint should carry the zone, the kind and the here flag');
local waters = fw.zone_list('Windurst Waters', warps);
check(waters ~= nil and #waters == 4,
      ('Windurst Waters should list four, not the copies on its markers, lists %d'):format(
          waters and #waters or 0));
local upper = fw.zone_list("Upper Delkfutt's Tower", warps);
check(upper ~= nil and #upper == 1 and upper[1].key == "Upper Delkfutt's Tower"
      and upper[1].label == 'Home Point #1',
      'Upper Delkfutt should list its own homepoint');
check(fw.zone_list("Lower Delkfutt's Tower", warps) == nil,
      'Lower Delkfutt has a guide and no homepoint');
check(fw.zone_list('Batallia Downs', warps) == nil,
      'a zone with no homepoint should list none');
check(fw.zone_list('Bastok Markets [S]', warps) ~= nil
      and #fw.zone_list('Bastok Markets [S]', warps) == 1,
      'a [S] zone should not pick up the present zone\'s homepoints');
check(fw.zone_list(nil, warps) == nil and fw.zone_list('', warps) == nil,
      'no zone name should list nothing');

if (fails == 0) then
    print(('ok: the D-pad wrap, the A-button gate and the widget\'s list all hold'));
else
    print(('%d check(s) failed'):format(fails));
    os.exit(1);
end
