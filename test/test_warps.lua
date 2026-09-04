--[[
* Self-check for the warp data.  Every row carries an icon type the popup knows
* how to draw, a label to print and a grid reference held apart from it in 'pos'
* so the popup can column it, each zone offers at most one Unity Concord, and
* a zone's Home Points are numbered 1..n with no gaps or repeats, so a bad merge
* fails here instead of drawing a blank row in game.  Run with any Lua 5.1+:
*     lua test/test_warps.lua
--]]

local TYPES = { home = true, guide = true, unity = true, abyssea = true,
                conflux = true };
local UW    = { home = 'hp', guide = 'sg', unity = 'uc', abyssea = 'aw',
                conflux = 'ab' };
-- The order the popup lists the types in, which is the order the rows sit in.
local RANK  = { home = 1, guide = 2, unity = 3, abyssea = 4, conflux = 5 };

local data = assert(loadfile('lib/warps.lua'))();
assert(type(data) == 'table', 'warps.lua did not return a table');

local byType = { home = 0, guide = 0, unity = 0, abyssea = 0, conflux = 0 };
local zones, rows, noGrid, cmds = 0, 0, {}, {};
-- Conflux rows, gathered per zone so the eight of a set can be checked as one:
-- they are numbered 1..8 with no gaps, and all eight name the same Abyssea zone
-- id, since a conflux only ever travels to the others standing in its own.
local fluxZid = {};

