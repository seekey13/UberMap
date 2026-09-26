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

if (fails == 0) then
    print(('ok: the D-pad wrap, the A-button gate and the widget\'s list all hold'));
else
    print(('%d check(s) failed'):format(fails));
    os.exit(1);
end
