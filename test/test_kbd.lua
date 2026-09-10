--[[
* Self-check for which keys the map and the favorites widget take and which
* they leave to the client.  Drives gpn.press and the two keyboard handlers
* over it -- gpn.key and gpn.state, the real ones out of lib/gpnav.lua rather
* than a copy -- over a stand-in ui table and the four callbacks ubermap.lua
* hands them: typing beats everything, the widget is asked first and wins
* outright, the arrows are the player's own until an F asks for them, the map
* takes them only while it is on screen, a press that only takes the map back
* off the mouse is spent doing that -- except Escape, which always has to work
* -- and U means nothing once the widget is off screen, while F carries on
* as the map's own Y.
*
* The half that matters most here is the state buffer.  Blocking the buffered
* edge keeps a key out of the game's menus, but the camera and the movement are
* polled from the immediate state every frame a key is held, so a key taken
* once has to stay wiped out of that buffer until it comes back up.  Run with
* any Lua 5.1+:
*     lua test/test_kbd.lua
--]]

local gp = assert(loadfile('lib/gpnav.lua'))();

local fails = 0;
local function check(ok, msg)
    if (not ok) then
        fails = fails + 1;
        print('FAIL: ' .. msg);
    end
end

-- The scan codes by name, for the cases below to press.  gpn.KEY is the table
-- under test and maps each of them to the action it stands for: the arrows are
-- the D-pad, either Enter is A and Escape is B.
local DIK = { up = 0xC8, down = 0xD0, left = 0xCB, right = 0xCD,
              enter = 0x1C, pad_enter = 0x9C, esc = 0x01, u = 0x16, f = 0x21,
              tab = 0x0F };
for name, dik in pairs(DIK) do
    check(gp.KEY[dik] ~= nil, ('%s should be one of the addon\'s keys'):format(name));
end
check(gp.KEY[DIK.enter] == 'a' and gp.KEY[DIK.pad_enter] == 'a',
      'both Enters should stand for the same action');

local ui, favs_n;
local function reset()
    -- The mouse drives by default, the way it does on a fresh session, so each
    -- case says outright when it is starting from a map the keys already have.
    ui = { fw_on = false, fw_key = false, is_open = { false, }, zoom = 1.0,
           fw_sel = 1, fw_hide = false, opened = 0, sent = 0, chat = 0,
           kb_typing = false, cfg_typing = false, kb_held = { },
           esc_frames = 0, focus_next = false, search_blur = false,
           gp_active = false, gp_ready = true, gp_act = nil };
    favs_n = 0;
end

-- The addon's side of the dispatch, cut down to what a press can be seen to do
-- from out here: a list of the right length, a count of the calls, and the
-- chat line asked of a number rather than of Ashita.
local h = {
    -- show(), minus the frame behind it.
    show = function ()
        ui.is_open[1]  = true;
        ui.opened      = ui.opened + 1;
        ui.focus_next  = false;
        ui.search_blur = false;
        ui.gp_act      = nil;
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
    chat_open = function () return ui.chat ~= 0; end,
};

-- The key_data handler: the buffered edge, and whether it was blocked.
local function key(dik, down)
    return gp.key(ui, dik, down, h);
end

-- The key_state handler, over a frame's state buffer given as a set of the
-- scan codes that are down.  The real buffer is a byte per scan code, so it is
-- built that way here too and handed over to be wiped in place.  Hands back
-- what is left of it for the game.
local function state(down_set)
    local buf = { };
    for dik in pairs(gp.KEY) do
        buf[dik] = 0;
    end
    for _, dik in ipairs(down_set) do
        buf[dik] = 1;
    end
    gp.state(ui, buf, h);
    local keys = { };
    for dik, v in pairs(buf) do
        if (v ~= 0) then
            keys[dik] = v;
        end
    end
    return keys;
end

local NAV = { DIK.up, DIK.down, DIK.left, DIK.right, DIK.enter, DIK.esc };

