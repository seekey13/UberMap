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

local ui = T{
    is_open     = { false, },
    texture     = nil,
    load_failed = false,
    zoom        = nil,  -- nil until the first frame gives us a viewport size
    pan_x       = 0,
    pan_y       = 0,
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
* Loads the map texture on first use.  The 15MB decode costs a noticeable
* hitch, so it is deliberately kept off the addon load and zone-in paths.
--]]
local function load_texture()
    if (ui.texture ~= nil or ui.load_failed) then
        return;
    end

    local ptr = ffi.new('IDirect3DTexture8*[1]');
    local res = C.D3DXCreateTextureFromFileExA(d3d8dev,
        ('%s/assets/Present_Map.jpg'):fmt(addon.path),
        TEX_W, TEX_H, 1, 0, C.D3DFMT_A8R8G8B8, C.D3DPOOL_MANAGED,
        C.D3DX_DEFAULT, C.D3DX_DEFAULT, 0, nil, nil, ptr);

    if (res ~= C.S_OK) then
        ui.load_failed = true;
        print(chat.header(addon.name):append(chat.error(
            ('Failed to load assets/Present_Map.jpg: %08X (%s)'):fmt(res, d3d.get_error(res)))));
        return;
    end

    local tex = ffi.new('IDirect3DTexture8*', ptr[0]);
    d3d.gc_safe_release(tex);
    ui.texture = tex;
end

--[[
* Opens the map.  If it is already open the current zoom and pan are left
* alone, so repeated Home Point visits do not yank the view back to fit.
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

    local fit = mm.fit_zoom(MAP_W, MAP_H, view_w, view_h);
    if (ui.zoom == nil) then
        ui.zoom = fit;
    end

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
    -- shift-drag moves the window instead of panning underneath it.
    local shift    = imgui.GetIO().KeyShift;
    local over_map = hovered and not shift
        and mouse_x >= origin_x and mouse_x < origin_x + view_w
        and mouse_y >= origin_y and mouse_y < origin_y + view_h;

    -- Wheel zooms about the cursor.
    local wheel = imgui.GetIO().MouseWheel;
    if (over_map and wheel ~= 0) then
        local old = ui.zoom;
        local new = mm.clamp(old * (ZOOM_STEP ^ wheel), fit, MAX_ZOOM);
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
    end
    imgui.EndChild();

    if (ui.debug) then
        ui.dbg = ('hovered=%s over_map=%s shift=%s wheel=%.2f drag=%s | mouse %.0f,%.0f origin %.0f,%.0f view %.0fx%.0f | zoom %.4f (fit %.4f) pan %.0f,%.0f'):fmt(
            tostring(hovered), tostring(over_map), tostring(shift), wheel, tostring(ui.dragging),
            mouse_x, mouse_y, origin_x, origin_y, view_w, view_h,
            ui.zoom, fit, ui.pan_x, ui.pan_y);
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

    if (args[2] ~= nil and args[2]:lower() == 'debug') then
        ui.debug = not ui.debug;
        notify(('NPC event debug: %s'):fmt(ui.debug and 'on' or 'off'));
        return;
    end

    ui.is_open[1] = not ui.is_open[1];
end);

ashita.events.register('unload', 'ubermap_unload', function ()
    ui.texture = nil;
end);
