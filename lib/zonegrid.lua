--[[
* UberMap - zone map grid and sheets.
*
* Kept free of Ashita/D3D dependencies so it can be exercised outside the game
* by test_zonegrid.lua.
*
* Positions on a zone map are u, v: 0..1 across the image, so the same data
* lands in the same place whatever size the art is drawn or shipped at, and
* replacing an image never moves a marker.
*
* A zone can be several sheets - Caedarva Mire is two for the warps it holds,
* Windurst Waters north and south.  A sheet is named by the game's own zone id
* and map index, '<zone>_<map>', which is also how the Remapster pack names its
* files.  A warp row says which sheet it is on with:
*   zid  - the zone it stands in, when that is not the marker's (the Abyssea
*          confluxes, whose grid references are places inside the Abyssea area)
*   map  - the game's map index within that zone, when the zone has more than
*          one sheet
--]]

local G = { };

-- FFXI's map grid: fifteen columns A..O and fifteen rows 1..15, drawn inside
-- a border half a cell wide.  On the 512px in-game maps that is a 16px border
-- and 32px cells, and the Remapster art keeps the same proportions at 2048.
G.DEFAULT = { ox = 1 / 32, oy = 1 / 32, cell_w = 1 / 16, cell_h = 1 / 16, n = 15 };

local A = string.byte('A');

--[[
* '(K-9)' or 'K-9' -> 11, 9.  nil for anything else, including a reference off
* the grid, so a typo cannot land a marker outside the map.
--]]
function G.parse(pos, grid)
    if (type(pos) ~= 'string') then
        return nil;
    end
    local l, n = pos:match('^%((%u)%-(%d+)%)$');
    if (l == nil) then
        l, n = pos:match('^(%u)%-(%d+)$');
    end
    if (l == nil) then
        return nil;
    end
    local size = (grid or G.DEFAULT).n;
    local col, row = l:byte() - A + 1, tonumber(n);
    if (col < 1 or col > size or row < 1 or row > size) then
        return nil;
    end
    return col, row;
end

-- The centre of a cell, in u, v.
function G.cell_uv(col, row, grid)
    grid = grid or G.DEFAULT;
    return grid.ox + (col - 0.5) * grid.cell_w,
           grid.oy + (row - 0.5) * grid.cell_h;
end

--[[
* Where a warp row sits on its sheet, in u, v.  An exact 'xy' = { u, v }, set
* in the editor, wins over the grid reference, which only says which cell.
* nil when the row has neither: it is listed in the panel but not drawn.
--]]
function G.row_uv(row, grid)
    if (type(row.xy) == 'table' and row.xy[1] and row.xy[2]) then
        return row.xy[1], row.xy[2];
    end
    local col, r = G.parse(row.pos, grid);
    if (col == nil) then
        return nil;
    end
    return G.cell_uv(col, r, grid);
end

function G.key(zone, map)
    return ('%d_%d'):format(zone, map);
end

--[[
* A zonemaps.lua entry's sheets, filled out: each gets its zone, map, key,
* file and grid, defaulted from the entry and the data file's own grid.
--]]
function G.sheets(entry, base_grid)
    local out = { };
    for i, s in ipairs(entry.sheets or { }) do
        local zone = s.zone or entry.id;
        local map  = s.map or 0;
        out[i] = {
            zone = zone,
            map  = map,
            key  = G.key(zone, map),
            name = s.name,
            file = s.file or (G.key(zone, map) .. '.png'),
            grid = s.grid or entry.grid or base_grid or G.DEFAULT,
        };
    end
    return out;
end

--[[
* Which of 'sheets' a warp row is on, by index, or nil when it is on none of
* them.  The zone is the row's zid if it has one, else the entry's; the map is
* the row's own if it names one, else the first sheet of that zone.
--]]
function G.row_sheet(entry, sheets, row)
    local zone = row.zid or entry.id;
    for i, s in ipairs(sheets) do
        if (s.zone == zone and (row.map == nil or row.map == s.map)) then
            return i;
        end
    end
    return nil;
end

-- How many sheets of 'sheets' belong to 'zone'.  Above one, a row in that
-- zone has to say which with 'map', or it lands on the first by default.
function G.zone_sheets(sheets, zone)
    local n = 0;
    for _, s in ipairs(sheets) do
        if (s.zone == zone) then
            n = n + 1;
        end
    end
    return n;
end

--[[
* The offset, in screen pixels, of the i'th of n markers sharing one spot.
* One marker sits on the spot; more spread evenly round a ring of radius r,
* starting at twelve o'clock, so each stays clickable.
--]]
function G.fan(i, n, r)
    if (n <= 1) then
        return 0, 0;
    end
    local a = (i - 1) / n * 2 * math.pi - math.pi / 2;
    return math.cos(a) * r, math.sin(a) * r;
end

--[[
* The markers one sheet draws: every row of 'rows' on sheet 'si' that has a
* position, as { row, index, u, v, fan_i, fan_n }.  'index' is the row's place
* in 'rows', which is how the panel and the marker find each other.  Rows that
* resolve to the same spot share it as a fan.
--]]
function G.layout(entry, sheets, rows, si)
    local sheet = sheets[si];
    if (sheet == nil) then
        return { };
    end
    local out, spots = { }, { };
    for i, row in ipairs(rows) do
        if (G.row_sheet(entry, sheets, row) == si) then
            local u, v = G.row_uv(row, sheet.grid);
            if (u ~= nil) then
                local k = ('%.4f,%.4f'):format(u, v);
                spots[k] = spots[k] or { };
                local m = { row = row, index = i, u = u, v = v };
                table.insert(spots[k], m);
                table.insert(out, m);
            end
        end
    end
    for _, list in pairs(spots) do
        for j, m in ipairs(list) do
            m.fan_i, m.fan_n = j, #list;
        end
    end
    return out;
end

--[[
* Warps per sheet, for the tab badges: counts[si] for each sheet, plus
* counts.off for rows that land on no sheet and are only in the panel.
--]]
function G.counts(entry, sheets, rows)
    local counts = { off = 0 };
    for i = 1, #sheets do
        counts[i] = 0;
    end
    for _, row in ipairs(rows) do
        local si = G.row_sheet(entry, sheets, row);
        if (si ~= nil) then
            counts[si] = counts[si] + 1;
        else
            counts.off = counts.off + 1;
        end
    end
    return counts;
end

--[[
* The sheet a zone opens on: the one the player stands on if it is one of
* these, else the one last looked at, else the entry's 'start', else the
* first.  Each is a sheet key or index, or nil when unknown.
--]]
function G.open_sheet(entry, sheets, here_key, last_key)
    for _, want in ipairs({ here_key, last_key }) do
        if (want ~= nil) then
            for i, s in ipairs(sheets) do
                if (s.key == want) then
                    return i;
                end
            end
        end
    end
    local start = entry.start;
    if (type(start) == 'number' and sheets[start] ~= nil) then
        return start;
    end
    return (#sheets > 0) and 1 or nil;
end

return G;
