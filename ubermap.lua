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

local chat     = require('chat');
local settings = require('settings');
local imgui = require('imgui');
local ffi   = require('ffi');
local d3d   = require('d3d8');
local mm    = require('lib.mapmath');

local C       = ffi.C;
local d3d8dev = d3d.get_device();

-- Opening a link hands it to the shell, which sends it to the default browser.
-- ShellExecute rather than os.execute: the latter flashes a console window over
-- the game.  Typed as void* so this needs none of the Windows typedefs.
-- keybd_event presses Escape for the map: Ashita's IKeyboard binds keys but
-- cannot send them, so leaving an NPC's menu goes through user32, the same way
-- MapBind does.
ffi.cdef[[
    void* ShellExecuteA(void* hwnd, const char* op, const char* file,
                        const char* params, const char* dir, int show);
    void __stdcall keybd_event(uint8_t vk, uint8_t scan, uint32_t flags, uintptr_t extra);
]]

-- A library that will not load leaves its feature off rather than the addon.
local function try_load(name)
    local ok, lib = pcall(ffi.load, name);
    return ok and lib or nil;
end

local shell32 = try_load('shell32');
local user32  = try_load('user32');
local SW_SHOWNORMAL = 1;

local function open_url(url)
    if (shell32 ~= nil) then
        shell32.ShellExecuteA(nil, 'open', url, nil, nil, SW_SHOWNORMAL);
    end
end

-- The two times of the world, each its own image with its own pixel size.  Map
-- coordinates - the numbers on every point row and the readout in the corner -
-- are in the source image's own pixels, so they mean different places on
-- different maps; a point belongs to whichever one its 'time' tag names.
local TIMES = {
    present = { file = 'Present_Map.jpg', w = 5504, h = 3072 },
    past    = { file = 'Past_Map.jpg',    w = 4096, h = 4096 },
};

-- D3D8 rounds non-power-of-two textures up, so loading Present_Map.jpg
-- natively lands on 8192x4096 (~134MB, doubled again by the managed pool's
-- system copy) which risks exhausting FFXI's 32-bit address space.  Both maps
-- are forced to 4096x2048 (~32MB) instead; drawing at each map's own size undoes
-- the squash, at the cost of some detail at full zoom.  Only one is resident at
-- once - switching between them drops the other.
local TEX_W, TEX_H = 4096, 2048;

-- The NPCs a warp starts from, as a name pattern and the warp type it begins.
-- Home Point entities are named 'Home Point #1', 'Home Point #2' and so on,
-- and Survival Guides carry their own name; the Unity Concord is a person, so
-- those are named one by one.  Use '/ubermap debug' to print the name of every
-- NPC event if a server renames them.
local WARP_NPC = T{
    { '^Home Point',        'home'  },
    { '^Survival Guide',    'guide' },
    { '^Igsli$',            'unity' },  -- Bastok Markets (E-11)
    { '^Urbiolaine$',       'unity' },  -- Southern San d'Oria (G-10)
    { '^Teldro%-Kesdrodo$', 'unity' },  -- Windurst Woods (J-10)
    { '^Yonolala$',         'unity' },  -- Windurst Woods (J-10)
};

-- The NPC interaction packets, and the offset each carries the NPC's target
-- index at.  0x034 puts 32 bytes of menu parameters ahead of its index, so it
-- does not share the offset the other two use.  Which one a talk arrives as is
-- the server's choice, so all three are watched.
local NPC_EVENT = T{ [0x032] = 0x08, [0x033] = 0x08, [0x034] = 0x28 };

-- How close one of those has to be to count as being stood at, in yalms, and
-- how often the map re-checks while it is open, in seconds.
local WARP_NPC_NEAR = 7;
local NEAR_POLL     = 0.5;

-- How far the player has to travel from where the map went up before it closes
-- itself again, in yalms.  Far enough that a nudge from a passing mob or the
-- knock of a spell does not drop the map mid-read, short enough that a step
-- taken to walk off does.
local MOVE_CLOSE = 1.0;

-- How long the map ignores NPC interaction packets after it sends a command,
-- in seconds.  The command makes the NPC talk, and that talk would otherwise
-- open the map straight back up on top of what was asked for.
-- ponytail: a fixed window; a reply-aware gate if the server ever lags past it.
local SEND_QUIET = 3.0;

-- Leaving an NPC's menu, as the Escape key rather than as the packet the key
-- sends: the client builds that packet with the event's own fields, which this
-- would otherwise have to read back out of the interaction packet and guess the
-- layout of.  The scan code is Escape's; the flag is the release.
local VK_ESCAPE, ESCAPE_SCAN, KEYEVENTF_KEYUP = 0x1B, 0x01, 0x02;

-- How many frames the press is held for.  The client reads the keyboard once a
-- frame, so a press and release inside one frame is never seen at all.
local ESCAPE_HOLD = 3;

-- The player is in an event, i.e. talking to something, at this server status.
local STATUS_EVENT = 4;

-- How long to wait between presses while a command waits on the menu closing,
-- and how long to wait for it in total, both in seconds.  Presses repeat
-- because a menu can be more than one deep and each press backs out one level;
-- the total is a give-up, so a menu that will not close cannot strand the
-- command until the next one replaces it.
local ESCAPE_RETRY, ESCAPE_WAIT = 0.5, 2.0;

-- NPCs and mobs occupy the bottom of the entity array; players start at 0x400
-- and pets and trusts above them, so the walk stops before either.
local NPC_FIRST, NPC_LAST = 0x000, 0x3FF;

local MAX_ZOOM  = 2.0;  -- two screen pixels per source map pixel
local ZOOM_STEP = 1.15; -- per wheel notch

-- ImGui packs colours as ABGR, not ARGB.
local COL_OUTLINE = 0xFF000000;

local READOUT_SCALE = 2.0;

-- Icons are anchored by their centre, in source-image pixels, but drawn at a
-- fixed screen size: the position tracks the map as it zooms, the marker does
-- not grow with it.
local ICON_SIZE    = 50;    -- screen pixels; the source art is square, 214x214
local POINT_SIZE   = 30;    -- screen pixels for point markers (entries with size = POINT_SIZE)
local ICON_ROUND   = 0.0625;  -- corner radius, as a fraction of the drawn size
local ICON_BORDER  = 2.0;   -- screen pixels
local ICON_HOT     = 1.05;  -- hovered nation icons draw this larger
local HOT_GROUP    = 'Nations';  -- the only group that grows on hover
local COL_ICON     = 0xFFFFFFFF;  -- white: tint that leaves the art untouched
local COL_SELECT   = 0xFF00FFFF;  -- yellow: ring around the point being edited

-- Everything outside the focused group draws at a quarter alpha.  The outline
-- fades with the glyph, or the stamp outlives the text it was behind.
local DIM_ALPHA = 0.25;

-- Labels sit above the icon at a fixed screen size, so they stay readable at
-- every zoom instead of shrinking away with the art.
local LABEL_SCALE = 1;
local LABEL_GAP   = 1;  -- screen pixels between the label and the icon

-- Two detail tiers, swapping at ZOOM_POINTS: below it the world overview (the
-- groups declared in lib/points.lua), at or above it the zone points that come
-- from the same file and the editor.  One tier replaces the other, so the
-- overview never sits underneath the points.
local ZOOM_POINTS = 1.0;

