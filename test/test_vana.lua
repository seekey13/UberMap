--[[
* Self-check for the Vanacore palette and scale, and for the four surfaces
* that draw with them.  Run with any Lua 5.1+ / LuaJIT, from the addon root:
*     lua test/test_vana.lua
*
* lib/vana.lua stays loadable without Ashita: the colours and S() do not ask
* ImGui for anything.  The draw calls are checked as source, the same way the
* config panel is, because they need a frame.
--]]

local vana = require('lib.vana');

local function same(got, want, msg)
    assert(got == want, (msg or '') .. ' got ' .. tostring(got) .. ', want ' .. tostring(want));
end

-- 1440px tall is 1.1. S() rounds.
vana.scale_to(1440);
same(vana.S(10), 11, 'S(10) at 1440');
same(vana.S(16), 18, 'S(16) at 1440');

-- 1080 is the short-screen clamp, 0.75 of the 1440 ratio, then times 1.1.
vana.scale_to(1080);
same(vana.S(16), 13, 'S(16) at 1080');
local at_1080 = vana.S(100);

vana.scale_to(720);
same(vana.S(100), at_1080, '720 clamps to the 1080 scale');

-- Taller than 1440 stops at 1.6, then times 1.1.
vana.scale_to(4000);
same(vana.S(100), math.floor(100 * 1.6 * 1.1 + 0.5), '4000 clamps at 1.6');

-- ImGui packs ABGR.
same(vana.u32('#FFFFFF'), 0xFFFFFFFF, 'white');
same(vana.u32('#161822'), 0xFF221816, 'bg');
same(vana.mix('#000000', '#FFFFFF', 0.5), '#808080', 'mix');

local tokens = {
    bg = '#161822', border = '#2A2E3E', line = '#242838', hover = '#1F2334',
    well = '#0E1017', well_edge = '#272B3C',
    field = '#080A10', field_edge = '#3E4460', popup = '#0F1118',
    white = '#FFFFFF', text = '#E8EAF1', text2 = '#BDC1D0',
    dim = '#7B8095', faint = '#4E536A',
    accent = '#7AA2F7', accent2 = '#A9C1FF', accent_lo = '#3E5CB3',
    accent_bg = '#1B2340',
    teal = '#5FD3B3', amber = '#E8B45C', rose = '#EE6F78',
    knob = '#F2F3F8', off = '#2B2F42', seg = '#313752', ink = '#0B1020',
};
for name, hex in pairs(tokens) do
    same(vana.P[name], hex, name);
end
same(vana.BODY, 16, 'BODY');
same(vana.SMALL, 13.5, 'SMALL');

local src = assert(io.open('ubermap.lua')):read('*a');
for _, needle in ipairs({
    'ui.style = require(\'lib.vana\');',
    'ui.style.bake();',
    'ui.style.frame();',
    'ui.style.field(',
    'st.plate(',
    'st.switch(',
    'ui.style.push(\'text\', font_px);',
    'vana  = true,',
    'st.P.rose',
    'st.P.teal',
    'ui.warp_pitch',
}) do
    assert(src:find(needle, 1, true), 'ubermap.lua is missing ' .. needle);
end

-- Segoe is baked from the style module, so the map file still has the one
-- AddFontFromFileTTF the font picker is allowed.
local adds = select(2, src:gsub('AddFontFromFileTTF', ''));
same(adds, 1, 'AddFontFromFileTTF in ubermap.lua');

print('ok: palette, scale clamps, and the search, config and widget draw with them');
