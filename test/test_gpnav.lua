--[[
* Self-check for the gamepad's map navigation math.  Two things have to hold:
* a fresh selection lands on the marker nearest the middle of the view, and a
* direction press lands on the marker that way rather than on a nearer one off
* to the side.  A marker no press can reach would be stranded, so the real map
* data is walked as well.  Run with any Lua 5.1+:
*     lua test/test_gpnav.lua
--]]

local gp = assert(loadfile('lib/gpnav.lua'))();

-- A 3x3 grid 100 apart, listed row by row -- 1 2 3 / 4 5 6 / 7 8 9 -- so 5 is
-- the middle one.  y grows downwards, the way the map's pixels do, which makes
-- 'up' the smaller y.
local grid = { };
for row = 0, 2 do
    for col = 0, 2 do
        table.insert(grid, { x = col * 100, y = row * 100 });
    end
end

-- An empty list has no answer at all, which is what an over-filtered map hands
-- in: every marker faded back leaves nothing to land on.
assert(gp.nearest({ }, 0, 0) == nil);
assert(gp.nearest(grid, 100, 100) == 5);
assert(gp.nearest(grid, 190, 10) == 3);
-- A tie goes to the earlier entry, so the same view always opens on the same
-- marker rather than picking between two by table order luck.
assert(gp.nearest({ { x = 0, y = 0 }, { x = 0, y = 0 } }, 0, 0) == 1);

-- From the middle of the grid, each direction is the neighbour that way.
assert(gp.step(grid, 5, 'up')    == 2);
assert(gp.step(grid, 5, 'down')  == 8);
assert(gp.step(grid, 5, 'left')  == 4);
assert(gp.step(grid, 5, 'right') == 6);

-- Nothing that way leaves the selection where it is, rather than wrapping to
-- the far side of the world: a map is not a menu.
assert(gp.step(grid, 2, 'up')    == nil);
assert(gp.step(grid, 8, 'down')  == nil);
assert(gp.step(grid, 4, 'left')  == nil);
assert(gp.step(grid, 6, 'right') == nil);

-- A press never lands back on where it started, whatever it is handed.
for _, dir in ipairs({ 'up', 'down', 'left', 'right' }) do
    for i = 1, #grid do
        assert(gp.step(grid, i, dir) ~= i);
    end
end
-- A button that is not a direction, and an index off the end of the list,
-- answer nothing instead of throwing.
assert(gp.step(grid, 5, 'a')   == nil);
assert(gp.step(grid, 99, 'up') == nil);

-- The marker straight ahead wins over a nearer one off to the side, which is
-- what makes a column of points walk like a column.
local aside = { { x = 0, y = 0 }, { x = 100, y = 0 }, { x = 50, y = 60 } };
assert(gp.step(aside, 1, 'right') == 2);
-- Far enough ahead and the one to the side wins after all: it is a preference,
-- not a blinker, or half the map would be unreachable.
local far = { { x = 0, y = 0 }, { x = 400, y = 0 }, { x = 50, y = 60 } };
assert(gp.step(far, 1, 'right') == 3);

-- Nothing on either map is left where the D-pad cannot get to it.  Walked over
-- the real data, since that is the only thing that says whether some corner of
-- Vana'diel is stranded: start where a fresh selection would, and see how far
-- the four directions reach from there.
local data = assert(loadfile('lib/points.lua'))();

local function reachable(list)
    if (#list == 0) then
        return;
    end
    local x0, y0, x1, y1;
    for _, ic in ipairs(list) do
        x0 = math.min(x0 or ic.x, ic.x);  y0 = math.min(y0 or ic.y, ic.y);
        x1 = math.max(x1 or ic.x, ic.x);  y1 = math.max(y1 or ic.y, ic.y);
    end
    local start = gp.nearest(list, (x0 + x1) / 2, (y0 + y1) / 2);
    local seen, queue = { [start] = true }, { start };
    while (#queue > 0) do
        local i = table.remove(queue);
        for _, dir in ipairs({ 'up', 'down', 'left', 'right' }) do
            local j = gp.step(list, i, dir);
            if (j ~= nil and not seen[j]) then
                seen[j] = true;
                table.insert(queue, j);
            end
        end
    end
    for i, ic in ipairs(list) do
        assert(seen[i], ('%s cannot be reached with the D-pad'):format(
                            tostring(ic.label)));
    end
end

local checked = 0;
for _, time in ipairs({ 'present', 'past' }) do
    -- The overview tier: every group's icons on this map, which is the list
    -- walked before anything has been zoomed into.
    local over = { };
    for _, g in ipairs(data.groups) do
        for _, ic in ipairs(g.icons) do
            if ((ic.time or 'present') == time) then
                table.insert(over, ic);
            end
        end
    end
    reachable(over);
    checked = checked + #over;

    -- And the zone points inside one marker of it, which is the list walked
    -- once one has been.
    local by_group = { };
    for _, ic in ipairs(data.points) do
        if ((ic.time or 'present') == time) then
            by_group[ic.group] = by_group[ic.group] or { };
            table.insert(by_group[ic.group], ic);
        end
    end
    for _, list in pairs(by_group) do
        reachable(list);
        checked = checked + #list;
    end
end

print(('gpnav OK: %d markers reachable'):format(checked));
