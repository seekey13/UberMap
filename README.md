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

Mouse wheel zooms about the cursor and left-drag pans. Hold **shift** while
dragging to move the window itself. The map also opens on its own when you talk
to a Home Point; if it is already open your current view is left alone.

## Coordinates

Hover the map and the bottom-left corner shows the **source-image pixel** under
the cursor: `0..5504` across and `0..3072` down, measured on
`assets/Present_Map.jpg` itself. Zooming and panning change where a coordinate
is drawn, never what it is, so the same spot on the map always reads the same
numbers.

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
`time` tag naming the era it belongs to.

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
