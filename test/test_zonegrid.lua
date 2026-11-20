--[[
* Self-check for zone map placement: grid references to positions, which sheet
* a warp row is on, the fan for rows sharing a spot, and the data in
* lib/zonemaps.lua against points.lua and warps.lua.  Run with any Lua 5.1+:
*     lua test/test_zonegrid.lua
--]]

local G      = assert(loadfile('lib/zonegrid.lua'))();
local ZM     = assert(loadfile('lib/zonemaps.lua'))();
local WARPS  = assert(loadfile('lib/warps.lua'))();
local POINTS = assert(loadfile('lib/points.lua'))();

local function near(a, b, eps)
    return math.abs(a - b) < (eps or 1e-9);
end

-- Parsing: with or without the brackets, and nothing off the 15x15 grid.
local c, r = G.parse('(K-9)');
assert(c == 11 and r == 9);
c, r = G.parse('A-1');
assert(c == 1 and r == 1);
c, r = G.parse('(O-15)');
assert(c == 15 and r == 15);
for _, bad in ipairs({ '(P-8)', '(A-0)', '(H-16)', 'H8', '(h-8)', '', '(K-9', 42 }) do
    assert(G.parse(bad) == nil, ('parsed %q'):format(tostring(bad)));
end

-- Cell centres: A-1 is half a cell in from the border, H-8 is dead centre,
-- O-15 mirrors A-1.
local u, v = G.cell_uv(1, 1);
assert(near(u, 1 / 32 + 1 / 32) and near(v, 1 / 16));
u, v = G.cell_uv(8, 8);
assert(near(u, 0.5) and near(v, 0.5));
u, v = G.cell_uv(15, 15);
assert(near(u, 1 - 1 / 16) and near(v, 1 - 1 / 16));

-- Measured on the Remapster art for West Ronfaure at 1024px: column A's label
-- is centred at 64px and row 15's at 960px.
u, v = G.cell_uv(1, 15);
assert(near(u * 1024, 64) and near(v * 1024, 960));

-- An exact xy wins over the grid reference; neither leaves the row undrawn.
u, v = G.row_uv({ pos = '(H-8)', xy = { 0.1, 0.2 } });
assert(near(u, 0.1) and near(v, 0.2));
assert(G.row_uv({ label = 'nowhere' }) == nil);

-- The fan: one marker sits on its spot, more ring round it evenly.
local x, y = G.fan(1, 1, 20);
assert(x == 0 and y == 0);
x, y = G.fan(1, 4, 20);
assert(near(x, 0, 1e-9) and near(y, -20, 1e-9));
local sx, sy = 0, 0;
for i = 1, 5 do
    local fx, fy = G.fan(i, 5, 20);
    assert(near(math.sqrt(fx * fx + fy * fy), 20, 1e-9));
    sx, sy = sx + fx, sy + fy;
end
assert(near(sx, 0, 1e-9) and near(sy, 0, 1e-9));

-- Sheets and rows, on a made-up zone of two maps plus another zone's map.
local entry  = { id = 79, sheets = { { map = 1, name = 'Map 1' }, { map = 2 },
                                     { zone = 15, map = 0 } } };
