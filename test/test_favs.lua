--[[
* Self-check for the favourites list.  A favourite is a warp row saved flat -
* the zone label it hung off plus the row's own fields - so it has to stay
* usable as a warp row after a round trip through the settings file, keep the
* order it was moved into, and match itself when the menu asks whether it is
* already listed.  Mirrors fav_index/fav_toggle/fav_move/warp_cmd in
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
                             label = row.label, zone = row.zone });
    end
end

local function fav_move(i, d)
    local j = i + d;
    if (j < 1 or j > #favs) then
        return;
    end
    favs[i], favs[j] = favs[j], favs[i];
end

local UW_TYPE = { home = 'hp', guide = 'sg', unity = 'uc' };

-- ('%s'):fmt is Ashita's string extension, which plain Lua does not have.
local function warp_cmd(label, row)
    local kind = UW_TYPE[row.type];
    if (kind == nil) then
        return nil;
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
check(#favs == 3, 'three adds should leave three favourites, got ' .. #favs);
check(favs[1].label == A.label, 'first added should be first listed');
check(favs[3].key == C_ZONE, 'last added should be last listed');

-- A saved favourite matches itself, and rows of another type or zone do not.
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
fav_toggle(B_ZONE, B);  -- back on the end, for the moves below

-- Reordering: down then up returns the list to where it started, and a move
-- off either end does nothing rather than wrapping.
local first = favs[1].label;
fav_move(1, 1);
check(favs[2].label == first, 'moving down should put it second');
fav_move(2, -1);
check(favs[1].label == first, 'moving back up should undo it');
fav_move(1, -1);
check(favs[1].label == first, 'up off the top should do nothing');
fav_move(#favs, 1);
check(favs[1].label == first, 'down off the bottom should do nothing');

-- The saved entry carries every field warp_cmd reads, so a favourite sends the
-- same line the popup row it came from does.
for _, f in ipairs(favs) do
    local from_row = warp_cmd(f.key, f);
    check(from_row ~= nil, 'a favourite should build a /uw: ' .. f.key .. ' - ' .. f.label);
end
check(warp_cmd(A_ZONE, favs[fav_index(A_ZONE, A)]) == warp_cmd(A_ZONE, A),
      'a favourite should send exactly what its row sends');

-- Settings round trip: the library writes tables out key by key and reads them
-- back as plain data, so an entry has to hold only strings.  A row field it
-- cannot serialize would be lost on the next login.
for _, f in ipairs(favs) do
    for k, v in pairs(f) do
        check(type(k) == 'string' and type(v) == 'string',
              ('favourite field %s is a %s, which will not survive settings')
              :format(tostring(k), type(v)));
    end
end

if (fails == 0) then
    print(('ok: %d favourites, add/remove, reorder and /uw all hold'):format(#favs));
else
    print(('%d check(s) failed'):format(fails));
    os.exit(1);
end
