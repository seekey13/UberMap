# Zone Map Zoom — Plan

> In progress. Steps 1–3 are done (pure math, grid/sheet logic, data + loader);
> nothing is drawn in game yet.

**Goal:** Selecting a zone on the world map glides the view into that zone's
own map, then shows every warp destination (Home Points, Survival Guide, Unity
Concord, Abyssea maw, Confluxes, Runic Portals) as a marker at its real spot on
the zone map. Clicking a marker sends the warp. Zooming back out, or pressing B
or Esc, returns to the world map.

**Reference:** OpenMap, a WoW addon in Lua. The parts we borrow:

- **One continuous view.** OpenMap never cuts from one map to another. Every
  zone image is placed in world coordinates, so going into a zone is a zoom on
  one canvas.
- **Switching by zoom, with hysteresis.** A zone takes over at 90% of its fit
  zoom and lets go below 70%, so the map does not flicker at the boundary.
- **Glides on click.** A click glides the view in over about 0.4 s, with an
  eased zoom on a log scale.
- **Fixed-size pins.** Markers keep the same size on screen at every zoom. Only
  their positions move.

The parts we leave out: baked tile pyramids, minimap blending, territory masks.
UberMap has about 150 zones and a handful of images each, so a crossfade is
enough.

## Decisions

- **Art: the Remapster pack** (`github.com/AkadenTK/remapster_maps`,
  `minimaps/ffxidb/`), licensed **CC BY-SA 4.0**. We may ship it as long as we:
  - credit Remapster and link both the repo and the license
    (`assets/zones/NOTICE.md` and the README)
  - say what we changed (resizing, re-encoding)
  - keep our edited copies under CC BY-SA
  - don't imply Remapster endorses UberMap

  The license covers the images only; the Lua code stays MIT. It does not
  cover Square Enix's rights in the maps the art is drawn from, which is the
  same grey area the shipped world maps are in. Your own art can replace any
  file later, one zone at a time, and keeps whatever license you give it.
- **Positions are stored in grid and u/v terms, never pixels.** Replacing an
  image never moves a marker, as long as the new art keeps the in-game grid
  layout. Art with a different layout sets its own `grid`.
- **Click (or A) enters a zone.** Wheel auto-enter is optional, behind
  `cfg.zone_auto`, off by default.
- **The warp list stays** as a panel docked on the zone view, linked to the
  markers.
- **Placement starts at cell centres** from the existing `(K-9)` references.
  The editor refines them to exact `xy` over time.

### What the Remapster files look like

- Each file is named `<zone id>_<map index>.png`, using the game's own IDs.
  A one-map zone is `_0`. A multi-map zone uses the game's map indices
  (Caedarva Mire is `79_1`..`79_4`; Windurst Waters is `238_1` for north and
  `238_2` for south).
- Each image is 2048×2048 RGBA and about 7 MB on disk.
- **The files ship unmodified, and the player chooses the size.** The config
  panel's **Full Size Zone Maps** switch (`cfg.zone_full`, on by default)
  loads them at full size. Off, it loads them at 1024 on a side
  (`ZONES.HALF`), which is a quarter of the texture memory: 4 MB instead of
  16 MB each once decoded. The scaling is D3DX's own, done as the texture is
  created from the file, so nothing on disk changes. Because we change nothing,
  NOTICE.md lists no modifications. Flipping the switch drops the cached zone
  textures (`ZONES.tex`), so the next zone loads at the new size.
- **Repo size.** At about 7 MB a file, the pilot's 10 files are about 70 MB,
  and the full pack is several hundred files. Before step 9 goes past the
  pilot, decide whether the full set lives in the repo, in Git LFS, or in a
  separate download the player drops into `assets/zones/`. The loader already
  handles a missing file by falling back to the warp list.
- The 15×15 grid sits inside a border half a cell wide: grid origin at 1/32 of
  the image, cells 1/16 wide. This matches the 512 px in-game maps (16 px
  border, 32 px cells). I measured it on West Ronfaure: column A is centred at
  64/1024 and row 15 at 960/1024.

