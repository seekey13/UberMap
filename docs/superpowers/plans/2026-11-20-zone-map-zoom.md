# Zone Map Zoom — Plan

> Draft for review. Nothing here is built yet.

**Goal:** Selecting a zone on the world map glides the view into that zone's
own map, then shows every warp destination (Home Points, Survival Guide, Unity
Concord, Abyssea maw, Confluxes, Runic Portals) as a marker at its real spot on
the zone map. Clicking a marker sends the warp. Zooming back out, or pressing B
or Esc, returns to the world map.

**Reference:** OpenMap, a WoW addon in Lua. The parts we borrow:

- **One continuous view.** OpenMap never cuts from one map to another. Every
  zone image is placed in world coordinates, and switching maps re-expresses
  the same view (centre and zoom) in the new map's coordinates.
- **Switching by zoom, with hysteresis.** A zone takes over at 90% of its fit
  zoom and lets go below 70%, so the map does not flicker at the boundary.
- **Glides on click.** A click glides the view in over about 0.4 s, with an
  eased zoom on a log scale.
- **Fixed-size pins.** Markers keep the same size on screen at every zoom. Only
  their positions move.

The parts we leave out: baked tile pyramids, minimap blending, territory masks.
UberMap has about 150 zones and one image each, so a crossfade is enough.

## What we have today

- The world map is one 4096×2048 texture per era. `mapmath.lua` handles
  `to_screen`, `to_map`, `zoom_anchor` and `fit_zoom`, and `ZOOM_POINTS = 1.0`
  splits the overview tier from the zone-point tier.
- A zone point is `{x, y, label, group}` in world-map pixels (`lib/points.lua`).
- A warp row's position is a grid reference string such as `pos = '(K-9)'`
  (`lib/warps.lua`). There are 150 zones and about 273 rows with a position.
  The letters run B–N and the numbers 3–14, which fits FFXI's standard 15×15
  grid (A–O, 1–15).
- Clicking a zone point opens `draw_warp_popup`, a list.

## Design

### 1. The third tier: `ui.zone`

`ui.zone` is the third tier, below overview and zone points. It holds:

- `label`: the point the user went into
- `map`: which sub-map, since some zones have more than one (Caedarva Mire
  map 1 and map 2)
- `zoom`, `pan_x`, `pan_y`: the zone map's own view
- `t`: the transition progress, from 0 (world) to 1 (zone)

This tier works like the other two. While `ui.zone ~= nil` the zone map is on
screen, and there is no separate level variable, which matches the gpnav
decision record.

### 2. Registration: where the zone map sits on the world map

Each zone map is drawn as a quad anchored on its world point. Its world-space
rect is centred on `(point.x, point.y)` with a per-zone `span`, the width of
world pixels the zone covers. The default is about 120 px, and the editor can
tune it per zone.

Placing the zone image *inside* the world map is what lets the transition be
one continuous zoom instead of a cut, because both images share the same view
math.

- New pure functions in `lib/mapmath.lua`:
  - `zone_rect(point, span, img_w, img_h)` returns `x0, y0, x1, y1` in world pixels
  - `world_to_zone(rect, img_w, img_h, wx, wy)` and its inverse
- At the switch, the view is converted between coordinate spaces the way
  OpenMap's `FromWorld` does: the same screen stays under the cursor and only
  the units change.

### 3. The transition

- **Into a zone (click or A):** glide over 0.45 s, ease-in-out on log(zoom),
  from the current view to the world zoom at which `zone_rect` fills the
  viewport. Over the last 40% of the glide, crossfade: the world texture fades
  out and the zone texture fades in on the same quad. ImGui's
  `AddImage(..., col)` alpha is enough for this, so no new shader is needed.
- **Out of a zone:** if the wheel takes the zone zoom below 70% of its fit
  zoom (the OpenMap hysteresis), or the user presses B, Esc or the new Back
  button, play the same glide in reverse. The view ends framing the zone
  point's group, which is where `gp_from` already lands.
- **Wheel-in with no click:** once the zoom passes 90% of a point's fit zoom
  and that point is centred and the view has been still for 0.3 s, auto-enter.
  This is off by default behind `cfg.zone_auto`, because a wheel that suddenly
  swaps maps can feel grabby.
- **Hitch-free loading:** load a zone texture when its point is hovered or
  the gamepad focuses it, so the image is ready before the click. Keep an LRU
  cache of 4 zone textures, each 512×512 or 1024×1024. This avoids the hitch
  that `load_texture` warns about.

### 4. Warp markers on the zone map

- Grid to pixel: add `grid_to_px("(K-9)", map)` to the new pure module
  `lib/zonegrid.lua`. FFXI maps draw the 15×15 grid inside a margin, so each
  map needs `{ox, oy, cell}` for its grid origin and cell size. One default
  fits nearly every map; maps that differ get an override in the data file.
