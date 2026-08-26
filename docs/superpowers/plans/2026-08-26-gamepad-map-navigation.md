# Gamepad Map Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drive the whole map from an XInput controller — D-pad walks the markers, A opens the next tier down (nation/region → zone points → warp list → warp), B backs out.

**Architecture:** Three tiers of nesting, but no `level` variable: the tier is already written on screen. `ui.warp ~= nil` is the warp list, `ui.focus ~= nil` is inside a nation/region, and everything else is the overview. The candidate list a press walks is "every marker drawn and not faded back", which `icon_visible()` and `icon_dim()` already answer, so the same two-line filter gives the overview markers below `ZOOM_POINTS` and the zone points above it with nothing to keep in step. Direction picking and centre-finding are pure map-pixel math and live in a new `lib/gpnav.lua` beside `lib/mapmath.lua`, so they can be exercised outside the game. The `xinput_button` handler queues an action rather than acting on one, because zooming needs the viewport size and only the draw knows that.

**Tech Stack:** Lua 5.1 / LuaJIT (Ashita v4), ImGui via Ashita's `imgui` binding, no new dependencies.

## Global Constraints

- **Lua 5.1 / LuaJIT compatible.** Ashita runs LuaJIT; the test files run under whatever `lua` is on PATH (5.4 here). No `goto`, no integer division, no 5.4-only library calls.
- **No new dependencies.** Everything needed is already required in `ubermap.lua`.
- **Comment style.** This codebase writes prose comments that say *why*, in full sentences, wrapped near 78 columns, above the code they explain. Match it. `--[[ * ... --]]` blocks head functions; `--` lines head statements.
- **Style.** Parenthesised conditions (`if (x ~= nil) then`), semicolon line endings, 4-space indent, `local` everything.
- **Tests run from the repo root**, one file per feature, plain `assert` plus a final `print` of what passed: `lua test/test_gpnav.lua`.
- **XInput button indices** are the bit positions Ashita's `xinput_button` event delivers: `0` D-pad up, `1` down, `2` left, `3` right, `12` A, `13` B. These are the six the map reads; every other button stays the client's.
- **The favorites widget wins.** While `ui.fw_on` is true the map takes no button at all, so approaching a warp NPC still puts the widget in front and it has to be dismissed first.
- **Stated assumptions** (called out because the spec did not settle them):
  1. **No toggle.** The map takes the six buttons whenever it is on screen. Unlike the widget, which appears unbidden while you stand somewhere, the map is a thing you deliberately opened and it covers 90% of the screen. If a toggle is wanted later it is a `cfg.gpad` flag and one `and cfg.gpad` in the handler.
  2. **B at the top closes the map.** The spec stops at "zoom back out"; without this a controller has no way to close the map at all, since the existing close is the Escape *key*.
  3. **An overview marker that stands for no zone points does nothing on A**, exactly as it does nothing on a click today. Five markers are like this (`Aht Urhgan`, and the four past-map Beastmen icons).

---

### Task 1: The navigation math

Pure map-pixel geometry: which marker a fresh selection starts on, and which one a direction press lands on. No Ashita, no ImGui, so it is testable outside the game the way `lib/mapmath.lua` is.

**Files:**
- Create: `lib/gpnav.lua`
- Test: `test/test_gpnav.lua`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `gpnav.nearest(list, cx, cy)` → integer index into `list`, or `nil` for an empty list. `list` is an array of tables carrying `.x` and `.y` in source-map pixels. Ties resolve to the lower index.
  - `gpnav.step(list, i, dir)` → integer index, or `nil` when nothing lies that way. `dir` is one of `'up'`, `'down'`, `'left'`, `'right'`; anything else answers `nil`. Never returns `i`.

- [ ] **Step 1: Write the failing test**

Create `test/test_gpnav.lua`:

```lua
--[[
* Self-check for the gamepad's map navigation math.  Two things have to hold:
* a fresh selection lands on the marker nearest the middle of the view, and a
* direction press lands on the marker that way rather than on a nearer one off
* to the side.  A marker no press can reach would be stranded, so the real map
* data is walked as well.  Run with any Lua 5.1+:
*     lua test/test_gpnav.lua
--]]

local gp = assert(loadfile('lib/gpnav.lua'))();

-- A 3x3 grid 100 apart, listed row by row -- 1 2 3 / 4 5 6 / 7 8 9 -- so 5 is
-- the middle one.  y grows downwards, the way the map's pixels do, which makes
-- 'up' the smaller y.
local grid = { };
for row = 0, 2 do
    for col = 0, 2 do
        table.insert(grid, { x = col * 100, y = row * 100 });
    end
end

-- An empty list has no answer at all, which is what an over-filtered map hands
-- in: every marker faded back leaves nothing to land on.
assert(gp.nearest({ }, 0, 0) == nil);
assert(gp.nearest(grid, 100, 100) == 5);
assert(gp.nearest(grid, 190, 10) == 3);
-- A tie goes to the earlier entry, so the same view always opens on the same
-- marker rather than picking between two by table order luck.
assert(gp.nearest({ { x = 0, y = 0 }, { x = 0, y = 0 } }, 0, 0) == 1);

-- From the middle of the grid, each direction is the neighbour that way.
assert(gp.step(grid, 5, 'up')    == 2);
assert(gp.step(grid, 5, 'down')  == 8);
assert(gp.step(grid, 5, 'left')  == 4);
assert(gp.step(grid, 5, 'right') == 6);

-- Nothing that way leaves the selection where it is, rather than wrapping to
-- the far side of the world: a map is not a menu.
assert(gp.step(grid, 2, 'up')    == nil);
assert(gp.step(grid, 8, 'down')  == nil);
assert(gp.step(grid, 4, 'left')  == nil);
assert(gp.step(grid, 6, 'right') == nil);

-- A press never lands back on where it started, whatever it is handed.
for _, dir in ipairs({ 'up', 'down', 'left', 'right' }) do
    for i = 1, #grid do
        assert(gp.step(grid, i, dir) ~= i);
    end
end
-- A button that is not a direction, and an index off the end of the list,
-- answer nothing instead of throwing.
assert(gp.step(grid, 5, 'a')   == nil);
assert(gp.step(grid, 99, 'up') == nil);

-- The marker straight ahead wins over a nearer one off to the side, which is
-- what makes a column of points walk like a column.
local aside = { { x = 0, y = 0 }, { x = 100, y = 0 }, { x = 50, y = 60 } };
assert(gp.step(aside, 1, 'right') == 2);
-- Far enough ahead and the one to the side wins after all: it is a preference,
-- not a blinker, or half the map would be unreachable.
local far = { { x = 0, y = 0 }, { x = 400, y = 0 }, { x = 50, y = 60 } };
assert(gp.step(far, 1, 'right') == 3);

-- Nothing on either map is left where the D-pad cannot get to it.  Walked over
-- the real data, since that is the only thing that says whether some corner of
-- Vana'diel is stranded: start where a fresh selection would, and see how far
-- the four directions reach from there.
local data = assert(loadfile('lib/points.lua'))();

local function reachable(list)
    if (#list == 0) then
        return;
    end
    local x0, y0, x1, y1;
    for _, ic in ipairs(list) do
        x0 = math.min(x0 or ic.x, ic.x);  y0 = math.min(y0 or ic.y, ic.y);
        x1 = math.max(x1 or ic.x, ic.x);  y1 = math.max(y1 or ic.y, ic.y);
    end
    local start = gp.nearest(list, (x0 + x1) / 2, (y0 + y1) / 2);
    local seen, queue = { [start] = true }, { start };
    while (#queue > 0) do
        local i = table.remove(queue);
        for _, dir in ipairs({ 'up', 'down', 'left', 'right' }) do
            local j = gp.step(list, i, dir);
            if (j ~= nil and not seen[j]) then
                seen[j] = true;
                table.insert(queue, j);
            end
        end
    end
    for i, ic in ipairs(list) do
        assert(seen[i], ('%s cannot be reached with the D-pad'):format(
                            tostring(ic.label)));
    end
end

local checked = 0;
for _, time in ipairs({ 'present', 'past' }) do
    -- The overview tier: every group's icons on this map, which is the list
    -- walked before anything has been zoomed into.
    local over = { };
    for _, g in ipairs(data.groups) do
        for _, ic in ipairs(g.icons) do
            if ((ic.time or 'present') == time) then
                table.insert(over, ic);
            end
        end
    end
    reachable(over);
    checked = checked + #over;

    -- And the zone points inside one marker of it, which is the list walked
    -- once one has been.
    local by_group = { };
    for _, ic in ipairs(data.points) do
        if ((ic.time or 'present') == time) then
            by_group[ic.group] = by_group[ic.group] or { };
            table.insert(by_group[ic.group], ic);
        end
    end
    for _, list in pairs(by_group) do
        reachable(list);
        checked = checked + #list;
    end
end

print(('gpnav OK: %d markers reachable'):format(checked));
```

