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
    ui = { fw_on = false, is_open = { false, }, zoom = 1.0, fw_sel = 1,
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
    if (not ui.is_open[1] or ui.zoom == nil) then
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
ui.is_open[1] = true;
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

-- A queue nothing is draining is a map that is not being drawn -- collapsed,
-- or behind a texture that failed -- and a hundred presses landing at once
-- when it comes back is worse than losing them.
reset();
ui.is_open[1] = true;
for _ = 1, 20 do
    button(0, 1);
    button(0, 0);
end
check(#ui.gp_q == GP_QUEUE_MAX,
      ('the queue should cap at %d, holds %d'):format(GP_QUEUE_MAX, #ui.gp_q));

-- Nothing else on the pad is anybody's business: Start, X and Y stay the
-- client's with the map wide open.
reset();
ui.is_open[1] = true;
for _, i in ipairs({ 4, 5, 8, 9, 14, 15 }) do
    check(not button(i, 1), ('button %d is not the map\'s'):format(i));
end

if (fails == 0) then
    print('ok: the widget wins, the map takes the six, releases follow presses');
else
    print(('%d check(s) failed'):format(fails));
    os.exit(1);
end
