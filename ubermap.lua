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
* Mouse wheel zooms, left-drag pans, Escape closes.  A controller drives the
* whole thing too: the D-pad walks the markers, A opens what is under it and B
* backs out.  /ubermap or /um toggles the map by hand; /um edit turns on the
* point editor (ctrl+click to place).
--]]

addon.name    = 'UberMap';
addon.author  = 'Seekey';
addon.version = '1.3';
addon.desc    = 'Displays the server map, automatically on Home Point interaction.';

require('common');

local chat     = require('chat');
local settings = require('settings');
local imgui = require('imgui');
local ffi   = require('ffi');
local d3d   = require('d3d8');
local mm    = require('lib.mapmath');
local gpn   = require('lib.gpnav');
local fz    = require('lib.fuzzy');
local unlocks = require('lib.unlocks');
local guide   = require('lib.guide');

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
-- and Survival Guides carry their own name; the Unity Concord and the Abyssea
-- teleporters are people, so those are named one by one.  A server that renames
-- them is fixed here.
local WARP_NPC = T{
    { '^Home Point',        'home'    },
    { '^Survival Guide',    'guide'   },
    { '^Igsli$',            'unity'   },  -- Bastok Markets (E-11)
    { '^Urbiolaine$',       'unity'   },  -- Southern San d'Oria (G-10)
    { '^Teldro%-Kesdrodo$', 'unity'   },  -- Windurst Woods (J-10)
    { '^Yonolala$',         'unity'   },  -- Windurst Woods (J-10)
    { '^Joachim$',          'abyssea' },  -- Port Jeuno (H-8)
    { '^Erich$',            'abyssea' },  -- Port Bastok (K-11)
    { '^Fabricius$',        'abyssea' },  -- Port Windurst (L-6)
    { '^Gilburt$',          'abyssea' },  -- Port San d'Oria (I-8)
    { '^Fabien$',           'abyssea' },  -- Ru'Lude Gardens (H-10)
};

-- The NPC interaction packets, and the offset each carries the NPC's target
-- index at.  0x034 puts 32 bytes of menu parameters ahead of its index, so it
-- does not share the offset the other two use.  Which one a talk arrives as is
-- the server's choice, so all three are watched.
local NPC_EVENT = T{ [0x032] = 0x08, [0x033] = 0x08, [0x034] = 0x28 };

-- The teleport masks, in the same terms: packet 0x63 type 6 says which
-- destinations are registered, and lib/unlocks.lua reads it.  The server sends
-- it on zoning in, so the map has one from the first zone after it loads and
-- none before that.
local MASK_PACKET = 0x063;

-- How close one of those has to be to count as being stood at, in yalms, and
-- how often the map re-checks while it is open, in seconds.
local WARP_NPC_NEAR = 7;
-- Both pollers run on the errand's cadence: one source for the one fact, which
-- is how often reading a thousand-odd entity slots is worth it.
local NEAR_POLL     = guide.NEAR_POLL;

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
-- ESCAPE_RETRY comes from the errand for the same reason: one fact about how
-- fast the client will take a second Escape, read by both menu exits.
local ESCAPE_RETRY, ESCAPE_WAIT = guide.ESCAPE_RETRY, 2.0;

-- NPCs and mobs occupy the bottom of the entity array; players start at 0x400
-- and pets and trusts above them, so the walk stops before either.
local NPC_FIRST, NPC_LAST = 0x000, 0x3FF;

-- The EXP Guides hand an Instant Warp scroll to anyone who asks, so one is
-- asked whenever the bag has no scroll and a slot to put one in.  Two entities
-- carry the name - 'EXP Guide' and 'EXP Guide (S)' - so the pattern matches the
-- start of both.  They are spawned rather than placed, which puts them in the
-- dynamic block above the players instead of among the NPCs, so their scan runs
-- the whole array out rather than stopping at NPC_LAST.
local EXP_GUIDE_NAME = '^EXP Guide';

-- And the zones they stand in: Ru'Lude Gardens holds the (S), Lower Jeuno the
-- other.  Checked before the entity walk, which turns the errand's standing
-- cost outside these two into one integer compare instead of a scan of the
-- whole array -- and a character carrying a scroll is not the common case, so
-- the bag gate alone was leaving that scan running most of the time.  A server
-- that puts its guides elsewhere adds the zone here, the same way it fixes the
-- name above.
local EXP_GUIDE_ZONES = { [243] = true, [245] = true };
local ENT_LAST       = 0x8FF;

local MAX_ZOOM  = 2.0;  -- two screen pixels per source map pixel
local ZOOM_STEP = 1.15; -- per wheel notch

-- ImGui packs colours as ABGR, not ARGB.  The _DIM outline is the same black
-- at COL_ICON_OFF's alpha, so a dimmed icon's border fades with its art.
local COL_OUTLINE     = 0xFF000000;
local COL_OUTLINE_DIM = 0x40000000;

-- Map text, the stamp behind it, and the fill under a warp row the cursor is
-- on.  The _DIM pair is the same colours at DIM_ALPHA, which is what everything
-- outside the focused group draws at; the stamp fades with the glyph or it
-- outlives the text it was behind.
--
-- Packed here as the defaults the pickers start from, and repacked by
-- repack_cols below whenever one of them is moved.  Not constants, for that
-- reason, but everything downstream reads them as though they were: one pack
-- per drag rather than one per string per frame.
local COL_TEXT      = 0xFF000000;  -- black
local COL_TEXT_DIM  = 0x40000000;
local COL_STAMP     = 0x80FFFFFF;  -- white, half alpha
local COL_STAMP_DIM = 0x20FFFFFF;
local COL_HOVER     = 0x2EFFFFFF;  -- white, a fifth of an alpha
-- The plate under a string, drawn behind the stamp.  Fully transparent by
-- default, so nothing about the map changes until the picker is moved: the
-- stamp is what makes the text readable, and a plate is the heavier answer for
-- someone who wants one anyway.
local COL_BG        = 0x00000000;  -- black, no alpha at all
local COL_BG_DIM    = 0x00000000;
local DIM_ALPHA     = 0.25;

-- Screen pixels the plate is grown by on each side, so the glyphs are not flush
-- against its edge.  The stamp reaches one pixel out, which the padding covers.
local BG_PAD        = 2;

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

-- What the config panel's scale boxes take, as whole percents of the sizes
-- above, and the steps their arrows move in.  One table rather than a constant
-- apiece, for the reason FONT_PX below is one: the chunk is near Lua's 200-local
-- ceiling, where loose constants cost more than the indirection.
local SCALE = {
    min = 25, max = 400, step = 5, fast = 25,
    -- cfg key and row name, in the order they stack.  The clamp on load, the
    -- boxes ImGui edits and the panel all walk this, so a box cannot drift from
    -- the setting it writes.
    rows = { { 'scale_point',   'Points'   },
             { 'scale_nation',  'Nations'  },
             { 'scale_tool',    'Tools'    },
             { 'scale_searchw', 'Search W' } },
};
local COL_ICON     = 0xFFFFFFFF;  -- white: tint that leaves the art untouched
local COL_SELECT   = 0xFF00FFFF;  -- yellow: ring around the point being edited

-- Labels sit above the icon at the size the Size box names, so they stay
-- readable at every zoom instead of shrinking away with the art.
local LABEL_GAP   = 1;  -- screen pixels between the label and the icon

-- Two detail tiers, swapping at ZOOM_POINTS: below it the world overview (the
-- groups declared in lib/points.lua), at or above it the zone points that come
-- from the same file and the editor.  One tier replaces the other, so the
-- overview never sits underneath the points.
local ZOOM_POINTS = 1.0;

-- Toolbar and editor panel, pinned in from the viewport corner by UI_MARGIN
-- screen pixels.
local UI_MARGIN = 20;
local FIELD_W   = 600;  -- search and editor text field width, screen pixels
local FIELD_MAX = 256;  -- search and editor text field length, bytes
local EDIT_ROW  = 28;   -- editor panel row pitch, screen pixels

-- Toolbar rows are drawn this many times the default frame height.  The height
-- comes from frame padding rather than a font scale: ImGui has one baked font
-- atlas, so scaling the font up magnifies its bitmap and goes blurry.
local ROW_H_MULT = 2.0;

-- The search box is shorter than the icons it shares the row with, and centred
-- against them.  Its own multiplier rather than ROW_H_MULT: the icons want the
-- height, a one-line text field does not.
local SEARCH_H_MULT = 1.5;

-- Layer toggles, drawn on the toolbar row.  Clicking one dims its icon;
-- the state is kept per file name in cfg.toggle (nil = lit).
local TOGGLES      = T{ 'Crystal.png', 'Guide.png', 'Unity.png', 'Abyssea.png' };
-- What each toggle is called on its tooltip, keyed the way cfg.toggle is.
local TOGGLE_NAME  = T{ ['Crystal.png'] = 'Home Points',
                        ['Guide.png']   = 'Survival Guides',
                        ['Unity.png']   = 'Unity Concords',
                        ['Abyssea.png']     = 'Abyssea Warps' };
local TOGGLE_GAP   = 6;   -- screen pixels between toggles

-- What the Size box will take, in screen pixels, and what it means by "leave it
-- alone", plus the faces the pulldown beside it lists.
--
-- A face costs more than a size does.  ImGui's font atlas is shared with every
-- other addon and outlives '/addon reload', and rebuilding it while draw lists
-- are still pending render is an access violation -- which is what the map's
-- first font picker did, and why the one here bakes every face it will ever
-- need on the load event and never touches the atlas again.  From then on
-- picking a face is a lookup, and a size is still only a scale on it.
--
-- Faces are named by their file name in dir, which is what the pulldown shows;
-- '' is ImGui's own font, left alone, and is what a map that has never been
-- near the pulldown draws with.
--
-- One table rather than a name apiece: this file is close enough to Lua's
-- 200-local ceiling for a chunk that loose constants cost more than the
-- indirection does.
local FONT_PX = {
    min = 8, max = 48, own = 0,
    bake  = 20.0,                  -- pixel size every face is baked at
    dir   = 'C:\\Windows\\Fonts\\',
    list  = T{ '', 'Arial', 'Calibri', 'Consola', 'Georgia',
               'Segoeui', 'Tahoma', 'Times', 'Verdana' },
    -- ImGui's own font is compiled into it rather than loaded from a file, so
    -- it has no file name to be listed under and is '' in the list.  This is
    -- what the pulldown shows in its place, so the row reads as a font rather
    -- than as a gap.
    own_name = 'ProggyClean',
    atlas = { },                   -- name -> baked font, or false if it failed
};
local COL_ICON_OFF = 0x40FFFFFF;  -- 25% opacity, i.e. 75% transparent

-- Warp type -> the toggle that lists it, so dimming a toggle drops those rows
-- from the popup.  A type no toggle names never shows.
local WARP_ICON = T{ home = 'Crystal.png', guide = 'Guide.png', unity = 'Unity.png',
                     abyssea = 'Abyssea.png' };

-- The Instant Warp scroll, drawn on the toggles' line after them.  Not a layer:
-- it warps out of the bag rather than from an NPC, so it filters nothing and is
-- lit only while a scroll is carried.
local WARP_ITEM_ICON = 'Warp.png';
local WARP_ITEM_ID   = 4181;
local WARP_ITEM_CMD  = '/item "Instant Warp" <me>';
-- Inventory container 0 - the bag, which is what /item reads from.  Its slot
-- count is read off the container rather than fixed here, since a bag can be
-- smaller than the eighty slots it tops out at.  Slot 0 is the gil slot rather
-- than an item, so the walk starts at 1.
local BAG = 0;

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
local POPUP_PAD      = 8;   -- screen pixels of margin on either side of the panel
local POPUP_ROW      = 24;  -- row pitch, screen pixels
local POPUP_ICON     = 24;  -- the box a type icon is fitted into
local POPUP_GAP      = 6;   -- screen pixels between the marker and the panel
local COL_POPUP_BG   = 0xE0101010;  -- near black, a little of the map showing through
local COL_POPUP_TEXT = 0xFFFFFFFF;  -- the panel has its own ground, so white reads
local COL_POPUP_OFF  = 0x60FFFFFF;  -- a row whose kind of NPC is not in reach
-- Light green, { 0.7, 1.0, 0.7, 1.0 }: a warp row already on the favorites
-- list.  On the map's warp panel only -- the favorites list itself is nothing
-- but favorites, and colouring every row of it green says nothing.
local COL_POPUP_FAV  = 0xFFB3FFB3;
-- Light red, { 1.0, 0.7, 0.7, 1.0 }, held apart from the grey above: not being
-- in front of the right NPC is a thing the player can walk off and fix, while a
-- destination they have never stood at is not, so the two do not read the same.
-- It also outranks the green: a favorite that will not travel is worth knowing
-- about whether or not it was saved.  Text only - the icon still says which kind
-- of NPC the row travels from, which is worth reading either way.
local COL_POPUP_LOCK = 0xFFB3B3FF;
-- What a red row says when the cursor stops on it.
local LOCK_TIP = T{
    home  = 'Not registered - interact with this Home Point once to unlock it',
    guide = 'Not registered - interact with this Survival Guide once to unlock it',
};

-- Multisend, in the viewport's bottom-right corner.  While it is lit every
-- command the map sends goes out through Thorny's Multisend instead of straight
-- to the client, so all the logged-in characters take the warp together.  Off
-- by default: it is the surprising thing to do, so it has to be asked for.
local MSS_ICON    = 'multicast.png';
local MSS_PREFIX  = '/mss ';
local COL_MSS_ON  = 0x80FFFFFF;  -- 50% opacity: it sits over the map
local COL_MSS_OFF = 0x40FFFFFF;  -- half that again, i.e. dimmed off

-- Favorites, in the viewport's bottom-left corner, mirroring Multisend.  The
-- heart opens a panel of warp rows saved out of the zone popups, in the order
-- they were put in and dragged to; clicking one sends its warp the same way
-- the popup row it came from does.
local FAV_ICON     = 'heart.png';
local FAV_EMPTY    = 'Right-click a warp to add it here';
-- What stands in its place while the list is narrowed to the NPC in reach and
-- nothing saved can be sent from it: the list is not empty, this warp's share
-- of it is, and the instructions would read as though nothing were saved.
local FAV_NONE     = 'No favorites for this warp';

-- The favorites widget: the same saved list, drawn as a small window of its own
-- and driven from the gamepad.  It comes up only where it can be used -- stood
-- at a Home Point, Survival Guide, Unity Concord or Abyssea teleporter --
-- because it swallows the buttons it reads, and the D-pad belongs to the
-- game's own menus everywhere else.  On by default, and turned off from the
-- '/um config' panel: the buttons it takes are ones the client has nothing to
-- do with while a warp menu is up.  It reads five of the seven below -- up,
-- down, A, B and Y, which swaps it for the full map -- and leaves left and
-- right to the client.
--
-- The map reads all seven.  It takes them only while it is on screen, which is
-- a place the player put it rather than one they walked into, so unlike the
-- widget it needs no toggle to justify swallowing them: the map is what a
-- press is for while it is up.  Y is the pad's right-click: on a warp row it
-- opens the same favorites menu the mouse's second button does.
--
-- Keyed by the XInput button index Ashita's xinput_button event delivers, so
-- one lookup answers both questions the handler has: whether the button is
-- read at all, and which of the seven it is.
local GP = {
    [0]  = 'up',
    [1]  = 'down',
    [2]  = 'left',
    [3]  = 'right',
    [12] = 'a',
    [13] = 'b',
    [15] = 'y',
};

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
    -- The three colour pickers, as the { r, g, b, a } floats ImGui edits in
    -- place.  Their defaults are the packed constants above, unpacked: a file
    -- that has never been near a picker draws exactly what it always did.
    col_text    = T{ 0.0, 0.0, 0.0, 1.0 },   -- map text
    col_outline = T{ 1.0, 1.0, 1.0, 0.5 },   -- the outline behind it
    col_hover   = T{ 1.0, 1.0, 1.0, 0.18 },  -- fill under the row the cursor is on
    col_bg      = T{ 0.0, 0.0, 0.0, 0.0 },   -- the plate behind the text, off
    -- Saved warp rows, in the order they are listed in.  Empty here and seeded
    -- in fill_defaults instead: settings.load merges these defaults into the
    -- saved file key by key and recurses into tables, array indices included,
    -- so rows sitting here would grow back into any list they had been deleted
    -- from -- and it saves the merged file straight back to disk, so they would
    -- stay.  See the seed in fill_defaults for the marker that tells a new file
    -- from an emptied one.
    favs   = T{ },
    -- Set the first time a character's file is filled in, and never read for
    -- anything else.  Only a flag written into the file can say whether an
    -- empty favorites list is one that has never been used or one the player
    -- emptied on purpose; both look the same on disk.
    seeded = false,
    widget = true,   -- the gamepad favorites widget is on
    -- The EXP Guide errand.  On by default, the way the widget is: it acts only
    -- on the walk past a guide and can be watched happening.  A toggle all the
    -- same, because it sends a packet and a keystroke with no click behind it.
    guide  = true,
    -- What the map's text is drawn at, in screen pixels.  Zero means the size
    -- ImGui's own font already comes out at, which is what the box shows until
    -- it is touched: a settings file that has never been near it draws exactly
    -- what the map always did, on whatever font Ashita is configured with.
    font_px = FONT_PX.own,
    -- The face it is drawn in, named the way FONT_PX.list names them.  Empty is
    -- ImGui's own font, which is what the map always drew with.
    font    = '',
    -- What the map's art is drawn at, as whole percents of the sizes the addon
    -- has always used: 100 is what it drew before these boxes existed, and what
    -- a settings file that has never been near them carries.  Separate knobs
    -- because the things they size are read at different distances.
    scale_point   = 100,  -- zone point markers, i.e. every icon carrying a size
    scale_nation  = 100,  -- the nation art, which carries none
    scale_tool    = 100,  -- toolbar row height, search box included
    scale_searchw = 100,  -- search box width
    -- The search box takes the keyboard the moment the map opens.  Off by
    -- default: the box swallows every key while it holds focus, movement
    -- included, so it is only worth opening the map into if you came to look
    -- something up.
    focus  = false,
    -- Uberwarp narrates every step of a warp it runs into the log, errors
    -- included.  The map is what asked for the warp, so the running commentary
    -- is noise by the time it arrives; the config panel's Hide Uberwarp Chat
    -- box turns it back on when a warp is misbehaving and the reason matters.
    quiet  = true,
    -- Whether walking up to a warp NPC -- Home Point, Survival Guide, Unity
    -- Concord or Abyssea teleporter -- puts the map on screen by itself.  On
    -- by default: that is what the map has always done, and the reason it
    -- exists.  Off leaves '/um' and Y at the favorites widget as the ways in.
    autoopen = true,
};
-- Loaded from a copy of the defaults, because the library hands its own default
-- table back for a key the file has no entry for: without the copy the first
-- dimmed toggle would edit the table above.  cfg is then written through
-- directly, and settings.save() called as each change is made rather than at
-- unload, so nothing is lost if the game goes down first.
local cfg = settings.load(default_settings:copy(true));

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
* Re-packs the seven words the map draws text, plates and hovers with from the
* four pickers.  Called once at load and once on the frame a picker moves,
* rather than per string per frame: the colours only move when a picker does.
--]]
local function repack_cols()
    COL_TEXT      = pack_col(cfg.col_text);
    COL_TEXT_DIM  = pack_col(cfg.col_text, DIM_ALPHA);
    COL_STAMP     = pack_col(cfg.col_outline);
    COL_STAMP_DIM = pack_col(cfg.col_outline, DIM_ALPHA);
    COL_HOVER     = pack_col(cfg.col_hover);
    COL_BG        = pack_col(cfg.col_bg);
    COL_BG_DIM    = pack_col(cfg.col_bg, DIM_ALPHA);