- [ ] **Step 2: Run it to make sure it fails**

Run from the repo root:

```bash
lua test/test_gpnav.lua
```

Expected: FAIL — `cannot open lib/gpnav.lua` out of the `assert(loadfile(...))` on line 12.

- [ ] **Step 3: Write the implementation**

Create `lib/gpnav.lua`:

```lua
--[[
* UberMap - gamepad map navigation math.
*
* Which marker a direction press lands on, and which one a fresh selection
* starts at.  Kept free of Ashita/ImGui dependencies so it can be exercised
* outside the game by test_gpnav.lua, the same way lib/mapmath.lua is.  All
* coordinates are source-map pixels, y growing downwards, so 'up' is towards
* the smaller y.
--]]

local M = { };

-- How far off to the side of the pressed direction a marker is allowed to be,
-- priced as a multiple of how far off it is.  Anything above 1 prefers the
-- marker straight ahead over a nearer one to the side, which is what makes a
-- column of zone points walk like a column; too high and the far side of the
-- map stops being reachable at all.  test_gpnav.lua walks the real data at
-- this weight and finds nothing stranded on either map.
local SIDE_WEIGHT = 2;

-- Offset from the current marker -> how far ahead it is in the pressed
-- direction, and how far off to the side.  Only the first decides whether a
-- marker is a candidate, so a press never lands behind where it started.
local AXIS = {
    up    = function(dx, dy) return -dy,  dx; end,
    down  = function(dx, dy) return  dy,  dx; end,
    left  = function(dx, dy) return -dx,  dy; end,
    right = function(dx, dy) return  dx,  dy; end,
};

--[[
* The index of the marker nearest (cx, cy), or nil for an empty list.  Ties go
* to the earlier entry, so the same list and the same centre always answer the
* same way rather than picking between two by table order luck.
--]]
function M.nearest(list, cx, cy)
    local best, best_d;
    for i, ic in ipairs(list) do
        local dx, dy = ic.x - cx, ic.y - cy;
        -- Squared: the ordering is the same and there is no root to take.
        local d = dx * dx + dy * dy;
        if (best_d == nil or d < best_d) then
            best, best_d = i, d;
        end
    end
    return best;
end

--[[
* The index a press of 'dir' from list[i] lands on, or nil when nothing lies
* that way -- which leaves the selection where it is rather than wrapping round
* to the far side of the world.  A direction that is not one of the four, and
* an index that is not in the list, answer nil as well.
--]]
function M.step(list, i, dir)
    local axis = AXIS[dir];
    local cur  = list[i];
    if (axis == nil or cur == nil) then
        return nil;
    end
    local best, best_s;
    for j, ic in ipairs(list) do
        if (j ~= i) then
            local fwd, side = axis(ic.x - cur.x, ic.y - cur.y);
            if (fwd > 0) then
                local s = fwd + SIDE_WEIGHT * math.abs(side);
                if (best_s == nil or s < best_s) then
                    best, best_s = j, s;
                end
            end
        end
    end
    return best;
end

return M;
```

- [ ] **Step 4: Run the test and make sure it passes**

```bash
lua test/test_gpnav.lua
```

Expected: PASS, printing `gpnav OK: 228 markers reachable` (the count follows `lib/points.lua`, so it moves as points are added; what matters is that no `assert` above it fired).

- [ ] **Step 5: Commit**

```bash
git add lib/gpnav.lua test/test_gpnav.lua
git commit -m "feat: add gamepad map navigation math"
```

---

### Task 2: Buttons, selection and hover

The six buttons come off the client while the map is up, queue up for the next frame, and the D-pad moves a highlight around the markers. A and B queue too but do nothing yet — they are Tasks 3 and 4.

**Files:**
- Modify: `ubermap.lua` — require block (~line 27), after the `FW` table (~line 380), the `ui` table (~line 628), `draw_icons` (~line 1826), a new block before `ask_for_masks` (~line 2013), `show` (~line 2037), the top of `draw_map` (~line 2653), and the `xinput_button` handler (~line 3391)
- Test: `test/test_gpad.lua`

