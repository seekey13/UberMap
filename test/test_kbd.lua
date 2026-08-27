--[[
* Self-check for which keys the map and the favorites widget take and which
* they leave to the client.  Mirrors nav.press and the two keyboard handlers in
* ubermap.lua: typing beats everything, the widget is asked first and wins
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

local fails = 0;
local function check(ok, msg)
    if (not ok) then
        fails = fails + 1;
        print('FAIL: ' .. msg);
    end
end

-- The table, exactly as ubermap.lua keys it: the DirectInput scan code, which
-- is what the game reads.  The arrows are the D-pad, either Enter is A and
-- Escape is B.
local KEY = {
    [0xC8] = 'up',    [0xD0] = 'down',
    [0xCB] = 'left',  [0xCD] = 'right',
    [0x1C] = 'a',     [0x9C] = 'a',
    [0x01] = 'b',
    [0x16] = 'u',     [0x21] = 'f',
    [0x0F] = 'tab',
};
local DIK = { up = 0xC8, down = 0xD0, left = 0xCB, right = 0xCD,
              enter = 0x1C, pad_enter = 0x9C, esc = 0x01, u = 0x16, f = 0x21,
              tab = 0x0F };
local QUEUE_MAX = 8;

local ui, favs_n;
local function reset()
    -- The mouse drives by default, the way it does on a fresh session, so each
    -- case says outright when it is starting from a map the keys already have.
    ui = { fw_on = false, fw_key = false, is_open = { false, }, zoom = 1.0,
           fw_sel = 1, fw_hide = false, opened = 0, sent = 0, chat = 0,
           kb_typing = false, cfg_typing = false, kb_held = { },
           esc_frames = 0, focus_next = false, search_blur = false,
           gp_active = false, gp_ready = true, gp_q = { } };
    favs_n = 0;
end

local function clamp(v, lo, hi)
    return (v < lo) and lo or ((v > hi) and hi or v);
end

-- nav.wake: marks the keys as what is driving, and says whether the press is
-- spent doing only that.
local function wake()
    local was = ui.gp_active;
    ui.gp_active = true;
    return not was;
end

-- nav.press, minus the two calls into the map that need a frame behind them.
local function press(act, down)
    if (ui.chat ~= 0 or ui.cfg_typing) then
        return false;
    end
    if (act == 'tab') then
        if (not ui.is_open[1] or not ui.gp_ready) then
            return false;
        end
        if (down) then
            ui.focus_next, ui.search_blur = not ui.kb_typing, ui.kb_typing;
        end
        return true;
    end
    if (ui.kb_typing) then
        return false;
    end
    if (act == 'b' and ui.esc_frames > 0) then
        return false;
    end

    if (ui.fw_on) then
        local n = favs_n;
        if (n == 0) then
            return false;
        end
        if (act == 'u') then
            if (down) then
                ui.fw_key     = false;
                ui.fw_hide    = true;
                -- show(), minus the frame behind it.
                ui.is_open[1]  = true;
                ui.opened      = ui.opened + 1;
                ui.search_blur = false;
            end
            return true;
        end
        if (ui.fw_key) then
            if (act ~= 'up' and act ~= 'down' and act ~= 'a' and act ~= 'b') then
                return false;
            end
            if (not down) then
                return true;
            end
            if (wake() and act ~= 'b') then
                return true;
            end
            if (act == 'up') then
                ui.fw_sel = (ui.fw_sel - 2) % n + 1;
            elseif (act == 'down') then
                ui.fw_sel = ui.fw_sel % n + 1;
            elseif (act == 'a') then
                -- fw_confirm(), minus the warp itself.
                ui.sent    = ui.sent + 1;
                ui.fw_hide = true;
            else
                ui.fw_key = false;
            end
            return true;
        end
        if (act == 'f') then
            if (down) then
                ui.fw_key = true;
                ui.fw_sel = clamp(ui.fw_sel, 1, n);
                wake();
            end
            return true;
        end
        if (act == 'b') then
            if (down) then
                ui.fw_hide = true;
            end
            return true;
        end
        return false;
    end

    if (not ui.is_open[1] or act == 'u') then
        return false;
    end
    if (act == 'f') then
        act = 'y';
    end
    if (ui.zoom == nil or not ui.gp_ready) then
        if (act ~= 'b') then
            return false;
        end
        if (down) then
            ui.is_open[1] = false;
        end
        return true;
    end
    if (not down) then
        return true;
    end
    if (wake() and act ~= 'b') then
        return true;
    end
    if (#ui.gp_q < QUEUE_MAX) then
        table.insert(ui.gp_q, act);
    end
    return true;
end

-- The key_data handler: the buffered edge, and whether it was blocked.
local function key(dik, down)
    local act = KEY[dik];
    if (act == nil) then
        return false;
    end
    if (not down) then
        if (ui.kb_held[dik]) then
            ui.kb_held[dik] = nil;
            return true;
        end
        return false;
    end
    if (not press(act, true)) then
        return false;
    end
    ui.kb_held[dik] = true;
    return true;
end

-- The key_state handler, over a frame's state buffer given as a set of the
-- scan codes that are down.  Hands back what is left of it for the game.
local function state(down_set)
    local keys = { };
    for _, dik in ipairs(down_set) do
        keys[dik] = 1;
    end
    for dik, act in pairs(KEY) do
        if (keys[dik] ~= nil and (ui.kb_held[dik] or press(act, false))) then
            keys[dik] = nil;
        end
    end
    return keys;
end

local NAV = { DIK.up, DIK.down, DIK.left, DIK.right, DIK.enter, DIK.esc };

-- Map shut and no widget: every key is the client's, and nothing is queued.
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
check(#ui.gp_q == 0, 'a shut map should queue nothing');

-- Map open, keys already driving: the six are taken, in the order pressed, and
-- either Enter is A.
reset();
ui.is_open[1], ui.gp_active = true, true;
for _, dik in ipairs(NAV) do
    check(key(dik, true), ('key 0x%02X should be taken with the map open'):format(dik));
    check(key(dik, false), ('key 0x%02X release should follow its press'):format(dik));
end
check(#ui.gp_q == 6, ('six presses should queue six actions, queued %d'):format(#ui.gp_q));
check(ui.gp_q[1] == 'up' and ui.gp_q[4] == 'right' and ui.gp_q[5] == 'a'
      and ui.gp_q[6] == 'b',
      'the queue should hold the actions in the order they were pressed');
check(key(DIK.pad_enter, true), 'the numpad Enter should be taken too');
check(ui.gp_q[7] == 'a', 'the numpad Enter should queue the same action');
key(DIK.pad_enter, false);
-- U is the widget's alone; the map behind it never sees it.  F is the map's
-- own Y, so with the widget gone it queues the favorites menu instead of
-- going back to the client.
check(not key(DIK.u, true), 'U should be the client\'s with the widget off screen');
check(state({ DIK.u })[DIK.u] ~= nil,
      'U should survive the state buffer with the widget off screen');
check(key(DIK.f, true), 'F should be taken by the map with the widget off screen');
check(ui.gp_q[8] == 'y', 'F should queue the same action the pad\'s Y does');
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

-- The state buffer is wiped on the frame the press lands as well, whichever
-- order the game reads its two buffers in.
reset();
ui.is_open[1], ui.gp_active = true, true;
check(state({ DIK.up })[DIK.up] == nil,
      'a key the map would take should be wiped before its edge is read');
check(#ui.gp_q == 0, 'the state buffer should act on nothing');

-- Escape closes the map, and goes on being wiped until it comes back up: the
-- client must not see the tail of a press that shut the map.
reset();
ui.is_open[1], ui.gp_active = true, true;
key(DIK.esc, true);
check(ui.gp_q[1] == 'b', 'Escape should queue the back-out');
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
    check(#ui.gp_q == 0, ('nothing should queue while %s'):format(field));
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
check(#ui.gp_q == 0, 'Tab should queue no map action');
-- The frame the box takes the caret, as the draw reports it.
ui.focus_next, ui.kb_typing = false, true;
check(key(DIK.tab, true), 'Tab should still be taken with the caret in the box');
key(DIK.tab, false);
check(ui.search_blur and not ui.focus_next,
      'Tab in the box should take the keyboard back off it');
-- and the caret is gone by the next frame, so the arrows are the map's again.
ui.kb_typing, ui.search_blur = false, false;
check(key(DIK.up, true), 'the arrows should be the map\'s again after a Tab out');
check(ui.gp_q[1] == 'up', 'and should queue the move they always did');
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
check(#ui.gp_q == 0, 'the map should queue nothing while the widget is up');
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
    check(#ui.gp_q == 0, 'U should queue nothing for the map it just opened');
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
check(#ui.gp_q == 0, 'the waking press should queue nothing');
check(ui.gp_active, 'the waking press should mark the keys as driving');
key(DIK.down, false);
check(key(DIK.down, true), 'the press after the wake should be taken');
check(#ui.gp_q == 1,
      ('the press after the wake should queue, queued %d'):format(#ui.gp_q));

-- Escape is the exception: it is the one way out of a map covering most of the
-- screen, so it acts on the first press however the map was being driven.
reset();
ui.is_open[1] = true;
check(key(DIK.esc, true), 'Escape off the mouse should be taken');
check(#ui.gp_q == 1 and ui.gp_q[1] == 'b',
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
-- collapsed -- has nothing to drain the queue, so a press there is lost.
-- Escape still has to work out of one, or the map could not be shut.
reset();
ui.is_open[1], ui.gp_ready, ui.gp_active = true, false, true;
check(not key(DIK.down, true), 'an undrawn map should leave the arrows to the client');
check(state({ DIK.down })[DIK.down] ~= nil,
      'an undrawn map should let the arrows walk the player');
check(#ui.gp_q == 0, 'an undrawn map should queue nothing');
check(key(DIK.esc, true), 'Escape should still be taken by an undrawn map');
check(not ui.is_open[1], 'Escape should close a map that is not being drawn');

-- A queue nothing is draining is worse than losing presses: a hundred landing
-- at once when the map comes back is not what any of them meant.
reset();
ui.is_open[1], ui.gp_active = true, true;
for _ = 1, 20 do
    key(DIK.up, true);
    key(DIK.up, false);
end
check(#ui.gp_q == QUEUE_MAX,
      ('the queue should cap at %d, holds %d'):format(QUEUE_MAX, #ui.gp_q));

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