-- Map shut and no widget: every key is the client's, and nothing is held.
-- The arrows above all: they are how the player walks, and the state buffer
-- has to come back untouched or the character stops moving.
reset();
for _, dik in ipairs(NAV) do
    check(not key(dik, true), ('key 0x%02X should be the client\'s with the map shut'):format(dik));
    check(state({ dik })[dik] ~= nil,
          ('key 0x%02X should survive the state buffer with the map shut'):format(dik));
end
check(not key(DIK.u, true), 'U should be the client\'s with no widget up');
check(not key(DIK.f, true), 'F should be the client\'s with no widget up');
check(ui.gp_act == nil, 'a shut map should hold nothing');

-- Map open, keys already driving: all six are taken.  One slot holds them, so
-- the five that land behind the first inside the same frame are dropped here
-- -- the frame that acts on the first is what changes the map under them.  The
-- Escape among them is the one exception, and takes the slot.
reset();
ui.is_open[1], ui.gp_active = true, true;
for _, dik in ipairs(NAV) do
    check(key(dik, true), ('key 0x%02X should be taken with the map open'):format(dik));
    check(key(dik, false), ('key 0x%02X release should follow its press'):format(dik));
end
check(ui.gp_act == 'b',
      ('the Escape should have taken the slot, holds %s'):format(tostring(ui.gp_act)));

-- The same run without the Escape: the first press is the one that keeps the
-- slot, and the four behind it are gone.
reset();
ui.is_open[1], ui.gp_active = true, true;
for _, dik in ipairs({ DIK.up, DIK.down, DIK.left, DIK.right, DIK.enter }) do
    check(key(dik, true), ('key 0x%02X should be taken with the map open'):format(dik));
    check(key(dik, false), ('key 0x%02X release should follow its press'):format(dik));
end
check(ui.gp_act == 'up',
      ('the slot should hold the first press, holds %s'):format(tostring(ui.gp_act)));

-- Escape is swallowed from the game whether it acts or not, so a back-out
-- landing behind a press that has not run yet has to take the slot rather than
-- go quiet: dropping it is a map with no way out of it for the frame.  Nothing
-- else takes the slot off anything.
reset();
ui.is_open[1], ui.gp_active = true, true;
check(key(DIK.up, true), 'the arrow should be taken');
key(DIK.up, false);
check(key(DIK.esc, true), 'the Escape behind it should be taken');
check(ui.gp_act == 'b',
      ('Escape should take the slot off the press ahead of it, holds %s'):format(tostring(ui.gp_act)));
key(DIK.esc, false);
check(key(DIK.f, true), 'the F behind the Escape should be taken');
check(ui.gp_act == 'b',
      ('only Escape should take the slot, holds %s'):format(tostring(ui.gp_act)));
key(DIK.f, false);

-- Which action each key stands for, a frame apiece: one slot, so a mapping
-- asked for behind another press would be reading the one that was dropped.
-- Either Enter is A, Escape is B, and F is the map's own Y.
for _, case in ipairs({ { DIK.enter, 'a' }, { DIK.pad_enter, 'a' },
                        { DIK.esc, 'b' }, { DIK.f, 'y' } }) do
    reset();
    ui.is_open[1], ui.gp_active = true, true;
    check(key(case[1], true),
          ('key 0x%02X should be taken with the map open'):format(case[1]));
    check(ui.gp_act == case[2],
          ('key 0x%02X should hold %s, holds %s'):format(case[1], case[2],
                                                         tostring(ui.gp_act)));
    key(case[1], false);
end

-- U is the widget's alone; the map behind it never sees it.  F is the map's
-- own Y, so with the widget gone it holds the favorites menu instead of
-- going back to the client.
reset();
ui.is_open[1], ui.gp_active = true, true;
check(not key(DIK.u, true), 'U should be the client\'s with the widget off screen');
check(state({ DIK.u })[DIK.u] ~= nil,
      'U should survive the state buffer with the widget off screen');
check(key(DIK.f, true), 'F should be taken by the map with the widget off screen');
check(state({ DIK.f })[DIK.f] == nil, 'F should be kept from the game while held');
key(DIK.f, false);