- A grid reference only gives a ±½-cell position, so a row may carry an exact
  `xy = {px, py}` that overrides `pos`. The editor (§6) writes those.
- Markers use the existing type icons (`Crystal.png`, `Guide.png`, and so on)
  at `POINT_SIZE` on screen, with the label on hover, or always on above
  zoom 1.5. They take the row states the popup already has: normal, teal,
  grey and red, through the same `warp_lit` and `warp_known`.
- Clicking a marker sends `warp_cmd(label, row)`. Right-click toggles the
  favorite, like the popup's context menu.
- When several rows share a cell (Confluxes, for example), they fan out in a
  small ring so each stays clickable.
- The warp list stays as a side panel docked on the zone view, with its rows
  linked to the markers: hovering a row pulses its marker, and hovering a
  marker highlights its row. Players who read the list keep it.
- Rows with no `pos` appear only in the side panel.

### 5. The zone map images (needs a decision, see Open questions)

- Files go in `assets/zones/<zone_id>[_<n>].png`, keyed by the game's zone ID
  plus a sub-map index.
- New data file `lib/zonemaps.lua`:
  `[label] = { id = 104, maps = { { file = '104_0.png', grid = {...}, span = 120 } } }`
- A zone with no image falls back to today's behaviour, the popup on the world
  map, so we can ship before every zone has art.

### 6. Editor additions (`/um edit`)

- Inside a zone, ctrl+drag a marker to set its exact `xy`. The change is
  saved to `warps.lua` through the same writer that `save_points` uses.
- On the world map, a `span` slider sets how large the zone quad lands, which
  makes the transition look aligned.

### 7. Gamepad

- A on a zone point enters the zone, replacing the step that opened the warp
  list.
- Inside the zone, the D-pad walks the markers using the existing
  `gpnav.pick` direction logic, A warps, and B leaves.
- The tier chain becomes: overview → zone points → **zone map** → warp.

### 8. Past/present

Most zone maps are the same in both eras. Past-only zones (the `[S]` zones)
get their own entries. Switching eras while inside a zone leaves the zone
first.

## Work breakdown

| # | Step | Files | Tests |
|---|------|-------|-------|
| 1 | Pure math: `zone_rect`, world↔zone, glide easing, hysteresis check | `lib/mapmath.lua` | `test/test_zoom.lua` + new `test_zonezoom.lua` |
| 2 | Grid ref → pixel, ring fan-out | `lib/zonegrid.lua` | `test/test_zonegrid.lua` (every `pos` in `warps.lua` parses and lands inside the map) |
| 3 | Data file + loader, a fallback when there is no art | `lib/zonemaps.lua`, `ubermap.lua` | data test: every key matches a point label |
| 4 | `ui.zone` state, texture cache, preload on hover | `ubermap.lua` | — |
| 5 | Glide + crossfade render path in `draw_map` | `ubermap.lua` | — (in game) |
| 6 | Zone markers + click to warp + side panel link | `ubermap.lua` | `test_warps.lua` additions |
| 7 | Gamepad tier | `lib/gpnav.lua`, `nav` | `test_gpnav.lua` |
| 8 | Editor: exact `xy`, `span` slider | `ubermap.lua` | `test_points.lua` |
| 9 | Pilot art: 5 zones (Konschtat, La Theine, Tahrongi, Caedarva ×2, Windurst Waters), then the rest | `assets/zones/` | — |
| 10 | README section + decision record | `README.md`, this file | — |

Steps 1–3 can be built and tested out of game. Step 9's pilot gives an early
in-game check of the transition before we commit to art for all 150 zones.

## Open questions for you

1. **Where do the zone images come from?**
   - (a) Ship pre-extracted PNGs in `assets/zones/`. This is simplest and
     matches how the world maps ship today. It means redistributing Square
     Enix map art, the same exposure the world maps already carry.
   - (b) Read them at runtime from the player's own FFXI client map DATs.
     Nothing is redistributed, but we need a DAT image decoder (the map DATs
     hold DXT or palette textures) and a zone→DAT table.
   - (c) A one-off script that extracts the PNGs locally on first run, a
     middle ground.
   - My recommendation: (a) for the pilot, and keep (b) open if
     redistribution is a concern.
2. **Enter on click only, or on wheel as well?** I proposed click/A by
   default, with wheel auto-enter behind a config switch.
3. **Keep the popup list?** I proposed keeping it as a docked side panel
   linked to the markers. The alternative is markers only.
4. **Precision.** Is cell-centre placement from the existing `(K-9)`
   references good enough to start, with exact positions refined in the
   editor over time?
