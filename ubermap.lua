--[[
* UberMap - by Seekey
*
* Shows the server map, automatically whenever you interact with a Home Point.
* Mouse wheel zooms, left-drag pans.  /ubermap or /um toggles it by hand.
--]]

addon.name    = 'UberMap';
addon.author  = 'Seekey';
addon.version = '1.0';
addon.desc    = 'Displays the server map, automatically on Home Point interaction.';

require('common');

local imgui = require('imgui');
local ffi   = require('ffi');
local d3d   = require('d3d8');
local mm    = require('mapmath');

local C       = ffi.C;
local d3d8dev = d3d.get_device();

-- Present_Map.jpg is 5504x3072.  D3D8 rounds non-power-of-two textures up, so
-- loading it natively lands on 8192x4096 (~134MB, doubled again by the managed
-- pool's system copy) which risks exhausting FFXI's 32-bit address space.  We
-- force a power-of-two 4096x2048 (~32MB) instead; drawing at MAP_W x MAP_H
-- undoes the squash, at the cost of some detail at full zoom.
local MAP_W, MAP_H = 5504, 3072;
local TEX_W, TEX_H = 4096, 2048;

-- Home Point entities are named 'Home Point #1', 'Home Point #2' and so on.
-- Use '/ubermap debug' to print the name of every NPC event if a server
-- renames them.
local HOMEPOINT_PATTERN = '^Home Point';

local MAX_ZOOM  = 1.0;  -- one screen pixel per source map pixel
local ZOOM_STEP = 1.15; -- per wheel notch

-- ImGui packs colours as ABGR, not ARGB.
local COL_READOUT = 0xFF000000;
local COL_OUTLINE = 0xFF000000;
local COL_TEXT_OUTLINE = 0x80FFFFFF;

local READOUT_SCALE = 2.0;

-- Icons are anchored by their centre, in source-image pixels, and drawn at
-- ICON_SIZE map pixels so they stay pinned to the map as it zooms.
local ICON_SIZE    = 100;   -- the source art is square, 214x214
local POINT_SIZE   = 40;    -- map pixels for point markers (entries with size = POINT_SIZE)
local ICON_ROUND   = 0.0625;  -- corner radius, as a fraction of the drawn size
local ICON_BORDER  = 2.0;   -- screen pixels
local COL_ICON     = 0xFFFFFFFF;  -- white: tint that leaves the art untouched
local COL_LABEL    = 0xFF000000;

-- Labels sit above the icon at a fixed screen size, so they stay readable at
-- every zoom instead of shrinking away with the art.
local LABEL_SCALE = 1;
local LABEL_GAP   = 2;  -- screen pixels between the label and the icon

-- Search box, pinned in from the viewport corner by SEARCH_MARGIN screen pixels.
local SEARCH_MARGIN = 50;
local SEARCH_W      = 200;
local SEARCH_MAX    = 256;

local ICONS = T{
    { file = 'SandOria.jpg',  x = 1075, y =  971, label = "San d'Oria" },
    { file = 'Bastok.jpg',    x = 1340, y = 1886, label = 'Bastok'     },
    { file = 'Jeuno.jpg',     x = 1737, y = 1207, label = 'Jeuno'      },
    { file = 'Windurst.jpg',  x = 2115, y = 1986, label = 'Windurst'   },
    { file = 'AhtUrhgan.jpg', x = 5009, y = 1796, label = 'Aht Urhgan' },
    { file = 'Point_0.png',  x = 1000, y =  695, label = 'Valdeaunia', border = false, size = POINT_SIZE },
    { file = 'Point_0.png',  x = 1538, y =  837, label = 'Fauregandi',  border = false, size = POINT_SIZE },
    { file = 'Point_0.png',  x = 1473, y =  941, label = 'Norvallen',   border = false, size = POINT_SIZE },
    { file = 'Point_0.png',  x = 1899, y =  976, label = 'Qufim',       border = false, size = POINT_SIZE },
    { file = 'Point_0.png',  x = 2029, y =  777, label = "Tu'Lia",     border = false, size = POINT_SIZE },
    { file = 'Point_0.png',  x = 1074, y = 1089, label = 'Ronfaure',    border = false, size = POINT_SIZE },
    { file = 'Point_0.png',  x =  702, y = 1185, label = 'Tavnazian Archipelago', border = false, size = POINT_SIZE },
    { file = 'Point_0.png',  x =  597, y = 1574, label = 'Vollbow',     border = false, size = POINT_SIZE },
    { file = 'Point_0.png',  x = 1105, y = 1459, label = 'Zulkheim',    border = false, size = POINT_SIZE },
    { file = 'Point_0.png',  x =  533, y = 2134, label = 'Kuzotz',      border = false, size = POINT_SIZE },
    { file = 'Point_0.png',  x = 1003, y = 1898, label = 'Gustaberg',   border = false, size = POINT_SIZE },
    { file = 'Point_0.png',  x = 1488, y = 1787, label = 'Movalpolos',  border = false, size = POINT_SIZE },
    { file = 'Point_0.png',  x = 1530, y = 1412, label = 'Derfland',    border = false, size = POINT_SIZE },
    { file = 'Point_0.png',  x = 2184, y = 1348, label = 'Aragoneu',    border = false, size = POINT_SIZE },
    { file = 'Point_0.png',  x = 2538, y = 1283, label = "Li'Telor",    border = false, size = POINT_SIZE },
    { file = 'Point_0.png',  x = 2295, y = 1577, label = 'Kolshushu',   border = false, size = POINT_SIZE },
    { file = 'Point_0.png',  x = 2180, y = 1780, label = 'Sarutabaruta', border = false, size = POINT_SIZE },
    { file = 'Point_0.png',  x = 2445, y = 2364, label = 'Elshimo Lowlands', border = false, size = POINT_SIZE },
    { file = 'Point_0.png',  x = 2669, y = 2364, label = 'Elshimo Uplands', border = false, size = POINT_SIZE },
    { file = 'Point_0.png',  x = 3863, y =  861, label = 'Arrapago Islands', border = false, size = POINT_SIZE },
    { file = 'Point_0.png',  x = 3981, y = 1343, label = 'Ruins of Alzadaal', border = false, size = POINT_SIZE },
    { file = 'Point_0.png',  x = 4158, y = 1713, label = 'Halvung Territory', border = false, size = POINT_SIZE },
    { file = 'Point_0.png',  x = 4072, y = 2344, label = 'Mamool Ja Savagelands', border = false, size = POINT_SIZE },
    { file = 'Point_0.png',  x = 4703, y = 1852, label = 'West Aht Urhgan', border = false, size = POINT_SIZE },
};

local ui = T{
    is_open     = { false, },
    texture     = nil,
    load_failed = false,
    zoom        = nil,  -- nil until the first frame gives us a viewport size
    pan_x       = 0,
    pan_y       = 0,
    search      = { '', },
    dragging    = false,
    drag_x      = 0,
    drag_y      = 0,
    debug       = false,
    dbg         = nil,
};

local function notify(msg)
    print(chat.header(addon.name):append(chat.message(msg)));
end

--[[
* ImGui has no outlined text, so stamp the string in white around itself before
* drawing it.  Keeps it readable over both land and ocean.
--]]
local function outlined_text(dl, x, y, text, col)
    for _, o in ipairs({ { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }) do
        dl:AddText({ x + o[1], y + o[2] }, COL_TEXT_OUTLINE, text);
    end
    dl:AddText({ x, y }, col, text);
end

--[[
* Loads a texture from assets/ at the given size, or nil if it fails.  Failures
* are reported once; a nil result on a later call means the file already failed.
--]]
local function load_asset(file, w, h)
    local ptr = ffi.new('IDirect3DTexture8*[1]');
    local res = C.D3DXCreateTextureFromFileExA(d3d8dev,
        ('%s/assets/%s'):fmt(addon.path, file),
        w, h, 1, 0, C.D3DFMT_A8R8G8B8, C.D3DPOOL_MANAGED,
        C.D3DX_DEFAULT, C.D3DX_DEFAULT, 0, nil, nil, ptr);

    if (res ~= C.S_OK) then
        print(chat.header(addon.name):append(chat.error(
            ('Failed to load assets/%s: %08X (%s)'):fmt(file, res, d3d.get_error(res)))));
        return nil;
    end

    local tex = ffi.new('IDirect3DTexture8*', ptr[0]);
    d3d.gc_safe_release(tex);
    return tex;
end

--[[
* Loads the map texture on first use.  The 15MB decode costs a noticeable
* hitch, so it is deliberately kept off the addon load and zone-in paths.
--]]
local function load_texture()
    if (ui.texture ~= nil or ui.load_failed) then
        return;
    end

    ui.texture = load_asset('Present_Map.jpg', TEX_W, TEX_H);
    ui.load_failed = (ui.texture == nil);
end

--[[
* Draws every icon centred on its map coordinate, with a rounded black border
* unless the entry sets border = false.
--]]
local function draw_icons(origin_x, origin_y, view_w, view_h)
    local dl = imgui.GetWindowDrawList();

    for _, ic in ipairs(ICONS) do
        local half = (ic.size or ICON_SIZE) * ui.zoom / 2;
        local cx = mm.to_screen(ic.x, ui.pan_x, ui.zoom, origin_x);
        local cy = mm.to_screen(ic.y, ui.pan_y, ui.zoom, origin_y);
        if (cx + half >= origin_x and cx - half <= origin_x + view_w
            and cy + half >= origin_y and cy - half <= origin_y + view_h) then
            if (ic.tex == nil and not ic.failed) then
                ic.tex    = load_asset(ic.file, C.D3DX_DEFAULT, C.D3DX_DEFAULT);
                ic.failed = (ic.tex == nil);
            end
            if (ic.tex ~= nil) then
                local id    = tonumber(ffi.cast('uint32_t', ic.tex));
                local p0    = { cx - half, cy - half };
                local p1    = { cx + half, cy + half };
                local round = half * 2 * ICON_ROUND;
                dl:AddImageRounded(id, p0, p1, { 0, 0 }, { 1, 1 }, COL_ICON,
                                   round, ImDrawCornerFlags_All);
                if (ic.border ~= false) then
                    dl:AddRect(p0, p1, COL_OUTLINE, round, ImDrawCornerFlags_All, ICON_BORDER);
                end

                if (ic.label ~= nil) then
                    imgui.SetWindowFontScale(LABEL_SCALE);
                    local tw, th = imgui.CalcTextSize(ic.label);
                    outlined_text(dl, cx - tw / 2, cy - half - th - LABEL_GAP,
                                  ic.label, COL_LABEL);
                    imgui.SetWindowFontScale(1.0);
                end
            end
        end
    end
end

--[[
* Opens the map.  If it is already open the current zoom and pan are left
* alone, so repeated Home Point visits do not yank the view back to the default.
--]]
local function show()
    ui.is_open[1] = true;
end

local function draw_map(view_w, view_h)
    if (ui.debug) then
        imgui.Text(ui.dbg or '');
        local _, avail_h = imgui.GetContentRegionAvail();
        view_h = avail_h;
    end

    -- The minimum zoom covers the viewport, so the map never letterboxes.
    -- Re-applied every frame because growing the window raises the floor.
    local cover = mm.cover_zoom(MAP_W, MAP_H, view_w, view_h);
    ui.zoom = mm.clamp(ui.zoom or cover, cover, MAX_ZOOM);

    -- The viewport's top-left, captured before the child is opened.
    local origin_x, origin_y = imgui.GetCursorScreenPos();
    local mouse_x, mouse_y   = imgui.GetMousePos();

    -- The map child covers the whole content region, so it is the window ImGui
    -- reports as hovered.  Without ChildWindows this test is false exactly when
    -- the cursor is over the map, which kills both zoom and pan.  RectOnly
    -- keeps it true mid-drag, when an active item would otherwise block it.
    local hovered = imgui.IsWindowHovered(
        bit.bor(ImGuiHoveredFlags_ChildWindows, ImGuiHoveredFlags_RectOnly));

    -- Ignore the mouse outside the map, and while shift is held, so a
    -- shift-drag moves the window instead of panning underneath it.  An active
    -- widget (the search box) also swallows the mouse, so it does not pan too.
    local shift    = imgui.GetIO().KeyShift;
    local over_map = hovered and not shift and not imgui.IsAnyItemActive()
        and mouse_x >= origin_x and mouse_x < origin_x + view_w
        and mouse_y >= origin_y and mouse_y < origin_y + view_h;

    -- Wheel zooms about the cursor.
    local wheel = imgui.GetIO().MouseWheel;
    if (over_map and wheel ~= 0) then
        local old = ui.zoom;
        local new = mm.clamp(old * (ZOOM_STEP ^ wheel), cover, MAX_ZOOM);
        if (new ~= old) then
            ui.pan_x = mm.zoom_anchor(ui.pan_x, mouse_x - origin_x, old, new);
            ui.pan_y = mm.zoom_anchor(ui.pan_y, mouse_y - origin_y, old, new);
            ui.zoom  = new;
        end
    end

    -- Left-drag pans.  Once a drag starts it keeps going even if the cursor
    -- leaves the map, which is what every other map viewer does.
    if (imgui.IsMouseDragging(0) and (over_map or ui.dragging)) then
        if (ui.dragging) then
            ui.pan_x = ui.pan_x - (mouse_x - ui.drag_x);
            ui.pan_y = ui.pan_y - (mouse_y - ui.drag_y);
        end
        ui.dragging = true;
        ui.drag_x, ui.drag_y = mouse_x, mouse_y;
    else
        ui.dragging = false;
    end

    local content_w = MAP_W * ui.zoom;
    local content_h = MAP_H * ui.zoom;
    ui.pan_x = mm.clamp_pan(ui.pan_x, content_w, view_w);
    ui.pan_y = mm.clamp_pan(ui.pan_y, content_h, view_h);

    -- The child clips and a negative cursor position does the panning, which
    -- avoids depending on ImGui's scroll API.
    if (imgui.BeginChild('ubermap_view', { view_w, view_h }, false,
            bit.bor(ImGuiWindowFlags_NoScrollbar, ImGuiWindowFlags_NoScrollWithMouse))) then
        imgui.SetCursorPos({ -ui.pan_x, -ui.pan_y });
        imgui.Image(tonumber(ffi.cast('uint32_t', ui.texture)), { content_w, content_h });
        draw_icons(origin_x, origin_y, view_w, view_h);

        imgui.SetCursorPos({ SEARCH_MARGIN, SEARCH_MARGIN });
        imgui.SetNextItemWidth(SEARCH_W);
        imgui.InputTextWithHint('##ubermap_search', 'Search', ui.search, SEARCH_MAX);

        -- Source-image pixel under the cursor.  Independent of zoom and pan, so
        -- the same spot on the map always reads the same numbers.
        if (over_map) then
            local mx = math.floor(mm.to_map(mouse_x, ui.pan_x, ui.zoom, origin_x));
            local my = math.floor(mm.to_map(mouse_y, ui.pan_y, ui.zoom, origin_y));
            -- The font scale applies to the draw list too, so it has to wrap
            -- the white stamps as well as the text itself.
            imgui.SetWindowFontScale(READOUT_SCALE);
            outlined_text(imgui.GetWindowDrawList(), origin_x + 6, origin_y + view_h - 30,
                          ('%d, %d'):fmt(mx, my), COL_READOUT);
            imgui.SetWindowFontScale(1.0);
        end
    end
    imgui.EndChild();

    if (ui.debug) then
        ui.dbg = ('hovered=%s over_map=%s shift=%s wheel=%.2f drag=%s | mouse %.0f,%.0f origin %.0f,%.0f view %.0fx%.0f | zoom %.4f (cover %.4f) pan %.0f,%.0f'):fmt(
            tostring(hovered), tostring(over_map), tostring(shift), wheel, tostring(ui.dragging),
            mouse_x, mouse_y, origin_x, origin_y, view_w, view_h,
            ui.zoom, cover, ui.pan_x, ui.pan_y);
    end
end

ashita.events.register('d3d_present', 'ubermap_present', function ()
    if (not ui.is_open[1]) then
        return;
    end

    load_texture();
    if (ui.texture == nil) then
        ui.is_open[1] = false;
        return;
    end

    local display = imgui.GetIO().DisplaySize;
    imgui.SetNextWindowSize({ display.x * 0.9, display.y * 0.9 }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowPos({ display.x * 0.05, display.y * 0.05 }, ImGuiCond_FirstUseEver);

    -- ImGui moves a window when you drag any empty part of it, child windows
    -- included, which fights the map's own panning.  Hold shift to move the
    -- window; otherwise it stays put and a drag pans the map instead.
    local flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoScrollbar,
                          ImGuiWindowFlags_NoScrollWithMouse);
    if (not imgui.GetIO().KeyShift) then
        flags = bit.bor(flags, ImGuiWindowFlags_NoMove);
    end

    -- No title bar and a 2px border, so the map runs nearly to the edges.
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 4, 4 });
    if (imgui.Begin('UberMap', ui.is_open, flags)) then
        local view_w, view_h = imgui.GetContentRegionAvail();
        if (view_w > 0 and view_h > 0) then
            draw_map(view_w, view_h);
        end
    end
    imgui.End();
    imgui.PopStyleVar();
end);