-- A key held down stays out of the game's state buffer for the whole hold,
-- which is what stops the arrows turning the camera: the edge is read once,
-- the state every frame after it.
reset();
ui.is_open[1], ui.gp_active = true, true;
check(key(DIK.left, true), 'the arrow press should be taken');
for frame = 1, 5 do
    check(state({ DIK.left })[DIK.left] == nil,
          ('the held arrow should stay wiped, frame %d'):format(frame));
end
check(key(DIK.left, false), 'the arrow release should be taken');
check(ui.kb_held[DIK.left] == nil, 'the release should let go of the hold');

-- And a key that is down but was never taken -- the same arrow with the map
-- shut under it -- is left alone frame after frame.  This is the case the hold
-- exists for: with the map gone there is nothing else left saying the key is
-- the map's, so only a key still held from a press it took stays wiped.
ui.is_open[1] = false;
check(state({ DIK.left })[DIK.left] ~= nil,
      'an arrow the map never took should reach the game');
key(DIK.left, true);   -- taken by nothing, so no hold is recorded
check(ui.kb_held[DIK.left] == nil, 'a key nothing took should record no hold');

-- An alt-tab or a device re-acquire while a key is down loses the release
-- event, and the hold it should have let go of would otherwise wipe that key
-- out of the buffer on every later press -- a camera that will not turn for
-- the whole of the next hold.  A frame that reads the key up is the one place
-- left that can say so, whether or not its event ever arrived.
reset();
ui.is_open[1], ui.gp_active = true, true;
key(DIK.up, true);
check(ui.kb_held[DIK.up], 'a press the map took should record a hold');
state({ });     -- the frame the window comes back on, with nothing down
check(ui.kb_held[DIK.up] == nil,
      'a frame that reads the key up should let go of a hold its release never did');
-- And the hold really is gone: the same key, held again with the map shut
-- under it, reaches the game rather than being wiped by a stale flag.
ui.is_open[1] = false;
check(state({ DIK.up })[DIK.up] ~= nil,
      'a later hold should reach the game once the lost release has been made good');

-- The state buffer is wiped on the frame the press lands as well, whichever
-- order the game reads its two buffers in.
reset();
ui.is_open[1], ui.gp_active = true, true;
check(state({ DIK.up })[DIK.up] == nil,
      'a key the map would take should be wiped before its edge is read');
check(ui.gp_act == nil, 'the state buffer should act on nothing');

-- Escape closes the map, and goes on being wiped until it comes back up: the
-- client must not see the tail of a press that shut the map.
reset();
ui.is_open[1], ui.gp_active = true, true;
key(DIK.esc, true);
check(ui.gp_act == 'b', 'Escape should hold the back-out');
ui.is_open[1] = false;  -- what nav.act does with it a frame later
check(state({ DIK.esc })[DIK.esc] == nil,
      'Escape should stay wiped while it is still held');
check(key(DIK.esc, false), 'the Escape release should be taken');
check(state({ DIK.esc })[DIK.esc] ~= nil,
      'Escape should be the client\'s again once released');

-- The addon's own Escape, held down through user32 to back out of an NPC's
-- menu, comes back round through DirectInput like any other: taking it would
-- be the map answering a press it made itself, and wiping it out of the state
-- buffer would keep it from the very menu it was sent to close.
reset();
ui.is_open[1], ui.gp_active, ui.esc_frames = true, true, 3;
check(not key(DIK.esc, true), 'an injected Escape should not be taken');
check(state({ DIK.esc })[DIK.esc] ~= nil,
      'an injected Escape should reach the menu it was sent to close');
check(ui.is_open[1], 'an injected Escape should not close the map');
ui.esc_frames = 0;
check(key(DIK.esc, true), 'a real Escape after the hold should be taken');

-- Typing beats all of it, three ways: the game's own chat line, the map's
-- search box, and a config number.  ImGui is fed from WNDPROC, which none of
-- this touches, so a key acted on here would land twice.
for _, field in ipairs({ 'chat', 'kb_typing', 'cfg_typing' }) do
    reset();
    ui.is_open[1], ui.gp_active = true, true;
    ui[field] = (field == 'chat') and 0x11 or true;
    for _, dik in ipairs(NAV) do
        check(not key(dik, true), ('key 0x%02X should be the caret\'s while %s'):format(dik, field));
        check(state({ dik })[dik] ~= nil,
              ('key 0x%02X should reach the game while %s'):format(dik, field));
    end
    check(ui.gp_act == nil, ('nothing should be held while %s'):format(field));
    check(ui.is_open[1], ('Escape should not close the map while %s'):format(field));