-- Search box, pinned in from the viewport corner by SEARCH_MARGIN screen pixels.
local SEARCH_MARGIN = 20;
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
-- Maw.png is left out until maw warps are implemented.
local TOGGLES      = T{ 'Crystal.png', 'Guide.png', 'Unity.png' };
-- What each toggle is called on its tooltip, keyed the way ui.toggle is.
local TOGGLE_NAME  = T{ ['Crystal.png'] = 'Home Points',
                        ['Guide.png']   = 'Survival Guides',
                        ['Unity.png']   = 'Unity Concords' };
local TOGGLE_GAP   = 6;   -- screen pixels between toggles
local PICK_LABEL_GAP = 2;  -- screen pixels between a picker's name and its swatch
local COL_ICON_OFF = 0x40FFFFFF;  -- 25% opacity, i.e. 75% transparent

-- Warp type -> the toggle that lists it, so dimming a toggle drops those rows
-- from the popup.  A type no toggle names never shows.
local WARP_ICON = T{ home = 'Crystal.png', guide = 'Guide.png', unity = 'Unity.png' };

-- The Instant Warp scroll, drawn on the toggles' line after them.  Not a layer:
-- it warps out of the bag rather than from an NPC, so it filters nothing and is
-- lit only while a scroll is carried.
local WARP_ITEM_ICON = 'Warp.png';
local WARP_ITEM_ID   = 4181;
local WARP_ITEM_CMD  = '/item "Instant Warp" <me>';
-- Inventory container 0 - the bag, which is what /item reads from - and its
-- slot count.  Slot 0 is the gil slot rather than an item, so the walk starts
-- at 1.
local BAG, BAG_SLOTS = 0, 80;

-- Warp popup: a header row and one row per destination, hung off the zone
-- point that opened it.
local POPUP_PAD      = 8;   -- screen pixels of margin inside the panel
local POPUP_ROW      = 24;  -- row pitch, screen pixels
local POPUP_ICON     = 24;  -- the box a type icon is fitted into
local POPUP_GAP      = 6;   -- screen pixels between the marker and the panel
local COL_POPUP_BG   = 0xE0101010;  -- near black, a little of the map showing through
local COL_POPUP_TEXT = 0xFFFFFFFF;  -- fixed, not the pickers: the panel has its own ground
local COL_POPUP_OFF  = 0x60FFFFFF;  -- a row whose kind of NPC is not in reach

-- Credits, opened by the heart in the viewport's bottom-right corner.  One
-- entry per credit: who, then one or more places to find them.
local THANKS_HEAD = "This addon wouldn't work or look good without:";
local THANKS = T{
    { 'Thorny / Uberwarp / Multisend',
      'https://github.com/ThornyFFXI/Uberwarp',
      'https://github.com/ThornyFFXI/Multisend' },
    { 'FFXI Remapster Project', 'https://remapster.com/' },
};

-- Flattened once into the rows the panel draws, blanks and all, so the draw
-- does not rebuild the layout every frame.  A row carrying a url is clickable.
local THANKS_ROWS = { { text = THANKS_HEAD }, { text = '' } };
for i, c in ipairs(THANKS) do
    if (i > 1) then
        table.insert(THANKS_ROWS, { text = '' });
    end
    table.insert(THANKS_ROWS, { text = c[1] });
    for j = 2, #c do
        table.insert(THANKS_ROWS, { text = c[j], url = c[j] });
    end
end
local COL_THANKS_URL = 0xFFB0B0B0;  -- grey: the link reads under the name
local COL_HEART      = 0x80FFFFFF;  -- 50% opacity: the heart sits over the map

-- Multisend, drawn left of the heart.  While it is lit every command the map
-- sends goes out through Thorny's Multisend instead of straight to the client,
-- so all the logged-in characters take the warp together.  Off by default: it
-- is the surprising thing to do, so it has to be asked for.
local MSS_ICON     = 'multicast.png';
local MSS_PREFIX   = '/mss ';
local COL_MSS_OFF  = 0x40FFFFFF;  -- half again the heart's 50%, i.e. dimmed off

-- The map data lives in lib/points.lua under the addon: the overview groups, in
-- draw order so later groups land on top of earlier ones where they overlap,
-- and the zone points placed with /um edit.  Editing writes the file back out.
local POINTS_FILE = ('%s/lib/points.lua'):fmt(addon.path);

-- Warp destinations keyed by a point's label, in lib/warps.lua under the addon.
-- An overlay on the map rather than map data, so it is loaded softly.
local WARPS_FILE = ('%s/lib/warps.lua'):fmt(addon.path);
local WARPS      = T{};

-- One flat list for drawing, each entry tagged with its group name, plus the
-- set of overview group names, so a point knows which detail tier it belongs to
-- whether it came from a group block, the points list, or the editor.
local ICON_GROUPS = T{};
local ICONS       = T{};
local OVERVIEW    = T{};

-- What the map remembers between sessions.  Ashita keeps a settings file per
-- character, under config/addons/UberMap, so two characters can carry their own
-- colours and layers.  Only the choices made by hand are kept: everything else
-- in ui is read from the world each time the map opens.
local default_settings = T{
    mss         = false,                     -- send through Multisend
    toggle      = { },                       -- toggle file name -> true when dimmed off
    col_text    = { 0.0, 0.0, 0.0, 1.0 },    -- map text, from the corner picker
    col_outline = { 1.0, 1.0, 1.0, 0.5 },    -- the stamp behind it
    col_hover   = { 1.0, 1.0, 1.0, 0.18 },   -- warp row under the cursor
};
local SAVED = { 'mss', 'toggle', 'col_text', 'col_outline', 'col_hover' };
local cfg   = settings.load(default_settings);

local ui = T{
    is_open     = { false, },
    time        = 'present',  -- which map of TIMES is on screen
    texture     = nil,
    tex_time    = nil,       -- time ui.texture was loaded for
    next_time   = nil,       -- time the switch was clicked for, applied at frame end
    load_failed = nil,       -- time whose image failed to load
    zoom        = nil,  -- nil until the first frame gives us a viewport size
    pan_x       = 0,
    pan_y       = 0,
    search      = { '', },
    search_hot  = false,
    -- col_text, col_outline, col_hover and toggle are saved settings, filled
    -- in by apply_settings below along with mss.
    dragging    = false,
    drag_x      = 0,
    drag_y      = 0,
    press       = nil,       -- marker the left button went down on
    near_kind   = false,     -- warp type last seen in reach; false until checked
    has_warp    = false,     -- an Instant Warp scroll was in the bag last poll
    near_at     = 0,         -- os.clock() of that check
    sent_at     = 0,         -- os.clock() the map last sent a command
    pending     = nil,       -- command held back until the NPC's menu closes
    pend_at     = 0,         -- os.clock() it started waiting, for the give-up
    esc_at      = 0,         -- os.clock() of the last Escape press
    esc_frames  = 0,         -- frames left before that press is released
    open_x      = nil,       -- where the player stood when the map went up;
    open_z      = nil,       -- nil until the first frame after opening reads it
    warp        = nil,       -- zone point whose warp popup is open
    warp_hot    = false,     -- cursor was inside that popup last frame
    thanks      = false,     -- credits panel is open
    col_dirty   = false,     -- a colour picker has been moved this drag
    focus       = nil,       -- group name to keep lit; everything else dims
    debug       = false,
    dbg         = nil,
    edit        = false,     -- point editor on
    sel         = nil,       -- the user point being edited
    moving      = false,     -- ctrl-drag in progress
    dirty       = false,     -- an edit is waiting to be written to lib/points.lua
    edit_name   = { '', },
    edit_group  = { 'Regions', },
};