**Interfaces:**
- Consumes: `gpnav.nearest(list, cx, cy)`, `gpnav.step(list, i, dir)` from Task 1.
- Produces:
  - `GP` — file-local table, XInput button index → action name, `{ [0]='up', [1]='down', [2]='left', [3]='right', [12]='a', [13]='b' }`.
  - `GP_QUEUE_MAX` — file-local number, `8`.
  - `ui.gp_icon` — the selected icon table itself, or nil for none. Read by `draw_icons`.
  - `ui.gp_from` — the overview icon A zoomed in from, or nil. Written in Task 3.
  - `ui.gp_row` — 1-based warp popup row, or nil for none lit. Used in Task 4.
  - `ui.gp_q` — array of queued action names; `ui.gp_held` — set of button indices whose press the map took.
  - `gp_list()` → array of the icon tables the gamepad can land on right now.
  - `gp_focus(view_w, view_h)` → `list, i`; ensures `ui.gp_icon` is on that list, re-centring it when it is not.
  - `gp_act(act, view_w, view_h)` → nil; acts on one queued action.
  - `gp_pump(view_w, view_h)` → nil; drains `ui.gp_q`.

- [ ] **Step 1: Write the failing test**

Create `test/test_gpad.lua`. It mirrors the handler the way `test_widget.lua` mirrors `fw_confirm`, because the handler itself needs Ashita to run:

```lua
--[[
* Self-check for which gamepad buttons the map takes and which it leaves to the
* client.  Mirrors the xinput_button handler in ubermap.lua: the favorites
* widget is asked first and wins outright, the map takes buttons only while it
* is on screen, and a release is blocked exactly when its press was -- a
* release handed to the client without the press would leave a button stuck
* down in the game's own menus.  Run with any Lua 5.1+:
*     lua test/test_gpad.lua
--]]

local fails = 0;
local function check(ok, msg)
    if (not ok) then
        fails = fails + 1;
        print('FAIL: ' .. msg);
    end
end

-- The two tables, exactly as ubermap.lua keys them: the XInput button index
-- the event delivers.
local GP = { [0] = 'up', [1] = 'down', [2] = 'left', [3] = 'right',
             [12] = 'a', [13] = 'b' };
local FW = { [0] = 'up', [1] = 'down', [12] = 'a', [13] = 'b' };
local GP_QUEUE_MAX = 8;

local ui, favs_n;
local function reset()
    ui = { fw_on = false, is_open = false, zoom = 1.0, fw_sel = 1,
           gp_q = { }, gp_held = { }, fw_held = { } };
    favs_n = 0;
end

-- The handler, minus the two calls into the map that need a frame behind them.
-- Hands back whether the press was blocked, which is the whole question.
local function button(index, state)
    local act = GP[index];
    if (act == nil) then
        return false;
    end
    if (state ~= 1) then
        if (ui.fw_held[index] or ui.gp_held[index]) then
            ui.fw_held[index], ui.gp_held[index] = nil, nil;
            return true;
        end
        return false;
    end
    if (ui.fw_on) then
        if (FW[index] == nil or favs_n == 0) then
            return false;
        end
        ui.fw_held[index] = true;
        if (act == 'up') then
            ui.fw_sel = (ui.fw_sel - 2) % favs_n + 1;
        elseif (act == 'down') then
            ui.fw_sel = ui.fw_sel % favs_n + 1;
        end
        return true;
    end
    if (not ui.is_open or ui.zoom == nil) then
        return false;
    end
    ui.gp_held[index] = true;
    if (#ui.gp_q < GP_QUEUE_MAX) then
        table.insert(ui.gp_q, act);
    end
    return true;
end

local ALL = { 0, 1, 2, 3, 12, 13 };

-- Every button the widget reads is one the map reads, under the same name, so
-- the two never disagree about what a press means.
for i, name in pairs(FW) do
    check(GP[i] == name, ('button %d should mean %q to both'):format(i, name));
end

-- Map shut: every one of the six is the client's, and nothing is queued.
reset();
for _, i in ipairs(ALL) do
    check(not button(i, 1), ('button %d should be the client\'s with the map shut'):format(i));
    check(not button(i, 0), ('button %d release should follow its press'):format(i));
end
check(#ui.gp_q == 0, 'a shut map should queue nothing');

-- Map open and the widget down: all six are taken, in the order pressed.
reset();
ui.is_open = true;
for _, i in ipairs(ALL) do
    check(button(i, 1), ('button %d should be taken with the map open'):format(i));
end
check(#ui.gp_q == 6, ('six presses should queue six actions, queued %d'):format(#ui.gp_q));
check(ui.gp_q[1] == 'up' and ui.gp_q[4] == 'right' and ui.gp_q[6] == 'b',
      'the queue should hold the actions in the order they were pressed');

-- The release of a press that was taken is taken too, and only once: a second
-- one is a release the client never gave us a press for.
for _, i in ipairs(ALL) do
    check(button(i, 0), ('button %d release should be taken'):format(i));
    check(not button(i, 0), ('button %d should only release once'):format(i));
end

-- The widget in front: it reads four of the six and the map gets none of them,
-- so walking up to a warp NPC still puts the widget first whatever is behind.
reset();
ui.is_open, ui.fw_on, favs_n = true, true, 3;
for _, i in ipairs({ 0, 1, 12, 13 }) do
    check(button(i, 1), ('button %d should be the widget\'s'):format(i));
end
check(#ui.gp_q == 0, 'the map should queue nothing while the widget is up');
-- One step each way, so the selection is back where it started: both of the
-- D-pad presses landed on the widget rather than on the map behind it.
check(ui.fw_sel == 1, ('the widget selection should have walked, is %d'):format(ui.fw_sel));
-- The two the widget does not read stay the client's rather than falling
-- through to the map behind it.
for _, i in ipairs({ 2, 3 }) do
    check(not button(i, 1), ('button %d should be the client\'s under the widget'):format(i));
end

-- A queue nothing is draining is a map that is not being drawn -- collapsed,
-- or behind a texture that failed -- and a hundred presses landing at once
-- when it comes back is worse than losing them.
reset();
ui.is_open = true;
for _ = 1, 20 do
    button(0, 1);
    button(0, 0);
end
check(#ui.gp_q == GP_QUEUE_MAX,
      ('the queue should cap at %d, holds %d'):format(GP_QUEUE_MAX, #ui.gp_q));

-- Nothing else on the pad is anybody's business: Start, X and Y stay the
-- client's with the map wide open.
reset();
ui.is_open = true;
for _, i in ipairs({ 4, 5, 8, 9, 14, 15 }) do
    check(not button(i, 1), ('button %d is not the map\'s'):format(i));
end

if (fails == 0) then
    print('ok: the widget wins, the map takes the six, releases follow presses');
else
    print(('%d check(s) failed'):format(fails));
    os.exit(1);
end
```