end

-- Tab is the exception, and the only one: a key that could only ever get the
-- keyboard into the search box would be a door with no handle on the inside.
-- Out of the box on the way in, into it on the way back, and never both at
-- once -- a pending blur that survived would swallow the focus the next press
-- asks for.
reset();
ui.is_open[1], ui.gp_active = true, true;
check(key(DIK.tab, true), 'Tab should be taken with the map open');
check(state({ DIK.tab })[DIK.tab] == nil,
      'Tab should be kept from the game while the map is open');
key(DIK.tab, false);
check(ui.focus_next and not ui.search_blur,
      'Tab off the box should hand it the keyboard');
check(ui.gp_act == nil, 'Tab should hold no map action');
-- The frame the box takes the caret, as the draw reports it.
ui.focus_next, ui.kb_typing = false, true;
check(key(DIK.tab, true), 'Tab should still be taken with the caret in the box');
key(DIK.tab, false);
check(ui.search_blur and not ui.focus_next,
      'Tab in the box should take the keyboard back off it');
-- and the caret is gone by the next frame, so the arrows are the map's again.
ui.kb_typing, ui.search_blur = false, false;
check(key(DIK.up, true), 'the arrows should be the map\'s again after a Tab out');
check(ui.gp_act == 'up', 'and should hold the move they always did');
-- Chat still beats it, and so does a config number: neither is the map's box.
reset();
ui.is_open[1], ui.chat = true, 0x11;
check(not key(DIK.tab, true), 'Tab should be the chat line\'s while it is open');
reset();
ui.is_open[1], ui.cfg_typing = true, true;
check(not key(DIK.tab, true), 'Tab should be a config number\'s while it has the caret');
-- Map shut, Tab is the client's: it is how the game cycles targets.
reset();
check(not key(DIK.tab, true), 'Tab should be the client\'s with the map shut');
check(state({ DIK.tab })[DIK.tab] ~= nil,
      'Tab should reach the game with the map shut');
-- Nor does the widget hold on to it: the box Tab moves to is the map's, so a
-- widget standing on its own leaves the key to the client like anything else.
reset();
ui.fw_on, favs_n = true, 3;
check(not key(DIK.tab, true), 'Tab should be the client\'s at a widget with no map');
-- A frame the map did not draw has no box to hand the caret to, so the key
-- goes back to the client rather than latching a focus that would fire on
-- whatever frame the box next comes back.
reset();
ui.is_open[1], ui.gp_ready = true, false;
check(not key(DIK.tab, true), "Tab should go back on a frame the map did not draw");
check(not ui.focus_next, "and should latch no focus for a later frame");
-- A map put away with a blur still pending comes back with it cleared, so the
-- first Tab in asks for the box rather than being spent on the stale blur.
reset();
ui.is_open[1], ui.kb_typing = true, true;
key(DIK.tab, true);
key(DIK.tab, false);
check(ui.search_blur, "Tab in the box should ask for the blur");
-- Put away with the caret still in the box: the draw clears kb_typing on the
-- way out, but nothing clears the blur until the map is opened again.
ui.is_open[1], ui.kb_typing = false, false;
ui.fw_on, favs_n = true, 3;
key(DIK.u, true);
key(DIK.u, false);
check(ui.is_open[1] and not ui.search_blur,
      "reopening the map should clear the pending blur");
key(DIK.tab, true);
key(DIK.tab, false);
check(ui.focus_next and not ui.search_blur,
      "and the first Tab back in should ask for the box");

-- The widget in front, before an F: the arrows are still the player's, since
-- walking up to a warp NPC is done while moving.  U and Escape work anyway.
reset();
ui.is_open[1], ui.fw_on, favs_n = true, true, 3;
for _, dik in ipairs({ DIK.up, DIK.down, DIK.left, DIK.right, DIK.enter }) do
    check(not key(dik, true), ('key 0x%02X should be the player\'s before an F'):format(dik));
    check(state({ dik })[dik] ~= nil,
          ('key 0x%02X should still walk the player before an F'):format(dik));
