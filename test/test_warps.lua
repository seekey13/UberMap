--[[
* Self-check for the warp data.  Every row carries an icon type the popup knows
* how to draw and a label to print, each zone offers at most one Unity Concord, and
* a zone's Home Points are numbered 1..n with no gaps or repeats, so a bad merge
* fails here instead of drawing a blank row in game.  Run with any Lua 5.1+:
*     lua test/test_warps.lua
--]]

local TYPES = { home = true, guide = true, unity = true };
local UW    = { home = 'hp', guide = 'sg', unity = 'uc' };

local data = assert(loadfile('lib/warps.lua'))();
assert(type(data) == 'table', 'warps.lua did not return a table');

local zones, rows, byType, noGrid, cmds = 0, 0, { home = 0, guide = 0, unity = 0 }, {}, {};

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

        -- Rows are grouped home, then guide, then unity.
        local rank = (row.type == 'home' and 1) or (row.type == 'guide' and 2) or 3;
        assert(rank >= seenOrder, ('%s[%d]: %s row out of order'):format(zone, i, row.type));
        seenOrder = rank;

        if row.type == 'unity' then unities = unities + 1; end
        if row.type == 'home' then
            local n = tonumber(row.label:match('^Home Point #(%d+)'));
            assert(n, ('%s[%d]: %q is not a numbered Home Point'):format(zone, i, row.label));
            assert(not homes[n], ('%s: duplicate Home Point #%d'):format(zone, n));
            homes[n] = true;
        end

        if not row.label:match('%(%u%-%d+%)$') then noGrid[#noGrid + 1] = zone .. ': ' .. row.label; end

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

print(('warps OK: %d zones, %d rows (%d home, %d guide, %d unity)')
      :format(zones, rows, byType.home, byType.guide, byType.unity));
for _, s in ipairs(noGrid) do print('  no grid reference -> ' .. s); end

-- Two commands the popup would send, so a change to the format is visible here.
table.sort(cmds);
print('  e.g. ' .. cmds[1]);
print('  e.g. ' .. cmds[#cmds]);