- [ ] **Step 2: Run it and read what it is claiming**

```bash
lua test/test_gpad.lua
```

Expected: PASS, printing `ok: the widget wins, the map takes the six, releases follow presses`.

It passes straight away, and that is the honest situation: the handler needs Ashita to run, so this file mirrors it the way `test/test_widget.lua` mirrors `fw_confirm`. What it is worth is that the rules are written down and checked against each other before the handler exists — a release that leaks without its press, a widget the map talks over, an unbounded queue. Step 7 is where it is cashed in: the finished handler gets read against this mirror line by line. If any check above fails now, the mirror itself is wrong; fix it before writing any of `ubermap.lua`.

- [ ] **Step 3: Add the button table and the state it drives**

In `ubermap.lua`, add the require. Find:

```lua
local mm    = require('lib.mapmath');
```

Replace with:

```lua
local mm    = require('lib.mapmath');
local gpn   = require('lib.gpnav');
```

Find the `FW` table:

```lua
local FW = {
    [0]  = 'up',
    [1]  = 'down',
    [12] = 'a',
    [13] = 'b',
};
```

Replace with:

```lua
local FW = {
    [0]  = 'up',
    [1]  = 'down',
    [12] = 'a',
    [13] = 'b',
};

-- The map reads the same four and the D-pad's other axis, keyed the same way.
-- It takes them only while it is on screen, which is a place the player put it
-- rather than one they walked into, so unlike the widget it needs no toggle to
-- justify swallowing them: the map is what a press is for while it is up.
local GP = {
    [0]  = 'up',
    [1]  = 'down',
    [2]  = 'left',
    [3]  = 'right',
    [12] = 'a',
    [13] = 'b',
};

-- How many presses may wait for a frame that is not coming.  A queue nothing
-- is draining is a map that is not being drawn -- the window collapsed, say --
-- and a hundred presses landing at once when it comes back is worse than
-- losing them.
local GP_QUEUE_MAX = 8;
```

Find, in the `ui` table:

```lua
    fw_held     = {},        -- buttons whose press the widget took, by index
```

Replace with:

```lua
    fw_held     = {},        -- buttons whose press the widget took, by index
    -- Gamepad map navigation.  The selection is the icon itself rather than a
    -- slot in a list, because the list it walks is built fresh out of whatever
    -- is on screen at each press; gp_from is the overview marker A zoomed in
    -- from, so B can put the view back with that one lit.  Both are nil until
    -- a button is pressed, which is what keeps a highlight off the map of
    -- somebody who is only ever using the mouse.
    gp_icon     = nil,
    gp_from     = nil,
    gp_row      = nil,       -- the warp list row lit, 1-based, nil for none
    gp_q        = {},        -- actions waiting for a frame to act on them
    gp_held     = {},        -- buttons whose press the map took, by index
```

- [ ] **Step 4: Add the list, the selection and the pump**

Find, just above `ask_for_masks`:

```lua
--[[
* Asks the server for the map markers, which it answers with the teleport masks
```

Replace with (the new block, then the comment that was there):

```lua
--[[
* Every marker the gamepad can land on right now: what is drawn, minus what is
* faded back -- the same two tests draw_icons puts a marker on the screen and
* under the cursor by.  Which tier that is answers itself, since the overview
* markers are the ones drawn below ZOOM_POINTS and the zone points the ones
* drawn above it: zooming with the wheel moves the selection between tiers as
* surely as an A press does, with no separate level to keep in step with it.
--]]
local function gp_list()
    local list = { };
    for _, ic in ipairs(ICONS) do
        if (icon_visible(ic) and not icon_dim(ic)) then
            table.insert(list, ic);
        end
    end
    return list;
end

--[[
* The list, and where in it the selection sits.  A selection that is not on the
* list any more -- zoomed past, filtered out by the toggles or the search box,
* or never made at all -- restarts at the marker nearest the middle of the
* viewport, which is what puts the first press of a session on the centre-most
* nation and what recovers every stale one after that.
--]]
local function gp_focus(view_w, view_h)
    local list = gp_list();
    for i, ic in ipairs(list) do
        if (ic == ui.gp_icon) then
            return list, i;
        end
    end
    local i = gpn.nearest(list,
                          mm.to_map(view_w / 2, ui.pan_x, ui.zoom, 0),
                          mm.to_map(view_h / 2, ui.pan_y, ui.zoom, 0));
    ui.gp_icon = (i ~= nil) and list[i] or nil;
    return list, i;
end

--[[
* Acts on one queued press, at the frame that knows how big the viewport is.
--]]
local function gp_act(act, view_w, view_h)
    local list, i = gp_focus(view_w, view_h);
    local j = gpn.step(list, i, act);
    if (j ~= nil) then
        ui.gp_icon = list[j];
    end
end

--[[
* Drains the presses that arrived since the last frame.  A queue rather than
* one pending action, so two presses inside a frame both land instead of the
* second eating the first; nothing is touched on a frame with no press in it,
* which is what keeps the gamepad's highlight off a map nobody has pressed a
* button at.
--]]
local function gp_pump(view_w, view_h)
    if (#ui.gp_q == 0) then
        return;
    end
    for _, act in ipairs(ui.gp_q) do
        gp_act(act, view_w, view_h);
    end
    ui.gp_q = { };
end

--[[
* Asks the server for the map markers, which it answers with the teleport masks
```

- [ ] **Step 5: Draw the selection, reset it on open, pump it in the draw**

Find, in `draw_icons`:

```lua
            local hot = over_map and not dim
                and mouse_x >= cx - half and mouse_x <= cx + half
                and mouse_y >= cy - half and mouse_y <= cy + half;
            local tex = nil;
            if (hot) then
                hot_ic = ic;
                tex = icon_texture((ic.file:gsub('_0%.png$', '_1.png')));
            end
```

Replace with:

```lua
            local hot = over_map and not dim
                and mouse_x >= cx - half and mouse_x <= cx + half
                and mouse_y >= cy - half and mouse_y <= cy + half;
            if (hot) then
                hot_ic = ic;
            end
            -- The gamepad's landing wears the same hover the cursor gives, so
            -- one thing on screen says what a press would act on.  It is not
            -- fed back as hot_ic: that is what a click acts on, and a click
            -- has to mean wherever the cursor actually is.  A marker faded
            -- back is not lit whatever the selection says, the same way it
            -- takes no cursor -- a stale selection left behind by the wheel is
            -- put right at the next press, not here.
            local lit = hot or (not dim and ic == ui.gp_icon);
            local tex = nil;
            if (lit) then
                tex = icon_texture((ic.file:gsub('_0%.png$', '_1.png')));
            end
```