end

--[[
* Bakes every face the pulldown lists into ImGui's font atlas.
*
* Called once, from the load event, and never again: the atlas is shared with
* every other addon, and adding to it from d3d_present mutates it while draw
* lists are pending render, which is an access violation rather than a slow
* frame.  Baking the whole list up front is what lets the pulldown switch faces
* mid-frame without ever touching the atlas again.
*
* A face that will not load -- a Windows without that file -- is remembered as
* false and simply never applies, leaving the map on ImGui's own font.
--]]
function FONT_PX.bake_all()
    for _, name in ipairs(FONT_PX.list) do
        if (name ~= '') then
            local ok, font = pcall(imgui.AddFontFromFileTTF,
                                   FONT_PX.dir .. name:lower() .. '.ttf',
                                   FONT_PX.bake);
            FONT_PX.atlas[name] = (ok and font) or false;
        end
    end
end

--[[
* The baked face the map draws with, or nil for ImGui's own -- which covers the
* default, a name whose file would not load, and a frame before bake_all has
* run.
--]]
function FONT_PX.face()
    return FONT_PX.atlas[cfg.font] or nil;
end

-- A settings file written before a key existed is handed back as it was saved,
-- without the new default filled in, so a character who used the map before
-- favorites would otherwise index a nil table.
local function fill_defaults()
    cfg.toggle = cfg.toggle or T{};
    cfg.favs   = cfg.favs   or T{};
    -- Six rows to start with, one per kind of warp NPC, so the widget has
    -- something to show at the first one a new character walks up to.  Seeded
    -- here rather than from default_settings, which merge would push back into
    -- a list they had been deleted from on every load; done once and
    -- remembered, so deleting them sticks.  Saved on the spot, because the
    -- merge's own save has already been and gone by the time this runs and
    -- nothing else here is guaranteed to write the file again.
    if (cfg.seeded ~= true) then
        cfg.seeded = true;
        if (#cfg.favs == 0) then
            -- Plain tables, the shape fav_toggle writes: a saved row is what
            -- these have to look like once they are on the list.
            local seeds = {
                { key = 'Rolanberry Fields',   type = 'unity',   label = 'Unity Concord' },
                { key = "Ru'Lude Gardens",     type = 'guide',   label = 'Survival Guide' },
                { key = 'Lower Jeuno',         type = 'home',    label = 'Home Point #2 (M)' },
                { key = 'Konschtat Highlands', type = 'abyssea', label = 'Abyssea - Konschtat' },
                { key = 'La Theine Plateau',   type = 'abyssea', label = 'Abyssea - La Theine' },
                { key = 'Tahrongi Canyon',     type = 'abyssea', label = 'Abyssea - Tahrongi' },
            };
            for _, f in ipairs(seeds) do
                table.insert(cfg.favs, f);
            end
        end
        settings.save();
    end
    -- A settings file written before the pickers existed carries no colours,
    -- and a picker handed a nil table would index it on the first frame.  The
    -- shape is checked rather than only the nil, for the same reason cfg.font is
    -- checked against the list below: the file is hand-editable, and a row of
    -- three floats would throw out of pack_col during login, from inside the
    -- settings callback.  Copied rather than shared, so editing one does not
    -- write the defaults above.
    local function fill_col(name)
        local c = cfg[name];
        if (type(c) == 'table' and type(c[1]) == 'number'
            and type(c[2]) == 'number' and type(c[3]) == 'number'
            and type(c[4]) == 'number') then
            return c;
        end
        return default_settings[name]:copy(true);
    end
    cfg.col_text    = fill_col('col_text');
    cfg.col_outline = fill_col('col_outline');
    cfg.col_hover   = fill_col('col_hover');
    cfg.col_bg      = fill_col('col_bg');
    -- Zero passes through the clamp untouched: it is the stand-in for ImGui's
    -- own size, which is not known until there is a frame to ask.
    cfg.font_px = (cfg.font_px == nil or cfg.font_px == FONT_PX.own)
        and FONT_PX.own
        or math.min(math.max(cfg.font_px, FONT_PX.min), FONT_PX.max);
    -- Checked against the list rather than taken as written: the name goes on
    -- the end of a Windows font path, and a hand-edited settings file is the
    -- one place a name the pulldown could never produce can come from.
    if (not FONT_PX.list:contains(cfg.font or '')) then
        cfg.font = '';
    end
    -- Clamped rather than trusted: the boxes take a typed number and the file
    -- is hand-editable.  A zero is a marker with no pixels in it; a missing key
    -- multiplies out to a nil size on the first frame.
    for _, row in ipairs(SCALE.rows) do
        cfg[row[1]] = math.min(math.max(math.floor(tonumber(cfg[row[1]]) or 100),
                                        SCALE.min), SCALE.max);
    end
    repack_cols();
    -- A settings file written before the errand existed has no entry for it,
    -- and a nil there is not the same as off: the default is on.  Written back
    -- as a real boolean so the next save records the answer either way.
    if (cfg.guide == nil) then
        cfg.guide = true;
    end
    if (cfg.quiet == nil) then
        cfg.quiet = false;
    end
    -- Same as the errand above: a file written before the toggle existed has no
    -- entry, and nil there is not off -- opening on the NPC is the default.
    if (cfg.autoopen == nil) then
        cfg.autoopen = true;
    end
    -- The map used to write the Campaign zones '(S)' and rewrite them to '[S]'
    -- on the way out; it names them '[S]' throughout now.  A favorite saved
    -- under the old name still travels, but nothing else about it looks up any
    -- more, so it is renamed in place the first time it is read back.
    for _, f in ipairs(cfg.favs) do
        f.key  = f.key  and (f.key:gsub('%(S%)$', '[S]'))  or f.key;
        f.zone = f.zone and (f.zone:gsub('%(S%)$', '[S]')) or f.zone;
    end
end
fill_defaults();

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
    search      = { '', },   -- search box text, boxed the way ImGui wants it
    search_at   = '',        -- search text the view was last framed for
    focus_next  = false,     -- hand the search box the keyboard on the next frame
    search_blur = false,     -- take it back off the search box on the next frame
    hot         = false,     -- cursor was over a widget, not the map
    config      = false,     -- the config panel is on screen
    cfg_dirty   = false,     -- a picker on the config strip has been moved
    cfg_typing  = false,     -- a numeric box held the keyboard on the last frame
    dragging    = false,
    drag_x      = 0,
    drag_y      = 0,
    press       = nil,       -- marker the left button went down on
    near_kind   = false,     -- warp type last seen in reach; false until checked
    -- The EXP Guide errand's whole state, shaped and stepped by lib/guide.lua.
    -- Kept out here rather than inside that file so the map can read
    -- errand.has_warp for the Instant Warp icon it draws.
    errand      = guide.state(),
    masks       = nil,       -- teleport mask block off the last 0x63 type 6
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
    -- The same for the right-click menu, which is drawn after everything it
    -- can land on: whatever is underneath reads this a frame late to know the
    -- cursor is really on the menu rather than on itself.
    ctx_hot     = false,
    -- The popup's top-left, stashed by the draw that worked it out, so a Y
    -- press can hang the favorites menu off the lit row without repeating the
    -- clamping that decided where the panel went.
    warp_px     = 0,
    warp_py     = 0,
    favs_open   = false,     -- favorites panel is up
    -- The gamepad widget.  fw_on is what the xinput handler reads to decide
    -- whether a button is its to take, and is written by the draw each frame,
    -- so the buttons are taken exactly while the list they drive is on screen.
    fw_on       = false,
    fw_shown    = false,     -- it was up last frame, i.e. this is not its first
    fw_sel      = 1,         -- the row the D-pad has landed on, 1-based
    fw_hide     = false,     -- B put it away until the player walks off the NPC
    -- The widget's right-click menu was up last frame.  Read the same way as
    -- ctx_hot: the popup is submitted after the list it hangs off, so the rows
    -- underneath learn it is there a frame late.
    fw_ctx      = false,
    -- The widget has the arrow keys.  Asked for with F while it is up and given
    -- back with Escape, because unlike the pad's D-pad the arrows are the
    -- player's own movement keys: swallowing them the moment a warp NPC came
    -- into reach would take walking away with them.
    fw_key      = false,
    pad_held    = {},        -- buttons whose press was taken, by index
    -- The same for the keyboard, by DirectInput scan code.  It is what keeps a
    -- key held down out of the game for as long as it is held: the buffered
    -- event says a key went down, but the camera and the movement are read off
    -- the immediate state buffer every frame after that.
    kb_held     = {},
    -- Gamepad map navigation.  The selection is the icon itself rather than a
    -- slot in a list, because the list it walks is built fresh out of whatever
    -- is on screen at each press; gp_from is the overview marker A zoomed in
    -- from, so B can put the view back with that one lit.  Both are nil until
    -- the map works out where the selection starts, which it only does while
    -- gp_active: the pad is what is working the map, rather than merely being
    -- plugged in behind a hand that is on the mouse.  A press the map or the
    -- widget takes sets it, cursor movement over either clears it, and it
    -- outlives the map closing -- a pad that was driving one still is when the
    -- next opens.  Off until then, so a player who never touches one is never
    -- shown a highlight arguing with their cursor.
    gp_icon     = nil,
    gp_from     = nil,
    gp_active   = false,
    -- Where the cursor was on the frame before, and whether it has moved since,
    -- worked out once a frame so the map and the widget read the same answer
    -- whichever of them draws first.
    ptr_x       = nil,
    ptr_y       = nil,
    ptr_moved   = false,
    -- The search box held the caret on the last frame.  The arrows, Enter and
    -- Escape are that box's own editing keys while it does, and ImGui is given
    -- them whether or not the client is blocked from them, so the key handler
    -- has to keep its hands off.  Written by the draw and cleared at the head
    -- of the frame, the same way cfg_typing is.
    kb_typing   = false,
    gp_row      = nil,       -- the warp list row lit, 1-based, nil for none
    gp_q        = {},        -- actions waiting for a frame to act on them
    gp_ready    = false,     -- the map drew last frame, so the queue is drained
    -- The favorite being dragged, as { i, live, moved } of the row that was
    -- pressed: i follows the cursor as the list reorders under it, live is
    -- whether it can travel, and moved tells a reorder from a plain click.
    fav_drag    = nil,
    -- The right-click menu, as { x, y, key, row } of the warp row it was opened
    -- on, or nil while it is shut.  The row is carried rather than looked up
    -- again, since the panel it came from may be gone by the time it is picked.
    ctx         = nil,
    focus       = nil,       -- group name to keep lit; everything else dims
    edit        = false,     -- point editor on
    sel         = nil,       -- the user point being edited
    moving      = false,     -- ctrl-drag in progress
    dirty       = false,     -- an edit is waiting to be written to lib/points.lua
    edit_name   = { '', },
    edit_group  = { '', },
    font_px     = { 0, },    -- the Size box, which edits cfg.font_px
    -- The scale boxes, keyed by the cfg key each edits, in InputInt's shape.
    -- Filled from SCALE.rows below rather than written out.
    scale       = T{ },
    -- What imgui.SetWindowFontScale is handed to draw the map's text at
    -- cfg.font_px, resolved once at the top of a frame rather than per label.
    font_scale  = 1.0,
};
ui.font_px[1] = cfg.font_px;
for _, row in ipairs(SCALE.rows) do
    ui.scale[row[1]] = { cfg[row[1]], };
end

--[[
* The screen pixels an icon is drawn at, through whichever marker scale owns it.
* Points and nations are told apart by ic.size, the way lib/points.lua has always
* split them: zone points carry 'size = POINT_SIZE', city icons carry none.
--]]
function SCALE.px(ic)
    return ic.size and (ic.size * cfg.scale_point / 100)
                    or (ICON_SIZE * cfg.scale_nation / 100);
end

-- Logging in, or switching characters, hands back that character's own file.
settings.register('settings', 'settings_update', function (s)
    cfg = s;
    fill_defaults();
    ui.font_px[1] = cfg.font_px;
    -- Mutated rather than replaced: ImGui edits the tables ui.scale already
    -- holds, so a fresh one here would leave the panel writing into an orphan.
    for _, row in ipairs(SCALE.rows) do
        ui.scale[row[1]][1] = cfg[row[1]];
    end
end);

local function map_size()
    local m = TIMES[ui.time];
    return m.w, m.h;
end

--[[
* Tooltip for the item just submitted.  Vetoed by a warp popup or the
* right-click menu lying over that item for the same reason its press is: the
* row is submitted before either, so ImGui hands it the hover of a cursor that
* is really over the thing on top.
--]]
local function item_tip(text)
    -- And vetoed by the pad or the keys driving, for the same reason the
    -- cursor's hover art is: a tooltip standing under a cursor nobody is
    -- holding is the mouse answering for a press it is not going to get.
    if (ui.gp_active) then
        return;
    end
    if (imgui.IsItemHovered() and not ui.warp_hot and not ui.ctx_hot) then
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
* True while FFXI is the window the OS is sending keys to.
*
* keybd_event is process-global and window-agnostic: it goes wherever the focus
* is, not to the game.  So an Escape sent while the player has alt-tabbed away
* lands in their browser instead - closing a dialog, cancelling a form, leaving
* a fullscreen video.  Every press the map itself sends follows a click on the
* map and so cannot happen alt-tabbed, but the guide errand presses with no
* click behind it at all, on a walk the player may well be watching from
* another window.
*
* Fails open: a build where these two cannot be read behaves as it always did
* rather than losing Escape entirely.
--]]
local function game_focused()
    local ok, same = pcall(function ()
        local fg   = ffi.cast('uintptr_t', AshitaCore:GetForegroundWindow());
        local game = ffi.cast('uintptr_t',
                              AshitaCore:GetProperties():GetFinalFantasyHwnd());
        return tonumber(fg) == tonumber(game);
    end);
    return (not ok) or same;
end

--[[
* Press Escape, to be released ESCAPE_HOLD frames later.  Refuses to start a
* second press while one is still held: a repeat would keep resetting the frame
* count, the release would never fire, and Escape would be left down for the
* whole system.  Refuses while the game is not the focused window for the same
* reason it refuses a double press: the key would land somewhere it was never
* meant for.
--]]
local function press_escape(now)
    if (user32 == nil or ui.esc_frames > 0 or not game_focused()) then
        return;
    end
    user32.keybd_event(VK_ESCAPE, ESCAPE_SCAN, 0, 0);
    ui.esc_frames = ESCAPE_HOLD;
    ui.esc_at     = now;
end

--[[
* Let Escape back up.  Safe to call when nothing is held, so a caller that is
* only making sure the key is not down does not have to check first.
--]]
local function release_escape()
    if (user32 == nil or ui.esc_frames == 0) then
        return;
    end
    user32.keybd_event(VK_ESCAPE, ESCAPE_SCAN, KEYEVENTF_KEYUP, 0);
    ui.esc_frames = 0;
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
    ui.ctx        = nil;
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
* The server id and target index of the nearest EXP Guide within WARP_NPC_NEAR,
* or nil when none is in reach.  Nearest for the same reason the warp NPCs are:
* the two guides can both be inside the radius, and the one being stood at is
* the one meant.
*
* Walks the whole array rather than stopping at NPC_LAST, since a guide is a
* spawned entity and sits above the players.  Two gates stand in front of that
* walk: the zone, checked here, and the bag, checked by lib/guide.lua before it
* calls at all.  The zone is the one that matters -- carrying a scroll is the
* state most players are in least often, so the bag gate alone left the scan
* running nearly everywhere.
--]]
local function near_exp_guide()
    local party = AshitaCore:GetMemoryManager():GetParty();
    if (party == nil or not EXP_GUIDE_ZONES[party:GetMemberZone(0)]) then
        return nil;
    end
    local ent = AshitaCore:GetMemoryManager():GetEntity();
    if (ent == nil) then
        return nil;
    end
    local id, index, near = nil, nil, WARP_NPC_NEAR * WARP_NPC_NEAR;
    for i = NPC_FIRST, ENT_LAST do
        -- Squared yalms against a squared radius, and the rendered bit, for the
        -- same reasons near_warp_type reads them that way.
        local d = ent:GetDistance(i);
        if (d < near and bit.band(ent:GetRenderFlags0(i), 0x200) == 0x200
            and (ent:GetName(i) or ''):match(EXP_GUIDE_NAME)) then
            id, index, near = ent:GetServerId(i), i, d;
        end
    end
    return id, index;
end

--[[
* Ask an NPC for whatever it hands out, which is the packet the client sends
* when its target is pressed: the entity's server id, its index, and a category
* of zero for a plain talk.  Seven dwords, the rest of them zero - no menu
* parameter and no position.
--]]
local function poke_npc(id, index)
    local p = { 0x1A, 0x07, 0, 0 };
    for i = 0, 3 do
        p[#p + 1] = bit.band(bit.rshift(id, i * 8), 0xFF);
    end
    p[#p + 1] = bit.band(index, 0xFF);
    p[#p + 1] = bit.band(bit.rshift(index, 8), 0xFF);
    -- Category, parameter and the three position floats, all left at zero.
    for _ = 1, 18 do
        p[#p + 1] = 0;
    end
    AshitaCore:GetPacketManager():AddOutgoingPacket(0x01A, p);
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
* Both answers the bag holds, in one walk of it: whether an Instant Warp scroll
* is carried, and whether every slot is taken.  Walked together because they
* read the same slots, and this runs whether the map is up or not.  The scroll
* is matched by item id rather than by name: the resource name a server gives an
* item need not be the string a name lookup wants.  The count comes from the
* container rather than fixed, since a bag can be smaller than the eighty slots
* it tops out at.
*
* pcall'd whole because the inventory is not readable while zoning.  A read that
* failed is reported as carried and full - the one pair of answers that asks a
* guide for nothing - and the third return says which it was, because that same
* pair read as an arrival would start the errand pressing Escape at a talk that
* was never opened.  Zoning is when the read fails and when a stray press is
* worst, so the two have to be told apart.
--]]
local function bag_state()
    local ok, has, full = pcall(function()
        local inv = AshitaCore:GetMemoryManager():GetInventory();
        local carried, free = false, false;
        for i = 1, inv:GetContainerCountMax(BAG) do
            local it = inv:GetContainerItem(BAG, i);
            if (it == nil or it.Id == 0) then
                free = true;
            elseif (it.Id == WARP_ITEM_ID and it.Count > 0) then
                carried = true;
            end
        end
        return carried, not free;
    end);
    if (not ok) then
        return true, true, false;
    end
    return has, full, true;
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
    ui.ring_bag = ring_bag();
    ui.ring     = ring_step(ui.ring_bag ~= nil, ring_worn(),
                            now - ui.ring_at < RING_EQUIP_WAIT);
    local kind = near_warp_type();
    if (kind ~= ui.near_kind) then
        ui.near_kind = kind;
        filter_to(kind);
        -- The list a drag was picked up out of is not the list it would be
        -- dropped into, so the row is let go where it lies rather than landing
        -- somewhere the hand never carried it.
        ui.fav_drag = nil;
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
* True while a label answers the search box, exactly or near enough: see
* lib/fuzzy.lua for how far out a query of a given length is allowed to be, so
* a misspelling still lands on what was meant.
*
* Spelling is only forgiven once nothing on the map answers the query as typed,
* so a query that names something real is taken at its word rather than
* dragging in everything an edit away from it.
*
* Both answers are remembered until the text in the box changes, since the
* distance is a table walk rather than a find, and the group pass below asks
* about the same labels over and over, every frame.
--]]
local search_cache = { q = nil, fuzzy = false, hits = { } };