local sheets = G.sheets(entry);
assert(#sheets == 3);
assert(sheets[1].key == '79_1' and sheets[1].file == '79_1.png' and sheets[1].grid == G.DEFAULT);
assert(sheets[3].key == '15_0' and sheets[3].zone == 15);
assert(G.zone_sheets(sheets, 79) == 2 and G.zone_sheets(sheets, 15) == 1);

local rows = {
    { label = 'a', pos = '(E-9)', map = 1 },
    { label = 'b', pos = '(G-6)', map = 2 },
    { label = 'c', pos = '(G-6)', map = 2 },
    { label = 'd', pos = '(H-8)', zid = 15 },
    { label = 'e', pos = '(H-8)', zid = 99 },   -- a zone with no sheet here
    { label = 'f', map = 2 },                  -- on a sheet, but no position
    { label = 'g', pos = '(B-2)' },            -- no map: first sheet of 79
};
assert(G.row_sheet(entry, sheets, rows[1]) == 1);
assert(G.row_sheet(entry, sheets, rows[2]) == 2);
assert(G.row_sheet(entry, sheets, rows[4]) == 3);
assert(G.row_sheet(entry, sheets, rows[5]) == nil);
assert(G.row_sheet(entry, sheets, rows[7]) == 1);

local counts = G.counts(entry, sheets, rows);
assert(counts[1] == 2 and counts[2] == 3 and counts[3] == 1 and counts.off == 1);

local lay = G.layout(entry, sheets, rows, 2);
assert(#lay == 2, 'the row with no position should not be drawn');
assert(lay[1].index == 2 and lay[2].index == 3);
assert(lay[1].fan_n == 2 and lay[2].fan_n == 2 and lay[1].fan_i ~= lay[2].fan_i);
lay = G.layout(entry, sheets, rows, 1);
assert(#lay == 2 and lay[1].fan_n == 1 and lay[2].fan_n == 1);
assert(#G.layout(entry, sheets, rows, 9) == 0);

-- The opening sheet: where the player stands, else the last one looked at,
-- else the entry's start, else the first.
assert(G.open_sheet(entry, sheets, '79_2', '15_0') == 2);
assert(G.open_sheet(entry, sheets, '200_0', '15_0') == 3);
assert(G.open_sheet(entry, sheets, nil, nil) == 1);
assert(G.open_sheet({ start = 2 }, sheets, nil, nil) == 2);
assert(G.open_sheet({ start = 7 }, sheets, nil, nil) == 1);
assert(G.open_sheet(entry, { }, nil, nil) == nil);

-- Every grid reference in warps.lua parses and lands inside the map.
local refs = 0;
for zone, list in pairs(WARPS) do
    for i, row in ipairs(list) do
        if (row.pos ~= nil) then
            local ru, rv = G.row_uv(row, ZM.grid);
            assert(ru ~= nil, ('%s[%d]: %q is off the grid'):format(zone, i, row.pos));
            assert(ru > 0 and ru < 1 and rv > 0 and rv < 1);
            refs = refs + 1;
        end
        assert(row.map == nil or (type(row.map) == 'number' and row.map >= 0
                                  and row.map == math.floor(row.map)),
               ('%s[%d]: bad map %q'):format(zone, i, tostring(row.map)));
    end
end
assert(refs > 200);

-- The data file: every key is a point on the map with warps, every sheet has
-- something on it, and a zone drawn as more than one sheet has every row say
-- which -- one left to the default would silently land on the first map, which
-- is how Caedarva's Survival Guide ended up on the wrong island in the plan.
local labels = { };
for _, ic in ipairs(POINTS.points or { }) do
    labels[ic.label] = true;
end
for _, g in ipairs(POINTS.groups or { }) do
    for _, ic in ipairs(g.icons or { }) do
        labels[ic.label] = true;
    end
end

assert(type(ZM.zones) == 'table' and type(ZM.span) == 'number' and ZM.span > 0);
local entries = 0;
for label, e in pairs(ZM.zones) do
    assert(labels[label], ('zonemaps: %q is not a point label'):format(label));
    assert(WARPS[label], ('zonemaps: %q has no warps'):format(label));
    assert(type(e.id) == 'number' and e.id > 0, ('zonemaps: %q bad id'):format(label));
    assert(e.span == nil or (type(e.span) == 'number' and e.span > 0));
    local sh = G.sheets(e, ZM.grid);
    assert(#sh > 0, ('zonemaps: %q has no sheets'):format(label));
    local keys = { };
    for _, s in ipairs(sh) do
        assert(not keys[s.key], ('zonemaps: %q lists %s twice'):format(label, s.key));
        keys[s.key] = true;
    end
    assert(e.start == nil or sh[e.start] ~= nil, ('zonemaps: %q bad start'):format(label));

    local n = G.counts(e, sh, WARPS[label]);
    for i, s in ipairs(sh) do
        assert(n[i] > 0, ('zonemaps: %q sheet %s has no warps on it'):format(label, s.key));
    end
    for i, row in ipairs(WARPS[label]) do
        local zone = row.zid or e.id;
        if (G.zone_sheets(sh, zone) > 1) then
            assert(row.map ~= nil,
                   ('%s[%d] %q: zone %d is %d sheets, the row needs a map')
                   :format(label, i, row.label, zone, G.zone_sheets(sh, zone)));
        end
        if (row.map ~= nil) then
            assert(G.row_sheet(e, sh, row) ~= nil,
                   ('%s[%d] %q: map %d is not one of its sheets'):format(label, i, row.label, row.map));
        end
    end
    entries = entries + 1;
end

-- The pilot set, checked against the art: Caedarva's Home Point and Azouph
-- portal on map 1, its Survival Guide and Dvucca portal on map 2; Windurst
-- Waters' Home Point #3 alone on the south half.
local function sheet_of(label, row_label)
    local e  = ZM.zones[label];
    local sh = G.sheets(e, ZM.grid);
    for _, row in ipairs(WARPS[label]) do
        if (row.label == row_label) then
            return sh[G.row_sheet(e, sh, row)].key;
        end
    end
end
assert(sheet_of('Caedarva Mire', 'Home Point #1') == '79_1');
assert(sheet_of('Caedarva Mire', 'Survival Guide') == '79_2');
assert(sheet_of('Caedarva Mire', 'Azouph Isle Staging Point') == '79_1');
assert(sheet_of('Caedarva Mire', 'Dvucca Isle Staging Point') == '79_2');
assert(sheet_of('North Windurst Waters', 'Home Point #3') == '238_2');
assert(sheet_of('South Windurst Waters', 'Home Point #1 (E)') == '238_1');
assert(sheet_of('Konschtat Highlands', 'Conflux #4') == '15_0');
assert(sheet_of('Konschtat Highlands', 'Unity Concord') == '108_0');
assert(G.open_sheet(ZM.zones['South Windurst Waters'],
                    G.sheets(ZM.zones['South Windurst Waters'])) == 2);

print(('test_zonegrid: ok (%d grid references, %d zone map entries)'):format(refs, entries));