Then find, a few lines below it:

```lua
                local grow  = (hot and ic.group == HOT_GROUP)
                              and half * ICON_HOT or half;
```

Replace with:

```lua
                local grow  = (lit and ic.group == HOT_GROUP)
                              and half * ICON_HOT or half;
```

Find, in `show`:

```lua
    ui.ctx       = nil;
    ask_for_masks();
```

Replace with:

```lua
    ui.ctx       = nil;
    -- The gamepad starts where the view does, which the first frame works out,
    -- and a press left over from the last time the map was up is not this
    -- one's: nothing is queued between the map closing and it opening again.
    ui.gp_icon   = nil;
    ui.gp_from   = nil;
    ui.gp_q      = {};
    ask_for_masks();
```

Find, at the top of `draw_map`:

```lua
    local map_w, map_h = map_size();
    local cover = mm.cover_zoom(map_w, map_h, view_w, view_h);
    ui.zoom = mm.clamp(ui.zoom or cover, cover, MAX_ZOOM);
```

Replace with:

```lua
    local map_w, map_h = map_size();
    local cover = mm.cover_zoom(map_w, map_h, view_w, view_h);
    ui.zoom = mm.clamp(ui.zoom or cover, cover, MAX_ZOOM);

    -- The gamepad's presses, acted on here rather than where they arrive: the
    -- zooms they ask for need the viewport size, and only a frame knows that.
    -- Ahead of the mouse below, so a press and a click on the same frame land
    -- in the order they were made.
    gp_pump(view_w, view_h);
```

- [ ] **Step 6: Rewrite the xinput handler**

Find the whole handler:

```lua
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
```

Replace with:

```lua
--[[
* event: xinput_button
* desc : Two things read the pad, and only ever one at a time.  The favorites
*        widget takes D-pad up and down, A and B while it is on screen, which
*        is only while a warp NPC is in reach.  The map takes those and the
*        D-pad's other axis while it is up: the D-pad walks the markers, A
*        opens what is under it and B backs out.  The widget is asked first, so
*        walking up to an NPC puts it in front of a map that is already open
*        and it has to be dismissed before the map answers again.  Every other
*        button, and every button at all outside those two, is the client's.
--]]
ashita.events.register('xinput_button', 'ubermap_xinput', function (e)
    local act = GP[e.button];
    if (act == nil) then
        return;
    end
```

Then find the rest of that handler's body:

```lua
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
```

Replace with:

```lua
    -- Both edges: the client never saw the press, so it is not handed the
    -- release either.  Which edge was taken is remembered rather than re-tested
    -- against ui.fw_on, because the press is what takes the widget off screen
    -- in two of the four cases -- B dismisses it and A warps out of range of
    -- the NPC holding it up -- and a release matched against the state after
    -- that would leak a button-up the client never got the button-down for.
    -- The map's own presses are held for the same reason: A on a warp row
    -- closes the map before the button comes back up.
    if (e.state ~= 1) then
        if (ui.fw_held[e.button] or ui.gp_held[e.button]) then
            ui.fw_held[e.button] = nil;
            ui.gp_held[e.button] = nil;
            e.blocked = true;
        end
        return;
    end

    -- The widget first, and outright: it is only ever up stood at a warp NPC,
    -- and there it is what a press is for.  The two buttons it does not read
    -- go to the client rather than to the map behind it, or dismissing it
    -- would be the only way to stop the map moving underneath.
    if (ui.fw_on) then
        local n = #fav_view();
        if (FW[e.button] == nil or n == 0) then
            return;
        end
        e.blocked = true;
        ui.fw_held[e.button] = true;

        if (act == 'up') then
            -- Wraps at both ends, the way the game's own menus do.  ponytail:
            -- one step a press; a held-D-pad repeat if a list ever gets long
            -- enough to want one.
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
        return;
    end

    -- The map, while it is on screen and has had a frame size the view.
    -- Queued rather than acted on here: the zooms need the viewport size, and
    -- only the draw knows that.
    if (not ui.is_open[1] or ui.zoom == nil) then
        return;
    end
    e.blocked = true;
    ui.gp_held[e.button] = true;
    if (#ui.gp_q < GP_QUEUE_MAX) then
        table.insert(ui.gp_q, act);
    end
end);
```

- [ ] **Step 7: Run the test and read it against the handler**

```bash
lua test/test_gpad.lua
```

Expected: `gpad OK`.

Then open `ubermap.lua` at the handler and `test/test_gpad.lua` at its `button` function and read them side by side. Every branch must line up: the release check on both held tables, the `ui.fw_on` block returning without blocking for a button `FW` does not name, the `is_open`/`zoom` gate, and the queue cap. Fix whichever one is wrong.

- [ ] **Step 8: Check it in the game**

`/addon reload ubermap`, open the map at a Home Point, and press the D-pad. Expected: a marker takes the hover art with no cursor near it, and each press moves it to the neighbour in that direction. The character does not move while the map is up. Close the map and press the D-pad again: the character moves as usual.

- [ ] **Step 9: Commit**

```bash
git add ubermap.lua test/test_gpad.lua
git commit -m "feat: walk the map markers with the D-pad"
```

---

### Task 3: A and B between the overview and a nation

A on a nation or region frames its zone points and lands on the centre-most one; B comes back out with that nation lit again; B at the top closes the map.

**Files:**
- Modify: `ubermap.lua` — `gp_act` (added in Task 2), and the mouse release in `draw_map` (~line 2751)

**Interfaces:**
- Consumes: `gp_focus(view_w, view_h)`, `ui.gp_icon`, `ui.gp_from` from Task 2; the existing `zoom_to_group(name, view_w, view_h)` → boolean, `zoom_to_map(view_w, view_h)`, `OVERVIEW[group_name]` → boolean, `warp_rows(label)` → array or nil, `ui.focus`, `ui.warp`, `ui.is_open`.
- Produces: `gp_act` handling `'a'` and `'b'`; `ui.gp_from` written by both the gamepad and the mouse.

- [ ] **Step 1: Teach gp_act the two buttons**

Find the whole of `gp_act` as Task 2 left it:

```lua
--[[
* Acts on one queued press, at the frame that knows how big the viewport is.
--]]
local function gp_act(act, view_w, view_h)
    local list, i = gp_focus(view_w, view_h);
    local j = gpn.step(list, i, act);
    if (j ~= nil) then
        ui.gp_icon = list[j];
    end
end
```

Replace with:

