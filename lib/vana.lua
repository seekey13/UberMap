--[[
* Vanacore look for UberMap's search box, config panel, favorites widget
* and the warp list hung off a zone point.
*
* The palette and the type are the /vana window's: a dark navy ground, one
* blue accent, and Segoe UI. Sizes for the panel go through S(), which follows
* the screen the way that window does. The search box keeps the Tools and
* Search W scales, and the map's own labels stay on the face the Font row picks.
*
* Controls are a hit target plus a drawing. ImGui still owns the text field,
* the colour picker and popup lists, with the palette pushed onto them.
*
* Sizes and colours follow Sidekick3's ui/kit.lua and ui/window.lua, which
* are the /vana window as an Ashita addon draws it: its title bar, close mark,
* group headings, rows, drop-down, popups and tooltips.
--]]

local vana = { };

-- One palette. Colours stay '#RRGGBB' until a draw asks for them.
vana.P = {
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

-- Body and small text, in unscaled pixels. S() is what a draw passes.
vana.BODY  = 16;
vana.SMALL = 13.5;

local DYNAMIC = (tonumber(IMGUI_VERSION_NUM) or 0) >= 19200;
-- The pixel size Segoe is baked at, and so what a build that is not DYNAMIC
-- draws it at whatever size is asked for.
local BAKE = 18;

local function gui()
    return require('imgui');
end

--[[
* '#RRGGBB' and an alpha, as the ABGR word a draw list takes.
--]]
function vana.u32(hex, alpha)
    local r = tonumber(hex:sub(2, 3), 16);
    local g = tonumber(hex:sub(4, 5), 16);
    local b = tonumber(hex:sub(6, 7), 16);
    local a = math.floor(math.max(0, math.min(1, alpha or 1)) * 255 + 0.5);
    return ((a * 256 + b) * 256 + g) * 256 + r;
end

--[[
* The same colour as the { r, g, b, a } floats PushStyleColor takes.
--]]
function vana.rgba(hex, alpha)
    return {
        tonumber(hex:sub(2, 3), 16) / 255,
        tonumber(hex:sub(4, 5), 16) / 255,
        tonumber(hex:sub(6, 7), 16) / 255,
        alpha or 1,
    };
end

--[[
* The colour t of the way from a to b. t is 0..1.
--]]
function vana.mix(a, b, t)
    t = math.max(0, math.min(1, t or 0));
    local out = '#';
    for i = 2, 6, 2 do
        local x = tonumber(a:sub(i, i + 1), 16);
        local y = tonumber(b:sub(i, i + 1), 16);
        out = out .. string.format('%02X', math.floor(x + (y - x) * t + 0.5));
    end
    return out;
end

-- 1440px tall is 1.1. Shorter screens stop at 0.75 of that ratio, taller at 1.6.
local scale = 1;

function vana.scale_to(screen_h)
    local h = tonumber(screen_h) or 1080;
    scale = math.max(0.75, math.min(1.6, h / 1440)) * 1.1;
end

function vana.S(n)
    return math.floor(n * scale + 0.5);
end

-- Segoe UI, one face per weight. Nil until bake finds the file.
local fonts = { ready = false };
local fonts_tried = false;

local measured, measured_scale, measured_n = { }, nil, 0;
local anim, last_clock, frame_dt = { }, nil, 0;

local function tick()
    local now = os.clock();
    frame_dt = last_clock and math.max(0, math.min(0.1, now - last_clock)) or 0;
    last_clock = now;
end

--[[
* id moves towards target. A new id starts there, so a control does not
* animate in from zero the frame it first draws. speed is how fast, and the
* close mark uses a quicker one than a switch.
--]]
function vana.ease(id, target, speed)
    local v = anim[id];
    if (v == nil) then
        v = target;
    else
        v = v + (target - v) * math.min(1, frame_dt * (speed or 18));
        if (math.abs(v - target) < 0.004) then
            v = target;
        end
    end
    anim[id] = v;
    return v;
end

--[[
* Segoe UI from Windows, baked once. Called from the load event, outside any
* frame: the atlas is shared, and adding to it mid-frame is the crash the map's
* font picker already guards against. A missing file leaves that face out and
* text falls back to ImGui's own.
--]]
function vana.bake()
    if (fonts_tried) then
        return;
    end
    fonts_tried = true;
    local im = gui();
    local dir = ((os.getenv and os.getenv('WINDIR')) or 'C:\\Windows') .. '\\Fonts\\';
    local function add(file)
        local path = dir .. file;
        local handle = io.open(path, 'rb');
        if (not handle) then
            return nil;
        end
        handle:close();
        local ok, face = pcall(im.AddFontFromFileTTF, path, BAKE);
        if (ok and face) then
            return face;
        end
        return nil;
    end
    local text = add('segoeui.ttf');
    if (not text) then
        return;
    end
    local semi = add('seguisb.ttf') or text;
    fonts.text = text;
    fonts.semi = semi;
    fonts.semi_italic = add('seguisbi.ttf') or semi;
    fonts.ready = true;
end

--[[
* Once a frame, before anything draws. The screen sets the scale, and a scale
* change throws out cached measurements.
--]]
function vana.frame()
    local h = 1080;
    local ok, io = pcall(function ()
        return gui().GetIO();
    end);
    if (ok and io and io.DisplaySize) then
        h = tonumber(io.DisplaySize.y) or h;
    end
    vana.scale_to(h);
    if (measured_scale ~= scale) then
        measured, measured_scale, measured_n = { }, scale, 0;
    end
    tick();
end

--[[
* Puts face `which` on the font stack at px, when Segoe loaded. False when the
* caller should leave ImGui's own font where it is. On a build that cannot
* draw a font at an arbitrary size, the face still goes on at the size it was
* baked at.
--]]
function vana.push(which, px)
    local face = fonts[which];
    if (not (fonts.ready and face)) then
        return false;
    end
    local im = gui();
    if (DYNAMIC) then
        im.PushFont(face, px);
    else
        im.PushFont(face);
    end
    return true;
end

function vana.pop()
    gui().PopFont();
end

local function text_wh(w, h)
    if (type(w) == 'table') then
        return w.x or w[1] or 0, w.y or w[2] or 0;
    end
    return w or 0, h or 0;
end

--[[
* Width and height of str in face `which` at px. Cached: the same labels are
* measured every frame.
--]]
function vana.measure(str, which, px)
    str = tostring(str or '');
    px = px or vana.S(vana.BODY);
    if (measured_scale ~= scale or measured_n > 4000) then
        measured, measured_scale, measured_n = { }, scale, 0;
    end
    local face = fonts[which];
    local key = tostring(face) .. '|' .. tostring(px) .. '|' .. str;
    local found = measured[key];
    if (found) then
        return found[1], found[2];
    end
    local im = gui();
    local w, h;
    if (fonts.ready and face and DYNAMIC) then
        im.PushFont(face, px);
        w, h = text_wh(im.CalcTextSize(str));
        im.PopFont();
    elseif (fonts.ready and face) then
        -- Baked at 18, and PushFont cannot take a size on this build, so
        -- AddText draws 18. Measuring 18 is what keeps a label inside its row.
        im.PushFont(face);
        w, h = text_wh(im.CalcTextSize(str));
        im.PopFont();
    else
        w, h = text_wh(im.CalcTextSize(str));
    end
    measured[key] = { w, h };
    measured_n = measured_n + 1;
    return w, h;
end

--[[
* Segoe's line holds a tall ascent and a descent, so text centred by its box
* sits low. This is how far to raise it. Text a caller places by hand, off
* CalcTextSize, takes it too.
--]]
local function lift(h)
    if (DYNAMIC and fonts.ready) then
        return math.floor(h * 0.06 + 0.5);
    end
    return 0;
end
vana.lift = lift;

--[[
* str with its middle on cy. which is a face name ('text', 'semi', ...).
--]]
function vana.text_mid(dl, x, cy, str, hex, which, px, alpha)
    local _, h = vana.measure(str, which, px);
    local y = cy - h / 2 - lift(h);
    local pushed = vana.push(which, px);
    dl:AddText({ x, y }, vana.u32(hex, alpha), str);
    if (pushed) then
        vana.pop();
    end
end

--[[
* Capitals one glyph at a time, spacing pixels apart. Returns the width.
* dl nil only measures, which is how a heading knows where its rule starts.
--]]
function vana.text_spaced(dl, x, cy, str, hex, which, px, spacing, alpha)
    str = tostring(str or '');
    spacing = spacing or 0;
    local start, i, n = x, 1, #str;
    while (i <= n) do
        local b = str:byte(i);
        local len = 1;
        if (b >= 0xF0) then
            len = 4;
        elseif (b >= 0xE0) then
            len = 3;
        elseif (b >= 0xC0) then
            len = 2;
        end
        local letter = str:sub(i, i + len - 1);
        if (dl ~= nil) then
            vana.text_mid(dl, x, cy, letter, hex, which, px, alpha);
        end
        x = x + vana.measure(letter, which, px) + spacing;
        i = i + len;
    end
    if (x == start) then
        return 0;
    end
    return x - start - spacing;
end

function vana.fill(dl, x, y, w, h, hex, radius, alpha, corners)
    if (w <= 0 or h <= 0) then
        return;
    end
    local col = vana.u32(hex, alpha);
    if (corners == nil) then
        dl:AddRectFilled({ x, y }, { x + w, y + h }, col, radius or 0);
    else
        dl:AddRectFilled({ x, y }, { x + w, y + h }, col, radius or 0, corners);
    end
end

function vana.outline(dl, x, y, w, h, hex, radius, alpha)
    if (w <= 0 or h <= 0) then
        return;
    end
    dl:AddRect({ x, y }, { x + w, y + h }, vana.u32(hex, alpha), radius or 0);
end

--[[
* A soft shadow just outside a panel: a pixel past it either side and two
* below. dl nil uses the background list, so a window clipped to its own
* plate still throws a shadow. A plate drawn inside another window passes that
* window's list, or the shadow lands behind it.
--]]
function vana.shadow(x, y, w, h, dl)
    if (dl == nil) then
        local im = gui();
        local ok, back = pcall(im.GetBackgroundDrawList);
        if (ok and back ~= nil) then
            dl = back;
        else
            dl = im.GetWindowDrawList();
        end
    end
    vana.fill(dl, x - 1, y, w + 2, h + 2, '#000000', vana.S(6), 0.35);
end

--[[
* The panel plate: shadow, ground, hairline. The shadow stays on dl, with the
* plate, so a panel inside the map is not hidden behind the map.
--]]
function vana.plate(dl, x, y, w, h)
    local r = vana.S(5);
    vana.shadow(x, y, w, h, dl);
    vana.fill(dl, x, y, w, h, vana.P.bg, r, 1);
    vana.outline(dl, x, y, w, h, vana.P.border, r, 1);
end

-- A window's name on its title bar: semibold, white, at the body size.
function vana.title(dl, x, cy, str, px)
    vana.text_mid(dl, x, cy, str, vana.P.white, 'semi', px or vana.S(vana.BODY));
end

--[[
* A group's heading: spaced small capitals in teal, then a faint teal rule.
* span is the width the rule may run to.
--]]
function vana.heading(dl, x, cy, str, span)
    local title = string.upper(str);
    local px = vana.S(vana.SMALL);
    local spacing = math.max(1, vana.S(1.2));
    local tw = vana.text_spaced(dl, x, cy, title, vana.P.teal, 'semi_italic', px, spacing);
    local line_x = x + tw + vana.S(10);
    local line_end = x + (span or 0);
    if (line_end > line_x) then
        dl:AddLine({ line_x, cy }, { line_end, cy }, vana.u32(vana.P.teal, 0.35), 1);
    end
end

function vana.label(dl, x, cy, str, px)
    vana.text_mid(dl, x, cy, str, vana.P.text, 'text', px or vana.S(vana.BODY));
end

--[[
* A chevron or a close mark, px pixels across, centred on cx, cy.
--]]
function vana.glyph(dl, kind, cx, cy, hex, px, alpha)
    local k = (px or 11) / 24;
    local col = vana.u32(hex, alpha);
    local thickness = math.max(1, 2 * k);
    local function p(px_, py)
        return { cx + (px_ - 12) * k, cy + (py - 12) * k };
    end
    if (kind == 'right') then
        dl:AddLine(p(9, 5), p(16, 12), col, thickness);
        dl:AddLine(p(16, 12), p(9, 19), col, thickness);
    elseif (kind == 'left') then
        dl:AddLine(p(15, 5), p(8, 12), col, thickness);
        dl:AddLine(p(8, 12), p(15, 19), col, thickness);
    elseif (kind == 'up') then
        dl:AddLine(p(5, 15), p(12, 8), col, thickness);
        dl:AddLine(p(12, 8), p(19, 15), col, thickness);
    elseif (kind == 'close') then
        dl:AddLine(p(6, 6), p(18, 18), col, thickness);
        dl:AddLine(p(18, 6), p(6, 18), col, thickness);
    else
        dl:AddLine(p(5, 9), p(12, 16), col, thickness);
        dl:AddLine(p(12, 16), p(19, 9), col, thickness);
    end
end

--[[
* A window's close mark: an X 72% of its box, dim until the pointer is on it
* and then rose, with no disc behind it. box is the square that takes the
* click, centred on cx, cy. veto stands it down while something drawn over it
* owns the cursor. Returns clicked, hovered.
--]]
function vana.close(id, cx, cy, box, veto)
    local im = gui();
    im.SetCursorScreenPos({ cx - box / 2, cy - box / 2 });
    local clicked = im.InvisibleButton(id, { box, box });
    local hovered = im.IsItemHovered() and not veto;
    vana.glyph(im.GetWindowDrawList(), 'close', cx, cy,
               hovered and vana.P.rose or vana.P.dim, box * 0.72);
    return (clicked and not veto) and true or false, hovered;
end

local CLEAR = { 0, 0, 0, 0 };

--[[
* The search box. A sunken field with two shadows under it, Segoe text, and a
* rose cross that clears it once it has text, lightening under the pointer.
* focus hands it the keyboard. Returns edited, hovered, active (the caret is
* in it).
--]]
function vana.field(id, x, y, w, h, buf, max, hint, font_px, focus)
    local im = gui();
    local dl = im.GetWindowDrawList();
    local r = math.max(4, math.floor(h * 0.22 + 0.5));
    vana.fill(dl, x, y + 2, w, h, '#000000', r, 0.30);
    vana.fill(dl, x, y + 4, w, h, '#000000', r, 0.18);
    vana.fill(dl, x, y, w, h, vana.P.field, r, 1);
    vana.outline(dl, x, y, w, h, vana.P.field_edge, r, 1);

    local show_x = buf[1] ~= nil and buf[1] ~= '';
    local xw = show_x and math.floor(h * 0.9) or 0;
    local pad = math.max(8, math.floor(h * 0.28 + 0.5));
    local pushed = vana.push('text', font_px);
    -- A build that cannot push a face at a size draws it at BAKE, so the
    -- window's font scale makes up the rest, the way the map's own labels
    -- reach theirs: font_px follows Tools, and the text has to as well.
    -- ImGui's own font, where Segoe would not load, goes by the same ratio.
    -- Put back before the icons on the row draw.
    if (not DYNAMIC) then
        im.SetWindowFontScale(font_px / BAKE);
    end
    local text_h = font_px;
    local ok_sz, sz = pcall(im.GetFontSize);
    if (ok_sz and sz and sz > 0) then
        text_h = sz;
    end
    local vpad = math.max(0, (h - text_h) / 2);

    im.PushStyleColor(ImGuiCol_FrameBg, CLEAR);
    im.PushStyleColor(ImGuiCol_FrameBgHovered, CLEAR);
    im.PushStyleColor(ImGuiCol_FrameBgActive, CLEAR);
    im.PushStyleColor(ImGuiCol_Text, vana.rgba(vana.P.text));
    im.PushStyleColor(ImGuiCol_TextDisabled, vana.rgba(vana.P.faint));
    im.PushStyleVar(ImGuiStyleVar_FramePadding, { pad, vpad });
    im.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 0);
    im.SetCursorScreenPos({ x, y });
    if (focus) then
        im.SetKeyboardFocusHere();
    end
    im.SetNextItemWidth(math.max(1, w - xw));
    local edited = im.InputTextWithHint(id, hint or '', buf, max);
    local hovered = im.IsItemHovered();
    local active = im.IsItemActive();
    im.PopStyleVar(2);
    im.PopStyleColor(5);
    if (not DYNAMIC) then
        im.SetWindowFontScale(1.0);
    end
    if (pushed) then
        vana.pop();
    end

    if (show_x) then
        local bx = x + w - xw;
        im.SetCursorScreenPos({ bx, y });
        if (im.InvisibleButton(id .. '.x', { xw, h })) then
            buf[1] = '';
            edited = true;
        end
        local hot = im.IsItemHovered();
        hovered = hovered or hot;
        local t = vana.ease(id .. '.x', hot and 1 or 0, 22);
        vana.glyph(dl, 'close', bx + xw / 2, y + h / 2,
                   vana.mix(vana.P.rose, '#FFA7AE', t), h * 0.42);
    end
    return edited == true, hovered, active;