--[[
* A settings value fit to hand to the other side, tables copied so the two never
* share one.  Sharing would tie the saved settings to whatever ui does next: the
* library hands back its own default table for a key the file has no entry for,
* so a colour picker would edit the defaults, and a saved toggle table would
* carry the proximity filter's later moves out on the following write.
--]]
local function copy_setting(v)
    if (type(v) ~= 'table') then
        return v;
    end
    local t = { };
    for k, tv in pairs(v) do
        t[k] = tv;
    end
    return t;
end

--[[
* Copies the saved settings onto ui.
--]]
local function apply_settings(s)
    for _, k in ipairs(SAVED) do
        ui[k] = copy_setting(s[k]);
    end
end

--[[
* Writes ui's side of the settings back out, as each one is changed rather than
* at unload, so nothing is lost if the game goes down first.  Only changes made
* by hand call this: the proximity filter moves the toggles on its own and that
* is the world talking, not a choice to remember.
--]]
local function save_settings()
    for _, k in ipairs(SAVED) do
        cfg[k] = copy_setting(ui[k]);
    end
    settings.save();
end

apply_settings(cfg);

-- Logging in, or switching characters, hands back that character's own file.
settings.register('settings', 'settings_update', function (s)
    cfg = s;
    apply_settings(s);
end);

local function map_size()
    local m = TIMES[ui.time];
    return m.w, m.h;
end

--[[
* Tooltip for the item just submitted.  Vetoed by a warp popup lying over that
* item for the same reason its press is: the row is submitted before the popup,
* so ImGui hands it the hover of a cursor that is really over the panel.
--]]
local function item_tip(text)
    if (imgui.IsItemHovered() and not ui.warp_hot) then
        imgui.SetTooltip(text);
    end
end

--[[
* True while the player is in an event: talking to an NPC, or watching a scene.
* Uberwarp holds its own conversation with the NPC, so a warp asked for from
* inside one collides with the menu already up and does nothing.
--]]
local function in_event()
    local ent = AshitaCore:GetMemoryManager():GetEntity();
    if (ent == nil) then
        return false;
    end
    local index = AshitaCore:GetMemoryManager():GetParty():GetMemberTargetIndex(0);
    return ent:GetStatusServer(index) == STATUS_EVENT;
end

--[[
* Press Escape, to be released ESCAPE_HOLD frames later.  Refuses to start a
* second press while one is still held: a repeat would keep resetting the frame
* count, the release would never fire, and Escape would be left down for the
* whole system.
--]]
local function press_escape(now)
    if (user32 == nil or ui.esc_frames > 0) then
        return;
    end
    user32.keybd_event(VK_ESCAPE, ESCAPE_SCAN, 0, 0);
    ui.esc_frames = ESCAPE_HOLD;
    ui.esc_at     = now;
end

--[[
* Hand a command to the game.  Multisend is one gate here rather than a prefix
* remembered at each call site.
--]]
local function queue_cmd(cmd)
    AshitaCore:GetChatManager():QueueCommand(-1, ui.mss and (MSS_PREFIX .. cmd) or cmd);
    -- sent_at holds off the NPC event the command triggers, which would
    -- otherwise open the map straight back up on top of what was asked for.
    ui.sent_at = os.clock();
end

--[[
* Every command the map sends goes out here.  A command asked for from inside an
* NPC's menu is held until Escape has closed it, since Uberwarp starts its own
* conversation and cannot while one is already up.  Without user32 there is no
* way to press Escape, so the command goes out as it always did and the player
* closes the menu themselves.
--]]
local function send_cmd(cmd)
    if (user32 ~= nil and in_event()) then
        ui.pending = cmd;
        ui.pend_at = os.clock();
        ui.sent_at = ui.pend_at;
        press_escape(ui.pend_at);
    else
        queue_cmd(cmd);
    end
    -- Sending is what the map was opened for, so it goes away whole: window,
    -- warp popup and credits panel together.
    ui.is_open[1] = false;
    ui.warp       = nil;
    ui.thanks     = false;
end

--[[
* A warp row shows while the toggle its type names is still lit.  A type no
* toggle names never shows.
--]]
local function warp_lit(w)
    local file = WARP_ICON[w.type];
    return file ~= nil and not ui.toggle[file];
end

--[[
* True while a row can actually be taken, i.e. the player is stood at the kind
* of NPC it travels from.  ui.near_kind is false before the first poll and nil
* while nothing is in reach, and neither matches a type, so both read as out of
* reach.
--]]
local function warp_reachable(w)
    return w.type == ui.near_kind;
end

-- True while a toggle that lists warp rows is dimmed, i.e. the map has been
-- narrowed to some of the kinds rather than showing all of them.
local function warps_filtered()
    for _, file in pairs(WARP_ICON) do
        if (ui.toggle[file]) then
            return true;
        end
    end
    return false;
end

-- True when the zone still has a row left after the toggles, i.e. its marker
-- has something to open.  Deliberately allocation free: this runs per marker
-- per frame, unlike warp_rows below.
local function warps_lit(label)
    for _, w in ipairs(WARPS[label] or {}) do
        if (warp_lit(w)) then
            return true;
        end
    end
    return false;
end

--[[
* The warp type an NPC's name begins, or nil when it begins none.
--]]
local function warp_npc_type(name)
    for _, v in ipairs(WARP_NPC) do
        if (name:match(v[1])) then
            return v[2];
        end
    end
    return nil;
end

--[[
* The warp type of the nearest such NPC within WARP_NPC_NEAR, or nil when none
* is in reach.  Nearest rather than first found: a zone can hold two kinds
* within the radius, and the one being stood at is the one meant.
--]]
local function near_warp_type()
    local ent = AshitaCore:GetMemoryManager():GetEntity();
    if (ent == nil) then
        return nil;
    end
    local kind, near = nil, WARP_NPC_NEAR * WARP_NPC_NEAR;
    for i = NPC_FIRST, NPC_LAST do
        -- GetDistance is squared yalms, so the radius is squared to match it
        -- rather than taking a root per entity.  0x200 is the rendered bit: a
        -- slot keeps the name of whatever last held it after that despawns.
        local d = ent:GetDistance(i);
        if (d < near and bit.band(ent:GetRenderFlags0(i), 0x200) == 0x200) then
            local t = warp_npc_type(ent:GetName(i) or '');
            if (t ~= nil) then
                kind, near = t, d;
            end
        end
    end
    return kind;
end

--[[
* Narrow the map to one kind of warp, or light every kind again when given nil.
--]]
local function filter_to(kind)
    for t, file in pairs(WARP_ICON) do
        ui.toggle[file] = (kind ~= nil and t ~= kind) or nil;
    end
end

--[[
* True while an Instant Warp scroll sits in the bag.  Matched by item id rather
* than by name: the resource name a server gives an item need not be the string
* a name lookup wants.  pcall'd whole because the inventory is not readable
* while zoning.
--]]
local function have_warp_item()
    local ok, found = pcall(function()
        local inv = AshitaCore:GetMemoryManager():GetInventory();
        for i = 1, BAG_SLOTS do
            local it = inv:GetContainerItem(BAG, i);
            if (it ~= nil and it.Id == WARP_ITEM_ID and it.Count > 0) then
                return true;
            end
        end
        return false;
    end);
    return ok and found;