```lua
--[[
* Acts on one queued press, at the frame that knows how big the viewport is.
*
* Nested the way the game's own menus are: the overview, the zone points inside
* one marker of it, and the warp list inside one of those.  A takes the next
* one down and B comes back up.  There is no level held anywhere, because the
* view already says which one it is on -- ui.focus is set exactly while a
* marker has been zoomed into, by a click as much as by an A press, so the two
* ways in share the one way out.
--]]
local function gp_act(act, view_w, view_h)
    local list, i = gp_focus(view_w, view_h);

    if (act == 'a') then
        local ic = ui.gp_icon;
        if (ic == nil) then
            return;
        end
        if (OVERVIEW[ic.group]) then
            -- Into the marker's zone points, framed the way a click frames
            -- them.  The selection is dropped rather than carried down: the
            -- view has moved, so the next gp_focus lands on the centre-most
            -- point of what was just framed.  A marker standing for no zone
            -- points at all frames nothing and stays where it is, exactly as
            -- a click on it does.
            if (zoom_to_group(ic.label, view_w, view_h)) then
                ui.gp_from = ic;
                ui.gp_icon = nil;
            end
        end
        return;
    end

    if (act == 'b') then
        if (ui.focus ~= nil) then
            -- Back out to the whole map with the marker that was zoomed into
            -- lit, so the way back in is one A press.  gp_from is nil when the
            -- view was framed by a search rather than by a marker, and then
            -- the selection restarts in the middle like any other stale one.
            zoom_to_map(view_w, view_h);
            ui.focus   = nil;
            ui.warp    = nil;
            ui.gp_icon = ui.gp_from;
            ui.gp_from = nil;
        else
            -- Already at the top, so B is what it is everywhere else in the
            -- game: the way out.  Escape does this for a keyboard, and a
            -- controller has nothing else that would.
            ui.is_open[1] = false;
        end
        return;
    end

    local j = gpn.step(list, i, act);
    if (j ~= nil) then
        ui.gp_icon = list[j];
    end
end
```

- [ ] **Step 2: Let a click leave the same trail**

Find, in `draw_map`:

```lua
        if (ui.press ~= nil and imgui.IsMouseReleased(0)) then
            if (OVERVIEW[ui.press.group]) then
                zoom_to_group(ui.press.label, view_w, view_h);
            else
```

Replace with:

```lua
        if (ui.press ~= nil and imgui.IsMouseReleased(0)) then
            if (OVERVIEW[ui.press.group]) then
                -- A click is the mouse's own way down the same nesting the
                -- gamepad walks, so B backs out of one as readily as the
                -- other: whichever marker was gone into is the one the way
                -- back out lands on.
                if (zoom_to_group(ui.press.label, view_w, view_h)) then
                    ui.gp_from = ui.press;
                end
            else
```

- [ ] **Step 3: Check it in the game**

`/addon reload ubermap`, open the map, and:

1. D-pad onto a nation or region, press **A**. Expected: the view frames that group's zone points and the hover is on the one nearest the middle of the framed view.
2. D-pad around inside it. Expected: the hover moves between that group's points only — everything else is faded back and takes no press.
3. Press **B**. Expected: the view pulls back to the whole map with the nation or region you came out of still hovered. Press **A** again: straight back in.
4. Press **B** at the whole-map view. Expected: the map closes.
5. Click a nation with the mouse, then press **B**. Expected: it backs out to the whole map with that nation hovered.
6. Press **A** on `Aht Urhgan` (present) or a past-map Beastmen icon. Expected: nothing happens and the hover stays put, the same as clicking one.

- [ ] **Step 4: Commit**

```bash
git add ubermap.lua
git commit -m "feat: zoom into a nation with A and back out with B"
```

---

### Task 4: The warp list

A on a zone point opens its warp panel with a row lit, up and down walk it, A sends the row, B shuts it.

**Files:**
- Modify: `ubermap.lua` — `gp_act` (~line 2060 after Task 3), `draw_warp_popup` (~line 2490), and the mouse release in `draw_map` (~line 2760)
- Test: `test/test_gpwarp.lua`

**Interfaces:**
- Consumes: `ui.gp_row` from Task 2; `gp_act` from Task 3; the existing `warp_rows(label)` → array of rows carrying `.label`, `.type`, `.pos`; `warp_cmd(label, row)` → string or nil; `warp_known(label, row)` → boolean; `send_cmd(cmd)`; `ui.near_kind`; `mm.clamp(v, lo, hi)`.
- Produces: `gp_rows()` → the open panel's rows or nil; `gp_act` handling the warp tier; a lit row in `draw_warp_popup`.

- [ ] **Step 1: Write the failing test**

Create `test/test_gpwarp.lua`:

```lua
--[[
* Self-check for the gamepad's warp list.  Three things have to hold: up and
* down wrap at both ends the way the favorites widget does, A sends only a row
* that can travel -- the same two tests (the kind of NPC in reach, the
* destination registered) the row is coloured on -- and a list opened with the
* mouse lights no row until a button is pressed, so the first press lands on
* the top row instead of stepping off a selection nothing on screen shows.
* Mirrors the warp tier of gp_act in ubermap.lua.  Run with any Lua 5.1+:
*     lua test/test_gpwarp.lua
--]]

local fails = 0;
local function check(ok, msg)
    if (not ok) then
        fails = fails + 1;
        print('FAIL: ' .. msg);
    end
end

-- The list under test, and what the world looks like around it.
local rows = {
    { label = 'Home Point #1',  type = 'home'  },
    { label = 'Survival Guide', type = 'guide' },
    { label = 'Home Point #2',  type = 'home'  },
};
-- Stands in for the teleport masks: everything registered but Home Point #2.
local registered = { ['Home Point #2'] = false };
local near_kind  = 'home';
local open, row  = true, nil;

local function clamp(v, lo, hi)
    return math.max(lo, math.min(v, hi));
end

-- One press, exactly as gp_act reads it.  Hands back the row it would send, or
-- nil where it sends nothing.
local function act(a)
    local n = #rows;
    if (a == 'b') then
        open = false;
        return nil;
    end
    if (row == nil) then
        row = 1;
        return nil;
    end
    row = clamp(row, 1, n);
    if (a == 'up') then
        row = (row - 2) % n + 1;
    elseif (a == 'down') then
        row = row % n + 1;
    elseif (a == 'a') then
        local r = rows[row];
        if (r ~= nil and r.type == near_kind
            and registered[r.label] ~= false) then
            return r;
        end
    end
    return nil;
end

-- Opened with the mouse: the first press lights the top row and sends nothing,
-- rather than travelling somewhere nobody had picked.
row = nil;
check(act('a') == nil, 'the first press on a mouse-opened list should send nothing');
check(row == 1, ('the first press should light the top row, lit %s'):format(tostring(row)));

-- Down walks the list in order and comes back round to the top.
row = 1;
for i = 1, #rows do
    check(row == i, ('down should be on row %d, is %d'):format(i, row));
    act('down');
end
check(row == 1, 'down off the last row should wrap to the first');

-- Up walks it backwards, and off the first row lands on the last.
act('up');
check(row == #rows, 'up off the first row should wrap to the last');

-- Stood at a Home Point: the registered Home Point row travels.
row = 1;
check(act('a') == rows[1], 'a registered row of the kind in reach should send');

-- The Survival Guide row does not, standing at a Home Point.
row = 2;
check(act('a') == nil, 'a guide row should not send from a Home Point');

-- Nor does the Home Point nobody has ever stood at: the /uw would be turned
-- down at the NPC, and a row that looks live but does nothing reads as broken.
row = 3;
check(act('a') == nil, 'an unregistered row should take no press');

-- The toggles can empty rows out from under an open list, so a landing past
-- the end is pulled back inside it before it steps.
row = 9;
act('up');
check(row == 2, ('a stale row should be pulled back in, landed on %s'):format(tostring(row)));

-- B shuts the list whatever is lit, including nothing.
row, open = nil, true;
act('b');
check(not open, 'B should shut a list with no row lit');
row, open = 2, true;
act('b');
check(not open, 'B should shut a list with a row lit');

if (fails == 0) then
    print('ok: the row wrap, the A gate and the unlit first press all hold');
else
    print(('%d check(s) failed'):format(fails));
    os.exit(1);
end
```

