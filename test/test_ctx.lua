--[[
* Self-check for where the favorites right-click menu lands.  The one thing
* that has to hold is that it never lies across the row it was opened on: a
* menu over that row puts its own item and the row under the same click, and
* picking one picks both.  Mirrors draw_ctx_menu in ubermap.lua.  Run with any
* Lua 5.1+:
*     lua test/test_ctx.lua
--]]

local mm = assert(loadfile('lib/mapmath.lua'))();

local fails = 0;
local function check(ok, msg)
    if (not ok) then
        fails = fails + 1;
        print('FAIL: ' .. msg);
    end
end

local POPUP_ROW = 22;   -- the row pitch both lists draw at
local CTX_H     = POPUP_ROW;  -- the menu is one row tall

-- draw_ctx_menu's placement, on the vertical axis alone: under the row, above
-- it when there is no room below, clamped to the viewport either way.
local function place(ry, origin_y, view_h)
    local py = ry + POPUP_ROW;
    if (py + CTX_H > origin_y + view_h) then
        py = ry - CTX_H;
    end
    return mm.clamp_box(py, CTX_H, origin_y, view_h);
end

-- No overlap means the menu's span and the row's span do not meet.
local function clear(py, ry)
    return py >= ry + POPUP_ROW or py + CTX_H <= ry;
end

-- A row in open space: the menu hangs under it, touching its bottom edge.
check(place(100, 0, 600) == 122, 'a row with room below should open under it');
check(clear(place(100, 0, 600), 100), 'that menu should clear the row');

-- The last row of a panel against the bottom of the viewport: below is off
-- screen, so the menu goes above the row instead of being clamped over it.
local ry = 600 - POPUP_ROW;
check(place(ry, 0, 600) == ry - CTX_H, 'a row at the bottom should open above');
check(clear(place(ry, 0, 600), ry), 'that menu should clear the row too');

-- Every row of a full-height panel, at a viewport offset: the menu is on
-- screen and off the row, wherever the row is.
for y = 0, 600 - POPUP_ROW, 2 do
    local r  = 50 + y;
    local py = place(r, 50, 600);
    check(py >= 50 and py + CTX_H <= 650,
          ('the menu should stay on screen for a row at %d'):format(r));
    check(clear(py, r), ('the menu should clear the row at %d'):format(r));
end

if (fails == 0) then
    print('ok: the menu opens off the row it was asked for, and stays on screen');
else
    print(('%d check(s) failed'):format(fails));
    os.exit(1);
end
