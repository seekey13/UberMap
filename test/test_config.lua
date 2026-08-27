--[[
* Self-check for the config panel's checkbox rows.  Run with any Lua
* 5.1+ / LuaJIT:
*     lua test/test_config.lua
*
* The rows are placed by hand under the pickers, and the plate behind them is
* sized from the same counts, so a row added to the list without the height
* following it draws off the bottom of the panel.  Source is read rather than
* run: the panel needs ImGui and a frame, and what breaks here is the
* arithmetic around it.
--]]

local src = assert(io.open('ubermap.lua')):read('*a');

local checks = src:match('local checks%s*=%s*{(.-)};%s*\n');
assert(checks, 'the config panel no longer builds its checkbox rows as one list');

-- Every row: the name it is drawn under, the cfg key it writes, and the box it
-- hands ImGui -- which is built from that same key, so a toggle made anywhere
-- else shows on the panel without being told.
local rows = {};
for label, box, key in checks:gmatch("{%s*'([^']-)',%s*\n?%s*{ cfg%.([%w_]+) }%s*,%s*'([%w_]+)'%s*}") do
    rows[#rows + 1] = { label = label, box = box, key = key };
end
assert(#rows == 2,
       ('the panel lists %d checkbox rows, not the 2 it offers'):format(#rows));

local seen = {};
for _, row in ipairs(rows) do
    assert(row.label ~= '', 'a checkbox row has no name beside it');
    assert(row.box == row.key,
           ('the %s row is drawn from cfg.%s, so a change to it would not show')
           :format(row.key, row.box));
    seen[row.key] = true;
end
assert(seen.autoopen, 'the auto-open row is gone from the config panel');
assert(seen.widget, 'the favorites widget row is gone from the config panel');

-- Both keys are real settings, or the checkbox writes somewhere nothing reads.
local defaults = src:match('local default_settings%s*=%s*T{(.-)\n};');
assert(defaults, 'default_settings is no longer written as one block');
for _, row in ipairs(rows) do
    assert(defaults:match('%f[%w]' .. row.key .. '%s*=%s*%a+'),
           ('%s has no entry in default_settings'):format(row.key));
end

-- The plate and the rows are placed off the same counts: the pulldown, the
-- numeric rows, the pickers, then one row per checkbox.
assert(src:find('pitch * (#picks + #nums + #checks + 1) - TOGGLE_GAP', 1, true),
       'the panel height no longer follows the number of checkbox rows');
assert(src:find('row_y + pitch * (#nums + #picks + i) });', 1, true),
       'the checkbox rows are no longer stacked under the pickers');
-- The width has to follow the names too: these are the longest text on the
-- panel, and a name wider than the plate runs off it.
assert(src:match('for _, chk in ipairs%(checks%) do%s*\n%s*panel_w = math%.max'),
       'the panel width no longer measures the checkbox names');

-- Ticking the widget back on has to clear a B press the same way '/um widget'
-- does, or the box reads on with nothing on screen.
assert(src:match("if %(chk%[3%] == 'widget'%) then%s*\n%s*ui%.fw_hide = false;"),
       'the widget checkbox no longer clears ui.fw_hide');

print('ok: 2 checkbox rows, both live off cfg, panel sized to fit them');
