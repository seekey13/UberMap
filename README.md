# UberMap

Ashita v4 addon by Seekey. Pops up a zoomable, pannable server map whenever you
interact with a Home Point.

## Install

Drop the `UberMap` folder into `Ashita/addons/`, then:

```
/addon load ubermap
```

## Use

| Command | Effect |
| --- | --- |
| `/ubermap` or `/um` | Toggle the map |
| `/ubermap debug` | Show an input-state overlay and print the name behind every NPC interaction event |
| `/ubermap edit` | Toggle the point editor |

The button at the right of the search row switches between past and present: it
reads **Past** while the present-day map is up and **Present** while the past one
is. Switching swaps `Present_Map.jpg` for `Past_Map.jpg` and draws only the
markers whose `time` matches. The two images have different sizes and share no
coordinates, so the view resets to the whole map on each switch, and only one
image is held in memory at a time.

Mouse wheel zooms about the cursor and left-drag pans. Hold **shift** while
dragging to move the window itself. The map also opens on its own when you talk
to a Home Point; if it is already open your current view is left alone.

## Warp list

Left-click a zone point - the markers that appear once the view is zoomed past
the overview - and a panel opens on it listing that zone's warp destinations:
its Home Points, Survival Guide and Unity Concord, each with the icon of its kind.
It is a read-out, not a travel menu; clicking a row does nothing yet. Clicking
anywhere else closes it, as does zooming, panning, or switching past/present,
and clicking another point replaces it. While the cursor is over the panel the
map underneath neither pans nor zooms.

The four icons at the right of the search row filter it: dimming **Crystal**
drops the Home Point rows, **Guide** the Survival Guides and **Unity** the Unity
Warps. **Maw** names no warp type and so filters nothing. A zone whose every row
is filtered out - or that has no warps at all - does not open a panel.

The data lives in `warps.lua` beside the addon, keyed by the zone name, which is
the point's `label` in `points.lua`. Rows are listed in the order the file gives
them:

```lua
["Aht Urhgan Whitegate"] = {
    { type = 'home',  label = 'Home Point #1 (H-9)' },
    { type = 'guide', label = 'Survival Guide (L-8)' },
},
```

`type` is `home`, `guide` or `unity`, picking `assets/Crystal.png`,
`assets/Guide.png` or `assets/Unity.png`. Unlike `points.lua` the file is an
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

Every change is written to `points.lua` beside the addon, which is loaded back
at startup - reloading the addon or the game does not lose the work. That file
holds all the map data: `groups` for the overview tiers drawn when zoomed out,
`points` for the zone markers drawn when zoomed in. Every marker carries a
`time` tag - `'present'` or `'past'` - naming the map it belongs to, and is drawn
only while that map is up. Points dropped with the editor take the map on screen
at the time; an untagged row counts as present.

Only the rows under `points` are editable. The `groups` icons are drawn but
cannot be selected, moved, or deleted; edit those in `points.lua` by hand.

If Home Points do not trigger it on your server, run `/ubermap debug`, talk to
one, and check the name it prints against `HOMEPOINT_PATTERN` in `ubermap.lua`.

The same toggle draws a line at the top of the map window showing `hovered`,
`over_map`, the wheel delta, zoom and pan. If zoom or pan stops responding,
that line says which gate is refusing the input.

## Development

`mapmath.lua` holds the view math with no game dependencies:

```
lua test_zoom.lua
```

## License

MIT. See [LICENSE](LICENSE).