- [ ] **Step 2: Run it and read what it is claiming**

```bash
lua test/test_gpwarp.lua
```

Expected: PASS, printing `ok: the row wrap, the A gate and the unlit first press all hold`.

As in Task 2 this file mirrors rather than imports, so it goes green before `gp_act` exists; what it buys is the rules written down and checked against each other first. Step 6 is where it is cashed in against the real thing. A failure here means the mirror is wrong — fix it before touching `ubermap.lua`.

- [ ] **Step 3: Add the warp tier to gp_act**

Find, immediately above `gp_act`:

```lua
--[[
* Acts on one queued press, at the frame that knows how big the viewport is.
*
```

Insert this function above that comment, so the file reads `gp_rows` then `gp_act`:

```lua
--[[
* The warp rows the panel is showing, or nil while it is shut.  The same call
* the panel makes for itself, kept out here so the gamepad's row arithmetic is
* not tangled up in the drawing.
--]]
local function gp_rows()
    return (ui.warp ~= nil) and warp_rows(ui.warp.label) or nil;
end

--[[
* Acts on one queued press, at the frame that knows how big the viewport is.
*
```

Then find, inside `gp_act`:

```lua
local function gp_act(act, view_w, view_h)
    local list, i = gp_focus(view_w, view_h);

    if (act == 'a') then
```

Replace with:

```lua
local function gp_act(act, view_w, view_h)
    -- The innermost tier first: with a warp list open it is what every press
    -- is for, and the markers underneath are not to move about behind it.
    local rows = gp_rows();
    if (rows ~= nil) then
        if (act == 'b') then
            ui.warp = nil;
            return;
        end
        if (ui.gp_row == nil) then
            -- The list was opened with the cursor, which lights no row of its
            -- own.  The first press lands on the top row rather than stepping
            -- off a selection nothing on screen is showing.
            ui.gp_row = 1;
            return;
        end
        -- The toggles can empty rows out from under a list that is open, so
        -- the landing is pulled back inside it before it steps.
        local n = #rows;
        ui.gp_row = mm.clamp(ui.gp_row, 1, n);
        if (act == 'up') then
            -- Wraps at both ends, like the widget's list and the game's menus.
            ui.gp_row = (ui.gp_row - 2) % n + 1;
        elseif (act == 'down') then
            ui.gp_row = ui.gp_row % n + 1;
        elseif (act == 'a') then
            -- The same two tests the row is coloured on: it travels only from
            -- the kind of NPC in reach, and only somewhere registered.  A row
            -- that fails either takes no press, exactly as it takes no click:
            -- the /uw would be turned down at the NPC, and a row that looks
            -- live but does nothing reads as a broken list.
            local r = rows[ui.gp_row];
            if (r ~= nil and r.type == ui.near_kind
                and warp_known(ui.warp.label, r)) then
                local cmd = warp_cmd(ui.warp.label, r);
                if (cmd ~= nil) then
                    -- Which closes the map and the panel with it, the way
                    -- sending always has.
                    send_cmd(cmd);
                end
            end
        end
        return;
    end

    local list, i = gp_focus(view_w, view_h);

    if (act == 'a') then
```

Then find, in the `'a'` branch that Task 3 wrote:

```lua
            if (zoom_to_group(ic.label, view_w, view_h)) then
                ui.gp_from = ic;
                ui.gp_icon = nil;
            end
        end
        return;
    end
```

Replace with:

```lua
            if (zoom_to_group(ic.label, view_w, view_h)) then
                ui.gp_from = ic;
                ui.gp_icon = nil;
            end
        else
            -- A zone nothing warps to leaves the panel shut rather than
            -- opening an empty one, the same test the click makes.  Opened
            -- from the pad, so the top row is lit and A would send it.
            if (warp_rows(ic.label) ~= nil) then
                ui.warp   = ic;
                ui.gp_row = 1;
            end
        end
        return;
    end
```

- [ ] **Step 4: Light the row in the panel**

Find, in `draw_warp_popup`:

```lua
            pdl:AddRect({ px, py }, { px + w, py + h }, COL_OUTLINE,
                        0, ImDrawCornerFlags_All, ICON_BORDER);
```

Replace with:

```lua
            pdl:AddRect({ px, py }, { px + w, py + h }, COL_OUTLINE,
                        0, ImDrawCornerFlags_All, ICON_BORDER);
            -- Kept inside the outline at both ends, so a lit first or last row
            -- does not paint over the border it sits against.  The same fill
            -- the favorites list lights its own rows with.
            local function light(ry)
                pdl:AddRectFilled(
                    { px + ICON_BORDER, math.max(ry, py + ICON_BORDER) },
                    { px + w - ICON_BORDER,
                      math.min(ry + POPUP_ROW, py + h - ICON_BORDER) },
                    COL_HOVER, 0, ImDrawCornerFlags_All);
            end
```

Then find, in the row loop below it:

