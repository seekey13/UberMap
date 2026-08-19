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

local chat  = require('chat');
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

local MAX_ZOOM  = 2.0;  -- two screen pixels per source map pixel
local ZOOM_STEP = 1.15; -- per wheel notch

-- ImGui packs colours as ABGR, not ARGB.
local COL_READOUT = 0xFF000000;
local COL_OUTLINE = 0xFF000000;
local COL_TEXT_OUTLINE = 0x80FFFFFF;

local READOUT_SCALE = 2.0;

-- Icons are anchored by their centre, in source-image pixels, but drawn at a
-- fixed screen size: the position tracks the map as it zooms, the marker does
-- not grow with it.
local ICON_SIZE    = 50;    -- screen pixels; the source art is square, 214x214
local POINT_SIZE   = 30;    -- screen pixels for point markers (entries with size = POINT_SIZE)
local ICON_ROUND   = 0.0625;  -- corner radius, as a fraction of the drawn size
local ICON_BORDER  = 2.0;   -- screen pixels
local COL_ICON     = 0xFFFFFFFF;  -- white: tint that leaves the art untouched
local COL_LABEL    = 0xFF000000;
local COL_SELECT   = 0xFF00FFFF;  -- yellow: ring around the point being edited

-- Faded versions, used for everything outside the focused group.  The label
-- needs its outline faded to match, or the white stamp outlives the glyph.
local COL_LABEL_OFF        = 0x40000000;
local COL_TEXT_OUTLINE_OFF = 0x20FFFFFF;

-- Labels sit above the icon at a fixed screen size, so they stay readable at
-- every zoom instead of shrinking away with the art.
local LABEL_SCALE = 1;
local LABEL_GAP   = 1;  -- screen pixels between the label and the icon

-- Two detail tiers, swapping at ZOOM_POINTS: below it the world overview (the
-- groups declared in points.lua), at or above it the zone points that come
-- from the same file and the editor.  One tier replaces the other, so the
-- overview never sits underneath the points.
local ZOOM_POINTS = 1.0;

-- Search box, pinned in from the viewport corner by SEARCH_MARGIN screen pixels.
local SEARCH_MARGIN = 50;
local SEARCH_W      = 600;
local SEARCH_MAX    = 256;
local EDIT_ROW      = 28;  -- editor panel row pitch, screen pixels

-- The search box is drawn this many times the default frame height.  The height
-- comes from frame padding rather than a font scale: ImGui has one baked font
-- atlas, so scaling the font up magnifies its bitmap and goes blurry.
local SEARCH_H_MULT   = 2.0;
local COL_SEARCH_BG   = { 1.0, 1.0, 1.0, 1.0 };
local COL_SEARCH_TEXT = { 0.0, 0.0, 0.0, 1.0 };
local COL_SEARCH_HINT = { 0.45, 0.45, 0.45, 1.0 };

-- Layer toggles, drawn on the search box's line.  Clicking one dims its icon;
-- the state is kept per file name in ui.toggle (nil = lit).
local TOGGLES      = T{ 'Crystal.png', 'Guide.png', 'Maw.png', 'Unity.png' };
local TOGGLE_GAP   = 6;   -- screen pixels between toggles
local COL_ICON_OFF = 0x40FFFFFF;  -- 25% opacity, i.e. 75% transparent

-- The map data lives in points.lua beside the addon: the overview groups, in
-- draw order so later groups land on top of earlier ones where they overlap,
-- and the zone points placed with /um edit.  Editing writes the file back out.
local POINTS_FILE = ('%s/points.lua'):fmt(addon.path);

-- One flat list for drawing, each entry tagged with its group name, plus the
-- set of overview group names, so a point knows which detail tier it belongs to
-- whether it came from a group block, the points list, or the editor.
local ICON_GROUPS = T{};
local ICONS       = T{};
local OVERVIEW    = T{};

