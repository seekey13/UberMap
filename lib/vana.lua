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
        local ok, face = pcall(im.AddFontFromFileTTF, path, 18);
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
    fonts.bold_italic = add('segoeuiz.ttf') or semi;
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

local function lift(h)
    if (DYNAMIC and fonts.ready) then
        return math.floor(h * 0.06 + 0.5);
    end
    return 0;
end

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
* A soft shadow just outside a panel. dl nil uses the background list, so a
* window clipped to its own plate still throws a shadow. A plate drawn inside
* another window passes that window's list, or the shadow lands behind it.
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
    local s = vana.S(1);
    vana.fill(dl, x - s, y + s, w + s * 2, h + s * 2, '#000000', vana.S(6), 0.35);
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

function vana.title(dl, x, cy, str, px)
    vana.text_mid(dl, x, cy, str, vana.P.white, 'semi', px or vana.S(19));
end

--[[
* A small-cap section rule. span is the width the rule may run to.
--]]
function vana.heading(dl, x, cy, str, span)
    local title = string.upper(str);
    local px = vana.S(vana.SMALL);
    local spacing = vana.S(1.2);
    if (spacing < 1) then
        spacing = 1;
    end
    local tw = vana.text_spaced(dl, x, cy, title, vana.P.teal, 'semi_italic', px, spacing);
    local line_x = x + tw + vana.S(8);
    local line_end = x + (span or 0);
    if (line_end > line_x + vana.S(4)) then
        dl:AddLine({ line_x, cy }, { line_end, cy }, vana.u32(vana.P.teal, 0.8), 1);
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

local CLEAR = { 0, 0, 0, 0 };

