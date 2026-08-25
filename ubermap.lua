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
addon.version = '1.1';
addon.desc    = 'Displays the server map, automatically on Home Point interaction.';

require('common');

local chat     = require('chat');
local settings = require('settings');
local imgui = require('imgui');
local ffi   = require('ffi');
local d3d   = require('d3d8');
local mm    = require('lib.mapmath');
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
-- Maw.png is left out until maw warps are implemented.
local TOGGLES      = T{ 'Crystal.png', 'Guide.png', 'Unity.png' };
-- What each toggle is called on its tooltip, keyed the way cfg.toggle is.
local TOGGLE_NAME  = T{ ['Crystal.png'] = 'Home Points',
                        ['Guide.png']   = 'Survival Guides',
                        ['Unity.png']   = 'Unity Concords' };
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
local WARP_ICON = T{ home = 'Crystal.png', guide = 'Guide.png', unity = 'Unity.png' };

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
-- Dim red, held apart from the grey above: not being in front of the right NPC
-- is a thing the player can walk off and fix, while a destination they have
-- never stood at is not, so the two do not read the same.  Text only - the icon
-- still says which kind of NPC the row travels from, which is worth reading
-- whether or not the destination is registered.
local COL_POPUP_LOCK = 0xA04040FF;
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
-- at a Home Point, Survival Guide or Unity Concord -- because it swallows the
-- buttons it reads, and the D-pad belongs to the game's own menus everywhere
-- else.  Off by default for the same reason: taking buttons off the client is
-- the surprising thing to do, so it has to be asked for.
--
-- Keyed by the XInput button index Ashita's xinput_button event delivers, so
-- one lookup answers both questions the handler has: whether the button is the
-- widget's, and which of the four it is.
local FW = {
    [0]  = 'up',
    [1]  = 'down',
    [12] = 'a',
    [13] = 'b',
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
    favs   = T{ },   -- saved warp rows, in the order they are listed in
    widget = false,  -- the gamepad favorites widget is on
    -- The EXP Guide errand.  On by default, unlike the widget: that one takes
    -- buttons off the client everywhere it is up, while this one acts only on
    -- the walk past a guide and can be watched happening.  A toggle all the
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
    -- The search box takes the keyboard the moment the map opens.  Off by
    -- default: the box swallows every key while it holds focus, movement
    -- included, so it is only worth opening the map into if you came to look
    -- something up.
    focus  = false,
    -- Uberwarp narrates every step of a warp it runs into the log, errors
    -- included.  The map is what asked for the warp, so the running commentary
    -- is noise by the time it arrives; /um quiet turns it back on when a warp
    -- is misbehaving and the reason matters.
    quiet  = true,
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
* Re-packs the five words the map draws text and hovers with from the three
* pickers.  Called once at load and once at the end of a picker drag, rather
* than per string per frame: the colours only move when a picker does.
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
    -- A settings file written before the pickers existed carries no colours,
    -- and a picker handed a nil table would index it on the first frame.  Copied
    -- rather than shared, so editing one does not write the defaults above.
    cfg.col_text    = cfg.col_text    or default_settings.col_text:copy(true);
    cfg.col_outline = cfg.col_outline or default_settings.col_outline:copy(true);
    cfg.col_hover   = cfg.col_hover   or default_settings.col_hover:copy(true);
    cfg.col_bg      = cfg.col_bg      or default_settings.col_bg:copy(true);
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
    hot         = false,     -- cursor was over a widget, not the map
    config      = false,     -- the colour pickers are on screen
    cfg_dirty   = false,     -- a picker on the config strip has been moved
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
    favs_open   = false,     -- favorites panel is up
    -- The gamepad widget.  fw_on is what the xinput handler reads to decide
    -- whether a button is its to take, and is written by the draw each frame,
    -- so the buttons are taken exactly while the list they drive is on screen.
    fw_on       = false,
    fw_shown    = false,     -- it was up last frame, i.e. this is not its first
    fw_sel      = 1,         -- the row the D-pad has landed on, 1-based
    fw_hide     = false,     -- B put it away until the player walks off the NPC
    fw_held     = {},        -- buttons whose press the widget took, by index
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
    -- What imgui.SetWindowFontScale is handed to draw the map's text at
    -- cfg.font_px, resolved once at the top of a frame rather than per label.
    font_scale  = 1.0,
};
ui.font_px[1] = cfg.font_px;

