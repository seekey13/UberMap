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

Mouse wheel zooms about the cursor, left-drag pans. The map also opens on its
own when you talk to a Home Point; if it is already open your current view is
left alone.

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
