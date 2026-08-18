# UberMap - Design

Ashita v4 addon by Seekey. Displays `assets/Present_Map.jpg` as a zoomable,
pannable overlay, opened automatically when the player interacts with a Home
Point.

## Files

| File | Purpose |
| --- | --- |
| `ubermap.lua` | The addon: texture load, packet hook, ImGui render, commands. |
| `mapmath.lua` | Pure view math (fit, clamp, zoom anchor). No Ashita deps. |
| `test_zoom.lua` | Standalone self-check for `mapmath.lua`. `lua test_zoom.lua`. |

## Home Point detection

Hook `packet_in` for IDs `0x032` and `0x034`, the two NPC interaction events.
Both carry the NPC's target index at offset `0x08`. Resolve the name through
`AshitaCore:GetMemoryManager():GetEntity():GetName(index)` and match
`^Home Point`.

Rejected alternatives:

- Outgoing `0x01A` action packets fire on every NPC trigger, including ones the
  server refuses.
- Event-ID matching is per-zone and breaks on custom content.

Because CatsEyeXI is a custom server, `/ubermap debug` prints the name behind
every NPC event so the pattern can be checked against live data.

## Texture

The source image is 5504x3072. D3D8 rounds non-power-of-two textures up, so a
native load becomes 8192x4096 - roughly 134MB of VRAM, doubled by the managed
pool's system-memory copy. That is a real out-of-memory risk inside FFXI's
32-bit address space.

`D3DXCreateTextureFromFileExA` is therefore called with an explicit 4096x2048
(~32MB, one mip level, `A8R8G8B8`, `D3DPOOL_MANAGED`). The texture stores the
image squashed; drawing it at `MAP_W x MAP_H * zoom` with full UVs restores the
true 1.7917 aspect. Cost is some detail at maximum zoom.

The 15MB JPEG decode is deferred to the first open so it never stalls addon
load or a zone-in. A failed load prints an error and closes the window rather
than retrying every frame.

## Rendering

`d3d_present` draws an ImGui window sized to 90% of the display on first use.
Inside it, a child window of the full content region provides clipping; the map
is drawn as a single `imgui.Image` at `MAP_W * zoom` by `MAP_H * zoom`, and
panning is a negative `imgui.SetCursorPos`. This avoids depending on ImGui's
scroll API, which this Ashita build does not appear to expose.

- **Zoom**: `GetIO().MouseWheel`, `zoom * 1.15^wheel`, clamped between
  fit-to-window and 1.0 (one screen pixel per source map pixel). The map pixel
  under the cursor stays pinned across the change.
- **Pan**: left-drag, tracked by frame-to-frame mouse delta. A drag that starts
  on the map continues even if the cursor leaves it.
- Mouse input is ignored unless the cursor is inside the map viewport, so
  dragging the title bar moves the window without also panning. The hover test
  needs `ImGuiHoveredFlags_ChildWindows`, because the map child covers the whole
  content region and is therefore the window ImGui reports as hovered - a bare
  `IsWindowHovered()` is false exactly when the cursor is over the map, killing
  both zoom and pan. `RectOnly` keeps it true mid-drag.
- Minimum zoom is fit-to-window, so the image can never shrink away from the
  frame. When one axis is smaller than the viewport, `clamp_pan` centers it.

## Behaviour

- Home Point interaction opens the map. If it is already open, zoom and pan are
  left untouched.
- `/ubermap` and `/um` both toggle. `/ubermap debug` toggles NPC event logging and
an on-screen readout of the input gates (`hovered`, `over_map`, wheel, zoom, pan).
- Closing is by command or the window's close button. No ESC hook, no
  click-to-dismiss, no auto-close when the Home Point menu ends.

## Out of scope for v1

`Bastok_Icon`, `Jeuno_Icon`, `Sandorian_Icon`, `Windurst_Icon`, `AU0` and `AU1`
are unused. No saved settings; zoom and pan reset when the addon reloads.
