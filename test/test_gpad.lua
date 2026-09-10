--[[
* Self-check for which gamepad buttons the map takes and which it leaves to the
* client.  Drives gpn.pad -- the real xinput_button dispatch out of
* lib/gpnav.lua, not a copy of it -- over a stand-in ui table and the four
* callbacks ubermap.lua hands it: the favorites widget is asked first and wins
* outright, the map takes buttons only while it is on screen, a press that only
* takes the pad back off the mouse is spent doing that, and a release is
* blocked exactly when its press was -- a release handed to the client without
* the press would leave a button stuck down in the game's own menus.  Run with
* any Lua 5.1+:
*     lua test/test_gpad.lua
--]]

local gp = assert(loadfile('lib/gpnav.lua'))();

local fails = 0;
local function check(ok, msg)
    if (not ok) then
        fails = fails + 1;
        print('FAIL: ' .. msg);
    end
end

local ui, favs_n;
local function reset()
    -- Driving by default, so each case says outright when it is starting from
    -- a map the mouse has just taken.
    ui = { fw_on = false, is_open = { false, }, zoom = 1.0, fw_sel = 1,
           fw_hide = false, opened = 0, sent = 0,
           gp_active = true, gp_ready = true, gp_act = nil, pad_held = { } };
    favs_n = 0;
end

-- The addon's side of the dispatch, cut down to what a press can be seen to do
-- from out here: a list of the right length, and a count of the calls.
local h = {
    -- show(), minus the frame behind it: the map comes up and starts empty.
    show = function ()
        ui.is_open[1] = true;
        ui.opened     = ui.opened + 1;
        ui.gp_act     = nil;
    end,
    -- fw_confirm(), minus the warp itself.  It leaves fw_hide alone: the real
    -- one sets it only when the row can travel, and setting it here would leave
    -- the flag already up before B is ever pressed, so the check that B puts the
    -- widget away would pass whether or not B still does it.
    fw_confirm = function ()
        ui.sent = ui.sent + 1;
    end,
    fav_view = function ()
        local t = { };
        for i = 1, favs_n do t[i] = i; end
        return t;
    end,
    -- The pad never asks, but the table is one shape for both halves.
    chat_open = function () return false; end,
};

-- One button event, and whether the client was kept from seeing it, which is
-- the whole question.
local function button(index, state)
    return gp.pad(ui, index, state, h);
end

local ALL = { 0, 1, 2, 3, 12, 13, 15 };

-- The seven the addon reads at all, exactly as ubermap.lua's handler looks
-- them up: the XInput button index the event delivers.
for _, i in ipairs(ALL) do
    check(gp.GP[i] ~= nil, ('button %d should be one of the addon\'s'):format(i));
end
-- The widget reads the five that are not left and right.
check(gp.GP[2] == 'left' and gp.GP[3] == 'right',
      'the two the widget leaves alone should be left and right');

-- Map shut: every one of the seven is the client's, and nothing is held.
reset();
for _, i in ipairs(ALL) do
    check(not button(i, 1), ('button %d should be the client\'s with the map shut'):format(i));
    check(not button(i, 0), ('button %d release should follow its press'):format(i));
end
check(ui.gp_act == nil, 'a shut map should hold nothing');

-- Map open and the widget down: all seven are taken.  One slot holds them,
-- so the six that land behind the first inside the same frame are dropped
-- here -- the frame that acts on the first is what changes the map under
-- them.  The B among them is the one exception, and takes the slot.
reset();
ui.is_open[1] = true;
for _, i in ipairs(ALL) do
    check(button(i, 1), ('button %d should be taken with the map open'):format(i));
end
check(ui.gp_act == 'b',
      ('the B should have taken the slot, holds %s'):format(tostring(ui.gp_act)));

-- The release of a press that was taken is taken too, and only once: a second
-- one is a release the client never gave us a press for.  The seven above are
-- still held, which is what this reads.
for _, i in ipairs(ALL) do
    check(button(i, 0), ('button %d release should be taken'):format(i));
    check(not button(i, 0), ('button %d should only release once'):format(i));
end

-- The same run without a B in it: the first press is the one that keeps the
-- slot, and the five behind it are gone.
reset();
ui.is_open[1] = true;
for _, i in ipairs({ 0, 1, 2, 3, 12, 15 }) do
    check(button(i, 1), ('button %d should be taken with the map open'):format(i));
end
check(ui.gp_act == 'up',
      ('the slot should hold the first press, holds %s'):format(tostring(ui.gp_act)));

