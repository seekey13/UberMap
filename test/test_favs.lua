--[[
* Self-check for the favorites list.  A favorite is a warp row saved flat -
* the zone label it hung off plus the row's own fields - so it has to stay
* usable as a warp row after a round trip through the settings file, keep the
* order it was moved into, and match itself when the menu asks whether it is
* already listed.  Mirrors fav_index/fav_toggle/fav_reorder/fav_pos/warp_cmd in
* ubermap.lua against the real data.  Run with any Lua 5.1+:
*     lua test/test_favs.lua
--]]

local WARPS = assert(loadfile('lib/warps.lua'))();

local favs = {};  -- stands in for cfg.favs

local function fav_index(key, row)
    for i, f in ipairs(favs) do
        if (f.key == key and f.type == row.type and f.label == row.label) then
            return i;
        end
    end
    return nil;
end

local function fav_toggle(key, row)
    local i = fav_index(key, row);
    if (i ~= nil) then
        table.remove(favs, i);
    else
        table.insert(favs, { key = key, type = row.type,
                             label = row.label, zone = row.zone,
                             zid = row.zid });
    end
end

local function fav_reorder(i, j)
    table.insert(favs, j, table.remove(favs, i));
end

-- The grid reference is read back out of the warp data rather than saved, so
-- a favorite has to be able to find its own row again.
local function fav_pos(f)
    for _, r in ipairs(WARPS[f.key] or {}) do
        if (r.type == f.type and r.label == f.label) then
            return r.pos;
        end
    end
    return nil;
end

local UW_TYPE = { home = 'hp', guide = 'sg', unity = 'uc', abyssea = 'aw',
                  conflux = 'ab' };

-- ('%s'):fmt is Ashita's string extension, which plain Lua does not have.
local function warp_cmd(label, row)
    local kind = UW_TYPE[row.type];
    if (kind == nil) then
        return nil;
    end
    if (row.type == 'conflux') then
        return string.format('/uw %s %s', kind, row.label:match('#(%d+)') or '');
    end
    local zone = (row.zone or label):gsub('%(S%)$', '[S]');
    local n = (row.type == 'home') and row.label:match('^Home Point #(%d+)') or nil;
    return string.format('/uw %s %s%s', kind, zone, (n ~= '1') and n or '');
end

local fails = 0;
local function check(ok, msg)
    if (not ok) then
        fails = fails + 1;
        print('FAIL: ' .. msg);
    end
end

-- Three real rows off three real zones, so the fields under test are the ones
-- the map actually saves rather than made-up ones.
local function pick(zone, want)
    for _, w in ipairs(assert(WARPS[zone], zone .. ' is not in lib/warps.lua')) do
        if (w.type == want) then
            return w;
        end
    end
    error(zone .. ' has no ' .. want .. ' row');
end

-- Misareaux Coast carries a Home Point and a Survival Guide, so two rows off
-- one zone test that the type is part of an entry's identity; Morimar Basalt
-- Fields carries a Home Point of the same label, so the third tests that the
-- zone is part of it too.
local A_ZONE = 'Misareaux Coast';
local B_ZONE = 'Misareaux Coast';
local C_ZONE = 'Morimar Basalt Fields';
local A = pick(A_ZONE, 'home');
local B = pick(B_ZONE, 'guide');
local C = pick(C_ZONE, 'home');
check(A.label == C.label,
      'the two Home Point rows should share a label, or the zone check below proves nothing');