end
check(ui.gp_act == nil, 'the map should hold nothing while the widget is up');
check(ui.fw_sel == 1, ('the row should not have walked, is %d'):format(ui.fw_sel));

-- Escape outside focus mode dismisses the widget rather than closing the map
-- behind it, the way B does on the pad.
check(key(DIK.esc, true), 'Escape should be the widget\'s');
check(ui.fw_hide, 'Escape should put the widget away');
check(ui.is_open[1], 'Escape at the widget should leave the map alone');

-- F hands it the arrows, and lights the row on the way in so the first arrow
-- steps it rather than being spent turning the highlight back on.
reset();
ui.fw_on, favs_n = true, 3;
check(key(DIK.f, true), 'F should be taken by the widget');
check(state({ DIK.f })[DIK.f] == nil, 'F should be kept from the game while held');
key(DIK.f, false);
check(ui.fw_key, 'F should hand the widget the arrows');
check(ui.gp_active, 'F should light the row');
check(key(DIK.down, true), 'the arrows should be the widget\'s after an F');
key(DIK.down, false);
check(ui.fw_sel == 2, ('the first arrow should step the row, is %d'):format(ui.fw_sel));
-- Wraps at both ends, the way the game's own menus do.
key(DIK.up, true); key(DIK.up, false);
key(DIK.up, true); key(DIK.up, false);
check(ui.fw_sel == 3, ('up past the top should wrap, is %d'):format(ui.fw_sel));
-- Left and right stay the client's even in focus mode: the widget is a single
-- column, and taking them would leave no way to work the menu behind it.
check(not key(DIK.left, true), 'left should stay the client\'s in focus mode');
check(not key(DIK.right, true), 'right should stay the client\'s in focus mode');
check(state({ DIK.left })[DIK.left] ~= nil,
      'left should reach the game in focus mode');

-- F seats the highlight on a row that is on the list.  A selection left over
-- from a longer one -- a favorite dropped while the widget was off screen --
-- would otherwise start the arrows off past the end of it.
reset();
ui.fw_on, favs_n, ui.fw_sel = true, 3, 9;
check(key(DIK.f, true), 'F should be taken by the widget');
check(ui.fw_sel == 3,
      ('F should pull a row past the end back onto the list, is %d'):format(ui.fw_sel));
reset();
ui.fw_on, favs_n, ui.fw_sel = true, 3, 0;
key(DIK.f, true);
check(ui.fw_sel == 1,
      ('F should pull a row below the list back onto it, is %d'):format(ui.fw_sel));

-- Enter sends the lit row, and the widget gets out of the way behind it.
reset();
ui.fw_on, favs_n, ui.fw_key, ui.gp_active = true, 3, true, true;
check(key(DIK.enter, true), 'Enter should be taken in focus mode');
check(ui.sent == 1, ('Enter should send the row once, sent %d'):format(ui.sent));

-- Escape in focus mode hands the arrows back and goes no further: the widget
-- stays up, so the F that got here is one press away again.
reset();
ui.fw_on, favs_n, ui.fw_key, ui.gp_active = true, 3, true, true;
check(key(DIK.esc, true), 'Escape should be taken in focus mode');
key(DIK.esc, false);
check(not ui.fw_key, 'Escape should hand the arrows back');
check(not ui.fw_hide, 'Escape out of focus mode should leave the widget up');
-- And the next one dismisses it, now that focus mode is off.
check(key(DIK.esc, true), 'the second Escape should be taken');
check(ui.fw_hide, 'the second Escape should put the widget away');