--[[
* The search box. A sunken field with two shadows under it, Segoe text, and a
* rose cross that clears it once it has text. focus hands it the keyboard.
* Returns edited, hovered, active (the caret is in it).
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
        vana.glyph(dl, 'close', bx + xw / 2, y + h / 2,
                   hot and vana.P.white or vana.P.rose, h * 0.42);
    end
    return edited == true, hovered, active;
end

-- Popup lists and the widget's right-click menu, in the palette.
local POPUP_COLORS = {
    { 'PopupBg', 'popup', 0.98 },
    { 'Border', 'border', 1 },
    { 'Text', 'text', 1 },
    { 'Header', 'accent_bg', 1 },
    { 'HeaderHovered', 'hover', 1 },
    { 'HeaderActive', 'accent_lo', 1 },
    { 'Separator', 'line', 1 },
};

function vana.push_popup()
    local im = gui();
    for _, entry in ipairs(POPUP_COLORS) do
        im.PushStyleColor(_G['ImGuiCol_' .. entry[1]], vana.rgba(vana.P[entry[2]], entry[3]));
    end
    im.PushStyleVar(ImGuiStyleVar_WindowPadding, { vana.S(10), vana.S(6) });
    im.PushStyleVar(ImGuiStyleVar_PopupRounding, vana.S(5));
    im.PushStyleVar(ImGuiStyleVar_PopupBorderSize, 1);
    im.PushStyleVar(ImGuiStyleVar_FrameRounding, vana.S(4));
    im.PushStyleVar(ImGuiStyleVar_ItemSpacing, { vana.S(8), vana.S(4) });
    return #POPUP_COLORS, 5;
end

function vana.pop_popup(colors, vars)
    local im = gui();
    im.PopStyleVar(vars or 5);
    im.PopStyleColor(colors or #POPUP_COLORS);
end

--[[
* A drop-down. shown is the closed face; body fills the list with Selectables.
* Returns whether the list is open, and whether the box is hovered.
--]]
function vana.combo(id, x, cy, w, shown, body)
    local im = gui();
    local h = vana.S(24);
    local y = cy - h / 2;
    im.SetCursorScreenPos({ x, y });
    local clicked = im.InvisibleButton(id, { w, h });
    local hovered = im.IsItemHovered();
    local list = id .. '.list';
    local open = false;
    pcall(function ()
        open = im.IsPopupOpen(list) and true or false;
    end);
    if (clicked) then
        im.OpenPopup(list);
        open = true;
    end
    local t = vana.ease(id .. '.hot', ((hovered or open) and 1 or 0));
    local dl = im.GetWindowDrawList();
    local r = vana.S(4);
    vana.fill(dl, x, y, w, h, vana.P.well, r, 1);
    vana.outline(dl, x, y, w, h, vana.mix(vana.P.well_edge, vana.P.accent_lo, t), r, 1);
    local px = vana.S(vana.SMALL + 0.5);
    vana.text_mid(dl, x + vana.S(8), cy, shown, vana.P.text2, 'text', px);
    vana.glyph(dl, open and 'up' or 'down', x + w - vana.S(14), cy, vana.P.dim, vana.S(8));
    -- Only while the list will actually Begin. A position nobody consumes
    -- lands on the next window in the frame.
    if (open) then
        im.SetNextWindowPos({ x, y + h + vana.S(2) });
    end
    local nc, nv = vana.push_popup();
    if (im.BeginPopup(list)) then
        open = true;
        local pushed = vana.push('text', vana.S(vana.BODY - 0.5));
        body();
        if (pushed) then
            vana.pop();
        end
        im.EndPopup();
    end
    vana.pop_popup(nc, nv);
    return open, hovered;
end

--[[
* A pill switch, 32 by 17. Returns the value, whether it changed, hovered.
--]]
function vana.switch(id, x, cy, on)
    local w, h = vana.S(32), vana.S(17);
    local y = cy - h / 2;
    local im = gui();
    im.SetCursorScreenPos({ x, y });
    local clicked = im.InvisibleButton(id, { w, h });
    local hovered = im.IsItemHovered();
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

local step_buf, step_meta = { }, { };

--[[
* A sunken stepper: chevrons on the ends, the number typed in the middle.
* A click steps by `step`, ctrl-click by `fast`, and holding repeats.
* Returns value, changed, typing, hovered.
--]]
function vana.stepper(id, x, cy, w, value, minv, maxv, step, fast)
    local im = gui();
    local h = vana.S(24);
    local y = cy - h / 2;
    local dl = im.GetWindowDrawList();
    local r = vana.S(4);
    vana.fill(dl, x, y, w, h, vana.P.well, r, 1);
    vana.outline(dl, x, y, w, h, vana.P.well_edge, r, 1);
    local cap = math.min(vana.S(24), math.floor(w / 3));
    local buf = step_buf[id];
    if (buf == nil) then
        buf = { tostring(value) };
        step_buf[id] = buf;
    end
    local meta = step_meta[id];
    if (meta == nil) then
        meta = { };
        step_meta[id] = meta;
    end
    if (not meta.editing) then
        buf[1] = tostring(value);
    end

    local changed = false;
    local function apply(v)
        v = math.max(minv, math.min(maxv, math.floor(v + 0.5)));
        if (v ~= value) then
            value = v;
            changed = true;
            buf[1] = tostring(v);
        end
    end

    -- The number is submitted first. The end caps come after it, or the field
    -- covers them and a click on a chevron only puts the caret in the number.
    local field_w = math.max(1, w - cap * 2);
    local px = vana.S(vana.SMALL + 0.5);
    local tw = vana.measure(buf[1] or '', 'text', px);
    local left_pad = math.floor((field_w - tw) / 2);
    if (left_pad < vana.S(2)) then
        left_pad = vana.S(2);
    end
    local pushed = vana.push('text', px);
    local text_h = px;
    local ok_sz, sz = pcall(im.GetFontSize);
    if (ok_sz and sz and sz > 0) then
        text_h = sz;
    end
    im.PushStyleColor(ImGuiCol_FrameBg, CLEAR);
    im.PushStyleColor(ImGuiCol_FrameBgHovered, CLEAR);
    im.PushStyleColor(ImGuiCol_FrameBgActive, CLEAR);
    im.PushStyleColor(ImGuiCol_Text, vana.rgba(vana.P.text2));
    im.PushStyleVar(ImGuiStyleVar_FramePadding, { left_pad, math.max(0, (h - text_h) / 2) });
    im.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 0);
    im.SetCursorScreenPos({ x + cap, y });
    im.SetNextItemWidth(field_w);
    local flags = ImGuiInputTextFlags_CharsDecimal or 0;
    -- The id changes after a step, below. An active field keeps the digits it
    -- was opened with, so a chevron press would land and then be drawn back.
    local edited = im.InputText(id .. '.n' .. tostring(meta.gen or 0), buf, 8, flags);
    local typing = im.IsItemActive();
    im.PopStyleVar(2);
    im.PopStyleColor(4);
    if (pushed) then
        vana.pop();
    end
    if (edited) then
        local n = tonumber(buf[1]);
        if (n ~= nil) then
            apply(n);
        end
    end

    local ax, ay = im.GetMousePos();
    local mx, my = ax, ay;
    if (type(ax) ~= 'number') then
        local ok, px_, py_ = pcall(function ()
            return ax.x or ax[1], ax.y or ax[2];
        end);
        mx, my = (ok and type(px_) == 'number') and px_ or nil,
                 (ok and type(py_) == 'number') and py_ or nil;
    end
    -- A popup over the row is another window. A click there is not a step.
    local win_hot = false;
    pcall(function ()
        win_hot = im.IsWindowHovered() and true or false;
    end);
    local function on(v)
        return v == true or v == 1;
    end
    local held_any, hot_any, stepped = false, false, false;
    local function endcap(side, dx, dir)
        local bx = x + dx;
        im.SetCursorScreenPos({ bx, y });
        im.InvisibleButton(id .. side, { math.max(1, cap), h });
        -- IsItemClicked, not the button's return: that return stays false on
        -- this build. The rect covers a field that still overlaps the cap and
        -- would otherwise take the click for itself.
        local item_hot = im.IsItemHovered();
        local item_click = on(im.IsItemClicked(0));
        local over = mx ~= nil and my ~= nil
                     and mx >= bx and mx < bx + cap and my >= y and my < y + h;
        local clicked = item_click or (over and win_hot and on(im.IsMouseClicked(0)));
        local arm = meta[side] or { };
        meta[side] = arm;
        local held = on(im.IsItemActive())
                     or clicked
                     or (over and win_hot and on(im.IsMouseDown(0)) and arm.at ~= nil);
        local hot = item_hot or (over and win_hot);
        held_any = held_any or held;
        hot_any = hot_any or hot;
        if (hot) then
            local corners = (dir < 0)
                and (rawget(_G, 'ImDrawFlags_RoundCornersLeft')
                     or rawget(_G, 'ImDrawCornerFlags_Left'))
                or (rawget(_G, 'ImDrawFlags_RoundCornersRight')
                    or rawget(_G, 'ImDrawCornerFlags_Right'));
            vana.fill(dl, bx + ((dir < 0) and 1 or 0), y + 1, cap - 1, h - 2,
                      '#FFFFFF', math.max(0, r - 1), 0.07, corners);
        end
        vana.glyph(dl, (dir < 0) and 'left' or 'right',
                   bx + cap / 2, cy, hot and vana.P.text or vana.P.dim, vana.S(8));
        local now = os.clock();
        if (not held) then
            arm.at = nil;
        else
            local due = clicked and true or false;
            if (not due and arm.at ~= nil) then
                local gap = (now - arm.at > 0.4) and 0.06 or 999;
                due = now - (arm.step or 0) >= gap;
            end
            if (due) then
                local io_ok, io = pcall(im.GetIO);
                local ctrl = io_ok and io and (io.KeyCtrl == true or io.KeyCtrl == 1);
                local d = ctrl and fast or step;
                apply(value + dir * d);
                stepped = true;
                arm.step = now;
                if (arm.at == nil) then
                    arm.at = now;
                end
            end
        end
    end
    endcap('.dec', 0, -1);
    endcap('.inc', math.max(0, w - cap), 1);

    -- A step has to win over the caret. The next frame draws a new field, so
    -- the one that took the click cannot write the old digits back.
    if (stepped) then
        meta.gen = (meta.gen or 0) + 1;
        meta.editing = false;
    else
        meta.editing = typing;
    end
    hot_any = hot_any or (not stepped and typing);
    return value, changed, meta.editing, hot_any or held_any;
end

return vana;