-- Adding lists them in the order they were added.
fav_toggle(A_ZONE, A);
fav_toggle(B_ZONE, B);
fav_toggle(C_ZONE, C);
check(#favs == 3, 'three adds should leave three favorites, got ' .. #favs);
check(favs[1].label == A.label, 'first added should be first listed');
check(favs[3].key == C_ZONE, 'last added should be last listed');

-- A saved favorite matches itself, and rows of another type or zone do not.
check(fav_index(A_ZONE, A) == 1, 'a listed row should be found');
check(fav_index(A_ZONE, B) == 2, 'the guide row is its own entry');
-- A and C are the same row but for the zone they hang off, so they stay two
-- entries rather than collapsing into one.
check(fav_index(A_ZONE, A) ~= fav_index(C_ZONE, C),
      'the same row under two zones should be two entries');
check(fav_index('Nowhere At All', A) == nil, 'an unlisted zone should not be found');

-- The same row again takes it off, and only it.
fav_toggle(B_ZONE, B);
check(#favs == 2, 'toggling a listed row should drop it, got ' .. #favs);
check(fav_index(B_ZONE, B) == nil, 'the dropped row should no longer be found');
check(fav_index(A_ZONE, A) == 1, 'dropping one should leave the others');
fav_toggle(B_ZONE, B);  -- back on the end, for the drags below

-- Reordering: dragging down then back up returns the list to where it started,
-- the rows a dragged one passes shift along rather than trading places, and a
-- drag onto the row it started on leaves the list alone.
local first, second, last = favs[1].label, favs[2].label, favs[#favs].label;
fav_reorder(1, 2);
check(favs[2].label == first, 'dragging down should put it second');
check(favs[1].label == second, 'the row it passed should shift up');
fav_reorder(2, 1);
check(favs[1].label == first, 'dragging back up should undo it');
fav_reorder(1, #favs);
check(favs[#favs].label == first, 'dragging to the end should put it last');
check(favs[#favs - 1].label == last, 'the rows it passed should all shift up');
fav_reorder(#favs, 1);
check(favs[1].label == first, 'dragging back to the top should undo it');
fav_reorder(1, 1);
check(favs[1].label == first, 'a drag onto its own row should do nothing');

-- A favorite finds its own row again, so the list can draw the grid reference
-- the popup drew without saving a copy of it.
for _, f in ipairs(favs) do
    local row;
    for _, r in ipairs(WARPS[f.key]) do
        if (r.type == f.type and r.label == f.label) then row = r; end
    end
    check(fav_pos(f) == row.pos,
          'a favorite should read its row\'s grid reference: ' .. f.label);
end
check(fav_pos({ key = 'Nowhere At All', type = 'home', label = 'Home Point #1' })
      == nil, 'a favorite off an unknown zone should have no grid reference');

-- The saved entry carries every field warp_cmd reads, so a favorite sends the
-- same line the popup row it came from does.
for _, f in ipairs(favs) do
    local from_row = warp_cmd(f.key, f);
    check(from_row ~= nil, 'a favorite should build a /uw: ' .. f.key .. ' - ' .. f.label);
end
check(warp_cmd(A_ZONE, favs[fav_index(A_ZONE, A)]) == warp_cmd(A_ZONE, A),
      'a favorite should send exactly what its row sends');

-- Settings round trip: the library writes tables out key by key and reads them
-- back as plain data, so an entry has to hold only scalars -- strings, or the
-- numbers it writes back with '%.17g', which is how a conflux row's zone id
-- travels.  A row field it cannot serialize would be lost on the next login.
for _, f in ipairs(favs) do
    for k, v in pairs(f) do
        check(type(k) == 'string'
              and (type(v) == 'string' or type(v) == 'number'),
              ('favorite field %s is a %s, which will not survive settings')
              :format(tostring(k), type(v)));
    end
end

-- The list as the panel and the widget draw it: narrowed to the type of warp
-- NPC in reach, whole when there is none, since a Survival Guide cannot send a
-- Home Point row and a row that cannot be pressed should not be listed.
-- A conflux row is narrowed on its zone as well, since every Abyssea area has
-- its own Conflux #3 and only the one the player stands in is reachable.
-- Mirrors fav_view in ubermap.lua.
local function fav_view(near_kind, near_zid)
    if (not near_kind) then
        return favs, nil;
    end
    local view, raw = {}, {};
    for i, f in ipairs(favs) do
        if (f.type == near_kind and (f.zid == nil or f.zid == near_zid)) then
            view[#view + 1] = f;
            raw[#raw + 1]   = i;
        end
    end
    return view, raw;
end

-- A guide row between the two home rows, so the slots the narrowed list maps
-- back to are not the slots it is drawn in.
fav_reorder(fav_index(B_ZONE, B), 2);
check(favs[2].type == 'guide', 'the guide row should be second for the checks below');

local whole, whole_raw = fav_view(nil);
check(whole == favs and whole_raw == nil,
      'with no NPC in reach the whole list should be shown, unnarrowed');

local home, home_raw = fav_view('home');
check(#home == 2, 'a Home Point should list only the two home rows, got ' .. #home);
check(home[1].type == 'home' and home[2].type == 'home',
      'no row of another type should be listed');
check(home_raw[1] == 1 and home_raw[2] == 3,
      'a narrowed row should map back to its own slot in the saved list');
check(#fav_view('guide') == 1, 'a Survival Guide should list only the guide row');
check(#fav_view('unity') == 0,
      'a warp with nothing saved for it should list nothing at all');

-- Dragging inside the narrowed list reorders the saved list, and leaves the
-- rows it does not show where they were.
local h1, h2, guide = home[1].label, home[2].label, favs[2].label;
fav_reorder(home_raw[1], home_raw[2]);
local after = fav_view('home');
check(after[1].label == h2 and after[2].label == h1,
      'a drag down the narrowed list should swap the two rows it shows');
check(fav_index(B_ZONE, B) ~= nil and favs[fav_index(B_ZONE, B)].label == guide,
      'the row the narrowed list hides should still be listed');
check(#favs == 3, 'narrowing should not add or drop anything, got ' .. #favs);

-- Two confluxes with the same label off two different Abyssea areas: standing
-- at one area's conflux lists that area's row and not the other's, and the
-- command each sends is the number alone, so the zone id is the only thing
-- telling them apart.
do
    local K, T2 = pick('Konschtat Highlands', 'conflux'),
                  pick('Tahrongi Canyon', 'conflux');
    check(K.label == T2.label,
          'the two conflux rows should share a label, or this check proves nothing');
    check(K.zid ~= T2.zid, 'the two conflux rows should name different zones');
    fav_toggle('Konschtat Highlands', K);
    fav_toggle('Tahrongi Canyon', T2);

    local at_k = fav_view('conflux', K.zid);
    check(#at_k == 1 and at_k[1].key == 'Konschtat Highlands',
          'a conflux should list only its own zone\'s row, got ' .. #at_k);
    check(#fav_view('conflux', 999) == 0,
          'an Abyssea area with nothing saved for it should list nothing');
    check(#fav_view(nil) == #favs,
          'away from every NPC the whole list should still be shown');
    check(warp_cmd('Konschtat Highlands', at_k[1]) == '/uw ab 1',
          'a saved conflux should send the number alone, got '
          .. tostring(warp_cmd('Konschtat Highlands', at_k[1])));
    check(warp_cmd('Konschtat Highlands', at_k[1]) == warp_cmd('Konschtat Highlands', K),
          'a saved conflux should send exactly what its row sends');

    fav_toggle('Konschtat Highlands', K);
    fav_toggle('Tahrongi Canyon', T2);
    check(#favs == 3, 'the two conflux rows should come back off again');
end

-- The three starter favorites, and the one thing that must stay true of them:
-- deleting one keeps it deleted.  settings.load merges the addon's defaults
-- into the saved file and recurses into tables, so a starter row left sitting
-- in default_settings is refilled by index on every load -- and the library
-- saves the merged table straight back to disk, so it stays.  merge below is
-- Ashita's own (addons/libs/sugar/table.lua), which the tests cannot require,
-- and seed mirrors the fill_defaults branch that replaced those rows.
do
    local function merge(self, src)
        for k, v in pairs(src) do
            if (type(v) == 'table') then
                if (rawget(self, k) == nil) then
                    self[k] = v;
                else
                    merge(self[k], v);
                end
            elseif (rawget(self, k) == nil) then
                self[k] = v;
            end
        end
        return self;
    end

    local function seed(cfg)
        if (cfg.seeded ~= true) then
            cfg.seeded = true;
            if (#cfg.favs == 0) then
                for i = 1, 6 do
                    table.insert(cfg.favs, { key = 'seed' .. i });
                end
            end
        end
        return cfg;
    end

    -- One load: the file off disk, the defaults merged in, then fill_defaults.
    local function load(file)
        return seed(merge(file, { favs = {}, seeded = false }));
    end

    local fresh = load({});
    check(#fresh.favs == 6, 'a new character should start with six favorites');

    -- Emptied on purpose and loaded again: the marker is already in the file,
    -- so nothing is put back.  This is the case the old defaults got wrong.
    local emptied = { favs = {}, seeded = true };
    check(#load(emptied).favs == 0,
          'an emptied list should stay empty across a load');

    -- And across as many loads as it likes.
    for _ = 1, 3 do
        load(emptied);
    end
    check(#emptied.favs == 0,
          'an emptied list should stay empty however often it is loaded');

    -- A list with rows of its own is not topped back up to three either.
    local kept = { favs = { { key = 'mine' } }, seeded = true };
    check(#load(kept).favs == 1 and kept.favs[1].key == 'mine',
          'a saved list should come back exactly as it was saved');
end

if (fails == 0) then
    print(('ok: %d favorites, add/remove, reorder, narrowing and /uw all hold'):format(#favs));
else
    print(('%d check(s) failed'):format(fails));
    os.exit(1);
end