-- Logging in, or switching characters, hands back that character's own file.
settings.register('settings', 'settings_update', function (s)
    cfg = s;
    fill_defaults();
    ui.font_px[1]  = cfg.font_px;
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
local UW_TYPE = T{ home = 'hp', guide = 'sg', unity = 'uc' };

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
* What a string will measure once outlined_text has drawn it: the map's face at
* the map's size, rather than at the size the window's own font comes out at.
*
* The scale is set around the measurement and put straight back: it is a window
* property, so leaving it on would take every widget on the toolbar with it.
--]]
local function text_size(text, scale)
    local face = FONT_PX.face();
    if (face) then imgui.PushFont(face); end
    imgui.SetWindowFontScale(scale or ui.font_scale);
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
    -- Asked for here rather than in the draw, so the box is handed the
    -- keyboard once on the way in instead of stealing it back every frame.
    ui.focus_next = cfg.focus;
    -- Opening reads the world afresh on the next frame, whatever the toggles
    -- were left at when it was last up.
    ui.near_kind = false;
    ui.near_at   = 0;
    -- and re-anchors where the player is standing now, so the map does not
    -- close on the distance walked since the last time it was up.
    ui.open_x    = nil;
    ui.open_z    = nil;
    -- A menu left open from the last time the map was up would come back with
    -- it, hung over a panel that is no longer there.
    ui.ctx       = nil;
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
*   veto - something lying over the list is eating its presses.
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
        local over  = mouse_x >= px and mouse_x <= px + w
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
    -- Why a red favorite does not travel.
    if (hot_lock ~= nil and not veto) then
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
* moment a Home Point, Survival Guide or Unity Concord is in reach, gone the
* moment it is not, whether or not the map is open.
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
        local hot_i = draw_fav_list(px, py, m, mouse_x, mouse_y,
                                    { sel = ui.fw_sel, grab = not shift });
        -- Mouse and D-pad share the one selection: a press of either button on
        -- a row moves it there, so A afterwards sends the row last touched
        -- rather than one the hand has left behind, and a row dragged up or
        -- down the list carries the selection along with it.
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
        if (not shift and imgui.BeginPopupContextItem('##ubermap_fw_ctx')) then
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
                                    { veto = ui.warp_hot });

        -- Right-click a listed favorite to take it back off the list, the
        -- same menu that put it on.
        if (imgui.IsMouseClicked(1) and hot_i ~= nil and not ui.warp_hot) then
            local f = fav_view()[hot_i];
            ui.ctx = { x = mouse_x, y = mouse_y, fresh = true,
                       key = f.key, row = f };
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
            local h = POPUP_ROW * #rows;

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
            -- hot_row is the row a left-click would send, so it is only
            -- ever a live one; hot_any is the row under the cursor whether
            -- it is live or not, which is what the right-click menu goes
            -- on - a destination can be favorited from anywhere, not only
            -- from in front of the NPC that travels to it.
            -- hot_lock is the tooltip a red row under the cursor should show,
            -- saying why that row will not travel.
            local hot_row, hot_any, hot_lock = nil, nil, nil;
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
                local over = mouse_x >= px and mouse_x <= px + w
                             and mouse_y >= ry and mouse_y < ry + POPUP_ROW;
                if (over) then
                    hot_any  = r;
                    hot_lock = (not known) and LOCK_TIP[r.type] or nil;
                end
                if (live and known and over) then
                    hot_row = r;
                    pdl:AddRectFilled(
                        { px + ICON_BORDER, math.max(ry, py + ICON_BORDER) },
                        { px + w - ICON_BORDER,
                          math.min(ry + POPUP_ROW, py + h - ICON_BORDER) },
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
                local col = (not known) and COL_POPUP_LOCK
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
            if (hot_lock ~= nil) then
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
            -- cursor, live or not.
            if (imgui.IsMouseClicked(1) and hot_any ~= nil) then
                ui.ctx = { x = mouse_x, y = mouse_y, fresh = true,
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
        -- Opened at the cursor, clamped so a right-click near an edge does
        -- not put the item off the viewport.
        local px = mm.clamp_box(ui.ctx.x, w, origin_x, view_w);
        local py = mm.clamp_box(ui.ctx.y, h, origin_y, view_h);

        cdl:AddRectFilled({ px, py }, { px + w, py + h }, COL_POPUP_BG,
                          0, ImDrawCornerFlags_All);
        cdl:AddRect({ px, py }, { px + w, py + h }, COL_OUTLINE,
                    0, ImDrawCornerFlags_All, ICON_BORDER);
        local ctx_hot = mouse_x >= px and mouse_x <= px + w
                        and mouse_y >= py and mouse_y <= py + h;
        if (ctx_hot) then
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
                zoom_to_group(ui.press.label, view_w, view_h);
            else
                -- A zone nothing warps to leaves the panel shut rather than
                -- opening an empty one.
                ui.warp = (warp_rows(ui.press.label) ~= nil) and ui.press or nil;
            end
            ui.press = nil;
        end

        local row_h = imgui.GetFrameHeight() * ROW_H_MULT;

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
        local search_h = imgui.GetFrameHeight() * SEARCH_H_MULT;
        imgui.PushStyleVar(ImGuiStyleVar_FramePadding,
                           { 6, math.max(0, (search_h - imgui.GetFontSize()) / 2) });
        -- Nudged down by half of what it gives up, so a shorter box still sits
        -- on the middle of the row rather than riding its top edge.
        imgui.SetCursorPos({ search_x, UI_MARGIN + (row_h - search_h) / 2 });
        -- Everything on this row is placed by absolute cursor position and none
        -- of it wraps, so a full-width box would push the toggles and the warp
        -- icons off the edge of a small viewport.  A share of the width instead,
        -- which leaves FIELD_W alone at 1080p and above.
        local search_w = math.min(FIELD_W, view_w * 0.35);
        imgui.SetNextItemWidth(search_w);
        -- Handed the keyboard on the frame after an open, when the setting asks
        -- for it.  ImGui takes the focus request for the next item drawn, so
        -- this sits right on top of the box.
        if (ui.focus_next) then
            ui.focus_next = false;
            imgui.SetKeyboardFocusHere();
        end
        imgui.InputTextWithHint('##ubermap_search', 'Search', ui.search, FIELD_MAX);
        imgui.PopStyleVar();
        -- Only while the mouse is working the field, the way the editor's rows
        -- below feed it: IsItemActive stays true for the whole time the caret
        -- sits in the box, and on its own it would leave the map unable to
        -- zoom, pan or be clicked for as long as a search was being typed --
        -- including, with /um focus on, the frame the map opens in.  Held mouse
        -- included, so dragging a selection across the text does not pan.
        ui.hot = ui.hot or imgui.IsItemHovered()
                 or (imgui.IsItemActive() and imgui.IsMouseDown(0));

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
        -- pulldown, the Size box and the four colour pickers, one to a row.
        -- ImGui writes into the
        -- tables cfg keeps, and repack_cols turns those back into the words the
        -- draw lists take, so the map retints as a picker moves.  NoInputs
        -- leaves only the swatch, which opens the picker on click; the name
        -- ImGui draws beside it labels the row, so nothing has to be stamped by
        -- hand the way it did over the map.  Widgets are left at ImGui's own
        -- frame height rather than the toolbar's doubled one: a stacked panel
        -- has the room, so nothing needs enlarging to stay hittable.  Behind
        -- '/um config' rather than the point editor: recolouring the map is
        -- something a player does to their own map, while the editor is for
        -- moving the markers everybody gets.
        if (ui.config) then
            local pick_flags = bit.bor(ImGuiColorEditFlags_NoInputs,
                                       ImGuiColorEditFlags_AlphaBar,
                                       ImGuiColorEditFlags_AlphaPreview);
            local picks = { { 'Text',       cfg.col_text },
                            { 'Outline',    cfg.col_outline },
                            { 'Background', cfg.col_bg },
                            { 'Hover',      cfg.col_hover } };
            -- The widest row decides the panel's width: the Size box wants two
            -- digits and the pair of step buttons InputInt puts on the end of
            -- it, a swatch is one frame square, and every row carries its name
            -- to the right of that.
            local fh      = imgui.GetFrameHeight();
            -- InputInt spends the width it is given on the field and both step
            -- buttons, with ImGui's own spacing and frame padding coming out of
            -- the field's share, so the digits are asked for with room around
            -- them rather than flush: two digits' worth of slack covers that
            -- padding at every font size the atlas is built at.
            local size_w  = fh * 2 + imgui.CalcTextSize('0000');
            local panel_w = size_w + POPUP_PAD + imgui.CalcTextSize('Size');
            for _, pick in ipairs(picks) do
                panel_w = math.max(panel_w,
                                   fh + POPUP_PAD + imgui.CalcTextSize(pick[1]));
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
            local panel_h = pitch * (#picks + 2) - TOGGLE_GAP + POPUP_PAD * 2;
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

            -- Size box, second row.
            imgui.SetCursorPos({ row_x, row_y + pitch });
            imgui.SetNextItemWidth(size_w);
            if (imgui.InputInt('Size##ubermap_font_px', ui.font_px, 1, 4)) then
                -- Clamped rather than trusted: the box takes a typed number as
                -- well as the step buttons, and a zero or a four-digit one would
                -- be a map with no labels on it either way.  Written back so the
                -- box shows what was actually taken.
                cfg.font_px   = math.min(math.max(ui.font_px[1], FONT_PX.min),
                                         FONT_PX.max);
                ui.font_px[1] = cfg.font_px;
                ui.cfg_dirty  = true;
            end
            -- Held while a picker's popup is open, which is outside the panel's
            -- own rect and so is not covered by the test above.
            ui.hot = ui.hot or imgui.IsItemActive();

            for i, pick in ipairs(picks) do
                imgui.SetCursorPos({ row_x, row_y + pitch * (i + 1) });
                if (imgui.ColorEdit4(pick[1], pick[2], pick_flags)) then
                    -- Repacked on the frame it moved, so the map retints under
                    -- the picker rather than at the end of the drag.
                    repack_cols();
                    ui.cfg_dirty = true;
                end
                ui.hot = ui.hot or imgui.IsItemActive();
            end
            -- One write per drag rather than one per frame of it: a colour
            -- picker reports a change on every frame the mouse moves inside it,
            -- and the Size box does the same for as long as a step button is
            -- held down.  A number typed into the box saves on the next frame,
            -- since nothing is held for that.
            if (ui.cfg_dirty and not imgui.IsMouseDown(0)) then
                ui.cfg_dirty = false;
                settings.save();
            end
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

    -- What the map's text is scaled by, resolved once here rather than per
    -- label.  Ahead of the widget as well as the map, since both draw text.
    --
    -- A settings file that has never been near the Size box carries zero, which
    -- stands for the size ImGui's own font already comes out at: there is no
    -- frame to ask that of until now, so it is answered here and written back
    -- the first time, and the box opens showing the number rather than a nought.
    local base = imgui.GetFontSize();
    if (cfg.font_px == FONT_PX.own) then
        cfg.font_px   = math.floor(base + 0.5);
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
                          ImGuiWindowFlags_NoScrollWithMouse,
                          ImGuiWindowFlags_NoBringToFrontOnFocus);
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

    if (sub == 'widget') then
        cfg.widget = not cfg.widget;
        -- Asking for it back is asking to see it: a B press earlier in this
        -- visit would otherwise leave it hidden with nothing on screen saying
        -- why, since only walking off the NPC clears that.
        ui.fw_hide = false;
        settings.save();
        notify(('favorites widget: %s'):fmt(cfg.widget
            and 'on, shows at a Home Point, Survival Guide or Unity Concord'
            or 'off'));
        return;
    end

    if (sub == 'guide') then
        cfg.guide = not cfg.guide;
        settings.save();
        notify(('EXP Guide scroll pickup: %s'):fmt(cfg.guide
            and 'on, fetches an Instant Warp scroll when you pass a guide'
            or 'off'));
        return;
    end

    if (sub == 'focus') then
        cfg.focus = not cfg.focus;
        settings.save();
        notify(('search box focus on open: %s'):fmt(cfg.focus
            and 'on, the map opens ready to type in'
            or 'off'));
        return;
    end

    if (sub == 'quiet') then
        cfg.quiet = not cfg.quiet;
        settings.save();
        notify(('Uberwarp chat lines: %s'):fmt(cfg.quiet
            and 'hidden, including its errors'
            or 'shown'));
        return;
    end

    if (sub == 'config') then
        ui.config = not ui.config;
        -- Opens the map with it: the pickers are drawn on the map, so turning
        -- them on with the map shut would put them nowhere.
        if (ui.config) then
            ui.is_open[1] = true;
        end
        notify(('colour pickers: %s'):fmt(ui.config
            and 'on, top-right of the map'
            or 'off'));
        return;
    end

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

--[[
* event: xinput_button
* desc : D-pad up and down walk the favorites widget, A sends the row it has
*        landed on and B puts the widget away.  Only while the widget is on
*        screen, which is only while a warp NPC is in reach; every other button,
*        and every button at all outside that, is left to the client.
--]]
ashita.events.register('xinput_button', 'ubermap_xinput', function (e)
    local act = FW[e.button];
    if (act == nil) then
        return;
    end

    -- Both edges: the client never saw the press, so it is not handed the
    -- release either.  Which edge was taken is remembered rather than re-tested
    -- against ui.fw_on, because the press is what takes the widget off screen
    -- in two of the four cases -- B dismisses it and A warps out of range of
    -- the NPC holding it up -- and a release matched against the state after
    -- that would leak a button-up the client never got the button-down for.
    if (e.state ~= 1) then
        if (ui.fw_held[e.button]) then
            ui.fw_held[e.button] = nil;
            e.blocked = true;
        end
        return;
    end

    local n = #fav_view();
    if (not ui.fw_on or n == 0) then
        return;
    end
    e.blocked = true;
    ui.fw_held[e.button] = true;

    if (act == 'up') then
        -- Wraps at both ends, the way the game's own menus do.  ponytail: one
        -- step a press; a held-D-pad repeat if a list ever gets long enough to
        -- want one.
        ui.fw_sel = (ui.fw_sel - 2) % n + 1;
    elseif (act == 'down') then
        ui.fw_sel = ui.fw_sel % n + 1;
    elseif (act == 'a') then
        fw_confirm();
    else
        -- The way back to the NPC's own menu: with A swallowed there would
        -- otherwise be no reaching it from a controller while stood here.
        ui.fw_hide = true;
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

--[[
* event: text_in
* desc : Drops Uberwarp's own chat lines while /um quiet is on.  Every line it
*        writes is stamped '[Uberwarp:<module>]', so a line is its own only when
*        both names are on it: matching the plugin name alone would swallow
*        anything else that so much as says the word, this addon included.  The
*        two are looked for apart rather than as one string because the plugin
*        writes a colour byte between them.  Blocked rather than emptied, which
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
