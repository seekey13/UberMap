--[[
* UberMap - by Seekey
*
* A zoomable world map that opens itself when you talk to a Home Point,
* Survival Guide or Unity Concord NPC, and closes again when you walk away.
* Clicking a zone point sends the warp for you, backing out of the NPC's menu
* first.  Present and past Vana'diel are separate maps, toggled in the corner
* alongside a Warp Ring button and a Multisend toggle that warps every
* logged-in character at once.
*
* Mouse wheel zooms, left-drag pans, Escape closes.  /ubermap or /um toggles
* the map by hand; /um edit turns on the point editor (ctrl+click to place).
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

-- keybd_event presses Escape for the map: Ashita's IKeyboard binds keys but
-- cannot send them, so leaving an NPC's menu goes through user32, the same way
-- MapBind does.
ffi.cdef[[
    void __stdcall keybd_event(uint8_t vk, uint8_t scan, uint32_t flags, uintptr_t extra);
]]

-- A library that will not load leaves its feature off rather than the addon.
local function try_load(name)
    local ok, lib = pcall(ffi.load, name);
    return ok and lib or nil;
end

local user32 = try_load('user32');

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
-- those are named one by one.  A server that renames them is fixed here.
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

-- Map text, the stamp behind it, and the fill under a warp row the cursor is
-- on.  The _DIM pair is the same colours at a quarter alpha, which is what
-- everything outside the focused group draws at; the stamp fades with the glyph
-- or it outlives the text it was behind.
local COL_TEXT      = 0xFF000000;  -- black
local COL_TEXT_DIM  = 0x40000000;
local COL_STAMP     = 0x80FFFFFF;  -- white, half alpha
local COL_STAMP_DIM = 0x20FFFFFF;
local COL_HOVER     = 0x2EFFFFFF;  -- white, a fifth of an alpha

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
-- the state is kept per file name in cfg.toggle (nil = lit).
-- Maw.png is left out until maw warps are implemented.
local TOGGLES      = T{ 'Crystal.png', 'Guide.png', 'Unity.png' };
-- What each toggle is called on its tooltip, keyed the way cfg.toggle is.
local TOGGLE_NAME  = T{ ['Crystal.png'] = 'Home Points',
                        ['Guide.png']   = 'Survival Guides',
                        ['Unity.png']   = 'Unity Concords' };
local TOGGLE_GAP   = 6;   -- screen pixels between toggles
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

-- The Warp Ring, drawn after the scroll.  Unlike the scroll it has to be worn
-- before it can be used, so the icon walks the player through that: it looks
-- for a ring held anywhere the client will equip out of - the bag and the eight
-- Mog Wardrobes, which is the mog house storage a ring can actually be worn
-- from - then equips it to ring1 and only then uses it.
local RING_ITEM_ICON  = 'warp_ring.png';
local RING_ITEM_ID    = 28540;
local RING_ITEM_NAME  = 'Warp Ring';
local RING_ITEM_CMD   = '/item "Warp Ring" <me>';
local RING_SLOT       = 13;  -- equipment slot index of ring1
-- How long the icon stays dead after an equip is asked for, in seconds: the
-- ring lands on the finger a moment after the command goes out, and a second
-- press in that gap would only ask for the same equip again.
local RING_EQUIP_WAIT = 9;
-- Containers a ring can be equipped out of: the bag plus Mog Wardrobe 1-8.
local RING_BAGS = T{ 0, 8, 10, 11, 12, 13, 14, 15, 16 };
-- Ashita's container id -> the number the /equip command names it by.
local RING_BAG_NUM = { [0] = 0, [8] = 1, [10] = 2, [11] = 3, [12] = 4,
                       [13] = 5, [14] = 6, [15] = 7, [16] = 8 };

-- Warp popup: a header row and one row per destination, hung off the zone
-- point that opened it.
local POPUP_PAD      = 8;   -- screen pixels of margin inside the panel
local POPUP_ROW      = 24;  -- row pitch, screen pixels
local POPUP_ICON     = 24;  -- the box a type icon is fitted into
local POPUP_GAP      = 6;   -- screen pixels between the marker and the panel
local COL_POPUP_BG   = 0xE0101010;  -- near black, a little of the map showing through
local COL_POPUP_TEXT = 0xFFFFFFFF;  -- the panel has its own ground, so white reads
local COL_POPUP_OFF  = 0x60FFFFFF;  -- a row whose kind of NPC is not in reach

-- Multisend, in the viewport's bottom-right corner.  While it is lit every
-- command the map sends goes out through Thorny's Multisend instead of straight
-- to the client, so all the logged-in characters take the warp together.  Off
-- by default: it is the surprising thing to do, so it has to be asked for.
local MSS_ICON    = 'multicast.png';
local MSS_PREFIX  = '/mss ';
local COL_MSS_ON  = 0x80FFFFFF;  -- 50% opacity: it sits over the map
local COL_MSS_OFF = 0x40FFFFFF;  -- half that again, i.e. dimmed off

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
-- layers.  Everything else the map needs is read from the world each time it
-- opens, and lives in ui below.
local default_settings = T{
    mss    = false,  -- send through Multisend
    toggle = T{ },   -- toggle file name -> true when dimmed off
};
-- Loaded from a copy of the defaults, because the library hands its own default
-- table back for a key the file has no entry for: without the copy the first
-- dimmed toggle would edit the table above.  cfg is then written through
-- directly, and settings.save() called as each change is made rather than at
-- unload, so nothing is lost if the game goes down first.
local cfg = settings.load(default_settings:copy(true));

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
    dragging    = false,
    drag_x      = 0,
    drag_y      = 0,
    press       = nil,       -- marker the left button went down on
    near_kind   = false,     -- warp type last seen in reach; false until checked
    has_warp    = false,     -- an Instant Warp scroll was in the bag last poll
    ring        = 'none',    -- Warp Ring step: none, equip or use, as of last poll
    ring_bag    = nil,       -- /equip container number the ring was found in
    -- os.clock() an equip was asked for, for the wait.  Starts a whole wait in
    -- the past rather than at 0, since os.clock() reads the process's own time
    -- and would otherwise sit inside the wait for the first seconds of a run.
    ring_at     = -RING_EQUIP_WAIT,
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
    focus       = nil,       -- group name to keep lit; everything else dims
    edit        = false,     -- point editor on
    sel         = nil,       -- the user point being edited
    moving      = false,     -- ctrl-drag in progress
    dirty       = false,     -- an edit is waiting to be written to lib/points.lua
    edit_name   = { '', },
    edit_group  = { 'Regions', },
};

-- Logging in, or switching characters, hands back that character's own file.
settings.register('settings', 'settings_update', function (s)
    cfg = s;
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
    AshitaCore:GetChatManager():QueueCommand(-1, cfg.mss and (MSS_PREFIX .. cmd) or cmd);
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
    -- Sending is what the map was opened for, so it goes away whole: window and
    -- warp popup together.
    ui.is_open[1] = false;
    ui.warp       = nil;
end

--[[
* A warp row shows while the toggle its type names is still lit.  A type no
* toggle names never shows.
--]]
local function warp_lit(w)
    local file = WARP_ICON[w.type];
    return file ~= nil and not cfg.toggle[file];
end

-- True while a toggle that lists warp rows is dimmed, i.e. the map has been
-- narrowed to some of the kinds rather than showing all of them.
local function warps_filtered()
    for _, file in pairs(WARP_ICON) do
        if (cfg.toggle[file]) then
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
        cfg.toggle[file] = (kind ~= nil and t ~= kind) or nil;
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
* The /equip container number a Warp Ring is held in, or nil when none is held
* anywhere it could be worn from.  Matched by item id for the same reason the
* scroll is, and pcall'd whole because the inventory is not readable while
* zoning.  Slot 0 of a container is not an item, so the walk starts at 1.
--]]
local function ring_bag()
    local ok, num = pcall(function()
        local inv = AshitaCore:GetMemoryManager():GetInventory();
        for _, c in ipairs(RING_BAGS) do
            for i = 1, inv:GetContainerCountMax(c) do
                local it = inv:GetContainerItem(c, i);
                if (it ~= nil and it.Id == RING_ITEM_ID and it.Count > 0) then
                    return RING_BAG_NUM[c];
                end
            end
        end
        return nil;
    end);
    return ok and num or nil;