local ui = T{
    is_open     = { false, },
    texture     = nil,
    load_failed = false,
    zoom        = nil,  -- nil until the first frame gives us a viewport size
    pan_x       = 0,
    pan_y       = 0,
    search      = { '', },
    search_hot  = false,
    toggle      = T{},   -- toggle file name -> true when dimmed off
    dragging    = false,
    drag_x      = 0,
    drag_y      = 0,
    press       = nil,       -- overview marker the left button went down on
    focus       = nil,       -- group name to keep lit; everything else dims
    debug       = false,
    dbg         = nil,
    edit        = false,     -- point editor on
    sel         = nil,       -- the user point being edited
    moving      = false,     -- ctrl-drag in progress
    dirty       = false,     -- an edit is waiting to be written to points.lua
    edit_name   = { '', },
    edit_group  = { 'Regions', },
};

-- ui.zoom is nil until the first frame sizes the viewport, so treat that as
-- hidden rather than comparing against nil.
local function icon_visible(ic)
    local z = ui.zoom;
    if (z == nil) then
        return false;
    end
    if (OVERVIEW[ic.group]) then
        return z < ZOOM_POINTS;
    end
    return z >= ZOOM_POINTS;
end

local function notify(msg)
    print(chat.header(addon.name):append(chat.message(msg)));
end

--[[
* Points placed in game go back to points.lua, so the work survives a reload.
* Group blocks are re-emitted as they were loaded: only the points list and the
* labels and positions in it are editable in game.
--]]
local function fmt_icon(ic, indent)
    local s = ('%s{ file = %q, x = %4d, y = %4d, label = %q'):fmt(
        indent, ic.file, ic.x, ic.y, ic.label or '');
    if (ic.border ~= nil) then
        s = s .. (', border = %s'):fmt(tostring(ic.border));
    end
    if (ic.size ~= nil) then
        s = s .. (ic.size == POINT_SIZE and ', size = POINT_SIZE'
                                         or (', size = %d'):fmt(ic.size));
    end
    -- Group icons take their group from the block they sit in, so only the
    -- points list carries the name on the row itself.
    if (ic.user and ic.group ~= nil) then
        s = s .. (', group = %q'):fmt(ic.group);
    end
    if (ic.time ~= nil) then
        s = s .. (', time = %q'):fmt(ic.time);
    end
    return s .. ' },\n';
end

local function save_points()
    local f = io.open(POINTS_FILE, 'w');
    if (f == nil) then
        notify(('could not write %s'):fmt(POINTS_FILE));
        return;
    end
    f:write('-- UberMap map data, rewritten by /um edit.\n--\n');
    f:write("-- 'groups' holds the overview tiers, drawn in order so later groups land on top\n");
    f:write("-- of earlier ones; their names are what the point rows below refer to by 'group'.\n");
    f:write("-- 'points' holds the zone markers, drawn once the view is zoomed past the\n");
    f:write("-- overview.  'time' tags the era a marker belongs to.\n");
    f:write(('local POINT_SIZE = %d;\n\nreturn {\n    groups = {\n'):fmt(POINT_SIZE));
    for _, g in ipairs(ICON_GROUPS) do
        f:write(('        { name = %q, icons = {\n'):fmt(g.name));
        for _, ic in ipairs(g.icons) do
            f:write(fmt_icon(ic, '            '));
        end
        f:write('        } },\n');
    end
    f:write('    },\n    points = {\n');
    for _, ic in ipairs(ICONS) do
        if (ic.user) then
            f:write(fmt_icon(ic, '        '));
        end
    end
    f:write('    },\n};\n');
    f:close();
end

-- The file is the addon's data, not an optional overlay, so a missing or broken
-- one is reported rather than passed over.
local function load_points()
    local chunk, err = loadfile(POINTS_FILE);
    if (chunk == nil) then
        notify(('could not read %s: %s'):fmt(POINTS_FILE, tostring(err)));
        return;
    end
    local ok, data = pcall(chunk);
    if (not ok or type(data) ~= 'table') then
        notify(('%s failed to load: %s'):fmt(POINTS_FILE, tostring(data)));
        return;
    end
    for _, g in ipairs(data.groups or {}) do
        table.insert(ICON_GROUPS, g);
        OVERVIEW[g.name] = true;
        for _, ic in ipairs(g.icons or {}) do
            ic.group = g.name;
            table.insert(ICONS, ic);
        end
    end
    for _, ic in ipairs(data.points or {}) do
        ic.user = true;
        table.insert(ICONS, ic);
    end
