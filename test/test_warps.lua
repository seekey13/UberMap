--[[
* Self-check for the warp data.  Every row carries an icon type the popup knows
* how to draw, a label to print and a grid reference held apart from it in 'pos'
* so the popup can column it, each zone offers at most one Unity Concord, and
* a zone's Home Points are numbered 1..n with no gaps or repeats, so a bad merge
* fails here instead of drawing a blank row in game.  An Abyssea row carries the
* zone Uberwarp names its destination by, so it always has a 'zone' override.  Run with any Lua 5.1+:
*     lua test/test_warps.lua
--]]

local TYPES = { home = true, guide = true, unity = true, abyssea = true };
local UW    = { home = 'hp', guide = 'sg', unity = 'uc', abyssea = 'ab' };
-- The order the popup lists the types in, which is the order the rows sit in.
local RANK  = { home = 1, guide = 2, unity = 3, abyssea = 4 };

local data = assert(loadfile('lib/warps.lua'))();
assert(type(data) == 'table', 'warps.lua did not return a table');

local byType = { home = 0, guide = 0, unity = 0, abyssea = 0 };
local zones, rows, noGrid, cmds = 0, 0, {}, {};

for zone, list in pairs(data) do
    assert(type(zone) == 'string' and zone ~= '', 'zone key must be a non-empty string');
    assert(type(list) == 'table', ('%s: value is not a table'):format(zone));
    assert(#list > 0, ('%s: has no rows'):format(zone));

    local unities, homes, seenOrder = 0, {}, 0;
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

        -- The /uw line the popup sends, built the way ubermap.lua builds it.
        local n = row.label:match('^Home Point #(%d+)');
        local cmd = ('/uw %s %s%s'):format(
            UW[row.type], (row.zone or zone):gsub('%(S%)$', '[S]'),
            (n ~= '1') and n or '');
        assert(cmd:match('^/uw %a%a %S.*%S$'),
               ('%s[%d]: bad command %q'):format(zone, i, cmd));
        cmds[#cmds + 1] = cmd;

        -- Rows are grouped home, then guide, then unity, then abyssea.
        local rank = RANK[row.type];
        assert(rank >= seenOrder, ('%s[%d]: %s row out of order'):format(zone, i, row.type));
        seenOrder = rank;

        if row.type == 'unity' then unities = unities + 1; end
        -- '/uw ab' takes the Vana'diel zone, never the city the NPC stands in.
        assert(row.type ~= 'abyssea' or row.zone ~= nil,
               ('%s[%d]: an Abyssea row needs its own zone'):format(zone, i));
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

    zones = zones + 1;
end

print(('warps OK: %d zones, %d rows (%d home, %d guide, %d unity, %d abyssea)')
      :format(zones, rows, byType.home, byType.guide, byType.unity, byType.abyssea));
for _, s in ipairs(noGrid) do print('  no grid reference -> ' .. s); end

-- Two commands the popup would send, so a change to the format is visible here.
table.sort(cmds);
print('  e.g. ' .. cmds[1]);
print('  e.g. ' .. cmds[#cmds]);