end

--[[
* Re-read what is in reach while the map is up and narrow to it.  Only when the
* answer has changed, so a toggle clicked by hand stands until the player walks
* off the NPC or up to a different kind.  Polled rather than done per frame:
* walking in and out of range happens on a human timescale, and the read is a
* thousand-odd entity slots.
--]]
local function poll_near(now)
    if (now - ui.near_at < NEAR_POLL) then
        return;
    end
    ui.near_at = now;
    ui.has_warp = have_warp_item();
    local kind = near_warp_type();
    if (kind ~= ui.near_kind) then
        ui.near_kind = kind;
        filter_to(kind);
    end
end

--[[
* True once the player has walked MOVE_CLOSE from the spot the map was opened
* at.  Measured against that spot rather than the last frame, so a slow walk
* adds up instead of falling under a per-frame threshold.  Position rather than
* a keypress, because the client also moves on gamepad, autorun and follow.
*
* The first call after opening only records the spot, so a map opened while
* already running does not shut on the same frame.  Zoning jumps the position
* and so closes the map, which is what walking through a zone line should do
* anyway.
--]]
local function player_moved()
    local ent = AshitaCore:GetMemoryManager():GetEntity();
    if (ent == nil) then
        return false;
    end
    local index = AshitaCore:GetMemoryManager():GetParty():GetMemberTargetIndex(0);
    local x, z  = ent:GetLocalPositionX(index), ent:GetLocalPositionZ(index);
    if (ui.open_x == nil) then
        ui.open_x, ui.open_z = x, z;
        return false;
    end
    local dx, dz = x - ui.open_x, z - ui.open_z;
    return dx * dx + dz * dz > MOVE_CLOSE * MOVE_CLOSE;
end

--[[
* Everything outside the focused group fades back, and so does a zone the
* toggles have left with no warp row: the marker stays on the map to say the
* zone is there, dimmed to say it holds none of the kind being looked for.  The
* overview tier carries no warps of its own, so the toggles leave it lit.
--]]
local function icon_dim(ic)
    if (ui.focus ~= nil and ic.group ~= ui.focus) then
        return true;
    end
    return not OVERVIEW[ic.group] and warps_filtered() and not warps_lit(ic.label);
end

-- Rows written before the past map existed carry no tag, so an untagged marker
-- is a present-day one.
local function icon_time(ic)
    return ic.time or 'present';
end

-- ui.zoom is nil until the first frame sizes the viewport, so treat that as
-- hidden rather than comparing against nil.
local function icon_visible(ic)
    local z = ui.zoom;
    if (z == nil) then
        return false;
    end
    if (icon_time(ic) ~= ui.time) then
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
* Release a held Escape, and send a command that was waiting on the menu it
* closed.  Runs every frame whether the map is up or not: sending closes the
* map, so by the time the menu is gone there is no map left to run it from.
--]]
local function pump_escape(now)
    if (ui.esc_frames > 0) then
        ui.esc_frames = ui.esc_frames - 1;
        if (ui.esc_frames == 0) then
            user32.keybd_event(VK_ESCAPE, ESCAPE_SCAN, KEYEVENTF_KEYUP, 0);
        end
        return;
    end

    if (ui.pending == nil) then
        return;
    end

    -- The menu is gone, so the command can go.
    if (not in_event()) then
        queue_cmd(ui.pending);
        ui.pending = nil;
        return;
    end

    if (now - ui.pend_at > ESCAPE_WAIT) then
        ui.pending = nil;
        notify('could not leave the menu; close it and click again');
        return;
    end

    -- Still in it, so back out another level.
    if (now - ui.esc_at > ESCAPE_RETRY) then
        press_escape(now);
    end
end

--[[
* Every named entity within NEAR_DUMP, printed with everything near_warp_type
* tests it on: the slot, so an NPC outside NPC_FIRST..NPC_LAST shows up as one;
* the distance, so a radius that is too tight shows up as one; the render flags,
* whose 0x200 bit a live entity carries; and the type its name matched, so a
* name the server spells differently shows up as '-'.  The whole array is
* walked, not just the NPC slice, because the slice is one of the things being
* checked.  '/ubermap near'.
--]]
local NEAR_DUMP = 30;  -- yalms
local DUMP_MAX  = 20;  -- rows, so a crowded zone cannot flood the log

local function near_dump()
    local ent = AshitaCore:GetMemoryManager():GetEntity();
    if (ent == nil) then
        notify('no entity manager - are you logged in?');
        return;
    end
    local shown, found = 0, 0;
    for i = 0, 2303 do
        local name = ent:GetName(i);
        local d    = ent:GetDistance(i);
        if (name ~= nil and name ~= '' and d < NEAR_DUMP * NEAR_DUMP) then
            found = found + 1;
            if (shown < DUMP_MAX) then
                shown = shown + 1;
                notify(('%04X %-22s %5.1fy flags %08X %s'):fmt(
                    i, name, math.sqrt(d), ent:GetRenderFlags0(i),
                    warp_npc_type(name) or '-'));
            end
        end
    end
    notify(('%d entity(s) within %dy, %d shown'):fmt(found, NEAR_DUMP, shown));
    notify(('filter sees: %s (radius %dy, slots %04X-%04X)'):fmt(
        near_warp_type() or 'nothing', WARP_NPC_NEAR, NPC_FIRST, NPC_LAST));
end