-- B is swallowed from the game whether it acts or not, so a back-out landing
-- behind a press that has not run yet has to take the slot rather than go
-- quiet: dropping it is a map with no way out of it for the frame.  Nothing
-- else takes the slot off anything.
reset();
ui.is_open[1] = true;
check(button(0, 1), 'the D-pad press should be taken');
check(button(13, 1), 'the B behind it should be taken');
check(ui.gp_act == 'b',
      ('B should take the slot off the press ahead of it, holds %s'):format(tostring(ui.gp_act)));
check(button(15, 1), 'the Y behind the B should be taken');
check(ui.gp_act == 'b',
      ('only B should take the slot, holds %s'):format(tostring(ui.gp_act)));

-- The widget in front: it reads five of the seven and the map gets none of
-- them, so walking up to a warp NPC still puts the widget first whatever is
-- behind.
reset();
ui.is_open[1], ui.fw_on, favs_n = true, true, 3;
for _, i in ipairs({ 0, 1, 12, 13 }) do
    check(button(i, 1), ('button %d should be the widget\'s'):format(i));
end
check(ui.gp_act == nil, 'the map should hold nothing while the widget is up');
-- One step each way, so the selection is back where it started: both of the
-- D-pad presses landed on the widget rather than on the map behind it.
check(ui.fw_sel == 1, ('the widget selection should have walked, is %d'):format(ui.fw_sel));
-- A is the widget's send and B is the way back to the NPC's own menu, so
-- neither of them reached the map either.
check(ui.sent == 1, ('A should send the lit row once, sent %d'):format(ui.sent));
check(ui.fw_hide, 'B should put the widget away');
-- The two the widget does not read stay the client's rather than falling
-- through to the map behind it.
for _, i in ipairs({ 2, 3 }) do
    check(not button(i, 1), ('button %d should be the client\'s under the widget'):format(i));
end

-- An empty list takes the widget off screen before it can be pressed, so its
-- five go back to the client rather than being swallowed by nothing.
reset();
ui.fw_on, favs_n = true, 0;
for _, i in ipairs(ALL) do
    check(not button(i, 1), ('button %d should be the client\'s with nothing saved'):format(i));
end

-- Y at the widget is the way up to the full map: the press is the widget's,
-- the widget puts itself away for this visit, and the map is opened rather
-- than driven -- nothing is held for it.
reset();
ui.fw_on, favs_n = true, 3;
check(button(15, 1), 'Y should be taken by the widget');
check(ui.fw_hide, 'Y should put the widget away');
check(ui.opened == 1, ('Y should open the map once, opened %d'):format(ui.opened));
check(ui.gp_act == nil, 'Y should hold nothing for the map it just opened');
check(ui.fw_sel == 1, ('Y should not step the row, is %d'):format(ui.fw_sel));
check(button(15, 0), 'the Y release should follow its press');

-- A map nothing is acting for is a map that is not being drawn -- collapsed,
-- or behind a texture that failed -- and twenty presses waiting for the frame
-- that comes back is worse than the one that was pressed first.
reset();
ui.is_open[1] = true;
button(0, 1);
button(0, 0);
for _ = 1, 19 do
    button(1, 1);
    button(1, 0);
end
check(ui.gp_act == 'up',
      ('twenty presses should leave the first, left %s'):format(tostring(ui.gp_act)));

-- A map that is open but not being drawn has nothing to act on the press, so
-- it is left to the client rather than swallowed: a blocked D-pad nothing acts
-- on is one dead in the game's own menus, with nothing on screen to say why.
reset();
ui.is_open[1], ui.gp_ready = true, false;
for _, i in ipairs(ALL) do
    check(not button(i, 1),
          ('button %d should be the client\'s with the map undrawn'):format(i));
end
check(ui.gp_act == nil, 'an undrawn map should hold nothing');

-- The mouse took the map off the pad.  The press that takes it back is still
-- the map's -- the client must not see it -- but it is spent lighting the
-- selection again rather than walking off one nothing on screen was showing.
reset();
ui.is_open[1], ui.gp_active = true, false;
check(button(0, 1), 'the waking press should still be taken');
check(ui.gp_act == nil, 'the waking press should hold nothing');
check(ui.gp_active, 'the waking press should mark the pad as driving');
check(button(0, 0), 'the waking press should release like any other');
check(button(1, 1), 'the press after the wake should be taken');
check(ui.gp_act == 'down',
      ('the press after the wake should be held, held %s'):format(tostring(ui.gp_act)));

-- The same at the widget, whose row the mouse puts out the same way: the
-- waking press lights it rather than stepping it, or worse sending it.
reset();
ui.fw_on, favs_n, ui.gp_active = true, 3, false;
check(button(1, 1), 'the widget should take the waking press');
check(ui.fw_sel == 1,
      ('a waking press should not step the row, is %d'):format(ui.fw_sel));
check(ui.sent == 0, 'a waking press should send nothing');
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