## Zones with more than one map

FFXI splits some zones into several maps, and the same grid reference (say
K-9) exists on each one. A grid reference alone therefore can't place a warp.

- **Sheets.** A zone in `lib/zonemaps.lua` lists its **sheets**, the maps shown
  as tabs. A sheet is named by its game zone ID and map index, for example
  `79_2`, which is also the Remapster file name. Only sheets that hold a warp
  are listed: Caedarva has four maps, but warps land on two.
- **Which sheet a row is on.** Its zone is the row's `zid` if it has one,
  otherwise the zone of the entry. Its map is the row's `map` if set, otherwise
  that zone's first sheet.
- **Confluxes get the Abyssea map as their own tab.** Conflux grid references
  are places inside the Abyssea area, and those rows already carry its `zid`.
  So Konschtat Highlands opens with two tabs: `108_0` (the Highlands) and
  `15_0` (Abyssea - Konschtat). The confluxes land at their real positions
  instead of at nonsense spots on the Highlands map.
- **One zone, two world-map points.** North and South Windurst Waters each have
  an entry with the same two sheets. `start` picks which tab each one opens on.
- **The rule the tests enforce.** If a row's zone has more than one sheet, the
  row must say which with `map`. A missing `map` silently falls to the first
  sheet, and that is easy to get wrong: Caedarva's Survival Guide (G-6) turned
  out to be on map 2, not map 1, when checked against the art.
- **The UI:**
  - A tab strip along the zone view, showing each sheet's name and a warp count
    badge (`zonegrid.counts`).
  - Switching tabs crossfades in place. LB/RB cycle tabs on a gamepad.
  - A zone opens on the sheet the player stands on (if the game exposes it),
    else the last one viewed, else `start`, else the first
    (`zonegrid.open_sheet`).
  - The warp list covers every sheet, grouped under sheet headers. Hovering or
    picking a row on another sheet switches to that tab first, then lights the
    marker.
  - Rows on no sheet are listed in the panel only.
  - The world-map zoom lines up with the zone's first sheet. The other sheets
    are reached by tab, not stitched together, because they are often other
    floors or overlapping areas.

## Design

### 1. One canvas

The zone map is a quad drawn inside the world map, centred on the zone's point
and `span` world pixels wide (`mapmath.zone_rect`). All view state (`zoom`,
`pan_x`, `pan_y`) stays in world-map pixels the whole time, so there is no
coordinate conversion at the switch. Being "in a zone" only decides which image
is drawn in that rect and which markers go on top of it. Markers convert u/v to
world coordinates (`mapmath.uv_to_world`) and then to screen coordinates with
the existing `to_screen`.

`MAX_ZOOM` becomes per-tier. Inside a zone, the cap is two screen pixels per
pixel of the zone image, not of the world map.

### 2. State: `ui.zone`

`ui.zone` holds:

- `label`: the point the user went into
- `si`: the current sheet index
- `t`: the transition progress, from 0 (world) to 1 (zone)
- `from` and `to`: the glide's end views, each `{cx, cy, zoom}`

While `ui.zone ~= nil` the zone tier is on screen. As the gpnav decision record
does, there is no separate level variable. The last sheet viewed is remembered
per label for the session.

### 3. The transition

- **Into a zone:** `mapmath.glide` over 0.45 s, from the current view to
  `rect_fit` of the zone quad. The zoom moves on a log scale, and the centre is
  weighted by how far the zoom has come, so the target grows into the middle
  instead of sliding past it. Over the last 40% (`mapmath.fade`), the zone
  image fades in on the quad above the world map, using the alpha of ImGui's
  `AddImage`.
- **Out of a zone:** wheeling below `ZONE_LEAVE` × fit (`mapmath.zone_hold`),
  or pressing B or Esc, plays the glide in reverse, landing on the zone point's
  group.
- **Loading:** a zone's textures start loading when its point is hovered or
  gets gamepad focus. An LRU cache keeps 4 textures.