end

-- Popup lists, colour pickers and the widget's right-click menu, in the
-- palette.
local POPUP_COLORS = {
    { 'PopupBg', 'popup' },
    { 'Border', 'border' },
    { 'Text', 'text' },
    { 'Header', 'accent_bg' },
    { 'HeaderHovered', 'hover' },
    { 'HeaderActive', 'accent_lo' },
    { 'Separator', 'line' },
    { 'FrameBg', 'well' },
    { 'FrameBgHovered', 'well' },
    { 'FrameBgActive', 'well' },
};

--[[
* ImGui's own popups in the palette, with the padding the panels here take
* away. Returns the counts pop_popup takes back off.
--]]
function vana.push_popup()
    local im = gui();
    for _, entry in ipairs(POPUP_COLORS) do
        im.PushStyleColor(_G['ImGuiCol_' .. entry[1]], vana.rgba(vana.P[entry[2]]));
    end
    im.PushStyleVar(ImGuiStyleVar_WindowPadding, { vana.S(10), vana.S(8) });
    im.PushStyleVar(ImGuiStyleVar_PopupRounding, vana.S(5));
    im.PushStyleVar(ImGuiStyleVar_PopupBorderSize, 1);
    im.PushStyleVar(ImGuiStyleVar_FramePadding, { vana.S(8), vana.S(4) });
    im.PushStyleVar(ImGuiStyleVar_FrameRounding, vana.S(4));
    im.PushStyleVar(ImGuiStyleVar_ItemSpacing, { vana.S(8), vana.S(6) });
    return #POPUP_COLORS, 6;