for zone, list in pairs(data) do
    assert(type(zone) == 'string' and zone ~= '', 'zone key must be a non-empty string');
    assert(type(list) == 'table', ('%s: value is not a table'):format(zone));
    assert(#list > 0, ('%s: has no rows'):format(zone));

    local unities, homes, seenOrder, fluxes = 0, {}, 0, {};
    for i, row in ipairs(list) do
        assert(type(row) == 'table', ('%s[%d]: row is not a table'):format(zone, i));
        assert(TYPES[row.type], ('%s[%d]: bad type %q'):format(zone, i, tostring(row.type)));
        assert(type(row.label) == 'string' and row.label ~= '',
               ('%s[%d]: label must be a non-empty string'):format(zone, i));
        assert(not row.label:match('%(%u%-%d+%)$'),
               ('%s[%d]: %q keeps its grid reference, move it to pos'):format(zone, i, row.label));
        assert(row.pos == nil or (type(row.pos) == 'string' and row.pos:match('^%(%u%-%d+%)$')),
               ('%s[%d]: bad pos %q'):format(zone, i, tostring(row.pos)));
        assert(row.zone == nil or (type(row.zone) == 'string' and row.zone ~= ''),
               ('%s[%d]: zone override must be a non-empty string'):format(zone, i));
        -- A zone id belongs to a conflux row and to nothing else: it is what
        -- says which Abyssea area's set of eight the row is one of, and a row
        -- of another type carrying one would be silently gated on a zone the
        -- player is never in.
        assert((row.zid ~= nil) == (row.type == 'conflux'),
               ('%s[%d]: zid belongs to conflux rows and only those'):format(zone, i));
        assert(row.zid == nil or (type(row.zid) == 'number' and row.zid > 0),
               ('%s[%d]: bad zid %q'):format(zone, i, tostring(row.zid)));

        -- The /uw line the popup sends, built the way ubermap.lua builds it.
        local n = row.label:match('^Home Point #(%d+)');
        local cmd;
        if (row.type == 'conflux') then
            -- Filed under the number alone: the zone is wherever the player
            -- already stands, so naming one would be a destination Uberwarp
            -- cannot find.
            cmd = ('/uw %s %s'):format(UW[row.type], row.label:match('#(%d+)'));
        else
            cmd = ('/uw %s %s%s'):format(
                UW[row.type], (row.zone or zone):gsub('%(S%)$', '[S]'),
                (n ~= '1') and n or '');
        end
        assert(cmd:match('^/uw %a%a %S.*%S$') or cmd:match('^/uw %a%a %S$'),
               ('%s[%d]: bad command %q'):format(zone, i, cmd));
        cmds[#cmds + 1] = cmd;

        -- Rows are grouped home, then guide, then unity, then abyssea, then
        -- the confluxes.
        local rank = RANK[row.type];
        assert(rank >= seenOrder, ('%s[%d]: %s row out of order'):format(zone, i, row.type));
        seenOrder = rank;

        if row.type == 'unity' then unities = unities + 1; end
        if row.type == 'conflux' then
            local n = tonumber(row.label:match('^Conflux #(%d+)'));
            assert(n, ('%s[%d]: %q is not a numbered Conflux'):format(zone, i, row.label));
            assert(not fluxes[n], ('%s: duplicate Conflux #%d'):format(zone, n));
            fluxes[n] = true;
            -- Every conflux of a zone stands in the same Abyssea area, so the
            -- ids cannot disagree: one that did would take a press in a zone
            -- its neighbours refuse it in.
            assert(fluxZid[zone] == nil or fluxZid[zone] == row.zid,
                   ('%s: conflux rows name two zone ids, %d and %d')
                   :format(zone, fluxZid[zone] or 0, row.zid));
            fluxZid[zone] = row.zid;
        end
        if row.type == 'home' then
            local n = tonumber(row.label:match('^Home Point #(%d+)'));
            assert(n, ('%s[%d]: %q is not a numbered Home Point'):format(zone, i, row.label));
            assert(not homes[n], ('%s: duplicate Home Point #%d'):format(zone, n));
            homes[n] = true;
        end

        if row.pos == nil then noGrid[#noGrid + 1] = zone .. ': ' .. row.label; end

        byType[row.type] = byType[row.type] + 1;
        rows = rows + 1;
    end

    assert(unities <= 1, ('%s: %d unity rows, expected at most 1'):format(zone, unities));

    local count = 0;
    for _ in pairs(homes) do count = count + 1; end
    for n = 1, count do
        assert(homes[n], ('%s: Home Point numbering has a gap at #%d'):format(zone, n));
    end

    -- A zone lists all eight confluxes or none: the set is what an Abyssea
    -- area has, and a short one is a merge that dropped rows rather than a
    -- place with fewer of them.
    count = 0;
    for _ in pairs(fluxes) do count = count + 1; end
    assert(count == 0 or count == 8,
           ('%s: %d conflux rows, expected 0 or 8'):format(zone, count));
    for n = 1, count do
        assert(fluxes[n], ('%s: Conflux numbering has a gap at #%d'):format(zone, n));
    end

    zones = zones + 1;
end

-- The three Abyssea areas reachable from a Cavernous Maw, each with its own
-- eight.  Named here so a zone id typed wrong fails the check rather than
-- quietly gating a row on an area the player never visits.
local WANT_ZID = { ['Konschtat Highlands'] = 15,
                   ['La Theine Plateau']   = 132,
                   ['Tahrongi Canyon']     = 45 };
for zone, zid in pairs(WANT_ZID) do
    assert(fluxZid[zone] == zid,
           ('%s: conflux rows name zone %s, expected %d')
           :format(zone, tostring(fluxZid[zone]), zid));
end
for zone in pairs(fluxZid) do
    assert(WANT_ZID[zone], ('%s: conflux rows on an unexpected zone'):format(zone));
end

print(('warps OK: %d zones, %d rows (%d home, %d guide, %d unity, %d abyssea, %d conflux)')
      :format(zones, rows, byType.home, byType.guide, byType.unity, byType.abyssea,
              byType.conflux));
for _, s in ipairs(noGrid) do print('  no grid reference -> ' .. s); end

-- Two commands the popup would send, so a change to the format is visible here.
table.sort(cmds);
print('  e.g. ' .. cmds[1]);
print('  e.g. ' .. cmds[#cmds]);