end
load_points();

local function point_at(mx, my)
    for _, ic in ipairs(ICONS) do
        -- The drawn size is in screen pixels, so it shrinks in map space as
        -- the view zooms in.
        local half = (ic.size or ICON_SIZE) / 2 / ui.zoom;
        if (ic.user and icon_visible(ic)
            and mx >= ic.x - half and mx <= ic.x + half
            and my >= ic.y - half and my <= ic.y + half) then
            return ic;
        end
    end
    return nil;
end

local function add_point(mx, my)
    local n = 0;
    for _, ic in ipairs(ICONS) do
        if (ic.user) then
            n = n + 1;
        end
    end
    local ic = {
        file   = 'Point_0.png',
        x      = mx,
        y      = my,
        label  = ('Point %d'):fmt(n + 1),
        group  = ui.edit_group[1],
        border = false,
        size   = POINT_SIZE,
        time   = 'present',
        user   = true,
    };
    table.insert(ICONS, ic);
    ui.dirty = true;
    return ic;
end

local function delete_point(ic)
    for i, v in ipairs(ICONS) do
        if (v == ic) then
            table.remove(ICONS, i);
            break;
        end
    end
    ui.dirty = true;
end

--[[
* ImGui has no outlined text, so stamp the string in white around itself before
* drawing it.  Keeps it readable over both land and ocean.
--]]
local function outlined_text(dl, x, y, text, col, outline)
    for _, o in ipairs({ { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }) do
        dl:AddText({ x + o[1], y + o[2] }, outline or COL_TEXT_OUTLINE, text);
    end
    dl:AddText({ x, y }, col, text);
end

--[[
* Loads a texture from assets/ at the given size, or nil if it fails.  Failures
* are reported once; a nil result on a later call means the file already failed.
--]]
local function load_asset(file, w, h)
    local ptr  = ffi.new('IDirect3DTexture8*[1]');
    -- D3DX rounds the texture up to a power of two, so the surface size says
    -- nothing about the art's shape.  The info struct reports the file's own
    -- dimensions, which is what callers need to draw it undistorted.
    local info = ffi.new('D3DXIMAGE_INFO[1]');
    local res = C.D3DXCreateTextureFromFileExA(d3d8dev,
        ('%s/assets/%s'):fmt(addon.path, file),
        w, h, 1, 0, C.D3DFMT_A8R8G8B8, C.D3DPOOL_MANAGED,
        C.D3DX_DEFAULT, C.D3DX_DEFAULT, 0, info, nil, ptr);

    if (res ~= C.S_OK) then
        print(chat.header(addon.name):append(chat.error(
            ('Failed to load assets/%s: %08X (%s)'):fmt(file, res, d3d.get_error(res)))));
        return nil;
    end

    local tex = ffi.new('IDirect3DTexture8*', ptr[0]);
    d3d.gc_safe_release(tex);
    return tex, info[0].Width, info[0].Height;
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
* One texture per asset file, shared by every icon that names it.  The entry is
* a box so a failed load caches its nil instead of retrying it every frame.
--]]
local icon_tex = T{};
local function icon_texture(file)
    if (icon_tex[file] == nil) then
        local tex, w, h = load_asset(file, C.D3DX_DEFAULT, C.D3DX_DEFAULT);
        -- tonumber: the info fields come back as cdata, which would poison
        -- the size arithmetic downstream.
        icon_tex[file] = { tex = tex, w = tonumber(w) or 1, h = tonumber(h) or 1 };
    end
    local e = icon_tex[file];
    return e.tex, e.w, e.h;
end