--[[
* Points placed in game go back to lib/points.lua, so the work survives a reload.
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
    f:write("-- overview.  'time' tags which map a marker belongs to.\n");
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

--[[
* Unlike lib/points.lua this file is an overlay: the map draws without it, so a
* missing or broken one costs the popups and nothing else.
--]]
local function load_warps()
    local chunk, err = loadfile(WARPS_FILE);
    if (chunk == nil) then
        notify(('could not read %s: %s'):fmt(WARPS_FILE, tostring(err)));
        return;
    end
    local ok, data = pcall(chunk);
    if (not ok or type(data) ~= 'table') then
        notify(('%s failed to load: %s'):fmt(WARPS_FILE, tostring(data)));
        return;
    end
    WARPS = T(data);
end
load_warps();

--[[
* The warp rows of a zone that the toggles leave lit, in the order the data
* lists them.  nil when the zone has none, which is what keeps the popup shut.
--]]
local function warp_rows(label)
    local rows = T{};
    for _, w in ipairs(WARPS[label] or {}) do
        if (warp_lit(w)) then
            table.insert(rows, w);
        end
    end
    return (#rows > 0) and rows or nil;
end

--[[
* The /uw line a row travels on.  The zone comes from the popup's key, which is
* the marker's label, except where a marker is not one zone: those rows carry a
* 'zone' of their own.  Home Points take their number straight off the label,
* the way the command wants it -- '/uw hp Aht Urhgan Whitegate3'.
--]]
local UW_TYPE = T{ home = 'hp', guide = 'sg', unity = 'uc' };

local function warp_cmd(label, row)
    local kind = UW_TYPE[row.type];
    if (kind == nil) then
        return nil;
    end
    -- The map writes the Campaign zones '(S)', the game calls them '[S]'.
    local zone = (row.zone or label):gsub('%(S%)$', '[S]');
    -- The first Home Point of a zone is the bare name: '#1' is the default the
    -- command falls back to, so sending it would be a zone the server rejects.
    local n = (row.type == 'home') and row.label:match('^Home Point #(%d+)') or nil;
    return ('/uw %s %s%s'):fmt(kind, zone, (n ~= '1') and n or '');
end

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
        time   = ui.time,
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
    if (ui.warp == ic) then
        ui.warp = nil;  -- or the panel keeps drawing off a marker that is gone
    end
    ui.dirty = true;
end

--[[
* Packs a picker's { r, g, b, a } floats into the ABGR word the draw list takes,
* fading the alpha by 'fade' when given.
--]]
local function pack_col(c, fade)
    local function q(v)
        return math.floor(math.min(math.max(v, 0), 1) * 255 + 0.5);
    end
    return q(c[4] * (fade or 1)) * 0x1000000
         + q(c[3]) * 0x10000 + q(c[2]) * 0x100 + q(c[1]);
end

--[[
* ImGui has no outlined text, so stamp the string in the outline colour around
* itself before drawing it.  Keeps it readable over both land and ocean.  Both
* colours come from the pickers, so every string on the map retints together.
--]]
local function outlined_text(dl, x, y, text, dim)
    local fade    = dim and DIM_ALPHA or nil;
    local outline = pack_col(ui.col_outline, fade);
    for _, o in ipairs({ { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }) do
        dl:AddText({ x + o[1], y + o[2] }, outline, text);
    end
    dl:AddText({ x, y }, pack_col(ui.col_text, fade), text);
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
    if (ui.tex_time == ui.time or ui.load_failed == ui.time) then
        return;
    end

    -- Drop the other map's texture before the new one is decoded, so the two
    -- never sit in memory together.  gc_safe_release frees it on collection,
    -- which is why the collect is explicit rather than left to run later.
    ui.texture = nil;
    ui.tex_time = nil;
    collectgarbage();

    ui.texture = load_asset(TIMES[ui.time].file, TEX_W, TEX_H);
    ui.tex_time = (ui.texture ~= nil) and ui.time or nil;
    ui.load_failed = (ui.texture == nil) and ui.time or nil;
end

--[[
* Switches which map is on screen.  The two images do not share a coordinate
* space, so the view is reset rather than carried across: zoom nil re-fits to
* the viewport on the next frame.
--]]
local function set_time(time)
    if (TIMES[time] == nil or time == ui.time) then
        return;
    end
    ui.time  = time;
    ui.zoom  = nil;
    ui.pan_x = 0;
    ui.pan_y = 0;
    ui.focus = nil;
    ui.sel   = nil;
    ui.press = nil;
    ui.warp  = nil;
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
* The nation art has no such pair, so those icons instead draw ICON_HOT larger
* while hovered.
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
            -- A dimmed marker is out of the subject of the view, so it does
            -- not take the cursor either: nothing to frame, nothing to open.
            local dim = icon_dim(ic);
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
                -- Grown only for the draw: the hit test above keeps the plain
                -- size, so the icon cannot swell out from under the cursor and
                -- flicker between the two states.
                local grow  = (hot and ic.group == HOT_GROUP)
                              and half * ICON_HOT or half;
                local id    = tonumber(ffi.cast('uint32_t', tex));
                local p0    = { cx - grow, cy - grow };
                local p1    = { cx + grow, cy + grow };
                local round = grow * 2 * ICON_ROUND;
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
                    outlined_text(dl, cx - tw / 2, cy - grow - th - LABEL_GAP,
                                  ic.label, dim);
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
        if (ic.group == name and icon_time(ic) == ui.time) then
            x0 = math.min(x0 or ic.x, ic.x);
            y0 = math.min(y0 or ic.y, ic.y);
            x1 = math.max(x1 or ic.x, ic.x);
            y1 = math.max(y1 or ic.y, ic.y);
        end
    end
    if (x0 == nil) then
        return false;
    end

    local map_w, map_h = map_size();
    local floor_z = math.max(ZOOM_POINTS, mm.cover_zoom(map_w, map_h, view_w, view_h));
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
    -- Opening reads the world afresh on the next frame, whatever the toggles
    -- were left at when it was last up.
    ui.near_kind = false;
    ui.near_at   = 0;
    -- and re-anchors where the player is standing now, so the map does not
    -- close on the distance walked since the last time it was up.
    ui.open_x    = nil;
    ui.open_z    = nil;
end

local function draw_map(view_w, view_h)
    if (ui.debug) then
        imgui.Text(ui.dbg or '');
        -- What the auto-filter is acting on, live: the kind in reach, when it
        -- was last read, and the toggle each kind was left at.
        imgui.Text(('near=%s polled %.1fs ago | crystal=%s guide=%s unity=%s warp=%s'):fmt(
            tostring(ui.near_kind), os.clock() - ui.near_at,
            tostring(ui.toggle['Crystal.png']), tostring(ui.toggle['Guide.png']),
            tostring(ui.toggle['Unity.png']), tostring(ui.has_warp)));
        -- What the menu escape is doing: whether the game says we are in one,
        -- the command waiting on it, and whether a press is still held.
        imgui.Text(('event=%s pending=%s held=%d user32=%s'):fmt(
            tostring(in_event()), tostring(ui.pending), ui.esc_frames,
            tostring(user32 ~= nil)));
        local _, avail_h = imgui.GetContentRegionAvail();
        view_h = avail_h;
    end

    -- The minimum zoom covers the viewport, so the map never letterboxes.
    -- Re-applied every frame because growing the window raises the floor.
    local map_w, map_h = map_size();
    local cover = mm.cover_zoom(map_w, map_h, view_w, view_h);
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
            -- again, so everything comes back up to full.  The popup goes with
            -- it, being anchored on a marker that just moved.
            ui.focus = nil;
            ui.warp  = nil;
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

    local content_w = map_w * ui.zoom;
    local content_h = map_h * ui.zoom;
    ui.pan_x = mm.clamp_pan(ui.pan_x, content_w, view_w);
    ui.pan_y = mm.clamp_pan(ui.pan_y, content_h, view_h);

    -- The child clips and a negative cursor position does the panning, which
    -- avoids depending on ImGui's scroll API.
    if (imgui.BeginChild('ubermap_view', { view_w, view_h }, false,
            bit.bor(ImGuiWindowFlags_NoScrollbar, ImGuiWindowFlags_NoScrollWithMouse))) then
        imgui.SetCursorPos({ -ui.pan_x, -ui.pan_y });
        imgui.Image(tonumber(ffi.cast('uint32_t', ui.texture)), { content_w, content_h });
        local hot_ic = draw_icons(origin_x, origin_y, view_w, view_h, over_map);

        -- Clicking an overview marker frames the group its label names; a zone
        -- point opens its warp list instead.  The press is remembered and acted
        -- on at release, so a drag that starts on a marker pans as usual instead
        -- of jumping the view.  Ctrl is the editor's chord, so it is left alone.
        if (imgui.IsMouseClicked(0)) then
            ui.press = (hot_ic ~= nil and not imgui.GetIO().KeyCtrl) and hot_ic or nil;
        end
        if (ui.dragging) then
            ui.press = nil;
        end
        if (ui.press ~= nil and imgui.IsMouseReleased(0)) then
            if (OVERVIEW[ui.press.group]) then
                zoom_to_group(ui.press.label, view_w, view_h);
            else
                -- A zone nothing warps to leaves the panel shut rather than
                -- opening an empty one.
                ui.warp = (warp_rows(ui.press.label) ~= nil) and ui.press or nil;
            end
            ui.press = nil;
        end

        local row_h = imgui.GetFrameHeight() * SEARCH_H_MULT;

        -- Past/present switch, first on the search row.  The art names the map
        -- you are on, not the one the press takes you to.  The switch is
        -- recorded and applied after the frame, because set_time clears the
        -- zoom that the rest of this frame still reads.  Drawn by hand for the
        -- same reason the toggles below are, and falling back to a text button
        -- if the art fails to load, so the other map stays reachable.
        local other = (ui.time == 'present') and 'past' or 'present';
        local ttex, tiw, tih = icon_texture(ui.time .. '.png');
        local time_w = (ttex ~= nil) and (row_h * tiw / tih)
                                     or (imgui.CalcTextSize('Present') + 2);
        imgui.SetCursorPos({ SEARCH_MARGIN, SEARCH_MARGIN });
        if (ttex ~= nil) then
            local sx, sy = imgui.GetCursorScreenPos();
            imgui.GetWindowDrawList():AddImage(tonumber(ffi.cast('uint32_t', ttex)),
                                               { sx, sy }, { sx + time_w, sy + row_h },
                                               { 0, 0 }, { 1, 1 }, COL_ICON);
            -- Vetoed by a warp popup lying over it, for the reason spelled out
            -- on the toggles below.
            if (imgui.InvisibleButton('##ubermap_time', { time_w, row_h })
                and not ui.warp_hot) then
                ui.next_time = other;
            end
        elseif (imgui.Button(ui.time == 'past' and 'Past' or 'Present', { time_w, row_h })
                and not ui.warp_hot) then
            ui.next_time = other;
        end
        local time_hot = imgui.IsItemHovered();
        item_tip('Switch to a map of the ' .. other);
        local search_x = SEARCH_MARGIN + time_w + TOGGLE_GAP;

        imgui.PushStyleVar(ImGuiStyleVar_FramePadding,
                           { 6, (row_h - imgui.GetFontSize()) / 2 });
        imgui.PushStyleColor(ImGuiCol_FrameBg, COL_SEARCH_BG);
        imgui.PushStyleColor(ImGuiCol_FrameBgHovered, COL_SEARCH_BG);
        imgui.PushStyleColor(ImGuiCol_FrameBgActive, COL_SEARCH_BG);
        imgui.PushStyleColor(ImGuiCol_Text, COL_SEARCH_TEXT);
        imgui.PushStyleColor(ImGuiCol_TextDisabled, COL_SEARCH_HINT);
        imgui.SetCursorPos({ search_x, SEARCH_MARGIN });
        imgui.SetNextItemWidth(SEARCH_W);
        imgui.InputTextWithHint('##ubermap_search', 'Search', ui.search, SEARCH_MAX);
        imgui.PopStyleColor(5);
        imgui.PopStyleVar();
        -- Read a frame late by over_map above, which is fine: a click focuses
        -- the box before the drag threshold is ever crossed.
        ui.search_hot = imgui.IsItemActive() or imgui.IsItemHovered() or time_hot;

        -- Toggle icons, sharing the search box's line.  Drawn by hand rather
        -- than with ImageButton, whose argument list moved between the ImGui
        -- versions Ashita has shipped; an InvisibleButton over an AddImage is
        -- the same widget without the version check.
        local tdl   = imgui.GetWindowDrawList();
        local tsize = row_h;
        local tx_at = search_x + SEARCH_W + TOGGLE_GAP;
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
                -- ui.warp_hot vetoes the press: this row is submitted before the
                -- warp popup, and ImGui gives hover to the first item that
                -- claims it, so a panel lying over a toggle would otherwise flip
                -- it from underneath.  A frame late, which is harmless - the
                -- panel does not move while it is open.
                if (imgui.InvisibleButton('##ubermap_toggle_' .. file, { tw, tsize })
                    and not ui.warp_hot) then
                    ui.toggle[file] = not ui.toggle[file];
                    save_settings();
                end
                item_tip((ui.toggle[file] and 'Show ' or 'Hide ')
                         .. (TOGGLE_NAME[file] or file));
                ui.search_hot = ui.search_hot or imgui.IsItemHovered();
                tx_at = tx_at + tw + TOGGLE_GAP;
            end
        end

        -- Instant Warp, last on that line.  It uses the scroll instead of
        -- filtering the map, so it is drawn dim and takes no press while none
        -- is carried.  The press is vetoed by a warp popup lying over it for
        -- the same reason the toggles above are.
        local wtex, wiw, wih = icon_texture(WARP_ITEM_ICON);
        if (wtex ~= nil) then
            local tw = tsize * wiw / wih;
            imgui.SetCursorPos({ tx_at, SEARCH_MARGIN });
            local sx, sy = imgui.GetCursorScreenPos();
            tdl:AddImage(tonumber(ffi.cast('uint32_t', wtex)),
                         { sx, sy }, { sx + tw, sy + tsize }, { 0, 0 }, { 1, 1 },
                         ui.has_warp and COL_ICON or COL_ICON_OFF);
            if (imgui.InvisibleButton('##ubermap_warpitem', { tw, tsize })
                and not ui.warp_hot and ui.has_warp) then
                send_cmd(WARP_ITEM_CMD);
            end
            item_tip(ui.has_warp and 'Use Instant Warp scroll'
                                  or 'No Instant Warp scroll in inventory');
            ui.search_hot = ui.search_hot or imgui.IsItemHovered();
        end

        -- Colour pickers, pinned to the viewport's top-right corner and
        -- sharing the search row's height.  ImGui writes into the tables
        -- outlined_text packs from, so the map retints as they move.
        -- NoInputs leaves only the swatch, which opens the picker on click;
        -- NoLabel forwards the name to that popup; the name is stamped over
        -- the swatch by hand instead, outlined because it sits on the map.
        -- Editor-only, like the coordinate readout: retinting is authoring.
        if (ui.edit) then
            local pick_flags = bit.bor(ImGuiColorEditFlags_NoInputs,
                                       ImGuiColorEditFlags_NoLabel,
                                       ImGuiColorEditFlags_AlphaBar,
                                       ImGuiColorEditFlags_AlphaPreview);
            imgui.PushStyleVar(ImGuiStyleVar_FramePadding,
                               { 6, (row_h - imgui.GetFontSize()) / 2 });
            local picks = { { 'Text',    ui.col_text },
                            { 'Outline', ui.col_outline },
                            { 'Hover',   ui.col_hover } };
            -- A label wider than its swatch widens that column rather than
            -- running into its neighbour, so the strip stays right-anchored.
            local total, lbl_h = 0, 0;
            for _, pick in ipairs(picks) do
                local lw, lh = imgui.CalcTextSize(pick[1]);
                pick[3] = math.max(row_h, lw);
                total   = total + pick[3];
                lbl_h   = math.max(lbl_h, lh);
            end
            local ldl    = imgui.GetWindowDrawList();
            local pick_x = view_w - SEARCH_MARGIN
                           - total - (#picks - 1) * TOGGLE_GAP;
            for _, pick in ipairs(picks) do
                local lw = imgui.CalcTextSize(pick[1]);
                outlined_text(ldl, origin_x + pick_x + (pick[3] - lw) / 2,
                              origin_y + SEARCH_MARGIN, pick[1]);
                imgui.SetCursorPos({ pick_x + (pick[3] - row_h) / 2,
                                     SEARCH_MARGIN + lbl_h + PICK_LABEL_GAP });
                if (imgui.ColorEdit4(pick[1], pick[2], pick_flags)) then
                    ui.col_dirty = true;
                end
                ui.search_hot = ui.search_hot
                                or imgui.IsItemActive() or imgui.IsItemHovered();
                pick_x = pick_x + pick[3] + TOGGLE_GAP;
            end
            -- One write per drag rather than one per frame of it: the picker
            -- reports a change on every frame the mouse moves inside it.
            if (ui.col_dirty and not imgui.IsMouseDown(0)) then
                ui.col_dirty = false;
                save_settings();
            end
            imgui.PopStyleVar();
        end

        -- Everything below the search row stacks from here.
        local edit_y = SEARCH_MARGIN + row_h + TOGGLE_GAP;

        -- Editor panel, stacked under the search box.  Its widgets feed
        -- search_hot too, so dragging in them edits text instead of panning.
        if (ui.edit) then
            if (ui.sel == nil) then
                outlined_text(imgui.GetWindowDrawList(),
                              origin_x + SEARCH_MARGIN, origin_y + edit_y,
                              'ctrl+click the map to add or grab a point');
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

        -- Source-image pixel under the cursor, for typing into a point's
        -- coordinates.  Independent of zoom and pan, so the same spot on the map
        -- always reads the same numbers.
        if (ui.edit and over_map) then
            local mx = math.floor(mm.to_map(mouse_x, ui.pan_x, ui.zoom, origin_x));
            local my = math.floor(mm.to_map(mouse_y, ui.pan_y, ui.zoom, origin_y));
            -- The font scale applies to the draw list too, so it has to wrap
            -- the white stamps as well as the text itself.
            imgui.SetWindowFontScale(READOUT_SCALE);
            outlined_text(imgui.GetWindowDrawList(), origin_x + 6, origin_y + view_h - 30,
                          ('%d, %d'):fmt(mx, my));
            imgui.SetWindowFontScale(1.0);
        end

        -- Credits, pinned to the viewport's bottom-right corner.  Drawn by hand
        -- for the same reason the toggles are, and falling back to a text
        -- button so the credits stay reachable if the art is missing.
        local htex, hiw, hih = icon_texture('heart.png');
        local heart_w = (htex ~= nil) and (row_h * hiw / hih)
                                      or (imgui.CalcTextSize('Thanks') + 12);
        local heart_x = view_w - SEARCH_MARGIN - heart_w;
        local heart_y = view_h - SEARCH_MARGIN - row_h;

        -- Multisend, sat left of the heart on the same line.  Art only: with no
        -- icon there is nothing to press and the map keeps sending the way it
        -- always did, rather than growing a second text button in the corner.
        local mtex, miw, mih = icon_texture(MSS_ICON);
        if (mtex ~= nil) then
            local mss_w = row_h * miw / mih;
            imgui.SetCursorPos({ heart_x - TOGGLE_GAP - mss_w, heart_y });
            local sx, sy = imgui.GetCursorScreenPos();
            imgui.GetWindowDrawList():AddImage(tonumber(ffi.cast('uint32_t', mtex)),
                                               { sx, sy }, { sx + mss_w, sy + row_h },
                                               { 0, 0 }, { 1, 1 },
                                               ui.mss and COL_HEART or COL_MSS_OFF);
            if (imgui.InvisibleButton('##ubermap_mss', { mss_w, row_h })
                and not ui.warp_hot) then
                ui.mss = not ui.mss;
                save_settings();
            end
            item_tip(ui.mss and 'Multisend on: warps go to every character'
                             or 'Multisend off: warps go to this character only');
            ui.search_hot = ui.search_hot or imgui.IsItemHovered();
        end

        imgui.SetCursorPos({ heart_x, heart_y });
        if (htex ~= nil) then
            local sx, sy = imgui.GetCursorScreenPos();
            imgui.GetWindowDrawList():AddImage(tonumber(ffi.cast('uint32_t', htex)),
                                               { sx, sy }, { sx + heart_w, sy + row_h },
                                               { 0, 0 }, { 1, 1 }, COL_HEART);
            if (imgui.InvisibleButton('##ubermap_thanks', { heart_w, row_h })
                and not ui.warp_hot) then
                ui.thanks = not ui.thanks;
            end
        elseif (imgui.Button('Thanks', { heart_w, row_h }) and not ui.warp_hot) then
            ui.thanks = not ui.thanks;
        end
        local heart_hot = imgui.IsItemHovered();
        ui.search_hot = ui.search_hot or heart_hot;

        -- Credits panel, hung above the heart on the same corner.  One row per
        -- THANKS_ROWS entry; a link row hands its url to the browser, and a
        -- click anywhere else shuts the panel.
        if (ui.thanks) then
            local kdl   = imgui.GetWindowDrawList();
            local _, th = imgui.CalcTextSize('X');
            local w     = 0;
            for _, r in ipairs(THANKS_ROWS) do
                w = math.max(w, imgui.CalcTextSize(r.text));
            end
            w = w + POPUP_PAD * 2;
            local h = POPUP_PAD * 2 + POPUP_ROW * #THANKS_ROWS;
            local px = origin_x + view_w - SEARCH_MARGIN - w;
            local py = mm.clamp_box(origin_y + heart_y - POPUP_GAP - h,
                                    h, origin_y, view_h);

            kdl:AddRectFilled({ px, py }, { px + w, py + h }, COL_POPUP_BG,
                              0, ImDrawCornerFlags_All);
            kdl:AddRect({ px, py }, { px + w, py + h }, COL_OUTLINE,
                        0, ImDrawCornerFlags_All, ICON_BORDER);
            local hot_link = nil;
            for i, r in ipairs(THANKS_ROWS) do
                local ry = py + POPUP_PAD + POPUP_ROW * (i - 1);
                -- Only a link row lights up, so the blanks and the heading do
                -- not read as things you can press.
                if (r.url ~= nil
                    and mouse_x >= px and mouse_x <= px + w
                    and mouse_y >= ry and mouse_y < ry + POPUP_ROW) then
                    hot_link = r.url;
                    kdl:AddRectFilled({ px + ICON_BORDER, ry },
                                      { px + w - ICON_BORDER, ry + POPUP_ROW },
                                      pack_col(ui.col_hover),
                                      0, ImDrawCornerFlags_All);
                end
                kdl:AddText({ px + POPUP_PAD, ry + (POPUP_ROW - th) / 2 },
                            (r.url ~= nil) and COL_THANKS_URL or COL_POPUP_TEXT,
                            r.text);
            end

            -- An InvisibleButton over the panel takes the press, so it neither
            -- falls through to the map nor starts a window move; the hover is
            -- tested by rect for the reason the warp panel below spells out.
            imgui.SetCursorPos({ px - origin_x, py - origin_y });
            imgui.InvisibleButton('##ubermap_thanks_panel', { w, h });
            local thanks_hot = mouse_x >= px and mouse_x <= px + w
                               and mouse_y >= py and mouse_y <= py + h;
            ui.search_hot = ui.search_hot or thanks_hot;
            -- heart_hot vetoes the close: the button that just opened the panel
            -- reports the same click this test sees.
            if (imgui.IsMouseClicked(0)) then
                if (hot_link ~= nil) then
                    open_url(hot_link);
                elseif (not thanks_hot and not heart_hot) then
                    ui.thanks = false;
                end
            end
        end

        -- Warp list for the zone point that was clicked, drawn after everything
        -- else so it lands on top of it.  Rows are read out in the order the
        -- data gives them, and clicking one sends its /uw.  No title row: the
        -- marker it hangs off already names the zone.
        if (ui.warp ~= nil) then
            local rows = warp_rows(ui.warp.label);
            if (rows == nil) then
                ui.warp = nil;  -- the toggles emptied it while it was open
            else
                local pdl    = imgui.GetWindowDrawList();
                local _, th  = imgui.CalcTextSize(ui.warp.label);
                -- The grid reference is a column of its own, so every row's
                -- label starts at one x and every '(F-11)' at another.
                local labw, posw = 0, 0;
                for _, r in ipairs(rows) do
                    labw = math.max(labw, imgui.CalcTextSize(r.label));
                    if (r.pos ~= nil) then
                        posw = math.max(posw, imgui.CalcTextSize(r.pos));
                    end
                end
                local lab_x = POPUP_PAD * 2 + POPUP_ICON;
                local pos_x = lab_x + labw + POPUP_PAD;
                local w     = ((posw > 0) and (pos_x + posw) or (lab_x + labw))
                              + POPUP_PAD;
                local h = POPUP_PAD * 2 + POPUP_ROW * #rows;

                -- Hung under the marker and clamped both ways, so a point near
                -- an edge does not push the panel off the viewport.
                local half = (ui.warp.size or ICON_SIZE) / 2;
                local px = mm.clamp_box(
                    mm.to_screen(ui.warp.x, ui.pan_x, ui.zoom, origin_x) - w / 2,
                    w, origin_x, view_w);
                local py = mm.clamp_box(
                    mm.to_screen(ui.warp.y, ui.pan_y, ui.zoom, origin_y) + half + POPUP_GAP,
                    h, origin_y, view_h);

                pdl:AddRectFilled({ px, py }, { px + w, py + h }, COL_POPUP_BG,
                                  0, ImDrawCornerFlags_All);
                pdl:AddRect({ px, py }, { px + w, py + h }, COL_OUTLINE,
                            0, ImDrawCornerFlags_All, ICON_BORDER);
                local hot_row = nil;
                for i, r in ipairs(rows) do
                    local ry = py + POPUP_PAD + POPUP_ROW * (i - 1);
                    -- A row only travels from the kind of NPC the player is
                    -- stood at, so one of another kind is drawn dim and takes
                    -- no hover or press.  Listed rather than dropped: the row
                    -- says the destination exists and what to walk up to.
                    local live = warp_reachable(r);
                    -- The hover is drawn straight into the list rather than
                    -- coming off an ImGui item, for the same reason the click
                    -- below is tested by hand: the panel is one InvisibleButton.
                    if (live and mouse_x >= px and mouse_x <= px + w
                        and mouse_y >= ry and mouse_y < ry + POPUP_ROW) then
                        hot_row = r;
                        pdl:AddRectFilled({ px + ICON_BORDER, ry },
                                          { px + w - ICON_BORDER, ry + POPUP_ROW },
                                          pack_col(ui.col_hover),
                                          0, ImDrawCornerFlags_All);
                    end
                    local tex, iw, ih = icon_texture(WARP_ICON[r.type]);
                    if (tex ~= nil) then
                        -- The art is not square, so fit it into the icon column
                        -- by its own aspect and centre the slack.
                        local sc = math.min(POPUP_ICON / iw, POPUP_ROW / ih);
                        local ix = px + POPUP_PAD + (POPUP_ICON - iw * sc) / 2;
                        local iy = ry + (POPUP_ROW - ih * sc) / 2;
                        pdl:AddImage(tonumber(ffi.cast('uint32_t', tex)),
                                     { ix, iy }, { ix + iw * sc, iy + ih * sc },
                                     { 0, 0 }, { 1, 1 },
                                     live and COL_ICON or COL_ICON_OFF);
                    end
                    local ty  = ry + (POPUP_ROW - th) / 2;
                    local col = live and COL_POPUP_TEXT or COL_POPUP_OFF;
                    pdl:AddText({ px + lab_x, ty }, col, r.label);
                    if (r.pos ~= nil) then
                        pdl:AddText({ px + pos_x, ty }, col, r.pos);
                    end
                end

                -- An InvisibleButton over the panel takes the press, so it
                -- neither falls through to the map nor starts a window move.
                -- The hover test is the rect and not IsItemHovered: ImGui gives
                -- hover to the first item that claims it, and the search row is
                -- submitted before this one.  Feeding search_hot keeps the map
                -- from panning or zooming underneath; a click anywhere else
                -- closes the panel.
                imgui.SetCursorPos({ px - origin_x, py - origin_y });
                imgui.InvisibleButton('##ubermap_warps', { w, h });
                local warp_hot = mouse_x >= px and mouse_x <= px + w
                                 and mouse_y >= py and mouse_y <= py + h;
                ui.search_hot = ui.search_hot or warp_hot;
                ui.warp_hot   = warp_hot;
                if (imgui.IsMouseClicked(0)) then
                    if (not warp_hot) then
                        ui.warp = nil;
                    elseif (hot_row ~= nil) then
                        local cmd = warp_cmd(ui.warp.label, hot_row);
                        if (cmd ~= nil) then
                            send_cmd(cmd);
                        end
                    end
                end
            end
        end
        if (ui.warp == nil) then
            ui.warp_hot = false;
        end
    end
    imgui.EndChild();

    if (ui.next_time ~= nil) then
        set_time(ui.next_time);
        ui.next_time = nil;
    end

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
    pump_escape(os.clock());

    if (not ui.is_open[1]) then
        return;
    end

    -- Walking away puts the map away: it covers most of the screen, so leaving
    -- it up while moving is never what was wanted.
    if (player_moved()) then
        ui.is_open[1] = false;
        return;
    end

    poll_near(os.clock());

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
    local at = NPC_EVENT[e.id];
    if (at == nil) then
        return false;
    end

    -- Read as two bytes rather than through struct: Ashita ships that library
    -- but nothing here requires it, and a little-endian short is two bytes.
    -- e.data carries the 4 byte header, so a packet offset is a 1-based string
    -- index already; a short packet leaves the bytes nil instead of throwing.
    local lo, hi = e.data:byte(at + 1), e.data:byte(at + 2);
    if (lo == nil or hi == nil) then
        return false;
    end

    local index = lo + hi * 256;
    local name  = AshitaCore:GetMemoryManager():GetEntity():GetName(index);
    if (name == nil or name == '') then
        return false;
    end

    if (ui.debug) then
        notify(('NPC event %04X: %s'):fmt(e.id, name));
    end

    -- A talk the map's own command started is not a reason to reopen it: the
    -- send closed it on purpose.
    if (warp_npc_type(name) ~= nil and os.clock() - ui.sent_at > SEND_QUIET) then
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

    if (sub == 'near') then
        near_dump();
        return;
    end

    -- Opening filters to whatever is in reach; closing leaves the toggles be.
    if (ui.is_open[1]) then
        ui.is_open[1] = false;
    else
        show();
    end
end);

ashita.events.register('unload', 'ubermap_unload', function ()
    -- Unloading mid-press would leave Escape held down for the whole system,
    -- since nothing is left to run the frame that releases it.
    if (user32 ~= nil and ui.esc_frames > 0) then
        user32.keybd_event(VK_ESCAPE, ESCAPE_SCAN, KEYEVENTF_KEYUP, 0);
        ui.esc_frames = 0;
    end
    ui.texture = nil;
    icon_tex = T{};
end);
