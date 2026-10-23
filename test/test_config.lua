--[[
* Self-check for the config panel's switch rows.  Run with any Lua
* 5.1+ / LuaJIT:
*     lua test/test_config.lua
*
* The rows are placed by hand under the Options heading, and the plate behind
* them is sized from the same counts, so a row added to the list without the
* height following it draws off the bottom of the panel.  Source is read
* rather than run: the panel needs ImGui and a frame, and what breaks here is
* the arithmetic around it.
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
assert(#rows == 7,
       ('the panel lists %d checkbox rows, not the 7 it offers'):format(#rows));

local seen = {};
for _, row in ipairs(rows) do
    assert(row.label ~= '', 'a checkbox row has no name beside it');
    assert(row.box == row.key,
           ('the %s row is drawn from cfg.%s, so a change to it would not show')
           :format(row.key, row.box));
    seen[row.key] = true;
end
-- Every setting that has no other way in now that the panel is the only
-- place these are toggled from: the commands they replaced are gone.
for _, key in ipairs({ 'autoopen', 'widget', 'fw_cancel', 'fw_group',
                        'guide', 'focus', 'quiet' }) do
    assert(seen[key], ('the %s row is gone from the config panel'):format(key));
    assert(not src:find(("sub == '%s'"):format(key), 1, true),
           ('/um %s is back, so the checkbox is no longer the only way in')
           :format(key));
end

-- Both keys are real settings, or the checkbox writes somewhere nothing reads.
local defaults = src:match('local default_settings%s*=%s*T{(.-)\n};');
assert(defaults, 'default_settings is no longer written as one block');
for _, row in ipairs(rows) do
    assert(defaults:match('%f[%w]' .. row.key .. '%s*=%s*%a+'),
           ('%s has no entry in default_settings'):format(row.key));
end

-- The plate, the Options heading and one switch per row. The height is the
-- title, the two headings and a row for the font, Bold, each slider, each
-- swatch and each switch, so a row added to the list without the height
-- following it draws off the bottom of the panel.
assert(src:find('st.plate(', 1, true),
       'the config panel no longer draws its plate');
assert(src:match("heading%('Options'%);%s*\n%s*for _, chk in ipairs%(checks%) do"),
       'the switches are no longer under an Options heading');
assert(src:find('st.switch(', 1, true),
       'the checkbox rows are no longer switches');
assert(src:find('line_h * (2 + #nums + #picks + #checks)', 1, true),
       'the panel height no longer follows the number of rows');
-- Every row goes through line_at, which is what the height above counts: a
-- row placed some other way would not be in the sum.
local lines = select(2, src:gsub('cy = line_at%(%);', ''));
assert(lines == 5, ('%d calls place a config row, not the 5 the height counts'
                    .. ' (the face, Bold, then the slider, swatch and switch'
                    .. ' loops)'):format(lines));
-- The numbers are sliders.
assert(src:find('st.slider(', 1, true), 'the number rows are no longer sliders');

-- Bold is off by default and saved on the spot, and the face it asks for is
-- baked at load beside the regular one: the atlas cannot be added to later.
local defaults_ = src:match('local default_settings%s*=%s*T{(.-)\n};');
assert(defaults_:match('%f[%w]bold%s*=%s*false'), 'Bold is not off by default');
assert(src:match("if %(bold_flip%) then%s*\n%s*cfg%.bold = bold_on;%s*\n%s*settings%.save%(%);"),
       'the Bold switch no longer saves the moment it is flipped');
assert(src:find('FONT_PX.atlas[name] = bake_file(name:lower() .. \'.ttf\') or false;', 1, true)
       and src:find('FONT_PX.bold[name] = bold and bake_file(bold) or false;', 1, true),
       'bake_all no longer bakes both the regular and the bold cut of each face');
-- The width has to follow the names too: these are the longest text on the
-- panel, and a name wider than the plate runs off it.
assert(src:match('for _, chk in ipairs%(checks%) do%s*\n%s*label_w = math%.max'),
       'the panel width no longer measures the switch names');

-- Ticking the widget back on has to clear a B press taken earlier in the
-- visit, or the box reads on with nothing on screen.
assert(src:match("if %(chk%[3%] == 'widget'%) then%s*\n%s*ui%.fw_hide = false;"),
       'the widget switch no longer clears ui.fw_hide');

print('ok: 7 switch rows, all live off cfg, panel sized to fit them');
