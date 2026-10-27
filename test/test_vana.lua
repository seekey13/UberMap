--[[
* Self-check for the VanaCore palette and scale, and for the four surfaces
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
    teal = '#5FD3B3', rose = '#EE6F78',
    knob = '#F2F3F8', off = '#2B2F42',
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
    'clipped = true,',
    'st.slider(',
    'st.P.rose',
    'st.P.teal',
    'ui.warp_pitch',
    'st.close(',
    'st.swatch(',
    'st.row(',
    'ui.style.tooltip(',
}) do
    assert(src:find(needle, 1, true), 'ubermap.lua is missing ' .. needle);
end
-- Every tooltip goes through the palette's: a bare SetTooltip is ImGui's grey
-- box in a window that is otherwise VanaCore's.
assert(not src:find('imgui.SetTooltip(', 1, true),
       'ubermap.lua calls SetTooltip directly instead of through ui.style.tooltip');

-- Segoe is baked from the style module, so the map file still has the one
-- AddFontFromFileTTF the font picker is allowed.
local adds = select(2, src:gsub('AddFontFromFileTTF', ''));
same(adds, 1, 'AddFontFromFileTTF in ubermap.lua');

--[[
* The controls, drawn against a stand-in ImGui.  What it records is what
* matters in game: every style colour, style var and font pushed is popped
* (ImGui asserts on an unbalanced stack), and the sizes and colours are
* VanaCore's.
--]]
local depth = { color = 0, var = 0, font = 0 };
local seen = { };
local hovered, click, open = false, false, { };
local dl = { lines = { }, rects = { }, texts = { } };
function dl:AddLine(a, b, col, t) self.lines[#self.lines + 1] = { a = a, b = b, col = col, t = t }; end
function dl:AddRectFilled(a, b, col, r) self.rects[#self.rects + 1] = { a = a, b = b, col = col, r = r }; end
function dl.AddRect() end
function dl.AddCircleFilled() end
function dl:AddText(p, col, s) self.texts[#self.texts + 1] = { p = p, col = col, s = s }; end
local function reset()
    dl.lines, dl.rects, dl.texts = { }, { }, { };
    seen = { };
end
local active, mouse = false, 0;
local input = { };  -- InputText's answer: { text typed, Enter pressed }
-- IsItemActive answers for the item drawn last: a button is held while
-- active is, a number box's field has the caret while caret is.
local caret, last = false, nil;
package.loaded['imgui'] = {
    GetIO = function () return { DisplaySize = { x = 2560, y = 1440 } }; end,
    IsItemActive = function ()
        if (last == 'input') then return caret; end
        return active;
    end,
    GetMousePos = function () return mouse, 0; end,
    SetKeyboardFocusHere = function () end,
    PushItemWidth = function () end,
    PopItemWidth = function () end,
    TextDisabled = function () end,
    CloseCurrentPopup = function () seen.closed = true; end,
    InputText = function (_, buf)
        last = 'input';
        if (input[1] ~= nil) then buf[1] = input[1]; end
        return input[2] == true;
    end,
    PushStyleColor = function () depth.color = depth.color + 1; end,
    PopStyleColor = function (n) depth.color = depth.color - (n or 1); end,
    PushStyleVar = function () depth.var = depth.var + 1; end,
    PopStyleVar = function (n) depth.var = depth.var - (n or 1); end,
    PushFont = function () depth.font = depth.font + 1; end,
    PopFont = function () depth.font = depth.font - 1; end,
    CalcTextSize = function (s) return #s * 7, 16; end,
    GetFontSize = function () return 16; end,
    GetWindowDrawList = function () return dl; end,
    SetCursorScreenPos = function (p) seen.cursor = p; end,
    InvisibleButton = function (_, size)
        last = 'button';
        seen.button = size;
        return click;
    end,
    IsItemHovered = function () return hovered; end,
    IsPopupOpen = function (id) return open[id] == true; end,
    OpenPopup = function (id) open[id] = true; end,
    BeginPopup = function (id) return open[id] == true; end,
    EndPopup = function () end,
    SetNextWindowPos = function (p) seen.next_pos = p; end,
    SetNextWindowSizeConstraints = function (a, b) seen.limits = { a, b }; end,
    SetTooltip = function (s) seen.tip = s; end,
    SetNextItemWidth = function () end,
    InputTextWithHint = function () last = 'input'; return false; end,
    SetWindowFontScale = function (s)
        seen.scales = seen.scales or { };
        seen.scales[#seen.scales + 1] = s;
    end,
};
local function balanced(what)
    same(depth.color, 0, what .. ': style colours left pushed');
    same(depth.var, 0, what .. ': style vars left pushed');
    same(depth.font, 0, what .. ': fonts left pushed');
end

vana.frame();  -- 1440 tall: S(n) is n * 1.1
local S = vana.S;

-- The popup style: ten colours and six vars, and they come back off.
local nc, nv = vana.push_popup();
same(nc, 10, 'popup colours');
same(nv, 6, 'popup vars');
vana.pop_popup(nc, nv);
balanced('push_popup');

-- A tooltip is wrapped, its '%' doubled for SetTooltip's printf, and balanced.
reset();
vana.tooltip('50% of the way there');
same(seen.tip, '50%% of the way there', 'tooltip text');
balanced('tooltip');
vana.tooltip(('word '):rep(30));
assert(seen.tip:find('\n', 1, true), 'a long tooltip is not wrapped');

-- The close mark: an X 72% of its box, dim at rest and rose under the pointer,
-- clicked only when nothing over it vetoes.
reset();
hovered, click = false, false;
local clicked, hot = vana.close('x', 100, 100, S(21));
assert(not clicked and not hot, 'an untouched close mark reports a click');
same(#dl.lines, 2, 'close mark strokes');
same(dl.lines[1].col, vana.u32(vana.P.dim), 'close mark at rest');
same(seen.button[1], S(21), 'close box');
local k = S(21) * 0.72 / 24;
same(dl.lines[1].a[1], 100 + (6 - 12) * k, 'close mark size');
reset();
hovered, click = true, true;
clicked, hot = vana.close('x', 100, 100, S(21));
assert(clicked and hot, 'a pressed close mark is not clicked');
same(dl.lines[1].col, vana.u32(vana.P.rose), 'close mark under the pointer');
clicked, hot = vana.close('x', 100, 100, S(21), true);
assert(not clicked and not hot, 'a vetoed close mark still takes the click');
hovered, click = false, false;

-- The group heading: teal capitals, then a teal rule at 0.35 from 10 after them.
-- The stand-in measures every glyph 7 wide, so 'LOOK' is four of them and the
-- three gaps between.
reset();
vana.heading(dl, 10, 50, 'Look', 300);
same(dl.texts[1].s, 'L', 'heading capitals');
same(dl.lines[1].col, vana.u32(vana.P.teal, 0.35), 'heading rule colour');
same(dl.lines[1].b[1], 310, 'heading rule end');
local tw = 4 * 7 + 3 * math.max(1, S(1.2));
same(dl.lines[1].a[1], 10 + tw + S(10), 'heading rule start');

-- The shadow: a pixel past the panel either side, two below, none above.
reset();
vana.shadow(10, 20, 100, 50, dl);
same(dl.rects[1].a[1], 9, 'shadow left');
same(dl.rects[1].a[2], 20, 'shadow top');
same(dl.rects[1].b[1], 111, 'shadow right');
same(dl.rects[1].b[2], 72, 'shadow bottom');

-- The drop-down: no list size set while it is shut; once clicked, a list at
-- least the box's width, and every push popped either way.
reset();
local list_open = vana.combo('##f', 0, 50, 150, 'Arial', function () end);
assert(not list_open and seen.limits == nil, 'a shut drop-down sizes a list');
balanced('combo shut');
click = true;
list_open = vana.combo('##f', 0, 50, 150, 'Arial', function () end);
click = false;
assert(list_open, 'a clicked drop-down does not open');
same(seen.limits[1][1], 150, 'the list is narrower than its box');
same(seen.limits[2][1], S(360), 'the list grows to 360');
balanced('combo open');
open = { };

-- The swatch says its hex, and how opaque a colour that is not solid is.
reset();
vana.swatch('##s', 300, 50, { 1, 1, 1, 0.5 }, false);
same(dl.texts[#dl.texts].s, '#FFFFFF  50%', 'half-alpha swatch label');
reset();
vana.swatch('##s', 300, 50, { 0, 0, 0, 1 }, false);
same(dl.texts[#dl.texts].s, '#000000', 'solid swatch label');
assert(vana.swatch_width() >= S(23) + #'#DDDDDD  100%' * 7, 'swatch room');

-- A chosen row is the accent's ground at 0.9 with its bar; a hovered one the
-- hover band at 0.8; neither, nothing.
reset();
vana.row(dl, 'r1', 0, 0, 200, 30, true, false);
same(#dl.rects, 2, 'chosen row fills');
same(dl.rects[1].col, vana.u32(vana.P.accent_bg, 0.9), 'chosen row ground');
same(dl.rects[2].col, vana.u32(vana.P.accent), 'chosen row bar');
reset();
vana.row(dl, 'r2', 0, 0, 200, 30, false, true);
same(#dl.rects, 1, 'hovered row fills');
same(dl.rects[1].col, vana.u32(vana.P.hover, 0.8), 'hovered row band');
reset();
vana.row(dl, 'r3', 0, 0, 200, 30, false, false);
same(#dl.rects, 0, 'a plain row draws a ground');

-- The slider: 180 wide, so a track of 180 - 52 - 10 from x.  A drag
-- lands on the steps up from the minimum; a typed number lands as a whole
-- one, step or not, on Enter.
local track = S(180) - S(52) - S(10);
reset();
active, mouse = true, 100 + track * 0.5;
local v, moved, typing = vana.slider('##s1', 100, 50, S(180), 100, 25, 400, 5, '%');
same(v % 5, 0, 'a dragged scale between steps');
assert(moved and math.abs(v - 212.5) <= 2.5, 'a drag to the middle of 25..400 lands at ' .. v);
assert(not typing, 'a drag reads as typing');
mouse = 100 - 50;
v = vana.slider('##s1', 100, 50, S(180), v, 25, 400, 5, '%');
same(v, 25, 'a drag past the left end');
mouse = 100 + track + 50;
v = vana.slider('##s1', 100, 50, S(180), v, 25, 400, 5, '%');
same(v, 400, 'a drag past the right end');
v, moved = vana.slider('##s1', 100, 50, S(180), 100, 25, 400, 5, '%', true);
assert(v == 100 and not moved, 'a vetoed slider still drags');
active = false;
same(dl.texts[#dl.texts].s, '100%', 'the value and its unit');
balanced('slider');

-- Clicking the value opens a box for a number; Enter puts it in, held to the
-- bounds and to a whole number, and shut, the box no longer has the keyboard.
reset();
click = true;
local _, click_moved, click_typing = vana.slider('##s2', 100, 50, S(180), 100, 25, 400, 5, '%');
click = false;
assert(click_typing and not click_moved, 'clicking the value opens no box');
input = { '137.4', true };
v, moved = vana.slider('##s2', 100, 50, S(180), 100, 25, 400, 5, '%');
assert(moved and v == 137, 'a typed 137.4 lands as ' .. tostring(v));
input = { '9000', true };
v = vana.slider('##s2', 100, 50, S(180), v, 25, 400, 5, '%');
same(v, 400, 'a typed number past the top');
input = { };
open = { };
local shut_moved, shut_typing = select(2, vana.slider('##s2', 100, 50, S(180), v, 25, 400, 5, '%'));
assert(not shut_typing and not shut_moved, 'a shut box still has the keyboard');
balanced('slider typing');

-- Escape, or a click off the field, takes the caret out with no Enter.  ImGui
-- would leave the box up with no caret in it, and an open box is typing to the
-- map, so the box shuts itself rather than keep the map's keys from it.
reset();
click = true;
vana.slider('##s3', 100, 50, S(180), 100, 25, 400, 5, '%');
click, caret = false, true;
local _, _, caret_typing = vana.slider('##s3', 100, 50, S(180), 100, 25, 400, 5, '%');
assert(caret_typing and not seen.closed, 'a box with the caret in it shut');
caret = false;
local esc_v, esc_moved = vana.slider('##s3', 100, 50, S(180), 100, 25, 400, 5, '%');
assert(seen.closed, 'a box that lost its caret without an Enter stayed up');
assert(esc_v == 100 and not esc_moved, 'a box that lost its caret typed a number');
open = { };
balanced('slider escape');

-- The search box, on a build that cannot push a face at a size, which this
-- stand-in is: the window's font scale takes the text from the size Segoe is
-- baked at to the one asked for, so Tools still sizes it, and is put back.
reset();
vana.field('##q', 0, 0, 300, 40, { 'jeuno' }, 64, 'Search', 36, false);
same(seen.scales and seen.scales[1], 2, 'the search text scale for 36px');
same(seen.scales[#seen.scales], 1, 'the window font scale put back');
balanced('field');

print('ok: palette, scale clamps, the search, config and widget draw with them,'
      .. ' and the controls are VanaCore\'s and leave ImGui balanced');
