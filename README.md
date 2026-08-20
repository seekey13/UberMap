# UberMap

Ashita v4 addon by Seekey. Pops up a zoomable, pannable server map whenever you
interact with a Home Point, Survival Guide or Unity Concord.

## Install

Drop the `UberMap` folder into `Ashita/addons/`, then:

```
/addon load ubermap
```

## Use

| Command | Effect |
| --- | --- |
| `/ubermap` or `/um` | Toggle the map |
| `/ubermap edit` | Toggle the point editor |

The button at the right of the search row switches between past and present: it
reads **Past** while the present-day map is up and **Present** while the past one
is. Switching swaps `Present_Map.jpg` for `Past_Map.jpg` and draws only the
markers whose `time` matches. The two images have different sizes and share no
coordinates, so the view resets to the whole map on each switch, and only one
image is held in memory at a time.

Mouse wheel zooms about the cursor and left-drag pans. Hold **shift** while
dragging to move the window itself. The map also opens on its own when you talk
to a Home Point, a Survival Guide or a Unity Concord NPC; if it is already open
your current view is left alone.

It closes itself once you walk a yalm from where it opened, so the map is never
left covering the screen while you move. Zoning counts as moving. Clicking a
warp row closes it too, since the warp is what the map was opened for.

## Warp list

Left-click a zone point - the markers that appear once the view is zoomed past
the overview - and a panel opens on it listing that zone's warp destinations:
its Home Points, Survival Guide and Unity Concord, each with the icon of its kind.
Clicking a row sends its `/uw` command - `/uw hp <zone>` for the first Home Point
and `/uw hp <zone>3` for the third, `/uw sg <zone>` for a Survival Guide and
`/uw uc <zone>` for a Unity Concord - and closes the panel. Clicking
anywhere else closes it, as does zooming, panning, or switching past/present,
and clicking another point replaces it. While the cursor is over the panel the
map underneath neither pans nor zooms.

Because the map opens when you talk to the NPC, the click lands while its menu
is still up, and Uberwarp cannot start its own conversation with one already
open. So the command waits: Escape is pressed for you, and it goes out once the
game reports the event over. A menu more than one level deep gets another press
every half second, and after two seconds the map gives up and says so rather
than holding the command. Nothing is injected at the packet level - the client
sends its own cancel, exactly as if you had pressed Escape yourself.

A row only travels from the kind of NPC you are stood at, so rows of any other
kind are drawn greyed out and take no click: the panel still lists the
destination and its icon says what to walk up to. Stand away from every warp NPC
and the whole panel reads grey.

A destination you have never stood at is a separate state: it is drawn
**purple**, takes no click from anywhere, and hovering it says why. Home Points
and Survival Guides have to be registered in person before they will travel to,
which the game records as a bit per destination and hands the client on zoning
in; the map reads the same bits the NPC's own menu greys its rows on, and pairs
them with Uberwarp's destination list so the row and the `/uw` it would send
agree. Unity Concords are open to every member, so they are never purple. If
either piece is missing - no unlock data back from the client, a destination
Uberwarp does not list - the row stays clickable rather than being locked out on
a guess.

The three icons at the right of the search row filter it: dimming **Crystal**
drops the Home Point rows, **Guide** the Survival Guides and **Unity** the Unity
Warps. A zone whose every row is filtered out - or that has no warps at all -
does not open a panel.

A fourth icon, **Warp**, sits after them and is not a filter: it reads an
Instant Warp scroll (item 4181) out of your bag, sending
`/item "Instant Warp" <me>` and closing the map. It is lit only while one is
carried and takes no click while it is not; the bag is re-read twice a second on
the same beat as the check below.

A fifth icon, **Warp Ring**, sits after that one and works in two steps, because
a ring has to be worn before it can be used. It looks for the ring (item 28540)
in your bag and in the eight Mog Wardrobes - the mog house storage the client
will equip out of - on the same twice-a-second beat. Carrying none leaves it
dimmed and dead. Carrying one you are not wearing leaves it dimmed, and clicking
it sends `/equip ring1 "Warp Ring" <container>` and keeps the map open, dead for
nine seconds while the ring lands. Wearing one lights it, and clicking it sends
`/item "Warp Ring" <me>` and closes the map. Hovering any of those steps says
which one it is on.

