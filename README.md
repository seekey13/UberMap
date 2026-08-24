# UberMap

Ashita v4 addon by Seekey. A zoomable, pannable map of Vana'diel that pops up when you talk to a Home Point, Survival Guide or Unity Concord, and warps you from it (using Uberwarp).

## Install

Drop the `UberMap` folder into `Ashita/addons/`, then `/addon load ubermap`.

| Command | Effect |
| --- | --- |
| `/ubermap`, `/um` | Toggle the map |
| `/ubermap edit` | Toggle the point editor |
| `/ubermap widget` | Toggle the gamepad favorites widget |

## The map

Mouse wheel zooms, left-drag pans, **shift**-drag moves the window.  
Talking to a warp NPC opens it; or use the command `/uw`.  
It closes itself once you walk away or a warp is used.  

**Past**/**Present**.  

## Warp list

Left-click a zone point — for a panel of that zone's destinations. Clicking a row sends its command and closes the panel:

| Kind | Command |
| --- | --- |
| Home Point #1 | `/uw hp <zone>` |
| Home Point #3 | `/uw hp <zone>3` |
| Survival Guide | `/uw sg <zone>` |
| Unity Concord | `/uw uc <zone>` |

### Row states

| Look | Meaning |
| --- | --- |
| Normal | Travels now |
| Grey | Wrong kind of NPC for where you stand; the icon says what to walk up to |
| **Red** | Never registered; takes no click from anywhere, hover says why |

## Toolbar

| Icon | Where | Does |
| --- | --- | --- |
| **Crystal**, **Guide**, **Unity** | Right of search | Dim one to drop that kind of row. A zone with nothing left opens no panel |
| **Warp** | After them | `/item "Instant Warp" <me>` and closes the map. Lit only while the scroll (4181) is carried |
| **Warp Ring** | After that | Two steps, see below |
| **Multisend** | Bottom right | Prefixes every command the map sends with `/mss ` |
| **Heart** | Bottom left | Opens favorites. Hidden while the gamepad widget is on, since that lists the same rows |

**Warp Ring** works in two steps, since a ring must be worn before use. It looks for item 28540 in your bag and the eight Mog Wardrobes the client will equip out of, re-read twice a second like the scroll. Carrying none: dimmed and dead. Carrying one unworn: dimmed, and clicking sends `/equip ring1 "Warp Ring" <container>`, keeps the map open and goes dead for nine seconds while the ring lands. Wearing one: lit, and clicking sends `/item "Warp Ring" <me>` and closes the map. Hovering says which step it is on.

While **Multisend** is lit every command — warp rows, scroll and ring alike — goes out through [Multisend](https://github.com/ThornyFFXI/Multisend) and repeats on every logged-in character. Off and dimmed until clicked.

**Favorites** are warp rows you saved, in your order. Right-click any row for *Add point to favorites list* — a row you cannot travel on right now works too, so a destination can be saved from anywhere. Each is named by its zone and row, e.g. `Windurst Woods - Home Point #2`. Clicking one warps exactly as its original row would, and it reads grey or red on the same two tests. Drag a row up or down to reorder the list; right-click offers *Remove point from favorites list*.

## Scroll pickup

Walk within 7 yalms of an **EXP Guide** or **EXP Guide (S)** carrying no Instant Warp scroll and with a free inventory slot, and one is asked for and taken without you stopping: the guide is poked with the same packet pressing its target sends, and the moment the scroll lands Escape backs out of the talk it arrived in.

Nothing to configure. All three have to be true — no scroll (4181) in the bag, a slot free for one, a guide in reach — and they get **one** poke between them. Any of the three going false arms the next one, so spending a scroll or walking off and back asks again, while standing at a guide that answered with nothing does not: it is given up on after five seconds and then left alone. So the packet count is one per scroll you actually collect, on no timer of its own.

Carrying a scroll or a full bag skips even the entity scan, so the cost on a character already holding one is a bag read twice a second and nothing else. Renamed on your server? `EXP_GUIDE_NAME` in `ubermap.lua` holds the pattern.

## Gamepad favorites widget

`/um widget` turns on a small window listing the same favorites, built for a controller. It comes up on its own the moment you walk up to a Home Point, Survival Guide or Unity Concord — map open or not — and goes away the moment you walk off. Never wider than that, because it swallows the buttons it reads and the D-pad belongs to the game's menus everywhere else.

| Button | Effect |
| --- | --- |
| D-pad up / down | Move the selection, wrapping at both ends |
| A | Warp to the selected row |
| B | Put the widget away until you walk off the NPC |

The widget and the map's panel are one list drawn twice, so the mouse works the same in either: click a row to warp, drag it up or down to reorder, right-click for *Remove point from favorites list*. Turning the widget on hides the heart and its panel, so the list is on screen in one place, not two.

Rows read grey or red on the same two tests the panel uses, and A refuses a row that reads either way — a favorite travels only from the kind of NPC it was saved off, and only to a destination you have registered. The window has no title bar and sizes itself to the list; like the map, hold shift to drag it somewhere else. Off by default, and saved per character with the rest of the settings.

XInput only: an Xbox pad, or anything Windows presents as one. A DirectInput controller (DualShock, DualSense) still works by mouse.

## Filters set themselves

Stand at a warp NPC and the map narrows to it: only that kind of row stays lit, since it is the only one you can travel on from there. Walk away and all three light again. Your own clicks are not overridden — a toggle you set by hand stands until you move to a different kind of NPC.

A dimmed filter reaches the map itself: a zone marker with no row left fades back the way an unfocused group does and stops taking the cursor. Dim **Guide** and **Unity** and only Home Point zones stay lit.

The Multisend gate, your favorites and the three toggles are saved per character in `config/addons/UberMap/<name>_<server id>/settings.lua` the moment you change one.

## Data

`lib/warps.lua` is keyed by zone name — the point's `label` in `lib/points.lua`:

```lua
["Aht Urhgan Whitegate"] = {
    { type = 'home',  label = 'Home Point #1',  pos = '(H-9)' },
    { type = 'guide', label = 'Survival Guide', pos = '(L-8)' },
},
```

`type` is `home`, `guide` or `unity`, picking `assets/Crystal.png`, `Guide.png` or `Unity.png`. `pos` is the grid reference, held apart from the label so the panel draws it in a column of its own; a row without one leaves it out. Rows draw in file order. A key that is not the game's own name for the zone — `Delkfutt Tower`, the two halves of Windurst Waters — carries a `zone` field with the name `/uw` wants; Campaign zones are written `[S]` the way Uberwarp spells them, so they need no override. Unlike `lib/points.lua` this file is an overlay: missing or broken, the addon says so once and runs on without panels.

## Coordinates

Hovering shows the **source-image pixel** under the cursor, bottom left: `0..5504` across by `0..3072` down on `Present_Map.jpg`, `0..4096` both ways on `Past_Map.jpg`. Zoom and pan change where a coordinate is drawn, never what it is — but the same numbers mean different places on the two maps.

Icons are listed in `ICONS` in `ubermap.lua`, a file in `assets/` plus the coordinate its centre sits on, drawn rounded with a black border:

```lua
{ file = 'Bastok.jpg', x = 1340, y = 1886 },
```

## Placing points in game

`/ubermap edit` turns on the editor. **Ctrl+click** the map to drop a point or grab one, hold to drag; plain drag still pans. The panel under the search box renames, regroups and deletes.

Changes are written to `lib/points.lua`, which is loaded back at startup, so reloading loses nothing. That file holds `groups` for the overview tiers drawn zoomed out and `points` for the zone markers drawn zoomed in. Every marker carries a `time` tag — `'present'` or `'past'` — and is drawn only on that map; points dropped with the editor take the map on screen, and a row with no tag is drawn on neither.

Only `points` rows are editable. `groups` icons are drawn but cannot be selected, moved or deleted — edit those by hand.

If Home Points do not trigger the map on your server they are named differently there: `WARP_NPC` in `ubermap.lua` holds the name patterns for all three kinds.

## Development

The checks run outside the game on any Lua 5.1+, against the real data files:

```
lua test/test_zoom.lua      # lib/mapmath.lua, the view math
lua test/test_points.lua    # every marker sits on a map that exists
lua test/test_warps.lua     # every warp row builds a /uw the game takes
lua test/test_toggles.lua   # the layer toggles against the real points
lua test/test_ring.lua      # the Warp Ring icon's equip-then-use steps
lua test/test_favs.lua      # favorites: add, remove, reorder and the /uw they send
lua test/test_widget.lua    # the widget's D-pad wrap and its A-button gate
lua test/test_guide.lua     # the EXP Guide errand: when it asks, and when it stops
lua test/test_unlocks.lua   # the unlock bit test, and every alias Uberwarp knows
```

## Credits

- Thorny — [Uberwarp](https://github.com/ThornyFFXI/Uberwarp) and
  [Multisend](https://github.com/ThornyFFXI/Multisend)
- The [FFXI Remapster Project](https://remapster.com/)

## License

MIT. See [LICENSE](LICENSE).