end

--[[
* True while a Warp Ring is worn in ring1.  The worn item is read back out of
* the container it came from: GetEquippedItem hands over an index packing the
* container in its high byte and the slot in its low one.
--]]
local function ring_worn()
    local ok, worn = pcall(function()
        local inv = AshitaCore:GetMemoryManager():GetInventory();
        local eq  = inv:GetEquippedItem(RING_SLOT);
        if (eq == nil or eq.Index == nil or eq.Index == 0) then
            return false;
        end
        local it = inv:GetContainerItem(math.floor(eq.Index / 256), eq.Index % 256);
        return it ~= nil and it.Id == RING_ITEM_ID;
    end);
    return ok and worn;
end

--[[
* The step the ring icon is on, from what the poll found and whether an equip
* is still landing: 'none' when none is held, 'use' when one is worn, 'equip'
* otherwise.  Only 'use' and 'equip' take a press.
--]]
local function ring_step(held, worn, waiting)
    if (not held) then
        return 'none';
    elseif (waiting) then
        return 'wait';
    end
    return worn and 'use' or 'equip';
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
    ui.ring_bag = ring_bag();
    ui.ring     = ring_step(ui.ring_bag ~= nil, ring_worn(),
                            now - ui.ring_at < RING_EQUIP_WAIT);
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
* True when a group marker stands for at least one zone the toggles have left
* with a warp row.  A marker no point carries the group of -- the beastmen
* strongholds, the Aht Urhgan crest -- says nothing either way, so it counts as
* lit rather than fading out on a question it cannot answer.
*
* ponytail: walks every icon per group marker.  Cheap at the thirty-odd markers
* an overview frame draws; index group -> labels at load if the point list ever
* grows an order of magnitude.
--]]
local function group_warps_lit(name)
    local any = false;
    for _, ic in ipairs(ICONS) do
        if (ic.group == name and ic.time == ui.time) then
            if (warps_lit(ic.label)) then
                return true;
            end
            any = true;
        end
    end
    return not any;