ashita.events.register('packet_in', 'ubermap_packet_in', function (e)
    -- 0x032 and 0x034 are the NPC interaction events; both carry the NPC's
    -- target index at offset 0x08.
    if (e.id ~= 0x032 and e.id ~= 0x034) then
        return false;
    end

    local index = struct.unpack('H', e.data, 0x08 + 1);
    local name  = AshitaCore:GetMemoryManager():GetEntity():GetName(index);
    if (name == nil or name == '') then
        return false;
    end

    if (ui.debug) then
        notify(('NPC event: %s'):fmt(name));
    end

    if (name:match(HOMEPOINT_PATTERN)) then
        show();
    end

    return false;
end);

ashita.events.register('command', 'ubermap_command', function (e)
    local args = e.command:args();
    if (#args == 0) then
        return;
    end

    local cmd = args[1]:lower();
    if (cmd ~= '/ubermap' and cmd ~= '/um') then
        return;
    end

    e.blocked = true;

    local sub = args[2] ~= nil and args[2]:lower() or nil;

    if (sub == 'debug') then
        ui.debug = not ui.debug;
        notify(('NPC event debug: %s'):fmt(ui.debug and 'on' or 'off'));
        return;
    end

    ui.is_open[1] = not ui.is_open[1];
end);

ashita.events.register('unload', 'ubermap_unload', function ()
    ui.texture = nil;
    for _, ic in ipairs(ICONS) do
        ic.tex = nil;
    end
end);