In the bottom-right corner, **Multisend** sends for your whole party of
characters: while it is lit every command the map sends - warp rows and the
Instant Warp scroll and the Warp Ring alike - goes out with a `/mss ` prefix, so
[Multisend](https://github.com/ThornyFFXI/Multisend) repeats it on every
logged-in character. It is off, and drawn dimmed, until clicked.

In the bottom-left corner opposite it, the **heart** opens your **favorites**:
warp rows you have saved, in the order you put them in. Right-click any row in a
zone's warp list to *Add point to favorites list* - a row you cannot travel on
from where you stand works too, so you can save a destination from anywhere on
the map. The list names each one by the zone it hangs off and the row itself,
e.g. `Windurst Woods - Home Point #2`.

Clicking a favourite sends its warp, exactly as clicking the row it came from
would; one you cannot use from where you stand is drawn dim and takes no press,
and one you have not registered yet is purple, the same way a popup row is. The `^` and `v` on the left of each row move it up
and down the list, and right-clicking a favourite offers *Remove point from
favorites list*. The list and its order are saved with the rest of your
settings.

The map sets those toggles for you, from what you are standing next to: within
10 yalms of a Home Point, a Survival Guide or a Unity Concord NPC - Igsli in
Bastok Markets, Urbiolaine in Southern San d'Oria, Teldro-Kesdrodo or Yonolala
in Windurst Woods - only that kind stays lit, since that NPC is the only one you
can warp from. Walk away and all three light again.

It is re-read twice a second while the map is up, but the toggles are only set
when the answer changes, so a toggle clicked by hand stands until you walk off
the NPC or up to a different kind.

While any of those three is dimmed the filter reaches the map itself: a zone
marker with no row left to show fades back the way an unfocused group does, and
stops taking the cursor. Dimming **Guide** and **Unity** so leaves only the
zones with a Home Point lit. With all three lit the map reads plain again.

The Multisend gate, your favorites and those three toggles are remembered per character, in
`config/addons/UberMap/<name>_<server id>/settings.lua`, written the moment you
change one, so your choices stand the next time you log in.

The data lives in `lib/warps.lua` under the addon, keyed by the zone name, which is
the point's `label` in `lib/points.lua`. A row whose key is not the game's own name
for the zone - `Delkfutt Tower`, the two halves of Windurst Waters - carries a
`zone` field with the name `/uw` wants; `(S)` keys are sent as `[S]`. `pos` is the
grid reference, held apart from the label so the panel can draw it in a column of
its own and every row's lines up; a row with no grid reference leaves it out. Rows
are listed in the order the file gives them:

```lua
["Aht Urhgan Whitegate"] = {
    { type = 'home',  label = 'Home Point #1', pos = '(H-9)' },
    { type = 'guide', label = 'Survival Guide', pos = '(L-8)' },
},
```

`type` is `home`, `guide` or `unity`, picking `assets/Crystal.png`,
`assets/Guide.png` or `assets/Unity.png`. Unlike `lib/points.lua` the file is an
overlay: if it is missing or broken the addon says so once and runs on without
the panels.

## Coordinates

Hover the map and the bottom-left corner shows the **source-image pixel** under
the cursor, measured on the map's own image: `0..5504` across and `0..3072` down
on `assets/Present_Map.jpg`, `0..4096` both ways on `assets/Past_Map.jpg`.
Zooming and panning change where a coordinate is drawn, never what it is, so the
same spot on a map always reads the same numbers - but the same numbers mean
different places on the two maps.

Icons are listed in `ICONS` in `ubermap.lua` - a file in `assets/` plus the
coordinate its centre sits on - and are drawn rounded with a black border:

```lua
{ file = 'Bastok.jpg', x = 1340, y = 1886 },
```

## Placing points in game

`/ubermap edit` turns on the point editor. **Ctrl+click** the map to drop a
point, or to grab one already there; keep the button held to drag it. The panel
under the search box renames it, sets its group, and deletes it. Plain drag
still pans, so only ctrl-drag moves points.

Every change is written to `lib/points.lua` under the addon, which is loaded back
at startup - reloading the addon or the game does not lose the work. That file
holds all the map data: `groups` for the overview tiers drawn when zoomed out,
`points` for the zone markers drawn when zoomed in. Every marker carries a
`time` tag - `'present'` or `'past'` - naming the map it belongs to, and is drawn
only while that map is up. Points dropped with the editor take the map on screen
at the time; a row with no tag is drawn on neither map.

Only the rows under `points` are editable. The `groups` icons are drawn but
cannot be selected, moved, or deleted; edit those in `lib/points.lua` by hand.

If Home Points do not trigger it on your server, they are named differently
there: `WARP_NPC` in `ubermap.lua` holds the name patterns, for Survival Guides
and Unity Concord NPCs as well.

## Development

The checks run outside the game on any Lua 5.1+, against the real data files:

```
lua test/test_zoom.lua      # lib/mapmath.lua, the view math
lua test/test_points.lua    # every marker sits on a map that exists
lua test/test_warps.lua     # every warp row builds a /uw the game takes
lua test/test_toggles.lua   # the layer toggles against the real points
lua test/test_ring.lua      # the Warp Ring icon's equip-then-use steps
lua test/test_favs.lua      # favorites: add, remove, reorder and the /uw they send
lua test/test_unlocks.lua   # the unlock bit test, and every alias Uberwarp knows
```

## Credits

This addon wouldn't work or look good without:

- Thorny - [Uberwarp](https://github.com/ThornyFFXI/Uberwarp) and
  [Multisend](https://github.com/ThornyFFXI/Multisend)
- The [FFXI Remapster Project](https://remapster.com/)

## License

MIT. See [LICENSE](LICENSE).