--[[
* Draws every icon centred on its map coordinate, with a rounded black border
* unless the entry sets border = false.  A hovered icon swaps to its _1 art
* (Point_0.png -> Point_1.png); entries without one keep the art they have.
*
* Returns the icon under the cursor, or nil.  Later icons win where they
* overlap, matching the draw order.
--]]
local function draw_icons(origin_x, origin_y, view_w, view_h, over_map)
    local dl = imgui.GetWindowDrawList();
    local mouse_x, mouse_y = imgui.GetMousePos();
    local hot_ic = nil;

    for _, ic in ipairs(ICONS) do
      if (icon_visible(ic)) then
        local half = (ic.size or ICON_SIZE) / 2;
        local cx = mm.to_screen(ic.x, ui.pan_x, ui.zoom, origin_x);
        local cy = mm.to_screen(ic.y, ui.pan_y, ui.zoom, origin_y);
        if (cx + half >= origin_x and cx - half <= origin_x + view_w
            and cy + half >= origin_y and cy - half <= origin_y + view_h) then
            -- Everything outside the focused group fades back, so the group
            -- that was clicked reads as the subject of the view.
            local dim = (ui.focus ~= nil and ic.group ~= ui.focus);
            local hot = over_map and not dim
                and mouse_x >= cx - half and mouse_x <= cx + half
                and mouse_y >= cy - half and mouse_y <= cy + half;
            local tex = nil;
            if (hot) then
                hot_ic = ic;
                tex = icon_texture((ic.file:gsub('_0%.png$', '_1.png')));
            end
            tex = tex or icon_texture(ic.file);
            if (tex ~= nil) then
                local id    = tonumber(ffi.cast('uint32_t', tex));
                local p0    = { cx - half, cy - half };
                local p1    = { cx + half, cy + half };
                local round = half * 2 * ICON_ROUND;
                dl:AddImageRounded(id, p0, p1, { 0, 0 }, { 1, 1 },
                                   dim and COL_ICON_OFF or COL_ICON,
                                   round, ImDrawCornerFlags_All);
                if (ic.border ~= false) then
                    dl:AddRect(p0, p1, COL_OUTLINE, round, ImDrawCornerFlags_All, ICON_BORDER);
                end
                if (ic == ui.sel) then
                    dl:AddRect({ p0[1] - 2, p0[2] - 2 }, { p1[1] + 2, p1[2] + 2 },
                               COL_SELECT, round, ImDrawCornerFlags_All, ICON_BORDER);
                end

                if (ic.label ~= nil) then
                    imgui.SetWindowFontScale(LABEL_SCALE);
                    local tw, th = imgui.CalcTextSize(ic.label);
                    outlined_text(dl, cx - tw / 2, cy - half - th - LABEL_GAP,
                                  ic.label,
                                  dim and COL_LABEL_OFF or COL_LABEL,
                                  dim and COL_TEXT_OUTLINE_OFF or nil);
                    imgui.SetWindowFontScale(1.0);
                end
            end
        end
      end
    end
    return hot_ic;
end

--[[
* Frames every point whose group matches 'name', so clicking an overview marker
* opens the zone points it stands for.  The zoom floor is ZOOM_POINTS, below
* which those points are not drawn at all.  Returns false when nothing carries
* the group, which leaves the view alone.
--]]
local ZOOM_PAD = 100;  -- map pixels of margin around the framed group