-- The box's text folded to lower case, held for as long as the text is
-- unchanged.  search_hit runs for every marker of every frame, and folding it
-- there allocated a string per marker per frame for an answer that only ever
-- changes on a keystroke.
local search_raw, search_low = nil, '';
local function search_query()
    if (search_raw ~= ui.search[1]) then
        search_raw = ui.search[1];
        search_low = search_raw:lower();
    end
    return search_low;
end

-- Points the cache at q and answers whether spelling is being forgiven for it.
local function search_prep(q)
    if (search_cache.q ~= q) then
        local fuzzy = true;
        for _, ic in ipairs(ICONS) do
            if ((ic.label or ''):lower():find(q, 1, true) ~= nil) then
                fuzzy = false;
                break;
            end
        end
        search_cache = { q = q, fuzzy = fuzzy, hits = { } };
    end
    return search_cache.fuzzy;
end

local function label_hit(label, q)
    local fuzzy = search_prep(q);
    local hit = search_cache.hits[label];
    if (hit == nil) then
        hit = fz.match(q, label:lower(), fuzzy);
        search_cache.hits[label] = hit;
    end
    return hit;
end

--[[
* True while a marker answers the search box.  An empty box matches everything,
* so the map is untouched until something is typed.
*
* A group marker answers for the zones it stands for as well as for its own
* name.  The overview is all that is drawn zoomed out, so a search for a zone
* has to leave the region holding it lit or there would be nothing left to
* click towards.
*
* ponytail: walks every icon per group marker, the same as group_warps_lit and
* on the same thirty-odd markers an overview frame draws.  Index group ->
* labels at load if the point list ever grows an order of magnitude.
--]]
local function search_hit(ic)
    local q = search_query();
    if (q == '') then
        return true;
    end
    if (label_hit(ic.label or '', q)) then
        return true;
    end
    if (OVERVIEW[ic.group]) then
        for _, p in ipairs(ICONS) do
            if (p.group == ic.label and p.time == ui.time
                and label_hit(p.label or '', q)) then
                return true;
            end
        end
    end
    return false;
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
    if (not search_hit(ic)) then
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
        if (ui.esc_frames == 1) then
            release_escape();
        else
            ui.esc_frames = ui.esc_frames - 1;
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
* The world lib/guide.lua reads and acts on, wired to the game.  One table
* built once: the errand runs every frame, and rebuilding six closures a frame
* to hand it the same six calls is the sort of garbage a present handler should
* not be making.
--]]
local guide_world = {
    in_event   = in_event,
    bag        = bag_state,
    near_guide = near_exp_guide,
    poke       = poke_npc,
    -- Something else owns Escape: a warp command waiting on a menu to close, or
    -- a press still held down from either exit.
    blocked    = function ()
        return ui.pending ~= nil or ui.esc_frames > 0;
    end,
    -- press_escape refuses while one is still held, so whether a press actually
    -- went out is what it reports back -- the errand spaces its retries off the
    -- presses that landed rather than the ones it asked for.
    press      = function (now)
        local before = ui.esc_frames;
        press_escape(now);
        return ui.esc_frames > before;
    end,
};

--[[
* Fetch an Instant Warp scroll from an EXP Guide, and leave again, without the
* player stopping.  The errand itself is lib/guide.lua; this is the gate in
* front of it.
*
* Runs every frame whether the map is up or not: the errand has nothing to do
* with the map being open, and the walk that starts it is one the player takes
* on the way past.
--]]
local function pump_guide(now)
    -- Off, or no way to leave the talk the scroll arrives in.  Escape is what
    -- ends the errand, so without user32 all this could do is drop the player
    -- into a guide's talk on every walk past with nothing able to close it.
    -- send_cmd can fall back on the player closing a menu they asked for; this
    -- one is not asked for, so it does not run at all.
    if (not cfg.guide or user32 == nil) then
        -- The map's Instant Warp icon reads has_warp to decide whether it is
        -- live, so the bag poll outlives the errand it was written for: with
        -- the errand off the icon still has to know whether a scroll is
        -- carried.  Nothing else here runs, so this costs one bag walk twice a
        -- second and no entity scan at all.
        local st = ui.errand;
        if (now - st.bag_at >= NEAR_POLL) then
            st.bag_at, st.has_warp = now, bag_state();
        end
        return;
    end
    guide.pump(ui.errand, guide_world, now);
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

-- Uberwarp's own destination data, which is where the unlock bits come from.
-- Read out of the install rather than shipped alongside the map: it is the
-- same copy Uberwarp performs the warp out of, so the two cannot drift.
-- The install path comes back with a trailing separator on some builds and
-- without on others, so it is taken off and put back.
unlocks.load(('%s/resources/ashitahelper/uberwarp/'):fmt(
    (AshitaCore:GetInstallPath():gsub('[\\/]+$', ''))));

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
local UW_TYPE = T{ home = 'hp', guide = 'sg', unity = 'uc', abyssea = 'ab' };

--[[
* The destination half of that line, which is also the name Uberwarp files its
* own data under, so lib/unlocks.lua can be asked about a row by the very
* string the command for it would carry.
--]]
local function warp_alias(label, row)
    -- The Campaign zones are named '[S]' throughout, the way Uberwarp spells
    -- them; a favorite saved under the old '(S)' was renamed on the way in.
    local zone = row.zone or label;
    -- The first Home Point of a zone is the bare name: '#1' is the default the
    -- command falls back to, so sending it would be a zone the server rejects.
    local n = (row.type == 'home') and row.label:match('^Home Point #(%d+)') or nil;
    return ('%s%s'):fmt(zone, (n ~= nil and n ~= '1') and n or '');
end

local function warp_cmd(label, row)
    local kind = UW_TYPE[row.type];
    if (kind == nil) then
        return nil;
    end
    return ('/uw %s %s'):fmt(kind, warp_alias(label, row));
end

--[[
* Whether the row's destination is one the player has stood at.  One that is
* not draws red and takes no press: the /uw for it would be turned down at
* the NPC, and a row that looks live but does nothing reads as a broken map.
--]]
local function warp_known(label, row)
    return unlocks.known(row.type, warp_alias(label, row), ui.masks);
end

--[[
* Favorites are saved flat rather than as a reference to a warp row: the row
* tables are rebuilt from lib/warps.lua on every load, so a saved reference
* would not survive that file being edited.  'key' is the marker label the row
* hung off, which is what warp_cmd wants alongside the row's own fields - and
* which makes the saved entry a warp row in its own right, so it can be passed
* straight back as one.
--]]
local function fav_index(key, row)
    for i, f in ipairs(cfg.favs) do
        if (f.key == key and f.type == row.type and f.label == row.label) then
            return i;
        end
    end
    return nil;
end

--[[
* Adds the row, or drops it again if it is already listed.  One entry point for
* both, since the menu is one item that reads whichever way the row is.
--]]
local function fav_toggle(key, row)
    local i = fav_index(key, row);
    if (i ~= nil) then
        table.remove(cfg.favs, i);
    else
        table.insert(cfg.favs, { key = key, type = row.type,
                                 label = row.label, zone = row.zone });
    end
    settings.save();
end

--[[
* Takes the favorite at i out and puts it back in at j, which is what dragging
* a row past its neighbours means: everything between the two shifts along by
* one, rather than i and j trading places.  Neither end runs off the list,
* since the slot a drag reads is clamped to it, so j is trusted.  Saving is
* left to the caller: one drag lands on a run of these, one per row crossed.
--]]
local function fav_reorder(i, j)
    table.insert(cfg.favs, j, table.remove(cfg.favs, i));
end

--[[
* The favorites as the lists show them.  Stood at a warp NPC, only the rows
* that NPC can actually send: a Survival Guide cannot take a Home Point row,
* so listing one there is a row that looks like a choice and is not.  With no
* NPC in reach -- near_kind nil, or false before the first poll -- there is
* nothing to narrow against, so the whole list is shown.
*
* Hands back the rows and, when narrowed, the slot each one sits in in
* cfg.favs, so a drag inside the narrowed list reorders the saved list: the
* row is pulled out of its own slot and put back in the one the row it was
* dragged onto holds, which lands it on that side of it in both lists.
--]]
local function fav_view()
    local kind = ui.near_kind;
    if (not kind) then
        return cfg.favs, nil;
    end
    local view, raw = T{ }, T{ };
    for i, f in ipairs(cfg.favs) do
        if (f.type == kind) then
            view[#view + 1] = f;
            raw[#raw + 1]   = i;
        end
    end
    return view, raw;
end

-- What a favorite reads as: the zone the row hung off, then the row itself,
-- e.g. 'Windurst Woods - Home Point #2'.
local function fav_text(f)
    return ('%s - %s'):fmt(f.key, f.label);
end

--[[
* The grid reference the favorite's row carries, e.g. '(F-11)', or nil for a
* row with none.  Looked up rather than saved with the entry: lib/warps.lua is
* where it comes from, so an edit there corrects favorites already listed, and
* ones saved before this column existed get theirs without a migration.  WARPS
* is read straight rather than through warp_rows, since a favorite is listed
* whether or not its type's toggle is lit.
--]]
local function fav_pos(f)
    for _, r in ipairs(WARPS[f.key] or {}) do
        if (r.type == f.type and r.label == f.label) then
            return r.pos;
        end
    end
    return nil;
end

local function point_at(mx, my)
    for _, ic in ipairs(ICONS) do
        -- The drawn size is in screen pixels, so it shrinks in map space as
        -- the view zooms in.
        local half = SCALE.px(ic) / 2 / ui.zoom;
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
* What a string will measure once outlined_text has drawn it: the map's face at
* the map's size, rather than at the size the window's own font comes out at.
*
* The scale is set around the measurement and put straight back: it is a window
* property, so leaving it on would take every widget on the toolbar with it.
--]]
local function text_size(text)
    local face = FONT_PX.face();
    if (face) then imgui.PushFont(face); end
    imgui.SetWindowFontScale(ui.font_scale);
    local w, h = imgui.CalcTextSize(text);
    imgui.SetWindowFontScale(1.0);
    if (face) then imgui.PopFont(); end
    return w, h;
end