end

function vana.pop_popup(colors, vars)
    local im = gui();
    im.PopStyleVar(vars or 6);
    im.PopStyleColor(colors or #POPUP_COLORS);
end

-- Lines past n characters broken at a space, so a tooltip stays narrow.
local function wrap_chars(s, n)
    local out = { };
    for line in (s .. '\n'):gmatch('(.-)\n') do
        while (#line > n) do
            local cut = line:sub(1, n + 1):match('^.*() ');
            if (not cut or cut < n / 2) then
                break;
            end
            out[#out + 1], line = line:sub(1, cut - 1), line:sub(cut + 1);
        end
        out[#out + 1] = line;
    end
    return table.concat(out, '\n');
end

local TIP_COLORS = {
    { 'PopupBg', 'popup', 0.97 },
    { 'Border', 'border', 1 },
    { 'Text', 'text', 1 },
};

--[[
* A tooltip by the mouse, in the palette and Segoe, wrapped. SetTooltip takes
* a printf format on Ashita 4.16's interface, so its '%' are doubled.
--]]
function vana.tooltip(s)
    if (s == nil or s == '') then
        return;
    end
    local im = gui();
    for _, entry in ipairs(TIP_COLORS) do
        im.PushStyleColor(_G['ImGuiCol_' .. entry[1]], vana.rgba(vana.P[entry[2]], entry[3]));
    end
    im.PushStyleVar(ImGuiStyleVar_WindowPadding, { vana.S(9), vana.S(6) });
    im.PushStyleVar(ImGuiStyleVar_WindowRounding, vana.S(4));
    im.PushStyleVar(ImGuiStyleVar_PopupRounding, vana.S(4));
    im.PushStyleVar(ImGuiStyleVar_PopupBorderSize, 1);
    local pushed = vana.push('text', vana.S(vana.SMALL + 0.5));
    im.SetTooltip((wrap_chars(tostring(s), 72):gsub('%%', '%%%%')));
    if (pushed) then
        vana.pop();
    end
    im.PopStyleVar(4);
    im.PopStyleColor(#TIP_COLORS);
end

--[[
* A drop-down. shown is the closed face; body fills the list with Selectables.
* The list is at least as wide as the box. Returns whether the list is open,
* and whether the box is hovered.
--]]
function vana.combo(id, x, cy, w, shown, body)
    local im = gui();
    local h, pad = vana.S(24), vana.S(8);
    local y = cy - h / 2;
    im.SetCursorScreenPos({ x, y });
    local clicked = im.InvisibleButton(id, { w, h });
    local hovered = im.IsItemHovered();
    local list = id .. '.list';
    local open = im.IsPopupOpen(list) == true;
    local dl = im.GetWindowDrawList();
    local r = vana.S(4);
    vana.fill(dl, x, y, w, h, vana.P.well, r, 1);
    vana.outline(dl, x, y, w, h, (hovered or open) and vana.P.accent_lo or vana.P.well_edge, r, 1);
    vana.text_mid(dl, x + pad, cy, shown, vana.P.text2, 'text', vana.S(vana.SMALL + 0.5));
    vana.glyph(dl, open and 'right' or 'down', x + w - pad - vana.S(4), cy, vana.P.dim, vana.S(11));
    if (clicked) then
        im.OpenPopup(list);
        open = true;
    end
    -- Only while the list will actually Begin. A position nobody consumes
    -- lands on the next window in the frame.
    if (open) then
        im.SetNextWindowPos({ x, y + h + vana.S(2) });
        im.SetNextWindowSizeConstraints({ w, 0 }, { math.max(w, vana.S(360)), vana.S(420) });
    end
    local nc, nv = vana.push_popup();
    if (im.BeginPopup(list)) then
        open = true;
        local pushed = vana.push('text', vana.S(vana.BODY - 1));
        body();
        if (pushed) then
            vana.pop();
        end
        im.EndPopup();
    end
    vana.pop_popup(nc, nv);
    return open, hovered;
end

-- '#RRGGBB' of the { r, g, b, a } floats a colour picker edits.
local function hex_of(col)
    local function byte(f)
        return math.floor(math.max(0, math.min(1, tonumber(f) or 0)) * 255 + 0.5);
    end
    return string.format('#%02X%02X%02X', byte(col[1]), byte(col[2]), byte(col[3]));
end

-- What a swatch says beside its square: the hex, and how opaque when not solid.
local function swatch_label(col)
    local a = math.max(0, math.min(1, tonumber(col[4]) or 1));
    if (a < 1) then
        return string.format('%s  %d%%', hex_of(col), math.floor(a * 100 + 0.5)), a;
    end
    return hex_of(col), a;
end

--[[
* The most room a swatch can take: its square, the gap, and the widest label
* any colour gives it. A panel sized by this does not change width as an
* alpha is dragged.
--]]
function vana.swatch_width()
    return vana.S(16) + vana.S(7)
           + vana.measure('#DDDDDD  100%', 'text', vana.S(vana.SMALL + 0.5));
end

--[[
* A colour swatch and its hex, the pair ending at right: a 16px rounded square
* of the colour at its own alpha, edged faint white, or in the accent while
* hovered or while its picker is open. A colour that is not solid says how
* opaque it is after its hex. col is the { r, g, b, a } floats the picker
* edits. Returns clicked, hovered.
--]]
function vana.swatch(id, right, cy, col, open)
    local im = gui();
    local h, sq = vana.S(20), vana.S(16);
    local y = cy - h / 2;
    local px = vana.S(vana.SMALL + 0.5);
    local hex = hex_of(col);
    local label, a = swatch_label(col);
    local tw = vana.measure(label, 'text', px);
    local w = sq + vana.S(7) + tw;
    local x = right - w;
    im.SetCursorScreenPos({ x, y });
    local clicked = im.InvisibleButton(id, { w, h });
    local hovered = im.IsItemHovered();
    local dl = im.GetWindowDrawList();
    if (open) then
        vana.fill(dl, x - vana.S(4), y, w + vana.S(8), h, vana.P.hover, vana.S(4), 1);
    end
    local lit = hovered or open;
    vana.fill(dl, x, y + vana.S(2), sq, h - vana.S(4), hex, vana.S(3), a);
    vana.outline(dl, x, y + vana.S(2), sq, h - vana.S(4),
                 lit and vana.P.accent or '#FFFFFF', vana.S(3), lit and 0.8 or 0.15);
    vana.text_mid(dl, right - tw, cy, label, vana.P.text2, 'text', px);
    return clicked and true or false, hovered;
end

--[[
* A list row's ground. The chosen row eases in the accent's ground and a 2px
* accent bar down its left; a row under the pointer that is not the chosen
* one takes the hover band. Inset a pixel top and bottom, so a lit first or
* last row leaves the panel's edge showing.
--]]
function vana.row(dl, id, x, y, w, h, chosen, hovered)
    local S = vana.S;
    local t = vana.ease(id, chosen and 1 or 0, 20);
    if (t > 0.01) then
        vana.fill(dl, x + S(4), y + 1, w - S(8), h - 2, vana.P.accent_bg, S(3), 0.9 * t);
        vana.fill(dl, x + S(4), y + S(5), S(2), h - S(10), vana.P.accent, S(1), t);
    end
    if (hovered and not chosen) then
        vana.fill(dl, x + S(4), y + 1, w - S(8), h - 2, vana.P.hover, S(3), 0.8);
    end
end

--[[
* A pill switch, 32 by 17. veto stands it down while something drawn over it
* owns the cursor. Returns the value, whether it changed, hovered.
--]]
function vana.switch(id, x, cy, on, veto)
    local w, h = vana.S(32), vana.S(17);
    local y = cy - h / 2;
    local im = gui();
    im.SetCursorScreenPos({ x, y });
    local clicked = im.InvisibleButton(id, { w, h }) and not veto;
    local hovered = im.IsItemHovered() and not veto;
    if (clicked) then
        on = not on;
    end
    local t = vana.ease(id, on and 1 or 0);
    local dl = im.GetWindowDrawList();
    vana.fill(dl, x, y, w, h, vana.mix(vana.P.off, vana.P.accent, t), h / 2, 1);
    if (hovered) then
        vana.fill(dl, x, y, w, h, '#FFFFFF', h / 2, 0.08);
    end
    local knob_r = (h - vana.S(4)) / 2;
    local knob_x = x + vana.S(2) + knob_r + (w - vana.S(4) - knob_r * 2) * t;
    dl:AddCircleFilled({ knob_x, cy }, knob_r, vana.u32(vana.P.knob), 24);
    return on, clicked and true or false, hovered;
end

local numbers = { };  -- a slider's id -> its typed number's text ({ s }), while that box is open

local function mouse_x(im)
    local mx = im.GetMousePos();
    if (type(mx) == 'table') then
        mx = mx.x or mx[1];
    end
    return tonumber(mx) or 0;
end

--[[
* The number typed in slider id's box, once Enter is pressed; nil until then.
* Escape or a click away shuts the box and types nothing.  ImGui itself only
* takes the caret out on Escape and leaves the box up, and an open box is what
* the map counts as typing, so its keys would stay the game's until a click.
--]]
local function number_box(id, minv, maxv)
    local im = gui();
    local typed = nil;
    local buf = numbers[id];
    local nc, nv = vana.push_popup();
    if (im.BeginPopup(id .. '.number')) then
        local pushed = vana.push('text', vana.S(vana.SMALL + 1));
        if (buf.focus) then
            im.SetKeyboardFocusHere();
            buf.focus = false;
        end
        im.PushItemWidth(vana.S(90));
        local flags = (ImGuiInputTextFlags_CharsDecimal or 0)
                      + (ImGuiInputTextFlags_EnterReturnsTrue or 0)
                      + (ImGuiInputTextFlags_AutoSelectAll or 0);
        if (im.InputText('##' .. id .. '.typed', buf, 16, flags)) then
            typed = tonumber(buf[1]);
            im.CloseCurrentPopup();
        elseif (buf.caret and not im.IsItemActive()) then
            im.CloseCurrentPopup();
        end
        buf.caret = im.IsItemActive();
        im.PopItemWidth();
        im.TextDisabled(string.format('%d to %d', minv, maxv));
        if (pushed) then
            vana.pop();
        end
        im.EndPopup();
    else
        numbers[id] = nil;
    end
    vana.pop_popup(nc, nv);
    return typed;
end

--[[
* A slider, w wide: the track, then the value with unit after it, which a
* click lets you type. A drag lands on the steps up from minv; a typed number
* is held to a whole one. veto stands it down while something drawn over it
* owns the cursor. Returns value, changed (each frame it moves), typing (its
* number box has the keyboard), hovered.
--]]
function vana.slider(id, x, cy, w, value, minv, maxv, step, unit, veto)
    local im = gui();
    local S, P = vana.S, vana.P;
    local dl = im.GetWindowDrawList();
    local value_w = S(52);
    local track = w - value_w - S(10);
    local function held(v)
        return math.max(minv, math.min(maxv, v));
    end
    -- The press area runs past the track's ends, so the knob drawn half past
    -- either end is still the slider's and not the map's to pan.
    im.SetCursorScreenPos({ x - S(4), cy - S(9) });
    im.InvisibleButton(id, { track + S(12), S(18) });
    local hovered = im.IsItemHovered() and not veto;
    local dragging = (im.IsItemActive() and not veto) and true or false;
    local changed = false;
    if (dragging) then
        local f = math.max(0, math.min(1, (mouse_x(im) - x) / track));
        local v = minv + (maxv - minv) * f;
        v = held(minv + math.floor((v - minv) / step + 0.5) * step);
        if (v ~= value) then
            value, changed = v, true;
        end
    end
    local f = (maxv > minv) and math.max(0, math.min(1, (value - minv) / (maxv - minv))) or 0;
    local th = S(4);
    vana.fill(dl, x, cy - th / 2, track, th, P.off, th / 2, 1);
    if (f > 0) then
        vana.fill(dl, x, cy - th / 2, math.max(th, track * f), th, P.accent, th / 2, 1);
    end
    local lit = vana.ease(id .. '.lit', (hovered or dragging) and 1 or 0, 22);
    dl:AddCircleFilled({ x + track * f, cy }, S(5.5) + S(1) * lit,
                       vana.u32(dragging and P.accent2 or vana.mix(P.knob, P.accent2, lit * 0.5)), 24);

    local vx = x + track + S(10);
    im.SetCursorScreenPos({ vx, cy - S(10) });
    local vclick = im.InvisibleButton(id .. '.value', { value_w, S(20) }) and not veto;
    local vhov = im.IsItemHovered() and not veto;
    if (vhov) then
        vana.fill(dl, vx, cy - S(10), value_w, S(20), P.hover, S(3), 1);
    end
    local px = S(vana.SMALL + 0.5);
    local shown = tostring(math.floor(value + 0.5)) .. (unit or '');
    vana.text_mid(dl, vx + value_w - S(4) - vana.measure(shown, 'text', px), cy,
                  shown, P.text2, 'text', px);
    if (vclick) then
        numbers[id] = { tostring(math.floor(value + 0.5)), focus = true };
        im.OpenPopup(id .. '.number');
    end
    if (numbers[id] ~= nil) then
        local typed = number_box(id, minv, maxv);
        if (typed ~= nil) then
            local v = held(math.floor(typed + 0.5));
            if (v ~= value) then
                value, changed = v, true;
            end
        end
    end
    return value, changed, numbers[id] ~= nil, hovered or vhov or dragging;
end

return vana;