local function zoom_to_group(name, view_w, view_h)
    local x0, y0, x1, y1;
    for _, ic in ipairs(ICONS) do
        if (ic.group == name) then
            x0 = math.min(x0 or ic.x, ic.x);
            y0 = math.min(y0 or ic.y, ic.y);
            x1 = math.max(x1 or ic.x, ic.x);
            y1 = math.max(y1 or ic.y, ic.y);
        end
    end
    if (x0 == nil) then
        return false;
    end

    local floor_z = math.max(ZOOM_POINTS, mm.cover_zoom(MAP_W, MAP_H, view_w, view_h));
    local fit = mm.fit_zoom(x1 - x0 + ZOOM_PAD * 2, y1 - y0 + ZOOM_PAD * 2,
                            view_w, view_h);
    ui.zoom  = mm.clamp(fit, floor_z, MAX_ZOOM);
    ui.pan_x = (x0 + x1) / 2 * ui.zoom - view_w / 2;
    ui.pan_y = (y0 + y1) / 2 * ui.zoom - view_h / 2;
    ui.focus = name;
    return true;
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
    -- shift-drag moves the window instead of panning underneath it.  The search
    -- box is skipped too, so dragging in it selects text instead of panning.
    -- IsAnyItemActive cannot stand in for that flag: ImGui sets ActiveId to the
    -- window's MoveId on any press in blank space, NoMove included, so it is
    -- true for exactly the drag that should pan.
    local shift    = imgui.GetIO().KeyShift;
    local over_map = hovered and not shift and not ui.search_hot
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
            -- Zooming by hand ends the group focus: the user is looking around
            -- again, so everything comes back up to full.
            ui.focus = nil;
        end
    end

    -- Point editor: ctrl+click drops a new point, or grabs the one already under
    -- the cursor, and holding the button drags it.  Plain drag still pans.
    if (ui.edit) then
        local mx = math.floor(mm.to_map(mouse_x, ui.pan_x, ui.zoom, origin_x));
        local my = math.floor(mm.to_map(mouse_y, ui.pan_y, ui.zoom, origin_y));
        if (over_map and imgui.GetIO().KeyCtrl and imgui.IsMouseClicked(0)) then
            ui.sel           = point_at(mx, my) or add_point(mx, my);
            ui.edit_name[1]  = ui.sel.label;
            ui.edit_group[1] = ui.sel.group;
            ui.moving        = true;
        end
        if (ui.moving) then
            if (not imgui.IsMouseDown(0)) then
                ui.moving = false;
            elseif (ui.sel.x ~= mx or ui.sel.y ~= my) then
                ui.sel.x, ui.sel.y = mx, my;
                ui.dirty = true;
            end
        end
    end

    -- Left-drag pans.  Once a drag starts it keeps going even if the cursor
    -- leaves the map, which is what every other map viewer does.
    if (not ui.moving and imgui.IsMouseDragging(0) and (over_map or ui.dragging)) then
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
        local hot_ic = draw_icons(origin_x, origin_y, view_w, view_h, over_map);

        -- Clicking an overview marker frames the group its label names.  The
        -- press is remembered and acted on at release, so a drag that starts on
        -- a marker pans as usual instead of jumping the view.  Ctrl is the
        -- editor's chord, so it is left alone.
        if (imgui.IsMouseClicked(0)) then
            ui.press = (hot_ic ~= nil and OVERVIEW[hot_ic.group]
                        and not imgui.GetIO().KeyCtrl) and hot_ic or nil;
        end
        if (ui.dragging) then
            ui.press = nil;
        end
        if (ui.press ~= nil and imgui.IsMouseReleased(0)) then
            zoom_to_group(ui.press.label, view_w, view_h);
            ui.press = nil;
        end

        local row_h = imgui.GetFrameHeight() * SEARCH_H_MULT;
        imgui.PushStyleVar(ImGuiStyleVar_FramePadding,
                           { 6, (row_h - imgui.GetFontSize()) / 2 });
        imgui.PushStyleColor(ImGuiCol_FrameBg, COL_SEARCH_BG);
        imgui.PushStyleColor(ImGuiCol_FrameBgHovered, COL_SEARCH_BG);
        imgui.PushStyleColor(ImGuiCol_FrameBgActive, COL_SEARCH_BG);
        imgui.PushStyleColor(ImGuiCol_Text, COL_SEARCH_TEXT);
        imgui.PushStyleColor(ImGuiCol_TextDisabled, COL_SEARCH_HINT);
        imgui.SetCursorPos({ SEARCH_MARGIN, SEARCH_MARGIN });
        imgui.SetNextItemWidth(SEARCH_W);
        imgui.InputTextWithHint('##ubermap_search', 'Search', ui.search, SEARCH_MAX);
        imgui.PopStyleColor(5);
        imgui.PopStyleVar();
        -- Read a frame late by over_map above, which is fine: a click focuses
        -- the box before the drag threshold is ever crossed.
        ui.search_hot = imgui.IsItemActive() or imgui.IsItemHovered();

        -- Toggle icons, sharing the search box's line.  Drawn by hand rather
        -- than with ImageButton, whose argument list moved between the ImGui
        -- versions Ashita has shipped; an InvisibleButton over an AddImage is
        -- the same widget without the version check.
        local tdl   = imgui.GetWindowDrawList();
        local tsize = row_h;
        local tx_at = SEARCH_MARGIN + SEARCH_W + TOGGLE_GAP;
        for _, file in ipairs(TOGGLES) do
            local tex, iw, ih = icon_texture(file);
            if (tex ~= nil) then
                -- The art is not square, so fit it into a tsize box by its own
                -- aspect and advance by the width it actually took.
                local tw = tsize * iw / ih;
                imgui.SetCursorPos({ tx_at, SEARCH_MARGIN });
                local sx, sy = imgui.GetCursorScreenPos();
                tdl:AddImage(tonumber(ffi.cast('uint32_t', tex)),
                             { sx, sy }, { sx + tw, sy + tsize }, { 0, 0 }, { 1, 1 },
                             ui.toggle[file] and COL_ICON_OFF or COL_ICON);
                if (imgui.InvisibleButton('##ubermap_toggle_' .. file, { tw, tsize })) then
                    ui.toggle[file] = not ui.toggle[file];
                end
                ui.search_hot = ui.search_hot or imgui.IsItemHovered();
                tx_at = tx_at + tw + TOGGLE_GAP;
            end
        end

        -- Everything below the search row stacks from here.
        local edit_y = SEARCH_MARGIN + row_h + TOGGLE_GAP;

        -- Editor panel, stacked under the search box.  Its widgets feed
        -- search_hot too, so dragging in them edits text instead of panning.
        if (ui.edit) then
            if (ui.sel == nil) then
                outlined_text(imgui.GetWindowDrawList(),
                              origin_x + SEARCH_MARGIN, origin_y + edit_y,
                              'ctrl+click the map to add or grab a point', COL_READOUT);
            else
                -- Rows are placed by hand rather than by flow, so the panel does
                -- not depend on the child's cursor advancing a particular amount.
                imgui.SetCursorPos({ SEARCH_MARGIN, edit_y });
                imgui.SetNextItemWidth(SEARCH_W);
                imgui.InputTextWithHint('##ubermap_pt_name', 'Name', ui.edit_name, SEARCH_MAX);
                local hot = imgui.IsItemActive() or imgui.IsItemHovered();

                imgui.SetCursorPos({ SEARCH_MARGIN, edit_y + EDIT_ROW });
                imgui.SetNextItemWidth(SEARCH_W);
                imgui.InputTextWithHint('##ubermap_pt_group', 'Group', ui.edit_group, SEARCH_MAX);
                hot = hot or imgui.IsItemActive() or imgui.IsItemHovered();

                if (ui.edit_name[1] ~= ui.sel.label or ui.edit_group[1] ~= ui.sel.group) then
                    ui.sel.label, ui.sel.group = ui.edit_name[1], ui.edit_group[1];
                    ui.dirty = true;
                end

                imgui.SetCursorPos({ SEARCH_MARGIN, edit_y + EDIT_ROW * 2 });
                imgui.Text(('%d, %d'):fmt(ui.sel.x, ui.sel.y));
                imgui.SetCursorPos({ SEARCH_MARGIN, edit_y + EDIT_ROW * 3 });
                if (imgui.Button('Delete')) then
                    delete_point(ui.sel);
                    ui.sel = nil;
                end
                ui.search_hot = ui.search_hot or hot or imgui.IsItemHovered();
            end
        end

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

    -- One write per finished edit, rather than one per frame of a drag.
    if (ui.dirty and not ui.moving) then
        save_points();
        ui.dirty = false;
    end

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

    if (sub == 'edit') then
        ui.edit = not ui.edit;
        if (ui.edit) then
            ui.is_open[1] = true;
        else
            ui.sel = nil;
        end
        notify(('point editor: %s'):fmt(ui.edit and 'on, ctrl+click the map' or 'off'));
        return;
    end

    if (sub == 'debug') then
        ui.debug = not ui.debug;
        notify(('NPC event debug: %s'):fmt(ui.debug and 'on' or 'off'));
        return;
    end

    ui.is_open[1] = not ui.is_open[1];
end);

ashita.events.register('unload', 'ubermap_unload', function ()
    ui.texture = nil;
    icon_tex = T{};
end);