end

--[[
* Everything outside the focused group fades back, and so does a zone the
* toggles have left with no warp row: the marker stays on the map to say the
* zone is there, dimmed to say it holds none of the kind being looked for.  An
* overview marker carries no warps of its own, so it answers for the zones it
* stands for: a nation or region whose every zone has been filtered out fades
* back with them.
--]]
local function icon_dim(ic)
    if (ui.focus ~= nil and ic.group ~= ui.focus) then
        return true;
    end
    if (not warps_filtered()) then
        return false;
    end
    if (OVERVIEW[ic.group]) then
        return not group_warps_lit(ic.label);
    end
    return not warps_lit(ic.label);
end

-- ui.zoom is nil until the first frame sizes the viewport, so treat that as
-- hidden rather than comparing against nil.
local function icon_visible(ic)
    local z = ui.zoom;
    if (z == nil) then
        return false;
    end
    if (ic.time ~= ui.time) then
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
* ImGui has no outlined text, so stamp the string in the stamp colour around
* itself before drawing it.  Keeps it readable over both land and ocean.
--]]
local function outlined_text(dl, x, y, text, dim)
    local stamp = dim and COL_STAMP_DIM or COL_STAMP;
    for _, o in ipairs({ { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }) do
        dl:AddText({ x + o[1], y + o[2] }, stamp, text);
    end
    dl:AddText({ x, y }, dim and COL_TEXT_DIM or COL_TEXT, text);
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

-- The width a piece of art takes when fitted to 'h' by its own aspect, or 0
-- when it is missing: none of it is square, and the buttons below sit in a row
-- that has to advance by what each one actually took.
local function icon_width(file, h)
    local tex, iw, ih = icon_texture(file);
    return (tex ~= nil) and (h * iw / ih) or 0;
end

--[[
* Art at (x, y) in window coordinates, fitted to 'h', with an InvisibleButton
* over it: the same widget ImageButton would be, without the version check its
* argument list has been through - the list moved between the ImGui versions
* Ashita has shipped.  Returns whether it was pressed, and the width it took.
*
* A warp popup lying over one of these eats the press: this row is submitted
* before the popup, and ImGui hands hover to the first item that claims it, so
* a panel over a toggle would otherwise flip it from underneath.  Read a frame
* late, which is harmless - the panel does not move while it is open.  Missing
* art draws nothing and takes no press.
--]]
local function icon_button(id, file, x, y, h, tint, tip)
    local w = icon_width(file, h);
    if (w == 0) then
        return false, 0;
    end
    local tex = icon_texture(file);
    imgui.SetCursorPos({ x, y });
    local sx, sy = imgui.GetCursorScreenPos();
    imgui.GetWindowDrawList():AddImage(tonumber(ffi.cast('uint32_t', tex)),
                                       { sx, sy }, { sx + w, sy + h },
                                       { 0, 0 }, { 1, 1 }, tint);
    local hit = imgui.InvisibleButton('##ubermap_' .. id, { w, h }) and not ui.warp_hot;
    if (tip ~= nil) then
        item_tip(tip);
    end
    -- Feeding search_hot keeps the map from panning or zooming underneath.
    ui.search_hot = ui.search_hot or imgui.IsItemHovered();
    return hit, w;
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
        if (ic.group == name and ic.time == ui.time) then
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

        -- Every widget on the row below ORs into search_hot, which is what
        -- keeps the map from panning or zooming underneath one.  Cleared here
        -- rather than assigned by whichever widget happens to be first.  Read a
        -- frame late by over_map above, which is fine: a click focuses a widget
        -- before the drag threshold is ever crossed.
        ui.search_hot = false;

        -- Past/present switch, first on the search row.  The art names the map
        -- you are on, not the one the press takes you to.  The switch is
        -- recorded and applied after the frame, because set_time clears the
        -- zoom that the rest of this frame still reads.
        local other = (ui.time == 'present') and 'past' or 'present';
        local time_hit, time_w = icon_button('time', ui.time .. '.png',
                                             SEARCH_MARGIN, SEARCH_MARGIN, row_h, COL_ICON,
                                             'Switch to a map of the ' .. other);
        if (time_hit) then
            ui.next_time = other;
        end
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
        ui.search_hot = ui.search_hot or imgui.IsItemActive() or imgui.IsItemHovered();

        -- Toggle icons, sharing the search box's line.
        local tx_at = search_x + SEARCH_W + TOGGLE_GAP;
        for _, file in ipairs(TOGGLES) do
            local hit, tw = icon_button('toggle_' .. file, file,
                                        tx_at, SEARCH_MARGIN, row_h,
                                        cfg.toggle[file] and COL_ICON_OFF or COL_ICON,
                                        (cfg.toggle[file] and 'Show ' or 'Hide ')
                                        .. (TOGGLE_NAME[file] or file));
            if (hit) then
                cfg.toggle[file] = not cfg.toggle[file];
                settings.save();
            end
            if (tw > 0) then
                tx_at = tx_at + tw + TOGGLE_GAP;
            end
        end

        -- Instant Warp, last on that line.  It uses the scroll instead of
        -- filtering the map, so it is drawn dim and takes no press while none
        -- is carried.
        local warp_hit, warp_w =
            icon_button('warpitem', WARP_ITEM_ICON, tx_at, SEARCH_MARGIN, row_h,
                        ui.has_warp and COL_ICON or COL_ICON_OFF,
                        ui.has_warp and 'Use Instant Warp scroll'
                                     or 'No Instant Warp scroll in inventory');
        if (warp_hit and ui.has_warp) then
            send_cmd(WARP_ITEM_CMD);
        end
        if (warp_w > 0) then
            tx_at = tx_at + warp_w + TOGGLE_GAP;
        end

        -- Warp Ring, after the scroll.  It takes two presses from cold - one to
        -- put the ring on, one to use it - so the icon is lit only on the step
        -- that warps, and the tooltip says which step it is on.  Equipping is
        -- queued rather than sent, so the map stays up for the second press.
        local left = RING_EQUIP_WAIT - (os.clock() - ui.ring_at);
        local ring_tip = ui.ring == 'use'   and 'Use Warp Ring'
                      or ui.ring == 'equip' and 'Equip Warp Ring to ring1'
                      or ui.ring == 'wait'  and ('Equipping Warp Ring (%ds)'):fmt(math.max(math.ceil(left), 0))
                      or 'No Warp Ring in inventory or Mog Wardrobe';
        if (icon_button('warpring', RING_ITEM_ICON, tx_at, SEARCH_MARGIN, row_h,
                        ui.ring == 'use' and COL_ICON or COL_ICON_OFF, ring_tip)) then
            if (ui.ring == 'use') then
                send_cmd(RING_ITEM_CMD);
            elseif (ui.ring == 'equip') then
                queue_cmd(('/equip ring1 "%s" %d'):fmt(RING_ITEM_NAME, ui.ring_bag or 0));
                ui.ring_at = os.clock();
                ui.ring    = 'wait';  -- held here until the next poll reads it back
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

        -- Multisend, pinned to the viewport's bottom-right corner.  Art only:
        -- with no icon there is nothing to press and the map keeps sending the
        -- way it always did.
        local mss_w = icon_width(MSS_ICON, row_h);
        if (icon_button('mss', MSS_ICON, view_w - SEARCH_MARGIN - mss_w,
                        view_h - SEARCH_MARGIN - row_h, row_h,
                        cfg.mss and COL_MSS_ON or COL_MSS_OFF,
                        cfg.mss and 'Multisend on: warps go to every character'
                                 or 'Multisend off: warps go to this character only')) then
            cfg.mss = not cfg.mss;
            settings.save();
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
                    -- ui.near_kind is false before the first poll and nil while
                    -- nothing is in reach; neither is a type, so both read as
                    -- out of reach.
                    local live = r.type == ui.near_kind;
                    -- The hover is drawn straight into the list rather than
                    -- coming off an ImGui item, for the same reason the click
                    -- below is tested by hand: the panel is one InvisibleButton.
                    if (live and mouse_x >= px and mouse_x <= px + w
                        and mouse_y >= ry and mouse_y < ry + POPUP_ROW) then
                        hot_row = r;
                        pdl:AddRectFilled({ px + ICON_BORDER, ry },
                                          { px + w - ICON_BORDER, ry + POPUP_ROW },
                                          COL_HOVER, 0, ImDrawCornerFlags_All);
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

--[[
* event: key
* desc : Escape puts the map away, the way it closes the game's own windows.
--]]
ashita.events.register('key', 'ubermap_key', function (e)
    if (e.wparam ~= VK_ESCAPE or not ui.is_open[1]) then
        return;
    end

    -- The event is the WNDPROC message, whose lparam carries the transition
    -- state: bit 31 set is the release, which nothing here has to answer.
    if (bit.band(e.lparam, bit.lshift(0x8000, 0x10)) ~= 0) then
        return;
    end

    -- Swallowed, or the client opens its own menu behind the map that just
    -- went away.
    ui.is_open[1] = false;
    e.blocked = true;
end);