--[[
* ImGui has no outlined text, so stamp the string in the stamp colour around
* itself before drawing it.  Keeps it readable over both land and ocean.
*
* A plate goes down first when the background picker has any alpha at all.
* Skipped outright when it has none, which is the default: the size of it costs
* a CalcTextSize, and every label on the map comes through here every frame.
--]]
local function outlined_text(dl, x, y, text, dim, scale)
    -- The face and the scale both reach the draw list as well as the widgets,
    -- so they wrap the stamps and the plate as much as the text itself, and are
    -- put back before anything else on the window is drawn.
    local face = FONT_PX.face();
    if (face) then imgui.PushFont(face); end
    imgui.SetWindowFontScale(scale or ui.font_scale);
    local bg = dim and COL_BG_DIM or COL_BG;
    if (bg >= 0x1000000) then
        local tw, th = imgui.CalcTextSize(text);
        dl:AddRectFilled({ x - BG_PAD, y - BG_PAD },
                         { x + tw + BG_PAD, y + th + BG_PAD },
                         bg, 0, ImDrawCornerFlags_All);
    end
    local stamp = dim and COL_STAMP_DIM or COL_STAMP;
    for _, o in ipairs({ { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }) do
        dl:AddText({ x + o[1], y + o[2] }, stamp, text);
    end
    dl:AddText({ x, y }, dim and COL_TEXT_DIM or COL_TEXT, text);
    imgui.SetWindowFontScale(1.0);
    if (face) then imgui.PopFont(); end
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
    -- The query is kept, but the view it was framed for belongs to the map
    -- being left.  Forgetting what it was framed for reframes it on the map
    -- being arrived at, instead of landing at cover with the other map's
    -- matches still dimming this one and nothing to pull the view back.
    ui.search_at = nil;
    ui.zoom  = nil;
    ui.pan_x = 0;
    ui.pan_y = 0;
    ui.focus = nil;
    ui.sel   = nil;
    ui.press = nil;
    ui.warp  = nil;
    ui.ctx   = nil;
    -- The pad's landings belong to the map being left as surely as the view
    -- does: gp_from would otherwise point at an overview marker of the other
    -- era, with ui.focus no longer holding it.
    ui.gp_icon = nil;
    ui.gp_from = nil;
    ui.gp_row  = nil;
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
* A warp popup or the right-click menu lying over one of these eats the press:
* this row is submitted before either, and ImGui hands hover to the first item
* that claims it, so a panel over a toggle would otherwise flip it from
* underneath.  Read a frame late, which is harmless - neither moves while it is
* open.  Missing art draws nothing and takes no press.
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
    local hit = imgui.InvisibleButton('##ubermap_' .. id, { w, h })
                and not ui.warp_hot and not ui.ctx_hot;
    if (tip ~= nil) then
        item_tip(tip);
    end
    -- Feeding ui.hot keeps the map from panning or zooming underneath.
    ui.hot = ui.hot or imgui.IsItemHovered();
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
        local half = SCALE.px(ic) / 2;
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
            if (hot) then
                hot_ic = ic;
            end
            -- The gamepad's landing wears the same hover the cursor gives, so
            -- one thing on screen says what a press would act on.  It is not
            -- fed back as hot_ic: that is what a click acts on, and a click
            -- has to mean wherever the cursor actually is.  A marker faded
            -- back is not lit whatever the selection says, the same way it
            -- takes no cursor -- a stale selection left behind by the wheel is
            -- put right at the next press, not here.
            -- And exactly one of the two is lit: with the pad or the keys
            -- driving, a cursor parked over some other marker would otherwise
            -- leave two markers looking equally pressable.  The cursor's own
            -- hover comes back the moment it moves over the map again, which
            -- is what hands the map back to the mouse.
            local lit = ui.gp_active
                        and (not dim and ic == ui.gp_icon)
                        or (not ui.gp_active and hot);
            local tex = nil;
            if (lit) then
                tex = icon_texture((ic.file:gsub('_0%.png$', '_1.png')));
            end
            tex = tex or icon_texture(ic.file);
            if (tex ~= nil) then
                -- Grown only for the draw: the hit test above keeps the plain
                -- size, so the icon cannot swell out from under the cursor and
                -- flicker between the two states.
                local grow  = (lit and ic.group == HOT_GROUP)
                              and half * ICON_HOT or half;
                local id    = tonumber(ffi.cast('uint32_t', tex));
                local p0    = { cx - grow, cy - grow };
                local p1    = { cx + grow, cy + grow };
                local round = grow * 2 * ICON_ROUND;
                dl:AddImageRounded(id, p0, p1, { 0, 0 }, { 1, 1 },
                                   dim and COL_ICON_OFF or COL_ICON,
                                   round, ImDrawCornerFlags_All);
                if (ic.border ~= false) then
                    dl:AddRect(p0, p1, dim and COL_OUTLINE_DIM or COL_OUTLINE,
                               round, ImDrawCornerFlags_All, ICON_BORDER);
                end
                if (ic == ui.sel) then
                    dl:AddRect({ p0[1] - 2, p0[2] - 2 }, { p1[1] + 2, p1[2] + 2 },
                               COL_SELECT, round, ImDrawCornerFlags_All, ICON_BORDER);
                end

                if (ic.label ~= nil) then
                    local tw, th = text_size(ic.label);
                    outlined_text(dl, cx - tw / 2, cy - grow - th - LABEL_GAP,
                                  ic.label, dim);
                end
            end
        end
      end
    end
    return hot_ic;
end

local ZOOM_PAD = 100;  -- map pixels of margin around the framed points

--[[
* Pulls the view all the way back out to the whole map, centred.  Below
* ZOOM_POINTS, so the overview markers are what is drawn: this is where the map
* starts and where a search with nothing left to show goes.
--]]
local function zoom_to_map(view_w, view_h)
    local map_w, map_h = map_size();
    ui.zoom  = mm.cover_zoom(map_w, map_h, view_w, view_h);
    ui.pan_x = (map_w * ui.zoom - view_w) / 2;
    ui.pan_y = (map_h * ui.zoom - view_h) / 2;
end

--[[
* Puts a map-pixel box in the middle of the viewport at the zoom that fits it,
* ZOOM_PAD of margin included.  The floor is ZOOM_POINTS, below which the zone
* points are not drawn at all, or the zoom that covers the viewport where that
* is higher; the ceiling is MAX_ZOOM, so a box of one point does not run away.
--]]
local function zoom_to_box(x0, y0, x1, y1, view_w, view_h)
    local map_w, map_h = map_size();
    local floor_z = math.max(ZOOM_POINTS, mm.cover_zoom(map_w, map_h, view_w, view_h));
    local fit = mm.fit_zoom(x1 - x0 + ZOOM_PAD * 2, y1 - y0 + ZOOM_PAD * 2,
                            view_w, view_h);
    ui.zoom  = mm.clamp(fit, floor_z, MAX_ZOOM);
    ui.pan_x = (x0 + x1) / 2 * ui.zoom - view_w / 2;
    ui.pan_y = (y0 + y1) / 2 * ui.zoom - view_h / 2;
end

--[[
* Frames every point 'want' accepts, on the map being shown.  Returns false
* when nothing is accepted, which leaves the view alone.
--]]
local function zoom_to_points(want, view_w, view_h)
    local x0, y0, x1, y1;
    for _, ic in ipairs(ICONS) do
        if (ic.time == ui.time and want(ic)) then
            x0 = math.min(x0 or ic.x, ic.x);
            y0 = math.min(y0 or ic.y, ic.y);
            x1 = math.max(x1 or ic.x, ic.x);
            y1 = math.max(y1 or ic.y, ic.y);
        end
    end
    if (x0 == nil) then
        return false;
    end
    zoom_to_box(x0, y0, x1, y1, view_w, view_h);
    return true;
end

--[[
* Frames every point whose group matches 'name', so clicking an overview marker
* opens the zone points it stands for.
--]]
local function zoom_to_group(name, view_w, view_h)
    if (not zoom_to_points(function(ic) return ic.group == name; end,
                           view_w, view_h)) then
        return false;
    end
    ui.focus = name;
    return true;
end

--[[
* Frames every zone point the search box matches, so a search lands on what it
* found instead of leaving it dimmed somewhere off screen.  Overview markers
* are left out: they stop being drawn at ZOOM_POINTS, which framing a match
* always passes, and a region marker sits nowhere near the zone it stands for.
*
* Any group focus is dropped on the way, since the search is the subject of the
* view now and a stale focus would dim the very points just framed.
*
* A forgiven spelling picks up the odd unrelated zone -- "juno" is a letter off
* "jung" as surely as it is off "jeuno" -- and one match on the far side of the
* world would frame the whole map rather than what was meant.  So a forgiven
* search frames the group holding the most of its matches, and only a forgiven
* one: a query spelled the way the map spells it frames everything it names,
* however far apart those are.  Every match stays lit either way.
*
* Nineteen of the region and nation names the overview carries -- Vollbow,
* Derfland, Zulkheim and the rest -- name no zone at all, so a search for one
* leaves no zone point to frame.  Those fall back to framing the zones the
* matched marker stands for, since the marker itself stops being drawn the
* moment framing passes ZOOM_POINTS: without it the view would sit wherever a
* shorter prefix had left it with every marker on it faded back.
--]]
local function zoom_to_search(view_w, view_h)
    -- Dropped up here rather than on the way out: a stale focus dims the very
    -- points a search frames, and it has to go whether or not one is found.
    ui.focus = nil;
    local q = search_query();
    local best;
    if (search_prep(q)) then
        local n = { };
        for _, ic in ipairs(ICONS) do
            if (ic.time == ui.time and not OVERVIEW[ic.group] and search_hit(ic)) then
                local g = ic.group or '';
                n[g] = (n[g] or 0) + 1;
                if (best == nil or n[g] > n[best]) then
                    best = g;
                end
            end
        end
    end
    if (zoom_to_points(function(ic)
            return not OVERVIEW[ic.group] and search_hit(ic)
                   and (best == nil or ic.group == best);
        end, view_w, view_h)) then
        return true;
    end

    -- No zone answers, so try the regions: a marker matched by its own name
    -- frames the zones underneath it.
    local region, any = { }, false;
    for _, ic in ipairs(ICONS) do
        if (OVERVIEW[ic.group] and ic.time == ui.time
            and label_hit(ic.label or '', q)) then
            region[ic.label] = true;
            any = true;
        end
    end
    if (any and zoom_to_points(function(ic)
            return not OVERVIEW[ic.group] and region[ic.group];
        end, view_w, view_h)) then
        return true;
    end

    -- Nothing on the map answers at all.  Back out to the whole of it, where
    -- the overview is drawn, rather than stranding the view inside the last
    -- match with everything on screen faded back.
    zoom_to_map(view_w, view_h);
    return false;
end

-- The map's own gamepad functions, hung off one table rather than standing as
-- five locals of their own.  This chunk runs a handful of names short of Lua's
-- limit of 200 locals to a function, and five more do not fit; it is the shape
-- SCALE.px is already written in, so it is no stranger here than there.
-- ponytail: one table because the limit is the whole reason for it.  Split the
-- chunk into modules and these can go back to being plain locals.
local nav = { };

--[[
* The keyboard's half of the same seven: the arrows are the D-pad, Enter is A
* and Escape is B, so one set of actions serves both and nav.act needs to know
* nothing about which hand made the press.
*
* U is the widget's alone and has no pad twin: the Y press that swaps the
* widget for the map.  F is read twice over -- at the widget it hands it the
* arrows, and on the map it is the pad's Y, which opens the favorites menu on
* the lit warp row.  Tab is the map's alone and has no pad twin either: it
* moves the keyboard between the map and its own search box.  They are here
* rather than as constants of their own because this chunk sits at Lua's limit
* of 200 locals; see nav's own note above.
*
* Keyed by DirectInput scan code rather than by virtual key, because that is
* what the game reads.  The WNDPROC key event carries virtual keys and can be
* blocked, but blocking it only keeps a key out of the client's *text* fields:
* movement, the camera and the menus are all read straight off DirectInput
* underneath it.  So these are matched in key_data and key_state instead, and
* the arrows really do stop turning the camera.
--]]
nav.key = {
    [0xC8] = 'up',    [0xD0] = 'down',
    [0xCB] = 'left',  [0xCD] = 'right',
    -- Both Enters, since a keyboard has two and only one of them is over by
    -- the letters.
    [0x1C] = 'a',     [0x9C] = 'a',
    [0x01] = 'b',
    [0x16] = 'u',     [0x21] = 'f',
    [0x0F] = 'tab',
};

--[[
* The list, and where in it the selection sits.  A selection that is not on the
* list any more -- zoomed past, filtered out by the toggles or the search box,
* or never made at all -- restarts at the marker nearest the middle of the
* viewport, which is what puts the first press of a session on the centre-most
* nation and what recovers every stale one after that.
--]]
function nav.focus(view_w, view_h)
    -- Every marker the pad can land on right now: what is drawn, minus what
    -- is faded back -- the same two tests draw_icons puts a marker on the
    -- screen and under the cursor by.  Which tier that is answers itself,
    -- since the overview markers are the ones drawn below ZOOM_POINTS and the
    -- zone points the ones above it: zooming with the wheel moves the
    -- selection between tiers as surely as an A press does, with no separate
    -- level to keep in step with it.
    local list = { };
    for _, ic in ipairs(ICONS) do
        if (icon_visible(ic) and not icon_dim(ic)) then
            table.insert(list, ic);
        end
    end
    for i, ic in ipairs(list) do
        if (ic == ui.gp_icon) then
            return list, i;
        end
    end
    local i = gpn.nearest(list,
                          mm.to_map(view_w / 2, ui.pan_x, ui.zoom, 0),
                          mm.to_map(view_h / 2, ui.pan_y, ui.zoom, 0));
    ui.gp_icon = (i ~= nil) and list[i] or nil;
    return list, i;
end

--[[
* The mouse taking the map back off the pad.  Movement over the map or over the
* widget says the hand is on the mouse, and the cursor's own hover is what says
* where a click would land there, so the pad's highlights are put out rather
* than left arguing with it.
*
* Only the highlights: gp_from is the way back out of a marker, not something
* drawn, and the widget's row is kept as a number so its arithmetic still has
* one -- gp_active is what decides whether either is lit.  Only a press of a
* button the map or the widget reads sets that again, and the next pump seats
* a marker under it.
--]]
function nav.mouse(hovered)
    if (not hovered or not ui.ptr_moved) then
        return;
    end
    ui.gp_active = false;
    ui.gp_icon = nil;
    ui.gp_row  = nil;
end

--[[
* Marks the pad as what is driving, and answers whether this press is spent
* doing only that.  The mouse moving over the map or the widget puts the pad's
* highlights out, so the press that turns them back on lights what it left
* rather than acting on it: the next frame seats a selection under it, and the
* press after that is the one that walks, opens or sends.  A press that acted
* on the way back in would step off -- or worse, send -- something nothing on
* screen was showing.
--]]
function nav.wake()
    local was = ui.gp_active;
    ui.gp_active = true;
    return not was;
end

--[[
* Acts on one queued press, at the frame that knows how big the viewport is.
*
* Nested the way the game's own menus are: the overview, the zone points inside
* one marker of it, and the warp list inside one of those.  A takes the next
* one down and B comes back up.  There is no level held anywhere, because the
* view already says which one it is on -- ui.focus is set exactly while a
* marker has been zoomed into, by a click as much as by an A press, so the two
* ways in share the one way out.
--]]
function nav.act(act, view_w, view_h)
    -- Inside even the warp list: while the favorites menu is up it is what
    -- every press is for, the same way a mouse click anywhere belongs to it
    -- rather than to what it is lying over.  A picks its one item, B and a
    -- second Y dismiss it, and everything else is swallowed so the list and
    -- the markers do not walk about behind it.
    if (ui.ctx ~= nil) then
        if (act == 'a') then
            fav_toggle(ui.ctx.key, ui.ctx.row);
        end
        if (act == 'a' or act == 'b' or act == 'y') then
            ui.ctx = nil;
        end
        return;
    end

    -- The innermost tier first: with a warp list open it is what every press
    -- is for, and the markers underneath are not to move about behind it.
    -- The rows the panel is showing, or nil while it is shut: the same call
    -- it makes for itself.
    local rows = (ui.warp ~= nil) and warp_rows(ui.warp.label) or nil;
    if (rows ~= nil) then
        if (act == 'b') then
            ui.warp = nil;
            return;
        end
        if (act == 'y') then
            -- The pad's right-click: the favorites menu on the lit row, live
            -- or not, exactly as the mouse's second button opens it.  Hung off
            -- the row itself, out of the panel's own top-left, so it reads as
            -- belonging to what was pressed rather than to the last place the
            -- cursor happened to be.  Under the row rather than over it, the
            -- same as the mouse's: the row stays readable and the menu is the
            -- only thing a press can land on.  A list opened with the mouse
            -- lights no row yet, and a press with nothing to point at opens
            -- nothing.
            local r = (ui.gp_row ~= nil) and rows[ui.gp_row] or nil;
            if (r ~= nil) then
                ui.ctx = { x = ui.warp_px + POPUP_PAD * 2,
                           ry = ui.warp_py + POPUP_ROW * (ui.gp_row - 1),
                           fresh = true, key = ui.warp.label, row = r };
            end
            return;
        end
        -- Where the press leaves the lit row, and whether it is a send: the
        -- wrapping and the pulling back inside a list the toggles have emptied
        -- are gpnav's, so test_gpwarp.lua drives the real thing.
        local send;
        ui.gp_row, send = gpn.row(ui.gp_row, #rows, act);
        if (send) then
            -- The same two tests the row is coloured on: it travels only from
            -- the kind of NPC in reach, and only somewhere registered.  A row
            -- that fails either takes no press, exactly as it takes no click:
            -- the /uw would be turned down at the NPC, and a row that looks
            -- live but does nothing reads as a broken list.
            local r = rows[ui.gp_row];
            if (r ~= nil and r.type == ui.near_kind
                and warp_known(ui.warp.label, r)) then
                local cmd = warp_cmd(ui.warp.label, r);
                if (cmd ~= nil) then
                    -- Which closes the map and the panel with it, the way
                    -- sending always has.
                    send_cmd(cmd);
                end
            end
        end
        return;
    end

    local list, i = nav.focus(view_w, view_h);

    if (act == 'a') then
        local ic = ui.gp_icon;
        if (ic == nil) then
            return;
        end
        if (OVERVIEW[ic.group]) then
            -- Into the marker's zone points, framed the way a click frames
            -- them.  The selection is dropped rather than carried down: the
            -- view has moved, so the next nav.focus lands on the centre-most
            -- point of what was just framed.  A marker standing for no zone
            -- points at all frames nothing and stays where it is, exactly as
            -- a click on it does.
            if (zoom_to_group(ic.label, view_w, view_h)) then
                ui.gp_from = ic;
                ui.gp_icon = nil;
            end
        else
            -- A zone nothing warps to leaves the panel shut rather than
            -- opening an empty one, the same test the click makes.  Opened
            -- from the pad, so the top row is lit and A would send it.
            if (warp_rows(ic.label) ~= nil) then
                ui.warp   = ic;
                ui.gp_row = 1;
            end
        end
        return;
    end

    if (act == 'b') then
        if (ui.focus ~= nil) then
            -- Back out to the whole map with the marker that was zoomed into
            -- lit, so the way back in is one A press.  gp_from is nil when the
            -- view was framed by a search rather than by a marker, and then
            -- the selection restarts in the middle like any other stale one.
            zoom_to_map(view_w, view_h);
            ui.focus   = nil;
            ui.warp    = nil;
            ui.gp_icon = ui.gp_from;
            ui.gp_from = nil;
        else
            -- Already at the top, so B is what it is everywhere else in the
            -- game: the way out.  Escape does this for a keyboard, and a
            -- controller has nothing else that would.
            ui.is_open[1] = false;
        end
        return;
    end

    local j = gpn.step(list, i, act);
    if (j ~= nil) then
        ui.gp_icon = list[j];
    end
end

--[[
* Drains the presses that arrived since the last frame.  A queue rather than
* one pending action, so two presses inside a frame both land instead of the
* second eating the first.  Then, for a pad only, the selection is seated if
* the presses left none: what keeps the highlight off the map of somebody
* using the mouse is gp_active, not the absence of a press.
--]]
function nav.pump(view_w, view_h)
    if (#ui.gp_q > 0) then
        -- Taken off the queue up front: what is not acted on below is dropped
        -- on purpose, and only the one case that puts presses back does.
        local q = ui.gp_q;
        ui.gp_q = { };
        for i, act in ipairs(q) do
            -- A press can close the map underneath the rest of them -- sending
            -- a warp does -- and what is left was aimed at a map that is no
            -- longer there.  Acting on it would seat a selection, or open a
            -- warp list, behind a window that is shut.
            if (not ui.is_open[1]) then
                break;
            end
            local had_warp = ui.warp;
            nav.act(act, view_w, view_h);
            -- A press that opened the warp list ends the drain, and the rest
            -- wait for the frame that draws it: ui.warp_px/py are written by
            -- draw_warp_popup and by nothing else, so a Y queued behind the A
            -- that opened the list would hang its menu off the last panel's
            -- corner -- or off 0, 0 if no panel has been drawn at all.
            if (had_warp == nil and ui.warp ~= nil) then
                for j = i + 1, #q do
                    table.insert(ui.gp_q, q[j]);
                end
                break;
            end
        end
    end
    -- A pad that is driving has no cursor to say where a press would land, so
    -- its marker is lit before it is pressed: on opening, and again on the
    -- frame A frames a nation and drops the selection that framed it.  Only
    -- where nothing is lit already, so the wheel and the mouse move the view
    -- without the selection chasing them.
    if (ui.gp_active and ui.gp_icon == nil) then
        nav.focus(view_w, view_h);
    end
end

--[[
* Asks the server for the map markers, which it answers with the teleport masks
* among other things.  The same request the client makes for itself every time
* the in-game map is opened, and header-only: nine bits of id, seven of size in
* dwords, then a sync the client fills in.
*
* Sent on opening rather than waited for, since the masks otherwise only arrive
* on zoning in - the map would sit ungated for a whole session that never
* zoned, and would still be showing the state from before a Home Point was
* registered in the one that did.
--]]
-- 0x114 with one dword of size in the top bits is 0x314, little end first.
local function ask_for_masks()
    AshitaCore:GetPacketManager():AddOutgoingPacket(0x114, { 0x14, 0x03, 0, 0 });
end

--[[
* Opens the map.  If it is already open the current zoom and pan are left
* alone, so repeated Home Point visits do not yank the view back to the default.
--]]
local function show()
    ui.is_open[1] = true;
    -- Raised over other addons' windows once on the way up, and never again:
    -- opening behind fancychat left the map unclickable, but a map that rose
    -- on every click would bury the favorites widget (see the flags at Begin).
    ui.raise_next = true;
    -- Asked for here rather than in the draw, so the box is handed the
    -- keyboard once on the way in instead of stealing it back every frame.
    ui.focus_next  = cfg.focus;
    ui.search_blur = false;
    -- Opening reads the world afresh on the next frame, whatever the toggles
    -- were left at when it was last up.
    ui.near_kind = false;
    ui.near_at   = 0;
    -- and re-anchors where the player is standing now, so the map does not
    -- close on the distance walked since the last time it was up.
    ui.open_x    = nil;
    ui.open_z    = nil;
    -- A menu left open from the last time the map was up would come back with
    -- it, hung over a panel that is no longer there.  Its veto goes with it,
    -- or the first frame back would have the panels deaf under a menu that is
    -- not there.
    ui.ctx       = nil;
    ui.ctx_hot   = false;
    -- The gamepad starts where the view does, which the first frame works out,
    -- and a press left over from the last time the map was up is not this
    -- one's: nothing is queued between the map closing and it opening again.
    ui.gp_icon   = nil;
    ui.gp_from   = nil;
    ui.gp_row    = nil;
    ui.gp_q      = {};
    ask_for_masks();
end

--[[
* Send the selected favorite, if it is one that can travel.  A row that cannot
* takes no press, the same way a red row in the panel takes no click: the /uw
* would be turned down at the NPC, and a row that looks live but does nothing
* reads as a broken list.  The two tests are the ones draw_fav_list colours a
* row on: a row travels only from the kind of NPC it was saved off, and only to
* somewhere the player has registered.
--]]
local function fw_confirm()
    local f = fav_view()[ui.fw_sel];
    if (f == nil or f.type ~= ui.near_kind or not warp_known(f.key, f)) then
        return;
    end
    local cmd = warp_cmd(f.key, f);
    if (cmd ~= nil) then
        send_cmd(cmd);
        -- The widget has been told what it was up for, so it gets out of the
        -- way: near_kind does not change until the zone does, so leaving it up
        -- would swallow A and B for the seconds the warp takes to resolve --
        -- exactly when the NPC's own menu might want them.  Walking off and
        -- back arms it again, the same as a B press does.
        ui.fw_hide = true;
    end
end

--[[
* Whether a key is the map's or the widget's right now, and -- on the press
* edge -- what it does.  Both keyboard handlers come through here: key_data
* acts on it and blocks the edge, key_state asks it with down false and wipes
* the key out of the frame's state buffer.  One answer, so the two cannot come
* apart and leave a key half taken.
*
* Hung off nav rather than standing as a local of its own for the reason the
* rest of nav is, and written down here rather than up beside it because it
* calls show and fw_confirm, which are locals declared below that point.
*
* Read in the same order the pad is: the widget is asked first and wins
* outright, then the map while it is on screen.  Unlike the pad the keys have
* to be handed back -- the arrows are how the player walks -- so the widget
* takes them only after an F and the map only while it is up.
--]]
function nav.press(act, down)
    -- Typing beats nearly all of it.  The game's own chat line or a bazaar
    -- comment has the keyboard first; the map's search box and its config
    -- numbers have it next, and the arrows, Enter and Escape are those boxes'
    -- own editing keys while a caret is in one.  ImGui is fed from WNDPROC,
    -- which none of this touches, so a key acted on here would land twice.
    -- Tab is the exception and is taken below, since a key that only ever gets
    -- the keyboard into the box would be a door with no handle on the inside.
    if (bit.band(AshitaCore:GetChatManager():IsInputOpen(), 0x01) ~= 0
        or ui.cfg_typing) then
        return false;
    end

    -- Tab is the one key the search box does not keep for itself: it is how
    -- the keyboard is handed to that box and how it is taken back again, so it
    -- is read before the caret is asked about rather than after.  The map's
    -- alone, since the box is part of the map: the widget below never sees it,
    -- and with the map shut it goes back to the client, which targets with it.
    if (act == 'tab') then
        -- A frame the map did not draw has no box to hand the caret to, the
        -- same reason the queue below is not fed from one: a focus latched
        -- there would sit until the box came back and then take the keyboard
        -- out of nowhere.  Back to the client instead, the way the rest go.
        if (not ui.is_open[1] or not ui.gp_ready) then
            return false;
        end
        if (down) then
            -- One or the other and never both.  A blur still pending from a
            -- map that was put away mid-search would otherwise swallow the
            -- focus this press is asking for.
            ui.focus_next, ui.search_blur = not ui.kb_typing, ui.kb_typing;
        end
        return true;
    end

    if (ui.kb_typing) then
        return false;
    end

    -- The addon's own Escape, held down through user32 to back out of an NPC's
    -- menu, comes back round through DirectInput like any other.  Taking it
    -- would be the map answering a press it made itself -- and wiping it out of
    -- the state buffer would keep it from the very menu it was sent to close.
    if (act == 'b' and ui.esc_frames > 0) then
        return false;
    end

    -- The widget first, and outright: it is only ever up stood at a warp NPC,
    -- and there a press is for it.
    if (ui.fw_on) then
        local n = #fav_view();
        if (n == 0) then
            return false;
        end

        -- The way up to the full map, and what the auto-open checkbox leaves
        -- behind when it is turned off: the pad's Y, on a key that is free
        -- whether or not the widget has been given the arrows.  The widget
        -- goes with it rather than staying up over the map, or it would keep
        -- taking the keys the map now wants.
        if (act == 'u') then
            if (down) then
                ui.fw_key  = false;
                ui.fw_hide = true;
                show();
            end
            return true;
        end

        if (ui.fw_key) then
            if (act ~= 'up' and act ~= 'down' and act ~= 'a' and act ~= 'b') then
                -- Left and right stay the client's even here: the widget is a
                -- single column, and taking them would leave no way to work
                -- the NPC's menu behind it.
                return false;
            end
            if (not down) then
                return true;
            end
            -- Escape hands the keys back whatever the highlight is doing, so
            -- there is always one press out of this mode.  The rest wait for
            -- the row to be lit again, the same as the pad's do: a press that
            -- acted on the way back in would step off -- or worse, send --
            -- something nothing on screen was showing.
            if (nav.wake() and act ~= 'b') then
                return true;
            end
            if (act == 'up') then
                -- Wraps at both ends, the way the game's own menus do.
                ui.fw_sel = (ui.fw_sel - 2) % n + 1;
            elseif (act == 'down') then
                ui.fw_sel = ui.fw_sel % n + 1;
            elseif (act == 'a') then
                fw_confirm();
            else
                -- Out of focus mode and no further: the widget stays up, so
                -- the F that got here is one press away again.
                ui.fw_key = false;
            end
            return true;
        end

        -- The arrows are the player's until they are asked for, since walking
        -- up to a warp NPC is something done while moving.
        if (act == 'f') then
            if (down) then
                ui.fw_key = true;
                ui.fw_sel = mm.clamp(ui.fw_sel, 1, n);
                -- Lights the row on the way in, so the first arrow steps it
                -- rather than being spent turning the highlight back on.
                nav.wake();
            end
            return true;
        end

        -- Escape outside focus mode dismisses the widget, the way B does on
        -- the pad: the NPC's own menu is behind it, and a second Escape is
        -- what backs out of that.
        if (act == 'b') then
            if (down) then
                ui.fw_hide = true;
            end
            return true;
        end
        return false;
    end

    -- The map, while it is on screen.  U is the widget's alone, so with the
    -- widget off screen it goes back to the client rather than falling
    -- through.  F is the map's own Y -- the favorites menu on the lit warp
    -- row -- so past here it travels as one: nav.act knows nothing about which
    -- hand made the press, and 'y' is the name that half of it already answers
    -- to.  At the top of the map it steps nothing and is dropped, exactly as
    -- the pad's Y is there.
    if (not ui.is_open[1] or act == 'u') then
        return false;
    end
    if (act == 'f') then act = 'y'; end

    -- A frame that is not drawing the map has nothing to drain the queue -- no
    -- texture, or a window ImGui collapsed -- so a press queued there is lost.
    -- Escape still has to work out of one, or the map could not be shut.
    if (ui.zoom == nil or not ui.gp_ready) then
        if (act ~= 'b') then
            return false;
        end
        if (down) then
            ui.is_open[1] = false;
        end
        return true;
    end

    if (not down) then
        return true;
    end
    -- Escape is the one exception to the wake: it is the way out of a map
    -- covering most of the screen, so it acts on the first press however the
    -- map was being driven.  See the xinput handler for the rest of it.
    if (nav.wake() and act ~= 'b') then
        return true;
    end
    -- Queued rather than acted on here: the zooms need the viewport size, and
    -- only the draw knows that.
    if (#ui.gp_q < 8) then
        table.insert(ui.gp_q, act);
    end
    return true;
end

--[[
* The favorites list itself, drawn once and used twice: the panel behind the
* heart and the gamepad widget's window put up the same rows, take the same
* clicks and reorder on the same drags.  Hand-drawn into whichever window's
* draw list is current rather than built out of ImGui items, because the panel
* is a rectangle laid over the map and lines its columns up by hand.
*
* Measuring is a call of its own because both callers need the size before
* they have anywhere to put it: the panel grows upwards out of the heart, and
* the widget's window sizes itself to whatever it is handed.  A list with
* nothing in it measures the one row of FAV_EMPTY instructions the panel draws
* in its place; the widget never sees that case, since an empty list takes it
* off screen before it measures anything.
--]]
local function fav_metrics()
    local favs  = fav_view();
    local n     = #favs;
    local _, th = imgui.CalcTextSize('A');
    -- Columns: the warp type's icon, then the text.  An empty list is one row
    -- of instructions with neither, since there is nothing to travel on yet.
    local lab_x = (n > 0) and (POPUP_PAD + POPUP_ICON + POPUP_PAD) or POPUP_PAD;
    -- The grid reference is a column of its own, the way the warp popup lays
    -- it out, so every row's '(F-11)' lines up whatever it is hung off.  A
    -- list where no row carries one has no column at all.
    local textw = (n == 0)
                  and (imgui.CalcTextSize(ui.near_kind and FAV_NONE or FAV_EMPTY))
                  or 0;
    local posw  = 0;
    for _, f in ipairs(favs) do
        -- Parenthesised: CalcTextSize hands back a width and a height, and
        -- both would otherwise go into math.max.
        textw = math.max(textw, (imgui.CalcTextSize(fav_text(f))));
        local p = fav_pos(f);
        if (p ~= nil) then
            posw = math.max(posw, (imgui.CalcTextSize(p)));
        end
    end
    local pos_x = lab_x + textw + POPUP_PAD;
    return { n     = n,
             th    = th,
             lab_x = lab_x,
             pos_x = pos_x,
             w     = ((posw > 0) and (pos_x + posw) or (lab_x + textw)) + POPUP_PAD,
             h     = POPUP_ROW * math.max(n, 1) };
end

--[[
* Draws the list fav_metrics measured at px, py and takes its presses: hover,
* drag to reorder, click to travel.  Hands back the row the cursor is on, for
* whichever right-click menu the caller hangs off it.  In opts:
*
*   sel  - a row to keep lit whatever the cursor is doing, i.e. the widget's
*          D-pad landing.  The panel has no selection of its own.
*   veto - something lying over the list is eating its presses, so no row of
*          it hovers, drags or right-clicks while that is up.
*   grab - false to draw the rows and take nothing, which is what hands a
*          press to the window underneath instead.
*
* One drag at a time, in ui.fav_drag: only ever one of the two lists is on
* screen, since turning the widget on takes the heart and its panel away.
--]]
local function draw_fav_list(px, py, m, mouse_x, mouse_y, opts)
    local dl      = imgui.GetWindowDrawList();
    local n, w, h = m.n, m.w, m.h;
    local sel     = opts.sel;
    local veto    = opts.veto;

    dl:AddRectFilled({ px, py }, { px + w, py + h }, COL_POPUP_BG,
                     0, ImDrawCornerFlags_All);
    dl:AddRect({ px, py }, { px + w, py + h }, COL_OUTLINE,
               0, ImDrawCornerFlags_All, ICON_BORDER);
    -- Kept inside the outline at both ends, so a lit first or last row does
    -- not paint over the border it sits against.
    local function light(ry)
        dl:AddRectFilled(
            { px + ICON_BORDER, math.max(ry, py + ICON_BORDER) },
            { px + w - ICON_BORDER,
              math.min(ry + POPUP_ROW, py + h - ICON_BORDER) },
            COL_HOVER, 0, ImDrawCornerFlags_All);
    end

    -- Which row the cursor is on, read while drawing and acted on after: a
    -- drag reorders the list the loop is walking.
    local hot_i, hot_live, hot_lock = nil, false, nil;
    local drag = ui.fav_drag;
    -- Narrowed to the NPC in reach, so every row drawn here is one that can be
    -- sent from where the player is stood; raw is nil when it is not narrowed,
    -- and then a row's slot in the list is its slot in cfg.favs.
    local favs, raw = fav_view();
    for i, f in ipairs(favs) do
        local ry = py + POPUP_ROW * (i - 1);
        -- The same two tests the popup rows use: a favorite travels only from
        -- the kind of NPC it was saved off, and only to somewhere the player
        -- has registered.  A favorite can outlive neither, so both are asked
        -- again every frame rather than saved with the entry.
        local live  = f.type == ui.near_kind;
        local known = warp_known(f.key, f);
        local over  = not veto
                      and mouse_x >= px and mouse_x <= px + w
                      and mouse_y >= ry and mouse_y < ry + POPUP_ROW;
        if (over) then
            hot_i, hot_live = i, live and known;
            hot_lock = (not known) and LOCK_TIP[f.type] or nil;
        end
        -- The selection, and over it the row under the cursor -- or while one
        -- is being dragged, the slot the cursor has carried it to rather than
        -- the one it was picked up from.  A row that is both reads brighter,
        -- since the two fills stack.
        if (i == sel) then
            light(ry);
        end
        if ((drag ~= nil and drag.i == i) or (drag == nil and over)) then
            light(ry);
        end
        local ty = ry + (POPUP_ROW - m.th) / 2;

        -- Unlike a popup row, a favorite comes back off disk, so its type is
        -- only as good as the settings file: one no toggle names draws no icon
        -- rather than looking one up under a nil.
        local art = WARP_ICON[f.type];
        local tex, iw, ih;
        if (art ~= nil) then tex, iw, ih = icon_texture(art); end
        if (tex ~= nil) then
            local sc = math.min(POPUP_ICON / iw, POPUP_ROW / ih);
            local ix = px + POPUP_PAD + (POPUP_ICON - iw * sc) / 2;
            local iy = ry + (POPUP_ROW - ih * sc) / 2;
            dl:AddImage(tonumber(ffi.cast('uint32_t', tex)),
                        { ix, iy }, { ix + iw * sc, iy + ih * sc },
                        { 0, 0 }, { 1, 1 },
                        live and COL_ICON or COL_ICON_OFF);
        end
        local col = (not known) and COL_POPUP_LOCK
                    or live and COL_POPUP_TEXT or COL_POPUP_OFF;
        dl:AddText({ px + m.lab_x, ty }, col, fav_text(f));
        local pos = fav_pos(f);
        if (pos ~= nil) then
            dl:AddText({ px + m.pos_x, ty }, col, pos);
        end
    end
    if (n == 0) then
        dl:AddText({ px + m.lab_x, py + (POPUP_ROW - m.th) / 2 },
                   COL_POPUP_OFF, ui.near_kind and FAV_NONE or FAV_EMPTY);
    end

    -- Same as the warp panel: one InvisibleButton over the whole thing so the
    -- press neither falls through to the map nor moves the window, with the
    -- hover tested as a rect rather than off the item.  It is also the last
    -- item either caller leaves behind, which is what a context popup hangs
    -- off.
    --
    -- A caller that wants the press can ask for a Dummy instead: it holds the
    -- same space open, so a window sized to its contents still comes out the
    -- size of the list, but takes no id and so leaves the press to the window
    -- it is drawn in.
    imgui.SetCursorScreenPos({ px, py });
    if (opts.grab == false) then
        imgui.Dummy({ w, h });
        return nil;
    end
    imgui.InvisibleButton('##ubermap_favs', { w, h });
    local fav_hot = mouse_x >= px and mouse_x <= px + w
                    and mouse_y >= py and mouse_y <= py + h;
    -- Held on to through a drag as well as a hover: a row dragged past the
    -- ends of the list puts the cursor outside the list, which would otherwise
    -- hand the same press to the map and pan it.
    ui.hot = ui.hot or fav_hot or ui.fav_drag ~= nil;
    -- Why a red favorite does not travel.  Not while the pad or the keys are
    -- driving: the cursor is not what a press would land on then.
    if (hot_lock ~= nil and not veto and not ui.gp_active) then
        imgui.SetTooltip(hot_lock);
    end

    if (ui.fav_drag ~= nil) then
        if (imgui.IsMouseDown(0)) then
            -- Held: the row rides to whichever slot the cursor is over, so the
            -- list reorders under the hand holding it.  Clamped to the list,
            -- since the cursor is free to leave it.
            local j = mm.clamp(
                math.floor((mouse_y - py) / POPUP_ROW) + 1, 1, n);
            if (j ~= ui.fav_drag.i) then
                fav_reorder(raw and raw[ui.fav_drag.i] or ui.fav_drag.i,
                            raw and raw[j] or j);
                ui.fav_drag.i, ui.fav_drag.moved = j, true;
            end
        elseif (imgui.IsMouseReleased(0)) then
            -- Let go: one that moved is a reorder to write out, one that never
            -- left its row is a plain click, so it travels.
            if (ui.fav_drag.moved) then
                settings.save();
            elseif (ui.fav_drag.live) then
                -- The saved entry carries every field warp_cmd reads, so it
                -- travels as the row it was taken from.
                local f   = favs[ui.fav_drag.i];
                local cmd = warp_cmd(f.key, f);
                if (cmd ~= nil) then
                    send_cmd(cmd);
                end
            end
            ui.fav_drag = nil;
        else
            -- The button came up while this list was not drawn, i.e. the map
            -- shut mid-drag.  The row keeps where it was dragged to; it just
            -- does not also travel.
            ui.fav_drag = nil;
        end
    elseif (imgui.IsMouseClicked(0) and hot_i ~= nil
            and ui.ctx == nil and not veto) then
        ui.fav_drag = { i = hot_i, live = hot_live, moved = false };
    end
    return hot_i;
end

--[[
* The gamepad favorites widget.  It rides with the NPC, not the map: up the
* moment a Home Point, Survival Guide, Unity Concord or Abyssea teleporter is
* in reach, gone the moment it is not, whether or not the map is open.
*
* That is also the only time the xinput handler takes a button -- one
* condition, written here and read there, so the two cannot come apart and
* leave the D-pad swallowed with nothing on screen to drive.
--]]
local function draw_fav_widget()
    -- Narrowed to the NPC in reach, so a list with nothing this NPC can send
    -- takes the widget off screen the same way an empty one does.
    local n = #fav_view();
    -- Only where it can be used -- stood at a warp NPC -- since the buttons it
    -- swallows are the game's everywhere else.  The map has nothing to do with
    -- it: walking up to a crystal is what puts it on screen, and the present
    -- handler polls the world on the frames the map is shut for exactly that.
    -- near_kind is a warp type, nil for no NPC in reach, or false before the
    -- first poll: both of the last two are falsy, so one test covers them.
    local on = cfg.widget and n > 0 and not ui.fw_hide and ui.near_kind;
    if (not on) then
        ui.fw_on, ui.fw_shown = false, false;
        -- A menu left open by a widget going off screen is gone with it, so
        -- the veto goes too: a stale one leaves the rows deaf on the way back.
        ui.fw_ctx = false;
        -- The arrows go back to the player with the list they were walking:
        -- a widget off screen holding the movement keys is a character that
        -- will not walk, with nothing on screen to say why.
        ui.fw_key = false;
        -- Walking off the NPC is what clears a dismissal: B puts the widget
        -- away for this visit, not for good.
        if (not ui.near_kind) then
            ui.fw_hide = false;
        end
        return;
    end
    ui.fw_on  = true;
    ui.fw_sel = mm.clamp(ui.fw_sel, 1, n);

    -- Asked for once, on the frame it comes up, and never again.  Ashita gives
    -- every addon the one ImGui context, and focusing a window closes every
    -- popup standing over it -- so a window that asks each frame spends the
    -- whole visit shutting other addons' combos and menus the moment they open,
    -- and its own along with them.
    --
    -- What used to make that per-frame ask look necessary was the map burying
    -- this on a click; the map carries NoBringToFrontOnFocus now, so a click
    -- down there leaves the stack alone and one ask on the way up holds.
    if (not ui.fw_shown) then
        ui.fw_shown = true;
        ui.fw_sel   = 1;
        imgui.SetNextWindowFocus();
    end

    local display = imgui.GetIO().DisplaySize;
    imgui.SetNextWindowPos({ UI_MARGIN, display.y * 0.5 }, ImGuiCond_FirstUseEver);
    -- No title bar, no ground and no border: the list draws its own panel,
    -- background and outline, and a window drawing its own around that is the
    -- second border and the margin of dead space outside it.  Sized to
    -- whatever the list needs, which with no padding is the list exactly.
    local flags = bit.bor(ImGuiWindowFlags_NoTitleBar,
                          ImGuiWindowFlags_NoBackground,
                          ImGuiWindowFlags_AlwaysAutoResize,
                          ImGuiWindowFlags_NoScrollbar,
                          ImGuiWindowFlags_NoScrollWithMouse);
    -- And moved the way the map is moved: a drag on a row belongs to the list
    -- and reorders it, so the window stays put unless shift is held.  With no
    -- padding there is no empty part of it left to drag by either, so shift
    -- also hands the list's own space back to the window below.
    local shift = imgui.GetIO().KeyShift;
    if (not shift) then
        flags = bit.bor(flags, ImGuiWindowFlags_NoMove);
    end
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0, 0 });
    -- 'true' rather than nil for the open flag: Ashita's binding reads a nil
    -- there as the two-argument Begin and throws the flags away, which puts
    -- back the title bar and the resize grip this is meant to be without.
    if (imgui.Begin('UberMap Favorites##ubermap_fw', true, flags)) then
        -- The panel's own list, drawn into this window rather than over the
        -- map: same rows, same colours, same drag to reorder.  No empty text,
        -- since a list with nothing in it took the widget down above.
        local m = fav_metrics();
        local mouse_x, mouse_y = imgui.GetMousePos();
        local px, py = imgui.GetCursorScreenPos();
        -- A cursor moving over the widget hands it to the mouse, whose own
        -- hover then says which row a click would send; the pad's row is drawn
        -- again from the next press of one.
        nav.mouse(imgui.IsWindowHovered(
            bit.bor(ImGuiHoveredFlags_ChildWindows, ImGuiHoveredFlags_RectOnly)));
        local hot_i = draw_fav_list(px, py, m, mouse_x, mouse_y,
                                    { sel = ui.gp_active and ui.fw_sel or nil,
                                      grab = not shift,
                                      veto = ui.fw_ctx });
        -- Mouse and D-pad share the one selection: a press of either button
        -- on a row moves it there, and a row dragged up or down the list
        -- carries the selection along with it.  A click puts the pad's
        -- highlight out, so the A after one lights the row it left and the A
        -- after that is what sends it.
        if (ui.fav_drag ~= nil) then
            ui.fw_sel = ui.fav_drag.i;
        elseif (hot_i ~= nil
                and (imgui.IsMouseClicked(0) or imgui.IsMouseClicked(1))) then
            ui.fw_sel = hot_i;
        end
        -- Right-click a row for the same one-item menu the map's panel offers.
        -- An ImGui popup rather than the hand-drawn menu draw_ctx_menu puts
        -- up: that one is drawn into the map window, which this window stands
        -- in front of.  It hangs off the list's InvisibleButton, and acts on
        -- the row the right-click just moved the selection to.
        --
        -- Placed under that row rather than at the cursor, the same as the
        -- map's menu and for the same reason: a menu lying over the row it
        -- came from puts its item and that row under the one click.  The rows
        -- stand down while it is up as well -- an ImGui popup blocks its own
        -- items from the ones below, but these rows are hand-tested rects and
        -- know nothing of it.
        --
        -- Behind the same shift test as the popup below, or the position is set
        -- for a popup that is never begun: Ashita shares one ImGui context
        -- across every addon, and a pending NextWindowPos nothing consumes
        -- lands on whatever window Begins next in the frame.
        if (not shift) then
            imgui.SetNextWindowPos({ px, py + POPUP_ROW * ui.fw_sel + POPUP_GAP });
        end
        -- Dressed in the panel's own colours, or this would be the one menu on
        -- screen wearing ImGui's: the ground and outline the lists draw
        -- themselves, and the hover the map's Hover picker sets.  Header* is
        -- what MenuItem lights with.
        imgui.PushStyleColor(ImGuiCol_PopupBg,
                             { 0.0627, 0.0627, 0.0627, 0.8784 });
        imgui.PushStyleColor(ImGuiCol_Border, { 0.0, 0.0, 0.0, 1.0 });
        imgui.PushStyleColor(ImGuiCol_HeaderHovered, cfg.col_hover);
        imgui.PushStyleColor(ImGuiCol_HeaderActive, cfg.col_hover);
        ui.fw_ctx = false;
        if (not shift and imgui.BeginPopupContextItem('##ubermap_fw_ctx')) then
            ui.fw_ctx = true;
            if (imgui.MenuItem('Remove point from favorites list')) then
                local f = fav_view()[ui.fw_sel];
                if (f ~= nil) then
                    -- One shorter from here: the selection is clamped back
                    -- onto the list at the top of the next draw, and an
                    -- emptied list takes the widget down with it.
                    fav_toggle(f.key, f);
                end
            end
            imgui.EndPopup();
        end
        imgui.PopStyleColor(4);
    end
    imgui.End();
    imgui.PopStyleVar();
end

--[[
* draw_map's panels live out here rather than inside it, and take the viewport
* they draw into as arguments.  Not for tidiness: Lua caps a function at 60
* upvalues, and one function holding every constant and helper the whole map
* view touches runs into that ceiling.  A panel of its own reaches for only
* what it draws.
--]]

local function draw_favs(origin_x, origin_y, view_w, view_h, mouse_x, mouse_y, row_h)
    -- The widget lists the same favorites in a window of its own, so the heart
    -- and the panel behind it stand down while it is on rather than putting
    -- one list on screen twice.  The panel is shut as well as hidden, so
    -- turning the widget back off does not bring a stale one back up.
    if (cfg.widget) then
        ui.favs_open = false;
        return;
    end

    -- Favorites, pinned to the bottom-left corner opposite Multisend.  The
    -- heart opens and shuts the list; the list itself grows upwards from it,
    -- so the heart stays where it was put however long the list gets.
    local fav_y = view_h - UI_MARGIN - row_h;
    if (icon_button('favs', FAV_ICON, UI_MARGIN, fav_y, row_h,
                    ui.favs_open and COL_MSS_ON or COL_MSS_OFF,
                    ui.favs_open and 'Hide favorites' or 'Show favorites')) then
        ui.favs_open = not ui.favs_open;
    end

    if (ui.favs_open) then
        -- The list the widget also puts up, drawn over the map: the panel is
        -- the frame around it, and everything inside -- rows, hover, drag to
        -- reorder, click to travel -- is draw_fav_list's.
        local m  = fav_metrics();
        local px = origin_x + UI_MARGIN;
        -- Clamped so a list longer than the viewport tucks against the top
        -- edge rather than running off it.
        local py = mm.clamp_box(origin_y + fav_y - POPUP_GAP - m.h,
                                m.h, origin_y, view_h);
        -- A warp popup lying over this panel eats its presses, the same way
        -- one over a toggle does: the popup is anchored on a marker, which can
        -- put it in this corner.  Read a frame late, which is harmless since
        -- neither panel moves while it is open.
        local hot_i = draw_fav_list(px, py, m, mouse_x, mouse_y,
                                    { veto = ui.warp_hot or ui.ctx_hot });

        -- Right-click a listed favorite to take it back off the list, the
        -- same menu that put it on.  Hung under the row rather than at the
        -- cursor: a menu lying over the row it was opened on puts its item and
        -- that row under the one click, which reads as picking both.  Rows are
        -- POPUP_ROW apart from the panel's top, so the hot row's bottom edge is
        -- its own index times the pitch.
        if (imgui.IsMouseClicked(1) and hot_i ~= nil and not ui.warp_hot) then
            local f = fav_view()[hot_i];
            ui.ctx = { x = mouse_x, ry = py + POPUP_ROW * (hot_i - 1),
                       fresh = true, key = f.key, row = f };
        end
    end
end

--[[
* The warp list for the zone point that was clicked.  See draw_favs above for
* why it is out here.
--]]
local function draw_warp_popup(origin_x, origin_y, view_w, view_h, mouse_x, mouse_y)
    -- Warp list for the zone point that was clicked, drawn after everything
    -- else so it lands on top of it.  Rows are read out in the order the
    -- data gives them, and clicking one sends its /uw.  No title row: the
    -- marker it hangs off already names the zone.
    if (ui.warp ~= nil) then
        local rows = warp_rows(ui.warp.label);
        if (rows == nil) then
            -- the toggles emptied it while it was open
            ui.warp   = nil;
            ui.gp_row = nil;
        else
            local pdl    = imgui.GetWindowDrawList();
            local _, th  = imgui.CalcTextSize(ui.warp.label);
            -- The grid reference is a column of its own, so every row's
            -- label starts at one x and every '(F-11)' at another.
            local labw, posw = 0, 0;
            for _, r in ipairs(rows) do
                -- Parenthesised: CalcTextSize hands back a height as well, and
                -- last in an argument list both of them would expand into the
                -- max.
                labw = math.max(labw, (imgui.CalcTextSize(r.label)));
                if (r.pos ~= nil) then
                    posw = math.max(posw, (imgui.CalcTextSize(r.pos)));
                end
            end
            local lab_x = POPUP_PAD * 2 + POPUP_ICON;
            local pos_x = lab_x + labw + POPUP_PAD;
            local w     = ((posw > 0) and (pos_x + posw) or (lab_x + labw))
                          + POPUP_PAD;
            local h = POPUP_ROW * #rows;

            -- Hung under the marker and clamped both ways, so a point near
            -- an edge does not push the panel off the viewport.
            local half = SCALE.px(ui.warp) / 2;
            local px = mm.clamp_box(
                mm.to_screen(ui.warp.x, ui.pan_x, ui.zoom, origin_x) - w / 2,
                w, origin_x, view_w);
            local py = mm.clamp_box(
                mm.to_screen(ui.warp.y, ui.pan_y, ui.zoom, origin_y) + half + POPUP_GAP,
                h, origin_y, view_h);
            -- Kept for the pad: Y hangs the favorites menu off the lit row,
            -- and the row's place on screen is this corner plus its pitch.
            ui.warp_px, ui.warp_py = px, py;

            pdl:AddRectFilled({ px, py }, { px + w, py + h }, COL_POPUP_BG,
                              0, ImDrawCornerFlags_All);
            pdl:AddRect({ px, py }, { px + w, py + h }, COL_OUTLINE,
                        0, ImDrawCornerFlags_All, ICON_BORDER);
            -- Kept inside the outline at both ends, so a lit first or last row
            -- does not paint over the border it sits against.  The same fill
            -- the favorites list lights its own rows with.
            local function light(ry)
                pdl:AddRectFilled(
                    { px + ICON_BORDER, math.max(ry, py + ICON_BORDER) },
                    { px + w - ICON_BORDER,
                      math.min(ry + POPUP_ROW, py + h - ICON_BORDER) },
                    COL_HOVER, 0, ImDrawCornerFlags_All);
            end
            -- hot_row is the row a left-click would send, so it is only
            -- ever a live one; hot_any is the row under the cursor whether
            -- it is live or not, which is what the right-click menu goes
            -- on - a destination can be favorited from anywhere, not only
            -- from in front of the NPC that travels to it.
            -- hot_lock is the tooltip a red row under the cursor should show,
            -- saying why that row will not travel.
            -- hot_ry is where hot_any's row starts, so the right-click menu
            -- can be hung under it rather than over it.
            local hot_row, hot_any, hot_lock, hot_ry = nil, nil, nil, nil;
            for i, r in ipairs(rows) do
                local ry = py + POPUP_ROW * (i - 1);
                -- A row only travels from the kind of NPC the player is
                -- stood at, so one of another kind is drawn dim and takes
                -- no hover or press.  Listed rather than dropped: the row
                -- says the destination exists and what to walk up to.
                -- ui.near_kind is false before the first poll and nil while
                -- nothing is in reach; neither is a type, so both read as
                -- out of reach.
                local live = r.type == ui.near_kind;
                -- A destination the player has never stood at is refused at
                -- the NPC whether or not they are in front of one, so it is
                -- drawn red and takes no press either.
                local known = warp_known(ui.warp.label, r);
                -- The hover is drawn straight into the list rather than
                -- coming off an ImGui item, for the same reason the click
                -- below is tested by hand: the panel is one InvisibleButton.
                -- The right-click menu is drawn over this panel and hangs off
                -- one of its own rows, so a row under it takes neither the
                -- hover nor either button: the menu is what the cursor is on.
                local over = not ui.ctx_hot
                             and mouse_x >= px and mouse_x <= px + w
                             and mouse_y >= ry and mouse_y < ry + POPUP_ROW;
                if (over) then
                    hot_any  = r;
                    hot_ry   = ry;
                    hot_lock = (not known) and LOCK_TIP[r.type] or nil;
                end
                -- The gamepad's landing, lit while the pad is what is
                -- driving the map, the way the favorites widget lights its own
                -- selection.  Out while the mouse has it, which lights the row
                -- under the cursor and nothing else.  A row that is both reads
                -- brighter, the two fills stacking.
                if (ui.gp_active and i == ui.gp_row) then
                    light(ry);
                end
                if (live and known and over) then
                    hot_row = r;
                    light(ry);
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
                -- Red first: a destination nobody has registered will not
                -- travel whether or not it was saved, and that is the thing
                -- worth knowing.  Then green for a row already on the list, so
                -- the panel says what is saved without opening the heart.
                -- Asked per row per frame like the two tests above it, since a
                -- Y press on the row underneath can save one while this panel
                -- is on screen.
                local col = (not known) and COL_POPUP_LOCK
                            or (fav_index(ui.warp.label, r) ~= nil)
                               and COL_POPUP_FAV
                            or live and COL_POPUP_TEXT or COL_POPUP_OFF;
                pdl:AddText({ px + lab_x, ty }, col, r.label);
                if (r.pos ~= nil) then
                    pdl:AddText({ px + pos_x, ty }, col, r.pos);
                end
            end

            -- An InvisibleButton over the panel takes the press, so it
            -- neither falls through to the map nor starts a window move.
            -- The hover test is the rect and not IsItemHovered: ImGui gives
            -- hover to the first item that claims it, and the toolbar row is
            -- submitted before this one.  Feeding ui.hot keeps the map
            -- from panning or zooming underneath; a click anywhere else
            -- closes the panel.
            imgui.SetCursorPos({ px - origin_x, py - origin_y });
            imgui.InvisibleButton('##ubermap_warps', { w, h });
            local warp_hot = mouse_x >= px and mouse_x <= px + w
                             and mouse_y >= py and mouse_y <= py + h;
            ui.hot = ui.hot or warp_hot;
            ui.warp_hot = warp_hot;
            -- Straight from the panel's own button rather than through
            -- item_tip, which vetoes on this very panel lying over things.
            if (hot_lock ~= nil and not ui.gp_active) then
                imgui.SetTooltip(hot_lock);
            end
            -- A click while the right-click menu is up belongs to the menu,
            -- which is drawn after this and reads the same press.  Without
            -- the guard, picking an item would close the panel out from
            -- under it as a click landing outside the panel's rect.
            if (imgui.IsMouseClicked(0) and ui.ctx == nil) then
                if (not warp_hot) then
                    ui.warp = nil;
                elseif (hot_row ~= nil) then
                    local cmd = warp_cmd(ui.warp.label, hot_row);
                    if (cmd ~= nil) then
                        send_cmd(cmd);
                    end
                end
            end
            -- Right-click opens the favorites menu on the row under the
            -- cursor, live or not.  Under that row rather than at the cursor,
            -- so the menu's item and the row it came from are never both under
            -- the same click.
            if (imgui.IsMouseClicked(1) and hot_any ~= nil) then
                ui.ctx = { x = mouse_x, ry = hot_ry, fresh = true,
                           key = ui.warp.label, row = hot_any };
            end
        end
    end
    if (ui.warp == nil) then
        ui.warp_hot = false;
    end
end

--[[
* The favorites right-click menu.  See draw_favs above for why it is out here.
--]]
local function draw_ctx_menu(origin_x, origin_y, view_w, view_h, mouse_x, mouse_y)
    -- Out unless the block below puts it back: a menu that is not up is not
    -- over anything, and a stale one would leave the panels underneath deaf.
    ui.ctx_hot = false;
    -- The right-click menu, drawn after both panels so it lands on top of
    -- whichever one it was opened from.  Hand-drawn like they are rather
    -- than an ImGui popup: the panels are one InvisibleButton each and have
    -- no per-row item for a popup to hang off.
    if (ui.ctx ~= nil) then
        local cdl   = imgui.GetWindowDrawList();
        local text  = (fav_index(ui.ctx.key, ui.ctx.row) ~= nil)
            and 'Remove point from favorites list'
            or 'Add point to favorites list';
        local tw, th = imgui.CalcTextSize(text);
        local w = tw + POPUP_PAD * 2;
        local h = POPUP_ROW;
        -- Hung under the row it was opened on, at the cursor's own column,
        -- and flipped above that row when there is no room below.  Never over
        -- it: a menu lying across the row would put its item and that row
        -- under the one click, which reads as picking both.  ui.ctx.ry is the
        -- row's top, so the two placements are its own pitch either side --
        -- plus POPUP_GAP, the same gap a panel keeps off its marker, so the
        -- two edges are apart rather than merely not overlapping.
        local px = mm.clamp_box(ui.ctx.x, w, origin_x, view_w);
        local py = ui.ctx.ry + POPUP_ROW + POPUP_GAP;
        if (py + h > origin_y + view_h) then
            py = ui.ctx.ry - h - POPUP_GAP;
        end
        -- Clamped last, so a row against either edge still puts the whole item
        -- on screen.
        py = mm.clamp_box(py, h, origin_y, view_h);

        cdl:AddRectFilled({ px, py }, { px + w, py + h }, COL_POPUP_BG,
                          0, ImDrawCornerFlags_All);
        cdl:AddRect({ px, py }, { px + w, py + h }, COL_OUTLINE,
                    0, ImDrawCornerFlags_All, ICON_BORDER);
        local ctx_hot = mouse_x >= px and mouse_x <= px + w
                        and mouse_y >= py and mouse_y <= py + h;
        -- What everything drawn before this reads next frame to know the
        -- cursor is on the menu and not on itself.
        ui.ctx_hot = ctx_hot;
        -- Lit under the cursor, and lit outright while the pad is driving: the
        -- menu is one item, so a pad opening it is already on the only thing
        -- there is to pick, and an unlit item would read as nothing to press.
        if (ctx_hot or ui.gp_active) then
            cdl:AddRectFilled({ px + ICON_BORDER, py + ICON_BORDER },
                              { px + w - ICON_BORDER, py + h - ICON_BORDER },
                              COL_HOVER, 0, ImDrawCornerFlags_All);
        end
        cdl:AddText({ px + POPUP_PAD, py + (h - th) / 2 }, COL_POPUP_TEXT, text);

        imgui.SetCursorPos({ px - origin_x, py - origin_y });
        imgui.InvisibleButton('##ubermap_ctx', { w, h });
        ui.hot = ui.hot or ctx_hot;

        -- Any press closes the menu; one on the item runs it first.  Both
        -- buttons, so a second right-click dismisses it rather than leaving
        -- two menus' worth of state behind.  The press that opened it is
        -- the same one this test reads, since the panels are drawn before
        -- this block, so the opening frame is skipped over.
        if (ui.ctx.fresh) then
            ui.ctx.fresh = false;
        elseif (imgui.IsMouseClicked(0) or imgui.IsMouseClicked(1)) then
            if (ctx_hot and imgui.IsMouseClicked(0)) then
                fav_toggle(ui.ctx.key, ui.ctx.row);
            end
            ui.ctx = nil;
        end
    end
end

--[[
* The whole of the map window's contents, drawn back to front: the map image
* and its markers, then the toolbar and search box over them, then the config
* strip, the point editor and the warp panels stacked on top.
*
* Everything here is inside the ubermap_view child, so the search box, the
* config numbers and the editor's two fields are all tab stops in one ImGui
* focus list -- ImGui's own Tab walks between them from WNDPROC, which is a
* separate path from the Tab nav.press reads off DirectInput.
--]]
local function draw_map(view_w, view_h)
    -- The minimum zoom covers the viewport, so the map never letterboxes.
    -- Re-applied every frame because growing the window raises the floor.
    local map_w, map_h = map_size();
    local cover = mm.cover_zoom(map_w, map_h, view_w, view_h);
    ui.zoom = mm.clamp(ui.zoom or cover, cover, MAX_ZOOM);

    -- The gamepad's presses, acted on here rather than where they arrive: the
    -- zooms they ask for need the viewport size, and only a frame knows that.
    -- Ahead of the mouse below, so a press and a click on the same frame land
    -- in the order they were made.
    nav.pump(view_w, view_h);

    -- The viewport's top-left, captured before the child is opened.
    local origin_x, origin_y = imgui.GetCursorScreenPos();
    local mouse_x, mouse_y   = imgui.GetMousePos();

    -- The map child covers the whole content region, so it is the window ImGui
    -- reports as hovered.  Without ChildWindows this test is false exactly when
    -- the cursor is over the map, which kills both zoom and pan.  RectOnly
    -- keeps it true mid-drag, when an active item would otherwise block it.
    local hovered = imgui.IsWindowHovered(
        bit.bor(ImGuiHoveredFlags_ChildWindows, ImGuiHoveredFlags_RectOnly));

    -- A cursor moving over any of that -- map, toolbar or panel -- is the hand
    -- leaving the pad, and takes the pad's highlight with it.  After the pump
    -- rather than before, so a press and a nudge of the mouse on the same
    -- frame end the way they would on two: with the mouse in charge.
    nav.mouse(hovered);

    -- Ignore the mouse outside the map, and while shift is held, so a
    -- shift-drag moves the window instead of panning underneath it.  Widgets are
    -- skipped too, so a press in one works it instead of panning the map.
    -- IsAnyItemActive cannot stand in for that flag: ImGui sets ActiveId to the
    -- window's MoveId on any press in blank space, NoMove included, so it is
    -- true for exactly the drag that should pan.
    local shift    = imgui.GetIO().KeyShift;
    local over_map = hovered and not shift and not ui.hot
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
                -- A click is the mouse's own way down the same nesting the
                -- gamepad walks, so B backs out of one as readily as the
                -- other: whichever marker was gone into is the one the way
                -- back out lands on.
                if (zoom_to_group(ui.press.label, view_w, view_h)) then
                    ui.gp_from = ui.press;
                end
            else
                -- A zone nothing warps to leaves the panel shut rather than
                -- opening an empty one.
                ui.warp = (warp_rows(ui.press.label) ~= nil) and ui.press or nil;
                -- Opened with the cursor, so no row is lit: the hover is what
                -- says which one a click would send, and a second highlight
                -- sitting on the top row would only argue with it.
                ui.gp_row = nil;
            end
            ui.press = nil;
        end

        -- The toolbar's height, and so the height every icon on it is fitted
        -- to: widths follow from each art's own aspect, so Tools sizes the
        -- whole line by this one number.
        local row_h = imgui.GetFrameHeight() * ROW_H_MULT * cfg.scale_tool / 100;

        -- Every widget on the row below ORs into ui.hot, which is what
        -- keeps the map from panning or zooming underneath one.  Cleared here
        -- rather than assigned by whichever widget happens to be first.  Read a
        -- frame late by over_map above, which is fine: a click focuses a widget
        -- before the drag threshold is ever crossed.
        ui.hot = false;

        -- Past/present switch, first on the toolbar row.  The art names the map
        -- you are on, not the one the press takes you to.  The switch is
        -- recorded and applied after the frame, because set_time clears the
        -- zoom that the rest of this frame still reads.
        local other = (ui.time == 'present') and 'past' or 'present';
        local time_hit, time_w = icon_button('time', ui.time .. '.png',
                                             UI_MARGIN, UI_MARGIN, row_h, COL_ICON,
                                             'Switch to a map of the ' .. other);
        if (time_hit) then
            ui.next_time = other;
        end
        -- Search box, next on the toolbar row.  Typing in it fades back every
        -- marker whose label does not match, which is icon_dim's doing; nothing
        -- is hidden, so the map keeps its shape while a search narrows it.
        local search_x = UI_MARGIN + time_w + TOGGLE_GAP;
        -- Sized off the row it sits on, text included: Tools scales the whole
        -- line, and a taller box whose glyphs stayed put would buy only padding.
        -- The font is a window property, so it goes straight back below -- the
        -- toggles are drawn on this same row.
        local search_h = imgui.GetFrameHeight() * SEARCH_H_MULT
                         * cfg.scale_tool / 100;
        imgui.SetWindowFontScale(cfg.scale_tool / 100);
        imgui.PushStyleVar(ImGuiStyleVar_FramePadding,
                           { 6, math.max(0, (search_h - imgui.GetFontSize()) / 2) });
        -- Nudged down by half of what it gives up, so the shorter box sits on
        -- the middle of the row rather than riding its top edge.
        imgui.SetCursorPos({ search_x, UI_MARGIN + (row_h - search_h) / 2 });
        -- The room the icons after the box need, at the size Tools draws them.
        local tools_w = TOGGLE_GAP * 3
                        + icon_width(WARP_ITEM_ICON, row_h)
                        + icon_width(RING_ITEM_ICON, row_h);
        for _, file in ipairs(TOGGLES) do
            tools_w = tools_w + icon_width(file, row_h) + TOGGLE_GAP;
        end
        -- The row is placed by absolute cursor position and does not wrap, so a
        -- full-width box would carry the toggles and the warp icons off the edge
        -- with no way to press them back.  A share of the width instead, which
        -- leaves FIELD_W alone at 1080p and above; Search W widens that share,
        -- but never into the room the icons beside it need.  Never below the
        -- share it always had, so a large Tools eats its own room, not the box's.
        local base     = math.min(FIELD_W, view_w * 0.35);
        local search_w = math.min(base * cfg.scale_searchw / 100,
                                  math.max(base, view_w - search_x
                                                 - tools_w - UI_MARGIN));
        imgui.SetNextItemWidth(search_w);
        -- Handed the keyboard on the frame after an open, when the setting asks
        -- for it.  ImGui takes the focus request for the next item drawn, so
        -- this sits right on top of the box.
        if (ui.focus_next) then
            ui.focus_next = false;
            imgui.SetKeyboardFocusHere();
        end
        -- Tab out of the box.  ImGui hands the caret back on its own from any
        -- item it stops being shown, so the box is drawn under a second id for
        -- the one frame that asks for it: same text, same hint, same width, so
        -- nothing on screen moves, and the frame after goes back to the first
        -- id with the caret gone.  There is no call that drops it outright --
        -- Ashita's ImGui exposes no ClearActiveID -- and handing the focus to a
        -- neighbour instead would leave it sat on the toggle beside the box.
        imgui.InputTextWithHint(ui.search_blur and '##ubermap_search_tab'
                                or '##ubermap_search',
                                'Search', ui.search, FIELD_MAX);
        ui.search_blur = false;
        imgui.PopStyleVar();
        imgui.SetWindowFontScale(1.0);
        -- Only while the mouse is working the field, the way the editor's rows
        -- below feed it: IsItemActive stays true for the whole time the caret
        -- sits in the box, and on its own it would leave the map unable to
        -- zoom, pan or be clicked for as long as a search was being typed --
        -- including, with Search Focus On Open ticked, the frame the map
        -- opens in.  Held mouse included, so dragging a selection across the
        -- text does not pan.
        ui.hot = ui.hot or imgui.IsItemHovered()
                 or (imgui.IsItemActive() and imgui.IsMouseDown(0));
        -- The caret being in the box, which is the whole of it rather than the
        -- mouse's share above: the arrows walk the text, Enter and Escape leave
        -- the field, and none of the three are the map's while it is being
        -- typed into -- including, with Search Focus On Open ticked, the frame
        -- the map opens in.
        ui.kb_typing = ui.kb_typing or imgui.IsItemActive();

        -- Reframed on every change to the text, so narrowing a search closes in
        -- on what is left.  Only on a change: refitting every frame would fight
        -- the wheel and the drag for the rest of the search.  Emptying the box
        -- goes the other way and pulls all the way back out to the whole map:
        -- clearing a search is how the next one starts, so the view starts over
        -- with it rather than being left inside the last match.
        if (ui.search[1] ~= ui.search_at) then
            ui.search_at = ui.search[1];
            if (ui.search_at ~= '') then
                zoom_to_search(view_w, view_h);
            else
                zoom_to_map(view_w, view_h);
                ui.focus = nil;
            end
        end

        -- Toggle icons, sharing the search box's line.
        local tx_at = search_x + search_w + TOGGLE_GAP;
        for _, file in ipairs(TOGGLES) do
            local hit, tw = icon_button('toggle_' .. file, file,
                                        tx_at, UI_MARGIN, row_h,
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
            icon_button('warpitem', WARP_ITEM_ICON, tx_at, UI_MARGIN, row_h,
                        ui.errand.has_warp and COL_ICON or COL_ICON_OFF,
                        ui.errand.has_warp and 'Use Instant Warp scroll'
                            or 'No Instant Warp scroll in inventory');
        if (warp_hit and ui.errand.has_warp) then
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
        if (icon_button('warpring', RING_ITEM_ICON, tx_at, UI_MARGIN, row_h,
                        ui.ring == 'use' and COL_ICON or COL_ICON_OFF, ring_tip)) then
            if (ui.ring == 'use') then
                send_cmd(RING_ITEM_CMD);
            elseif (ui.ring == 'equip') then
                queue_cmd(('/equip ring1 "%s" %d'):fmt(RING_ITEM_NAME, ui.ring_bag or 0));
                ui.ring_at = os.clock();
                ui.ring    = 'wait';  -- held here until the next poll reads it back
            end
        end

        -- Config panel, pinned to the viewport's top-right corner: the face
        -- pulldown, the Size box, the scale boxes and the four colour pickers,
        -- one to a row.  ImGui writes into the tables cfg keeps and repack_cols
        -- turns those back into the words the draw lists take, so the map
        -- retints as a picker moves; the scales are read straight off cfg, so it
        -- resizes as an arrow is held.  NoInputs leaves only the swatch, which
        -- opens the picker on click, and the name ImGui draws beside it labels
        -- the row.  Widgets stay at ImGui's own frame height rather than the
        -- toolbar's doubled one: a stacked panel has the room.  Behind
        -- '/um config' rather than the point editor: recolouring is something a
        -- player does to their own map, while the editor moves the markers
        -- everybody gets.
        if (ui.config) then
            local pick_flags = bit.bor(ImGuiColorEditFlags_NoInputs,
                                       ImGuiColorEditFlags_AlphaBar,
                                       ImGuiColorEditFlags_AlphaPreview);
            local picks = { { 'Text',       cfg.col_text },
                            { 'Outline',    cfg.col_outline },
                            { 'Background', cfg.col_bg },
                            { 'Hover',      cfg.col_hover } };
            -- The rows that are not about how the map looks, on the end of
            -- the panel: the name, the box ImGui edits, and the cfg key it
            -- writes.  The box is built from cfg on the frame it is drawn
            -- rather than kept, so a toggle made from '/um' shows here without
            -- anything having to be told about it.
            local checks = { { 'Warp NPC Opens Map',
                               { cfg.autoopen }, 'autoopen' },
                             { 'Favorites Widget',
                               { cfg.widget }, 'widget' },
                             { 'EXP Guide Pickup',
                               { cfg.guide }, 'guide' },
                             { 'Search Focus On Open',
                               { cfg.focus }, 'focus' },
                             { 'Hide Uberwarp Chat',
                               { cfg.quiet }, 'quiet' } };
            -- Every InputInt row: the name it is drawn under, the box ImGui
            -- edits, the cfg key it writes, and the bounds and steps it takes.
            -- Size is one of them rather than a case of its own.
            local nums = { { 'Size', ui.font_px, 'font_px',
                             FONT_PX.min, FONT_PX.max, 1, 4 } };
            for _, row in ipairs(SCALE.rows) do
                table.insert(nums, { row[2], ui.scale[row[1]], row[1],
                                     SCALE.min, SCALE.max, SCALE.step, SCALE.fast });
            end
            -- The widest row decides the panel's width: an InputInt wants its
            -- digits and the pair of step buttons ImGui puts on the end of it, a
            -- swatch is one frame square, and every row carries its name to the
            -- right of that.
            local fh      = imgui.GetFrameHeight();
            -- InputInt spends the width it is given on the field and both
            -- step buttons, with ImGui's spacing and frame padding coming out
            -- of the field's share, so the digits are asked for with slack:
            -- three digits of it, at the widest a box holds -- the scales'
            -- three, not the Size box's two, which clipped every scale row.
            local size_w  = fh * 2 + imgui.CalcTextSize('000000');
            local panel_w = 0;
            for _, num in ipairs(nums) do
                panel_w = math.max(panel_w,
                                   size_w + POPUP_PAD + imgui.CalcTextSize(num[1]));
            end
            for _, pick in ipairs(picks) do
                panel_w = math.max(panel_w,
                                   fh + POPUP_PAD + imgui.CalcTextSize(pick[1]));
            end
            -- A checkbox is a frame square with its name beside it, the same
            -- shape as a swatch -- and these names are long enough to be what
            -- decides the panel's width.
            for _, chk in ipairs(checks) do
                panel_w = math.max(panel_w,
                                   fh + POPUP_PAD + imgui.CalcTextSize(chk[1]));
            end
            -- The pulldown carries no name, so it spends the panel's whole width
            -- on the face and the arrow ImGui puts on its end -- one frame's
            -- worth, the same as a swatch.
            for _, name in ipairs(FONT_PX.list) do
                panel_w = math.max(panel_w, fh + POPUP_PAD + imgui.CalcTextSize(
                    (name ~= '') and name or FONT_PX.own_name));
            end
            panel_w = panel_w + POPUP_PAD * 2;
            local pitch   = fh + TOGGLE_GAP;
            -- The face pulldown, then every numeric row, then the pickers,
            -- then the checkboxes on the end.
            local panel_h = pitch * (#picks + #nums + #checks + 1) - TOGGLE_GAP
                            + POPUP_PAD * 2;
            local px      = view_w - UI_MARGIN - panel_w;
            local py      = UI_MARGIN;

            -- Drawn like the warp and favorites panels rather than as a window
            -- of its own: this one lives inside the map child, and a plate under
            -- it is what keeps ImGui's own label text off the map art.
            local ldl = imgui.GetWindowDrawList();
            ldl:AddRectFilled({ origin_x + px, origin_y + py },
                              { origin_x + px + panel_w, origin_y + py + panel_h },
                              COL_POPUP_BG, 0, ImDrawCornerFlags_All);
            ldl:AddRect({ origin_x + px, origin_y + py },
                        { origin_x + px + panel_w, origin_y + py + panel_h },
                        COL_OUTLINE, 0, ImDrawCornerFlags_All, ICON_BORDER);
            -- The panel is a solid block over the map, so the gaps between its
            -- rows have to swallow a drag as much as the widgets do.  Tested as
            -- a rect for that reason rather than off any one item.
            ui.hot = ui.hot
                     or (mouse_x >= origin_x + px
                         and mouse_x <= origin_x + px + panel_w
                         and mouse_y >= origin_y + py
                         and mouse_y <= origin_y + py + panel_h);

            local row_x, row_y = px + POPUP_PAD, py + POPUP_PAD;

            -- Face pulldown, first row of the panel.  No name beside it: the row
            -- it sits on says what it is, and the panel is narrow enough that a
            -- name would come out of the pulldown's own width.  Rows are drawn
            -- in ImGui's own font rather than in the face they name -- previewing
            -- one means pushing it per row, and the point of this panel is the
            -- map.
            imgui.SetCursorPos({ row_x, row_y });
            imgui.SetNextItemWidth(panel_w - POPUP_PAD * 2);
            local shown = (cfg.font ~= '') and cfg.font or FONT_PX.own_name;
            if (imgui.BeginCombo('##ubermap_font', shown, ImGuiComboFlags_None)) then
                for _, name in ipairs(FONT_PX.list) do
                    if (imgui.Selectable(((name ~= '') and name or FONT_PX.own_name)
                                         .. '##ubermap_font_' .. name,
                                         name == cfg.font)) then
                        cfg.font = name;
                        settings.save();
                    end
                end
                imgui.EndCombo();
                -- The list stands outside the panel's rect, so a drag over it
                -- would pan the map underneath without this.
                ui.hot = true;
            end
            ui.hot = ui.hot or imgui.IsItemActive();

            -- The Size box and the scale boxes, stacked under the pulldown.
            -- The map reads cfg every frame, so a scale takes effect as its
            -- arrows are held rather than when the panel closes.
            for i, num in ipairs(nums) do
                imgui.SetCursorPos({ row_x, row_y + pitch * i });
                imgui.SetNextItemWidth(size_w);
                if (imgui.InputInt(num[1] .. '##ubermap_' .. num[3],
                                   num[2], num[6], num[7])) then
                    -- Clamped rather than trusted: a box takes a typed
                    -- number as well as its step buttons, and a zero or a
                    -- four-digit one is a map with no labels or no markers on
                    -- it.  Written back so the box shows what was taken.
                    cfg[num[3]] = math.min(math.max(num[2][1], num[4]), num[5]);
                    num[2][1]   = cfg[num[3]];
                    ui.cfg_dirty = true;
                end
                -- Held while a box has the keyboard, which is outside the
                -- panel's own rect once a picker popup is up and so is not
                -- covered by the test above.  Also what defers the save:
                -- InputInt reports a change per keystroke, so a number typed a
                -- digit at a time would be a save per digit.  Only the save --
                -- cfg takes every keystroke, so a '2' on the way to '24' clamps
                -- up to the minimum and the map draws at it.
                ui.cfg_typing = ui.cfg_typing or imgui.IsItemActive();
            end
            ui.hot = ui.hot or ui.cfg_typing;

            for i, pick in ipairs(picks) do
                imgui.SetCursorPos({ row_x, row_y + pitch * (i + #nums) });
                if (imgui.ColorEdit4(pick[1], pick[2], pick_flags)) then
                    -- Repacked on the frame it moved, so the map retints under
                    -- the picker rather than at the end of the drag.
                    repack_cols();
                    ui.cfg_dirty = true;
                end
                ui.hot = ui.hot or imgui.IsItemActive();
            end

            -- The checkboxes, last rows of the panel.  Saved on the spot
            -- rather than deferred through cfg_dirty like the pickers and the
            -- boxes: a checkbox reports its change once, not once a frame for
            -- as long as the mouse is held.
            for i, chk in ipairs(checks) do
                imgui.SetCursorPos({ row_x,
                                     row_y + pitch * (#nums + #picks + i) });
                if (imgui.Checkbox(chk[1] .. '##ubermap_' .. chk[3], chk[2])) then
                    cfg[chk[3]] = chk[2][1];
                    -- Ticking it back on is asking to see it, and a B press
                    -- earlier in this visit is otherwise only cleared by
                    -- walking off the NPC.
                    if (chk[3] == 'widget') then
                        ui.fw_hide = false;
                    end
                    settings.save();
                end
                ui.hot = ui.hot or imgui.IsItemActive();
            end
            -- The write itself is flushed from d3d_present rather than here, so
            -- a change still reaches the file on the frame the panel or the map
            -- is closed out from under it.
        end

        -- Everything below the toolbar row stacks from here.
        local edit_y = UI_MARGIN + row_h + TOGGLE_GAP;

        -- Editor panel, stacked under the toolbar row.  Its widgets feed
        -- ui.hot too, so dragging in them edits text instead of panning.
        if (ui.edit) then
            if (ui.sel == nil) then
                outlined_text(imgui.GetWindowDrawList(),
                              origin_x + UI_MARGIN, origin_y + edit_y,
                              'ctrl+click the map to add or grab a point');
            else
                -- Rows are placed by hand rather than by flow, so the panel does
                -- not depend on the child's cursor advancing a particular amount.
                imgui.SetCursorPos({ UI_MARGIN, edit_y });
                imgui.SetNextItemWidth(FIELD_W);
                imgui.InputTextWithHint('##ubermap_pt_name', 'Name', ui.edit_name, FIELD_MAX);
                local hot = imgui.IsItemActive() or imgui.IsItemHovered();

                imgui.SetCursorPos({ UI_MARGIN, edit_y + EDIT_ROW });
                imgui.SetNextItemWidth(FIELD_W);
                imgui.InputTextWithHint('##ubermap_pt_group', 'Group', ui.edit_group, FIELD_MAX);
                hot = hot or imgui.IsItemActive() or imgui.IsItemHovered();

                if (ui.edit_name[1] ~= ui.sel.label or ui.edit_group[1] ~= ui.sel.group) then
                    ui.sel.label, ui.sel.group = ui.edit_name[1], ui.edit_group[1];
                    ui.dirty = true;
                end

                imgui.SetCursorPos({ UI_MARGIN, edit_y + EDIT_ROW * 2 });
                imgui.Text(('%d, %d'):fmt(ui.sel.x, ui.sel.y));
                imgui.SetCursorPos({ UI_MARGIN, edit_y + EDIT_ROW * 3 });
                if (imgui.Button('Delete')) then
                    delete_point(ui.sel);
                    ui.sel = nil;
                end
                ui.hot = ui.hot or hot or imgui.IsItemHovered();
            end
        end

        -- Source-image pixel under the cursor, for typing into a point's
        -- coordinates.  Independent of zoom and pan, so the same spot on the map
        -- always reads the same numbers.
        if (ui.edit and over_map) then
            local mx = math.floor(mm.to_map(mouse_x, ui.pan_x, ui.zoom, origin_x));
            local my = math.floor(mm.to_map(mouse_y, ui.pan_y, ui.zoom, origin_y));
            -- Twice the size the rest of the map's text is at, rather than twice
            -- ImGui's own: the readout is a number being read off a map that has
            -- already been sized, so it follows the Size box up and down.
            outlined_text(imgui.GetWindowDrawList(), origin_x + 6, origin_y + view_h - 30,
                          ('%d, %d'):fmt(mx, my), false,
                          ui.font_scale * READOUT_SCALE);
        end

        -- Multisend, pinned to the viewport's bottom-right corner.  Art only:
        -- with no icon there is nothing to press and the map keeps sending the
        -- way it always did.
        local mss_w = icon_width(MSS_ICON, row_h);
        if (icon_button('mss', MSS_ICON, view_w - UI_MARGIN - mss_w,
                        view_h - UI_MARGIN - row_h, row_h,
                        cfg.mss and COL_MSS_ON or COL_MSS_OFF,
                        cfg.mss and 'Multisend on: warps go to every character'
                                 or 'Multisend off: warps go to this character only')) then
            cfg.mss = not cfg.mss;
            settings.save();
        end

        -- The three panels, in the order they stack: favorites over the map,
        -- a zone's warp list over that, and the right-click menu over both.
        draw_favs(origin_x, origin_y, view_w, view_h, mouse_x, mouse_y, row_h);
        draw_warp_popup(origin_x, origin_y, view_w, view_h, mouse_x, mouse_y);
        draw_ctx_menu(origin_x, origin_y, view_w, view_h, mouse_x, mouse_y);
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

-- The one place the font atlas may be written to: outside any frame, once per
-- load.  Everything after this only ever pushes what was baked here.
ashita.events.register('load', 'ubermap_load', function ()
    FONT_PX.bake_all();
end);

ashita.events.register('d3d_present', 'ubermap_present', function ()
    local now = os.clock();
    pump_escape(now);
    pump_guide(now);

    -- Has the cursor moved since the last frame?  Answered here, ahead of
    -- everything that draws, so the map and the widget both read the one
    -- answer however they are ordered.  The first frame has nothing to compare
    -- against and counts as still, or loading the addon with the cursor
    -- anywhere near the map would read as the mouse taking over.
    local px, py = imgui.GetMousePos();
    ui.ptr_moved = (ui.ptr_x ~= nil) and (px ~= ui.ptr_x or py ~= ui.ptr_y);
    ui.ptr_x, ui.ptr_y = px, py;

    -- One write per drag rather than one per frame of it: a colour picker
    -- reports a change on every frame the mouse moves inside it, and the Size
    -- box does the same for every keystroke typed into it and for as long as a
    -- step button is held down.  Checked here rather than on the panel, and
    -- against the frame before it, so a change still lands on the frame the
    -- panel or the map is closed out from under it.
    if (ui.cfg_dirty and not imgui.IsMouseDown(0) and not ui.cfg_typing) then
        ui.cfg_dirty = false;
        settings.save();
    end
    ui.cfg_typing = false;
    -- Cleared here and written by the draw, so a map put away with the caret in
    -- the search box does not leave the keys deaf behind it.
    ui.kb_typing  = false;

    -- What the map's text is scaled by, resolved once here rather than per
    -- label.  Ahead of the map, and of the readout and labels it draws through
    -- outlined_text.
    --
    -- A settings file that has never been near the Size box carries zero, which
    -- stands for the size ImGui's own font already comes out at: there is no
    -- frame to ask that of until now, so it is answered here and written back
    -- the first time, and the box opens showing the number rather than a nought.
    -- Clamped on the way in like every other write to it, or an Ashita
    -- configured with a font outside the bounds would put a number in the box
    -- that the next login silently shrinks.
    local base = imgui.GetFontSize();
    if (cfg.font_px == FONT_PX.own) then
        cfg.font_px   = math.min(math.max(math.floor(base + 0.5), FONT_PX.min),
                                 FONT_PX.max);
        ui.font_px[1] = cfg.font_px;
    end
    -- A picked face is baked at FONT_PX.bake rather than at whatever ImGui's own
    -- font measures, and pushing it is what the scale then multiplies, so the
    -- divisor has to follow the face or the Size box would mean two different
    -- things depending on which one is up.
    if (FONT_PX.face()) then base = FONT_PX.bake; end
    ui.font_scale = (base > 0) and (cfg.font_px / base) or 1.0;

    -- Ahead of everything else, and unconditionally: the widget is up on the
    -- NPC alone, so it has to be drawn on the frames the map returns out of
    -- below as well as the ones it does not.
    --
    -- Which means the world has to be read on those frames too, since that is
    -- what puts the widget up.  Kept behind the toggle: with the widget off
    -- nothing outside the map reads this, and the poll walks a thousand-odd
    -- entity slots.  The map's own call below stands for when it is off, and
    -- costs nothing extra here -- poll_near rate-limits itself.
    if (cfg.widget) then
        poll_near(now);
    end
    draw_fav_widget();

    -- The map's presses are only worth swallowing on the frames it is drawn:
    -- nav.pump is what drains them, and every early return below -- put away
    -- by the step just taken, no texture, and further down a window ImGui
    -- collapsed or sized to nothing -- leaves nothing to do the draining.
    -- Blocked presses with no drain is a D-pad dead in the game's own menus as
    -- well as on the map, with nothing on screen to say why.  Put out here and
    -- set again where the drain actually happens.
    ui.gp_ready = false;

    if (not ui.is_open[1]) then
        return;
    end

    -- Walking away puts the map away: it covers most of the screen, so leaving
    -- it up while moving is never what was wanted.
    if (player_moved()) then
        ui.is_open[1] = false;
        return;
    end

    poll_near(now);

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
    --
    -- And it never raises itself over anything, because it takes its clicks by
    -- hover rather than focus and has no use for being in front: at 90% of the
    -- screen it would otherwise bury the favorites widget, and every other
    -- addon's window with it, on the first click anywhere in it.
    local flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoScrollbar,
                          ImGuiWindowFlags_NoScrollWithMouse);
    -- The one frame it opens, the map takes the front of the stack, or it
    -- comes up buried under whatever addon window was focused last (fancychat
    -- covers most of the screen and made it unclickable).  NoBringToFrontOnFocus
    -- would veto the raise even with SetNextWindowFocus, so it is left off for
    -- this frame only; every later frame it goes back on and clicks in the map
    -- leave the stack alone, keeping the favorites widget on top.
    if (ui.raise_next) then
        ui.raise_next = false;
        imgui.SetNextWindowFocus();
    else
        flags = bit.bor(flags, ImGuiWindowFlags_NoBringToFrontOnFocus);
    end
    if (not imgui.GetIO().KeyShift) then
        flags = bit.bor(flags, ImGuiWindowFlags_NoMove);
    end

    -- No title bar and a 2px border, so the map runs nearly to the edges.
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 4, 4 });
    if (imgui.Begin('UberMap', ui.is_open, flags)) then
        local view_w, view_h = imgui.GetContentRegionAvail();
        if (view_w > 0 and view_h > 0) then
            ui.gp_ready = true;
            draw_map(view_w, view_h);
        end
    end
    imgui.End();
    imgui.PopStyleVar();
end);

ashita.events.register('packet_in', 'ubermap_packet_in', function (e)
    -- The teleport masks, which say which destinations are registered.  Taken
    -- off the wire rather than out of the client's own copy: the layout here is
    -- the server's own header file, while the copy's is an offset in a struct
    -- that has to be guessed right.
    if (e.id == MASK_PACKET) then
        -- Every 0x63 that is not the one wanted reads back nil, which would
        -- throw away a block already in hand, so only a good one is taken.
        ui.masks = unlocks.read_packet(e.data) or ui.masks;
        return false;
    end

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
    -- cfg.autoopen is the '/um config' checkbox: with it off the NPC is walked
    -- up to in peace, and Y at the favorites widget or '/um' puts the map up.
    if (warp_npc_type(name) ~= nil and cfg.autoopen
        and os.clock() - ui.sent_at > SEND_QUIET) then
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

    if (sub == 'config') then
        ui.config = not ui.config;
        -- Opens the map with it: the panel is drawn on the map, so turning it
        -- on with the map shut would put it nowhere.  Through show(), which is
        -- what clears a right-click menu and its veto left over from the last
        -- time the map was up; a map already open is left exactly as it is.
        if (ui.config and not ui.is_open[1]) then
            show();
        end
        notify(('config panel: %s'):fmt(ui.config
            and 'on, top-right of the map'
            or 'off'));
        return;
    end

    if (sub == 'edit') then
        ui.edit = not ui.edit;
        if (ui.edit) then
            if (not ui.is_open[1]) then
                show();
            end
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

--[[
* event: xinput_button
* desc : Two things read the pad, and only ever one at a time.  The favorites
*        widget takes D-pad up and down, A, B and Y while it is on screen,
*        which is only while a warp NPC is in reach.  The map takes those and
*        the D-pad's other axis and Y while it is up: the D-pad walks the
*        markers, A opens what is under it, B backs out, and Y is the
*        right-click that opens the favorites menu on a warp row -- while at
*        the widget Y is what swaps the widget for the map itself.  The widget
*        is asked first, so walking up to an NPC puts it in front of a map
*        that is already open and it has to be dismissed before the map
*        answers again.  Every other button, and every button at all outside
*        those two, is the client's.
--]]
ashita.events.register('xinput_button', 'ubermap_xinput', function (e)
    local act = GP[e.button];
    if (act == nil) then
        return;
    end

    -- Both edges: the client never saw the press, so it is not handed the
    -- release either.  Which edge was taken is remembered rather than re-tested
    -- against ui.fw_on, because the press is what takes the widget off screen
    -- in two of the four cases -- B dismisses it and A warps out of range of
    -- the NPC holding it up -- and a release matched against the state after
    -- that would leak a button-up the client never got the button-down for.
    -- The map's own presses are held for the same reason: A on a warp row
    -- closes the map before the button comes back up.
    if (e.state ~= 1) then
        if (ui.pad_held[e.button]) then
            ui.pad_held[e.button] = nil;
            e.blocked = true;
        end
        return;
    end

    -- The widget first, and outright: it is only ever up stood at a warp NPC,
    -- and there it is what a press is for.  The two buttons it does not read
    -- go to the client rather than to the map behind it, or dismissing it
    -- would be the only way to reach the NPC's own menu.
    if (ui.fw_on) then
        local n = #fav_view();
        -- Left and right stay the client's: the widget is a single column, and
        -- taking them would leave no way to work the menu behind it short of
        -- dismissing it.
        if (act == 'left' or act == 'right' or n == 0) then
            return;
        end
        e.blocked = true;
        ui.pad_held[e.button] = true;

        -- Marked here rather than at the head of the handler: what turns the
        -- pad's highlights back on is a press this widget took, not a pad
        -- being plugged in.  Anything else -- the other face buttons, a
        -- release, a trigger -- says nothing about which hand is on the map,
        -- and a player working the mouse with a controller still in reach had
        -- the highlight coming back on all of them.
        if (nav.wake()) then
            return;
        end

        if (act == 'up') then
            -- Wraps at both ends, the way the game's own menus do.  ponytail:
            -- one step a press; a held-D-pad repeat if a list ever gets long
            -- enough to want one.
            ui.fw_sel = (ui.fw_sel - 2) % n + 1;
        elseif (act == 'down') then
            ui.fw_sel = ui.fw_sel % n + 1;
        elseif (act == 'a') then
            fw_confirm();
        elseif (act == 'y') then
            -- The way up to the full map from the widget, and what the
            -- auto-open checkbox leaves behind when it is turned off.  The
            -- widget goes with it rather than staying up over the map: it would
            -- otherwise keep taking the D-pad and A that the map now wants.
            ui.fw_hide = true;
            show();
        else
            -- The way back to the NPC's own menu: with A swallowed there would
            -- otherwise be no reaching it from a controller while stood here.
            ui.fw_hide = true;
        end
        return;
    end

    -- The map, while it is on screen, has had a frame size the view, and is
    -- being drawn -- a frame that returns out early has nothing to drain what
    -- is queued.  Queued rather than acted on here: the zooms need the
    -- viewport size, and only the draw knows that.
    if (not ui.is_open[1] or ui.zoom == nil or not ui.gp_ready) then
        return;
    end
    e.blocked = true;
    ui.pad_held[e.button] = true;
    -- The map's own seven, on the press edge, while the map is up: the only
    -- thing that says the pad is what is driving it.  See the widget above.
    if (nav.wake()) then
        return;
    end
    -- How many presses may wait for a frame that is not coming.  A queue
    -- nothing is draining is a map that is not being drawn -- the window
    -- collapsed, say -- and a hundred presses landing at once when it comes
    -- back is worse than losing them.
    if (#ui.gp_q < 8) then
        table.insert(ui.gp_q, act);
    end
end);

ashita.events.register('unload', 'ubermap_unload', function ()
    -- Unloading mid-press would leave Escape held down for the whole system,
    -- since nothing is left to run the frame that releases it.
    release_escape();
    ui.texture = nil;
    icon_tex = T{};
end);

--[[
* event: key_data
* desc : The keyboard's half of the gamepad, read the same way and in the same
*        order.  The widget is asked first and wins outright, exactly as it
*        does on the pad: U swaps it for the full map, F hands it the arrows,
*        and Escape puts it away.  With it off screen the map takes the arrows,
*        Enter and Escape while it is up -- the arrows walk the markers, Enter
*        opens what is under one and Escape backs out, which at the top is what
*        closes the map the way it closes the game's own windows.
*
*        This is DirectInput's buffered stream -- the edges, as the game reads
*        them -- and not the WNDPROC key event.  Blocking that one only keeps a
*        key out of the client's text fields; movement, the camera and the
*        menus are all read from here and from the state buffer below, which is
*        why an arrow taken there still turned the camera.
*
*        Both edges are taken, and which one was is remembered rather than
*        re-tested: the press is what closes the map in two of these cases, and
*        a release matched against the state after that would leak a key-up the
*        client never got the key-down for.
--]]
ashita.events.register('key_data', 'ubermap_key_data', function (e)
    local act = nav.key[e.key];
    if (act == nil) then
        return false;
    end

    if (not e.down) then
        if (ui.kb_held[e.key]) then
            ui.kb_held[e.key] = nil;
            e.blocked = true;
            return true;
        end
        return false;
    end

    if (not nav.press(act, true)) then
        return false;
    end
    ui.kb_held[e.key] = true;
    e.blocked = true;
    return true;
end);

--[[
* event: key_state
* desc : DirectInput's immediate state buffer, read once a frame: what the game
*        polls a held key from, so blocking the edge above is not enough on its
*        own -- the camera turns for as long as an arrow is down, and it never
*        looks at the buffered stream to learn that.
*
*        Two things are wiped out of it.  A key whose press was taken, for as
*        long as it is held, which is the whole of the case above; and a key
*        that is down and would be taken, which covers the frame the two
*        buffers are read in the other order and the game would otherwise see
*        one frame of it.
--]]
ashita.events.register('key_state', 'ubermap_key_state', function (e)
    local keys = ffi.cast('uint8_t*', e.data_raw);
    for dik, act in pairs(nav.key) do
        if (keys[dik] == 0) then
            -- The release edge above is what normally clears this, but an
            -- alt-tab or a device re-acquire while the key is down loses that
            -- event, and a flag left set wipes the key out of this buffer on
            -- every later press -- a camera that will not turn for the whole
            -- of the next hold.  This buffer is the one place that can say a
            -- key is up whether or not its event ever arrived.
            ui.kb_held[dik] = nil;
        elseif (ui.kb_held[dik] or nav.press(act, false)) then
            keys[dik] = 0;
        end
    end
end);

--[[
* event: text_in
* desc : Drops Uberwarp's own chat lines while Hide Uberwarp Chat is ticked.
*        Every line it writes is stamped '[Uberwarp:<module>]', so a line is
*        its own only when both names are on it: matching the plugin name alone
*        would swallow anything else that so much as says the word, this addon
*        included.  The two are looked for apart rather than as one string
*        because the plugin writes a colour byte between them.  Blocked rather than emptied, which
*        keeps the line out of the log file as well.
--]]
-- The task modules Uberwarp names itself after, straight out of the plugin.
local UW_MODULE = T{
    'TaskHelper', 'HomePoint', 'SurvivalGuide', 'UnityWarp', 'CrystalWarp',
    'AbysseaConflux', 'AbysseaWarp', 'CastoffPoint', 'CavernousMaw', 'Elvorseal',
    'EschaEnter', 'EschanPortal', 'ProtoWaypoint', 'RunicPortal', 'ScalableArea',
    'Waypoint', 'WaitForZone', 'Wait',
};

ashita.events.register('text_in', 'ubermap_text_in', function (e)
    if (not cfg.quiet) then
        return;
    end

    local msg = e.message_modified;
    if (not msg:contains('Uberwarp')) then
        return;
    end

    for _, m in ipairs(UW_MODULE) do
        if (msg:contains(m)) then
            e.blocked = true;
            return;
        end
    end
end);