-- U at the widget is the way up to the full map, whether or not the arrows
-- were ever asked for: the widget puts itself away and the map is opened
-- rather than driven, so nothing is queued for it.
for _, focused in ipairs({ false, true }) do
    reset();
    ui.fw_on, favs_n, ui.fw_key = true, 3, focused;
    check(key(DIK.u, true), 'U should be taken by the widget');
    check(ui.fw_hide, 'U should put the widget away');
    check(not ui.fw_key, 'U should hand the arrows back');
    check(ui.opened == 1, ('U should open the map once, opened %d'):format(ui.opened));
    check(ui.gp_act == nil, 'U should hold nothing for the map it just opened');
    check(ui.fw_sel == 1, ('U should not step the row, is %d'):format(ui.fw_sel));
    -- The widget is off screen the moment it is drawn again, so the hold is
    -- the only thing left keeping U from the game.
    ui.fw_on = false;
    check(state({ DIK.u })[DIK.u] == nil, 'the held U should not reach the game');
    check(key(DIK.u, false), 'the U release should follow its press');
end

-- The mouse had the map.  The press that takes it back is still the map's --
-- the client must not see it -- but it is spent lighting the selection again
-- rather than walking off one nothing on screen was showing.
reset();
ui.is_open[1] = true;
check(key(DIK.down, true), 'the waking press should still be taken');
check(ui.gp_act == nil, 'the waking press should hold nothing');
check(ui.gp_active, 'the waking press should mark the keys as driving');
key(DIK.down, false);
check(key(DIK.down, true), 'the press after the wake should be taken');
check(ui.gp_act == 'down',
      ('the press after the wake should be held, held %s'):format(tostring(ui.gp_act)));

-- Escape is the exception: it is the one way out of a map covering most of the
-- screen, so it acts on the first press however the map was being driven.
reset();
ui.is_open[1] = true;
check(key(DIK.esc, true), 'Escape off the mouse should be taken');
check(ui.gp_act == 'b',
      'Escape should act on the waking press rather than be spent on it');

-- The same at the widget, whose row the mouse puts out the same way.
reset();
ui.fw_on, favs_n, ui.fw_key = true, 3, true;
check(key(DIK.down, true), 'the widget should take the waking press');
check(ui.fw_sel == 1,
      ('a waking press should not step the row, is %d'):format(ui.fw_sel));
key(DIK.down, false);
key(DIK.down, true);
check(ui.fw_sel == 2,
      ('the press after the wake should step the row, is %d'):format(ui.fw_sel));

-- A map that is open but not being drawn -- no texture, or a window ImGui
-- collapsed -- has nothing to act on the press, so one there is lost.
-- Escape still has to work out of one, or the map could not be shut.
reset();
ui.is_open[1], ui.gp_ready, ui.gp_active = true, false, true;
check(not key(DIK.down, true), 'an undrawn map should leave the arrows to the client');
check(state({ DIK.down })[DIK.down] ~= nil,
      'an undrawn map should let the arrows walk the player');
check(ui.gp_act == nil, 'an undrawn map should hold nothing');
check(key(DIK.esc, true), 'Escape should still be taken by an undrawn map');
check(not ui.is_open[1], 'Escape should close a map that is not being drawn');

-- A map nothing is acting for is worse than losing presses: twenty waiting for
-- the frame that comes back is not what any of them meant.  One slot, and the
-- first press is the one it keeps.
reset();
ui.is_open[1], ui.gp_active = true, true;
key(DIK.up, true);
key(DIK.up, false);
for _ = 1, 19 do
    key(DIK.down, true);
    key(DIK.down, false);
end
check(ui.gp_act == 'up',
      ('twenty presses should leave the first, left %s'):format(tostring(ui.gp_act)));

-- An empty widget reads no key at all: it is off screen, and the list the
-- arrows would walk is not there.
reset();
ui.fw_on, favs_n = true, 0;
for _, dik in ipairs({ DIK.up, DIK.down, DIK.enter, DIK.esc, DIK.u, DIK.f }) do
    check(not key(dik, true), ('key 0x%02X should be the client\'s with an empty widget'):format(dik));
    check(state({ dik })[dik] ~= nil,
          ('key 0x%02X should reach the game with an empty widget'):format(dik));
end

if (fails == 0) then
    print('ok: held keys stay wiped, typing wins, the widget wins, Escape always acts');
else
    print(('%d check(s) failed'):format(fails));
    os.exit(1);
end
