# Gamepad Map Navigation — Decision Record

> Shipped. This was an implementation plan; the step-by-step instructions and
> the source they quoted have been cut, because the code is the code and a
> second copy of it only drifts. What is left is what the code cannot say for
> itself: what was decided, and what was deliberately left out.
>
> The feature lives in `lib/gpnav.lua`, the `nav` table in `ubermap.lua`, and
> the `xinput_button` handler. Its tests are `test/test_gpnav.lua`,
> `test/test_gpwarp.lua` and `test/test_gpad.lua`.

**Goal:** Drive the whole map from an XInput controller — D-pad walks the markers, A opens the next tier down (nation/region → zone points → warp list → warp), B backs out.

**Architecture:** Three tiers of nesting, but no `level` variable: the tier is already written on screen. `ui.warp ~= nil` is the warp list, `ui.focus ~= nil` is inside a nation/region, and everything else is the overview. The candidate list a press walks is "every marker drawn and not faded back", which `icon_visible()` and `icon_dim()` already answer, so the same two-line filter gives the overview markers below `ZOOM_POINTS` and the zone points above it with nothing to keep in step. Direction picking, centre-finding and the warp list's row arithmetic are pure math and live in `lib/gpnav.lua` beside `lib/mapmath.lua`, so they can be exercised outside the game. The `xinput_button` handler queues an action rather than acting on one, because zooming needs the viewport size and only the draw knows that.

**Tech stack:** Lua 5.1 / LuaJIT (Ashita v4), ImGui via Ashita's `imgui` binding, no new dependencies.

## Decisions

- **XInput button indices** are the bit positions Ashita's `xinput_button` event delivers: `0` D-pad up, `1` down, `2` left, `3` right, `12` A, `13` B, `15` Y. These are the seven the map reads; every other button stays the client's. The favorites widget reads five of them — the seven minus left and right.
- **The favorites widget wins.** While `ui.fw_on` is true the map takes no button at all, so approaching a warp NPC still puts the widget in front and it has to be dismissed first.
- **No toggle.** The map takes the seven buttons whenever it is on screen. Unlike the widget, which appears unbidden while you stand somewhere, the map is a thing you deliberately opened and it covers 90% of the screen. If a toggle is wanted later it is a `cfg.gpad` flag and one `and cfg.gpad` in the handler.
- **B at the top closes the map.** The spec stopped at "zoom back out"; without this a controller has no way to close the map at all, since the existing close is the Escape *key*.
- **An overview marker that stands for no zone points does nothing on A**, exactly as it does nothing on a click today. Five markers are like this (`Aht Urhgan`, and the four past-map Beastmen icons).
- **Both button edges are swallowed together.** A release handed to the client without its press would leave a button stuck down in the game's own menus, so which edge was taken is remembered in `ui.pad_held` rather than re-tested against state the press itself may have changed.
- **The pad has to be driving before a press acts.** Cursor movement over the map or the widget puts the pad's highlights out; the press that turns them back on is spent doing only that (`nav.wake`), so nothing steps off — or sends — a row nothing on screen was showing.
- **Presses are only swallowed on frames that drain them.** `ui.gp_ready` says the map actually drew; a frame that returns out early has nothing to run `nav.pump`, and blocking with no drain is a D-pad dead in the game as well as on the map.

## Constraints that shaped it

- **Lua 5.1 / LuaJIT compatible.** Ashita runs LuaJIT; the test files run under whatever `lua` is on PATH. No `goto`, no integer division, no 5.4-only library calls.
- **`ubermap.lua` is one flat main chunk near Lua's 200-locals-per-function cap.** The feature's functions hang off one `local nav = { }` table rather than standing as locals of their own, the shape `SCALE.px` already uses. Check headroom with `luac -p` before adding any top-level `local`.
- **No new dependencies.** Everything needed was already required in `ubermap.lua`.
- **Tests run from the repo root**, one file per feature, plain `assert`/`check` plus a final `print` of what passed: `lua test/test_gpnav.lua`.

## Deliberately left out

- **Held-D-pad repeat.** One step a press, like the favorites widget. Add it when a list is long enough to want one.
- **A toggle.** See the decisions above; it is `cfg.gpad` and one `and` in the handler if it turns out to be wanted.
- **Analogue stick panning.** The D-pad reaches every marker on both maps (`test_gpnav.lua` proves it), so a stick would only be another way to do what the D-pad already does.
- ~~**The right-click favorites menu from the pad.**~~ Left out at first — "the pad travels, it does not curate" — and put back before shipping: **Y** on a warp row opens the same menu the mouse's second button does, since a controller with no way to favorite has to reach for the mouse to build the list it then drives.
