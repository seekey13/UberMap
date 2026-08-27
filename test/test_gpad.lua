--[[
* Self-check for which gamepad buttons the map takes and which it leaves to the
* client.  Mirrors the xinput_button handler in ubermap.lua: the favorites
* widget is asked first and wins outright, the map takes buttons only while it
* is on screen, a press that only takes the pad back off the mouse is spent
* doing that, and a release is blocked exactly when its press was -- a release
* handed to the client without the press would leave a button stuck down in
* the game's own menus.  Run with any Lua 5.1+:
*     lua test/test_gpad.lua
--]]

local fails = 0;
local function check(ok, msg)
    if (not ok) then
        fails = fails + 1;
        print('FAIL: ' .. msg);
    end
end

-- The table, exactly as ubermap.lua keys it: the XInput button index the event
-- delivers.  The widget reads the five that are not left and right.
local GP = { [0] = 'up', [1] = 'down', [2] = 'left', [3] = 'right',
             [12] = 'a', [13] = 'b', [15] = 'y' };
local QUEUE_MAX = 8;

local ui, favs_n;
local function reset()
    -- Driving by default, so each case says outright when it is starting from
    -- a map the mouse has just taken.
    ui = { fw_on = false, is_open = { false, }, zoom = 1.0, fw_sel = 1,
           fw_hide = false, opened = 0,
           gp_active = true, gp_q = { }, pad_held = { } };
    favs_n = 0;
end

-- nav.wake: marks the pad as what is driving, and says whether the press is
-- spent doing only that.
local function wake()
    local was = ui.gp_active;
    ui.gp_active = true;
    return not was;
end

-- The handler, minus the two calls into the map that need a frame behind them.
-- Hands back whether the press was blocked, which is the whole question.
local function button(index, state)
    local act = GP[index];
    if (act == nil) then
        return false;
    end
    if (state ~= 1) then
        if (ui.pad_held[index]) then
            ui.pad_held[index] = nil;
            return true;
        end
        return false;
    end
    if (ui.fw_on) then
        if (act == 'left' or act == 'right' or favs_n == 0) then
            return false;
        end
        ui.pad_held[index] = true;
        if (wake()) then
            return true;
        end
        if (act == 'up') then
            ui.fw_sel = (ui.fw_sel - 2) % favs_n + 1;
        elseif (act == 'down') then
            ui.fw_sel = ui.fw_sel % favs_n + 1;
        elseif (act == 'y') then
            -- show(), minus the frame behind it: the widget puts itself away
            -- for this visit and the map comes up in its place.
            ui.fw_hide    = true;
            ui.is_open[1] = true;
            ui.opened     = ui.opened + 1;
        end
        return true;
    end
    if (not ui.is_open[1] or ui.zoom == nil) then
        return false;
    end
    ui.pad_held[index] = true;
    if (wake()) then
        return true;
    end
    if (#ui.gp_q < QUEUE_MAX) then
        table.insert(ui.gp_q, act);
    end
    return true;
end

local ALL = { 0, 1, 2, 3, 12, 13, 15 };

-- Map shut: every one of the seven is the client's, and nothing is queued.
reset();
for _, i in ipairs(ALL) do
    check(not button(i, 1), ('button %d should be the client\'s with the map shut'):format(i));
    check(not button(i, 0), ('button %d release should follow its press'):format(i));
end
check(#ui.gp_q == 0, 'a shut map should queue nothing');

-- Map open and the widget down: all seven are taken, in the order pressed.
reset();
ui.is_open[1] = true;
for _, i in ipairs(ALL) do
    check(button(i, 1), ('button %d should be taken with the map open'):format(i));
end
check(#ui.gp_q == 7, ('seven presses should queue seven actions, queued %d'):format(#ui.gp_q));
check(ui.gp_q[1] == 'up' and ui.gp_q[4] == 'right' and ui.gp_q[6] == 'b'
      and ui.gp_q[7] == 'y',
      'the queue should hold the actions in the order they were pressed');

-- The release of a press that was taken is taken too, and only once: a second
-- one is a release the client never gave us a press for.
for _, i in ipairs(ALL) do
    check(button(i, 0), ('button %d release should be taken'):format(i));
    check(not button(i, 0), ('button %d should only release once'):format(i));
end

-- The widget in front: it reads five of the seven and the map gets none of
-- them, so walking up to a warp NPC still puts the widget first whatever is
-- behind.
reset();
ui.is_open[1], ui.fw_on, favs_n = true, true, 3;
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

-- Y at the widget is the way up to the full map: the press is the widget's,
-- the widget puts itself away for this visit, and the map is opened rather
-- than driven -- nothing is queued for it.
reset();
ui.fw_on, favs_n = true, 3;
check(button(15, 1), 'Y should be taken by the widget');
check(ui.fw_hide, 'Y should put the widget away');
check(ui.opened == 1, ('Y should open the map once, opened %d'):format(ui.opened));
check(#ui.gp_q == 0, 'Y should queue nothing for the map it just opened');
check(ui.fw_sel == 1, ('Y should not step the row, is %d'):format(ui.fw_sel));
check(button(15, 0), 'the Y release should follow its press');

-- A queue nothing is draining is a map that is not being drawn -- collapsed,
-- or behind a texture that failed -- and a hundred presses landing at once
-- when it comes back is worse than losing them.
reset();
ui.is_open[1] = true;
for _ = 1, 20 do
    button(0, 1);
    button(0, 0);
end
check(#ui.gp_q == QUEUE_MAX,
      ('the queue should cap at %d, holds %d'):format(QUEUE_MAX, #ui.gp_q));

-- The mouse took the map off the pad.  The press that takes it back is still
-- the map's -- the client must not see it -- but it is spent lighting the
-- selection again rather than walking off one nothing on screen was showing.
reset();
ui.is_open[1], ui.gp_active = true, false;
check(button(0, 1), 'the waking press should still be taken');
check(#ui.gp_q == 0, 'the waking press should queue nothing');
check(ui.gp_active, 'the waking press should mark the pad as driving');
check(button(0, 0), 'the waking press should release like any other');
check(button(1, 1), 'the press after the wake should be taken');
check(#ui.gp_q == 1,
      ('the press after the wake should queue, queued %d'):format(#ui.gp_q));

-- The same at the widget, whose row the mouse puts out the same way: the
-- waking press lights it rather than stepping it, or worse sending it.
reset();
ui.fw_on, favs_n, ui.gp_active = true, 3, false;
check(button(1, 1), 'the widget should take the waking press');
check(ui.fw_sel == 1,
      ('a waking press should not step the row, is %d'):format(ui.fw_sel));
check(button(1, 0), 'the waking press should release like any other');
button(1, 1);
check(ui.fw_sel == 2,
      ('the press after the wake should step the row, is %d'):format(ui.fw_sel));

-- Nothing else on the pad is anybody's business: Start, the shoulders and X
-- stay the client's with the map wide open.
reset();
ui.is_open[1] = true;
for _, i in ipairs({ 4, 5, 8, 9, 14 }) do
    check(not button(i, 1), ('button %d is not the map\'s'):format(i));
end

if (fails == 0) then
    print('ok: the widget wins, Y opens the map, releases follow presses');
else
    print(('%d check(s) failed'):format(fails));
    os.exit(1);
end