```lua
                if (live and known and over) then
                    hot_row = r;
                    pdl:AddRectFilled(
                        { px + ICON_BORDER, math.max(ry, py + ICON_BORDER) },
                        { px + w - ICON_BORDER,
                          math.min(ry + POPUP_ROW, py + h - ICON_BORDER) },
                        COL_HOVER, 0, ImDrawCornerFlags_All);
                end
```

Replace with:

```lua
                -- The gamepad's landing, lit whatever the cursor is doing, the
                -- way the favorites widget lights its own selection.  Nil
                -- while the list was opened with the mouse, which lights the
                -- row under the cursor and nothing else.  A row that is both
                -- reads brighter, the two fills stacking.
                if (i == ui.gp_row) then
                    light(ry);
                end
                if (live and known and over) then
                    hot_row = r;
                    light(ry);
                end
```

- [ ] **Step 5: Leave no row lit when the mouse opens the panel**

Find, in `draw_map`:

```lua
                -- A zone nothing warps to leaves the panel shut rather than
                -- opening an empty one.
                ui.warp = (warp_rows(ui.press.label) ~= nil) and ui.press or nil;
```

Replace with:

```lua
                -- A zone nothing warps to leaves the panel shut rather than
                -- opening an empty one.
                ui.warp = (warp_rows(ui.press.label) ~= nil) and ui.press or nil;
                -- Opened with the cursor, so no row is lit: the hover is what
                -- says which one a click would send, and a second highlight
                -- sitting on the top row would only argue with it.
                ui.gp_row = nil;
```

- [ ] **Step 6: Run the test and read it against gp_act**

```bash
lua test/test_gpwarp.lua
```

Expected: `gpwarp OK`.

Then read `test/test_gpwarp.lua`'s `act` against the warp tier of `gp_act` in `ubermap.lua`, branch by branch: B before everything, the nil row consuming one press, the clamp before the step, the two tests A makes. Fix whichever is wrong.

- [ ] **Step 7: Run the whole suite**

Nothing in this feature touches the map data, the search or the favorites, but the popup draw and the xinput handler were both edited and both are covered elsewhere:

```bash
for t in test/test_*.lua; do echo "== $t"; lua "$t" || break; done
```

Expected: every file prints its own OK line and none exits non-zero.

- [ ] **Step 8: Check it in the game**

`/addon reload ubermap`, stand at a Home Point, open the map, and:

1. D-pad to a nation, **A**, D-pad to a zone point, **A**. Expected: the warp panel opens under that point with its top row lit.
2. D-pad up and down. Expected: the lit row walks the list and wraps at both ends.
3. **B**. Expected: the panel shuts and the hover is back on the zone point, the view unchanged.
4. **A** again, D-pad to a row that can travel, **A**. Expected: the warp is sent and the map closes.
5. **A** on a red row (somewhere never registered) or a greyed one (another kind of NPC). Expected: nothing happens, the row stays lit.
6. Open a panel by clicking a zone point with the mouse. Expected: no row is lit until a button is pressed, and the first press lights the top row without sending anything.

- [ ] **Step 9: Commit**

```bash
git add ubermap.lua test/test_gpwarp.lua
git commit -m "feat: open and send the warp list from the pad"
```

---

### Task 5: Document it

**Files:**
- Modify: `README.md:11-18` (the command table's neighbourhood), `README.md:95-110` (after the widget section), `ubermap.lua:11` (the header comment), `ubermap.lua:17` (the version)

**Interfaces:**
- Consumes: the finished behaviour of Tasks 2-4.
- Produces: nothing code reads.

- [ ] **Step 1: Bump the version**

Find:

```lua
addon.version = '1.2';
```

Replace with:

```lua
addon.version = '1.3';
```

- [ ] **Step 2: Say so in the header**

Find:

```lua
* Mouse wheel zooms, left-drag pans, Escape closes.  /ubermap or /um toggles
* the map by hand; /um edit turns on the point editor (ctrl+click to place).
```

Replace with:

```lua
* Mouse wheel zooms, left-drag pans, Escape closes.  A controller drives the
* whole thing too: the D-pad walks the markers, A opens what is under it and B
* backs out.  /ubermap or /um toggles the map by hand; /um edit turns on the
* point editor (ctrl+click to place).
```

- [ ] **Step 3: Add the README section**

In `README.md`, find:

```markdown
XInput only: an Xbox pad, or anything Windows presents as one. A DirectInput controller (DualShock, DualSense) still works by mouse.
```

Replace with:

```markdown
XInput only: an Xbox pad, or anything Windows presents as one. A DirectInput controller (DualShock, DualSense) still works by mouse.

## Gamepad map navigation

The map itself reads the pad whenever it is open — no toggle, because unlike the widget it is somewhere you deliberately went. A hover appears on the marker nearest the middle of the view the first time you press anything, and the buttons are the map's until it closes.

| Button | Effect |
| --- | --- |
| D-pad | Move the hover to the marker that way. Nothing that way, nothing moves — it does not wrap round the world |
| A | Zoom into the nation or region under the hover, then open a zone point's warp list, then send the row |
| B | Back out one step: the warp list, then the whole map with the nation you came out of still hovered, then the map closes |

Three tiers, nested the way the game's own menus are, and the mouse walks the same ones: click a nation and **B** still backs out of it, click a zone point and the D-pad still walks the rows that come up. A list opened with the mouse lights no row until you press something, so the cursor's own hover is never argued with.

The favorites widget wins while it is up. Walk to a Home Point with the map open and the widget takes the pad; dismiss it with **B** and the map answers again. The rows behave the same either way — a destination you have not registered reads red, a row saved off a different kind of NPC reads grey, and **A** refuses both.
```

- [ ] **Step 4: Add the row to the command table's neighbours**

In `README.md`, find:

```markdown
Mouse wheel zooms, left-drag pans, **shift**-drag moves the window/widget.  
```

Replace with:

```markdown
Mouse wheel zooms, left-drag pans, **shift**-drag moves the window/widget.  
A controller works it too — see [Gamepad map navigation](#gamepad-map-navigation).  
```

- [ ] **Step 5: Commit**

```bash
git add README.md ubermap.lua
git commit -m "docs: describe gamepad map navigation, bump to 1.3"
```

---

## What this plan deliberately leaves out

- **Held-D-pad repeat.** One step a press, like the favorites widget. Add it when a list is long enough to want one.
- **A toggle.** See the assumptions above; it is `cfg.gpad` and one `and` in the handler if it turns out to be wanted.
- **Analogue stick panning.** The D-pad reaches every marker on both maps (`test_gpnav.lua` proves it), so a stick would only be another way to do what the D-pad already does.
- **The right-click favorites menu from the pad.** Favoriting stays a mouse job; the pad travels, it does not curate.