- **Fallback:** a point with no art (`ZONES.get` returns nil) keeps today's
  warp list on the world map.

### 4. Warp markers

- `zonegrid.layout` returns each marker's u/v. Rows that resolve to the same
  spot get `fan_i` and `fan_n`, and `zonegrid.fan` rings them in screen pixels.
- Markers use the existing type icons at `POINT_SIZE`, in the same normal,
  teal, grey and red states, through `warp_lit` and `warp_known`.
- Click sends `warp_cmd`, and right-click toggles the favorite.
- Hovering a panel row lights its marker, and hovering a marker lights its row.
  They are matched through `layout`'s `index`.

### 5. Editor (`/um edit`)

- Inside a zone, ctrl+drag a marker to set its exact `xy`, in u/v, written back
  to `warps.lua`. Its `map` is the sheet it was dropped on.
- On the world map, a `span` slider controls how the zone quad lines up.

### 6. Gamepad

- A on a zone point enters the zone.
- Inside a zone, the D-pad walks the markers through `gpnav.pick`, A warps,
  B leaves, and LB/RB switch sheets.

### 7. Past/present

Past-only zones (`[S]`) get their own entries. Switching era while in a zone
leaves the zone first.

## Data files

`lib/zonemaps.lua` is keyed by point label:

```lua
["Caedarva Mire"] = { id = 79, span = 120, start = 1, sheets = {
    { map = 1, name = 'Map 1' },
    { map = 2, name = 'Map 2' },
} },
["Konschtat Highlands"] = { id = 108, sheets = {
    { map = 0 },
    { zone = 15, map = 0, name = 'Abyssea - Konschtat' },
} },
```

In `lib/warps.lua`, rows gain an optional `map = <game map index>`, and later
`xy = { u, v }`.

## Work breakdown

| # | Step | Files | Tests | Status |
|---|------|-------|-------|--------|
| 1 | Pure math: `zone_rect`, u/v↔world, `rect_fit`, `zone_hold`, `glide`, `ease`, `fade`, `pan_for`/`centre_of` | `lib/mapmath.lua` | `test/test_zonezoom.lua` | **done** |
| 2 | Grid ref → u/v, sheets, row→sheet, layout + fan, counts, opening sheet | `lib/zonegrid.lua` | `test/test_zonegrid.lua` | **done** |
| 3 | Data file (6 pilot points), `map` on the multi-map rows, `ZONES.load` / `ZONES.get` with the no-art fallback, NOTICE, Full Size Zone Maps switch | `lib/zonemaps.lua`, `lib/warps.lua`, `ubermap.lua`, `assets/zones/NOTICE.md` | `test/test_zonegrid.lua` data checks, `test/test_config.lua` | **done** |
| 4 | `ui.zone` state, texture LRU (created at `ZONES.size()`), preload on hover | `ubermap.lua` | — | |
| 5 | Glide + crossfade render path in `draw_map`, per-tier max zoom | `ubermap.lua` | — (in game) | |
| 6 | Markers, tabs, click to warp, linked panel | `ubermap.lua` | `test_warps.lua` additions | |
| 7 | Gamepad tier + LB/RB | `lib/gpnav.lua`, `nav` | `test_gpnav.lua` | |
| 8 | Editor: exact `xy` + `map`, `span` slider | `ubermap.lua` | `test_points.lua` | |
| 9 | Pilot art, unmodified: `102_0 108_0 117_0 15_0 132_0 45_0 79_1 79_2 238_1 238_2`; then the rest, auditing `map` on every multi-map zone | `assets/zones/` | the data test fails any multi-map row with no `map` | |
| 10 | README section + credits, decision record | `README.md`, this file | — | |

## Still open

- Can Ashita read which sheet the player currently stands on, for
  `open_sheet`'s `here_key`? If it can't, a zone opens on the last sheet viewed
  or on `start`.
- Default `span` is 120 world pixels. It will need tuning per zone once it is
  seen in game.
