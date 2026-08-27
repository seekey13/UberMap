--[[
* Self-check for which keys the map and the favorites widget take and which
* they leave to the client.  Mirrors the key handler in ubermap.lua: typing
* beats everything, the widget is asked first and wins outright, the arrows are
* the player's own until an F asks for them, the map takes them only while it
* is on screen, a press that only takes the map back off the mouse is spent
* doing that -- except Escape, which always has to work -- and U and F mean
* nothing once the widget is off screen.  Run with any Lua 5.1+:
*     lua test/test_kbd.lua
--]]

local fails = 0;
local function check(ok, msg)
    if (not ok) then
        fails = fails + 1;
        print('FAIL: ' .. msg);
    end
end

-- The table, exactly as ubermap.lua keys it: the virtual-key code the event
-- delivers.  The arrows are the D-pad, Enter is A and Escape is B.
local KEY = {
    [0x26] = 'up',    [0x28] = 'down',
    [0x25] = 'left',  [0x27] = 'right',
    [0x0D] = 'a',     [0x1B] = 'b',
    [0x55] = 'u',     [0x46] = 'f',
};
local VK = { up = 0x26, down = 0x28, left = 0x25, right = 0x27,
             enter = 0x0D, esc = 0x1B, u = 0x55, f = 0x46 };
local QUEUE_MAX = 8;

local ui, favs_n;
local function reset()
    -- The mouse drives by default, the way it does on a fresh session, so each
    -- case says outright when it is starting from a map the keys already have.
    ui = { fw_on = false, fw_key = false, is_open = { false, }, zoom = 1.0,
           fw_sel = 1, fw_hide = false, opened = 0, sent = 0, chat = 0,
           kb_typing = false, cfg_typing = false,
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

-- The handler, minus the two calls into the map that need a frame behind them.
-- Hands back whether the press was blocked, which is the whole question.
local function key(vk)
    if (ui.chat ~= 0 or ui.kb_typing or ui.cfg_typing) then
        return false;
    end

    local act = KEY[vk];

    if (ui.fw_on) then
        local n = favs_n;
        if (n == 0) then
            return false;
        end
        if (act == 'u') then
            ui.fw_key     = false;
            ui.fw_hide    = true;
            -- show(), minus the frame behind it.
            ui.is_open[1] = true;
            ui.opened     = ui.opened + 1;
            return true;
        end
        if (ui.fw_key) then
            if (act ~= 'up' and act ~= 'down' and act ~= 'a' and act ~= 'b') then
                return false;
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
            ui.fw_key = true;
            ui.fw_sel = clamp(ui.fw_sel, 1, n);
            wake();
            return true;
        end
        if (act == 'b') then
            ui.fw_hide = true;
            return true;
        end
        return false;
    end

    if (not ui.is_open[1] or act == nil or act == 'u' or act == 'f') then
        return false;
    end
    if (ui.zoom == nil or not ui.gp_ready) then
        if (act == 'b') then
            ui.is_open[1] = false;
            return true;
        end
        return false;
    end
    if (wake() and act ~= 'b') then
        return true;
    end
    if (#ui.gp_q < QUEUE_MAX) then
        table.insert(ui.gp_q, act);
    end
    return true;
end

local NAV = { VK.up, VK.down, VK.left, VK.right, VK.enter, VK.esc };

-- Map shut and no widget: every key is the client's, and nothing is queued.
-- The arrows above all: they are how the player walks.
reset();
for _, vk in ipairs(NAV) do
    check(not key(vk), ('key 0x%02X should be the client\'s with the map shut'):format(vk));
end
check(not key(VK.u), 'U should be the client\'s with no widget up');
check(not key(VK.f), 'F should be the client\'s with no widget up');
check(#ui.gp_q == 0, 'a shut map should queue nothing');

-- Map open, keys already driving: the six are taken, in the order pressed.
reset();
ui.is_open[1], ui.gp_active = true, true;
for _, vk in ipairs(NAV) do
    check(key(vk), ('key 0x%02X should be taken with the map open'):format(vk));
end
check(#ui.gp_q == 6, ('six presses should queue six actions, queued %d'):format(#ui.gp_q));
check(ui.gp_q[1] == 'up' and ui.gp_q[4] == 'right' and ui.gp_q[5] == 'a'
      and ui.gp_q[6] == 'b',
      'the queue should hold the actions in the order they were pressed');
-- U and F are the widget's alone; the map behind it never sees them.
check(not key(VK.u), 'U should be the client\'s with the widget off screen');
check(not key(VK.f), 'F should be the client\'s with the widget off screen');
check(#ui.gp_q == 6, 'U and F should queue nothing for the map');

-- Typing beats all of it, three ways: the game's own chat line, the map's
-- search box, and a config number.  A key acted on here would land twice.
for _, field in ipairs({ 'chat', 'kb_typing', 'cfg_typing' }) do
    reset();
    ui.is_open[1], ui.gp_active = true, true;
    ui[field] = (field == 'chat') and 0x11 or true;
    for _, vk in ipairs(NAV) do
        check(not key(vk), ('key 0x%02X should be the caret\'s while %s'):format(vk, field));
    end
    check(#ui.gp_q == 0, ('nothing should queue while %s'):format(field));
    check(ui.is_open[1], ('Escape should not close the map while %s'):format(field));
end

-- The widget in front, before an F: the arrows are still the player's, since
-- walking up to a warp NPC is done while moving.  U and Escape work anyway.
reset();
ui.is_open[1], ui.fw_on, favs_n = true, true, 3;
for _, vk in ipairs({ VK.up, VK.down, VK.left, VK.right, VK.enter }) do
    check(not key(vk), ('key 0x%02X should be the player\'s before an F'):format(vk));
end
check(#ui.gp_q == 0, 'the map should queue nothing while the widget is up');
check(ui.fw_sel == 1, ('the row should not have walked, is %d'):format(ui.fw_sel));

-- Escape outside focus mode dismisses the widget rather than closing the map
-- behind it, the way B does on the pad.
check(key(VK.esc), 'Escape should be the widget\'s');
check(ui.fw_hide, 'Escape should put the widget away');
check(ui.is_open[1], 'Escape at the widget should leave the map alone');

-- F hands it the arrows, and lights the row on the way in so the first arrow
-- steps it rather than being spent turning the highlight back on.
reset();
ui.fw_on, favs_n = true, 3;
check(key(VK.f), 'F should be taken by the widget');
check(ui.fw_key, 'F should hand the widget the arrows');
check(ui.gp_active, 'F should light the row');
check(key(VK.down), 'the arrows should be the widget\'s after an F');
check(ui.fw_sel == 2, ('the first arrow should step the row, is %d'):format(ui.fw_sel));
-- Wraps at both ends, the way the game's own menus do.
key(VK.up); key(VK.up);
check(ui.fw_sel == 3, ('up past the top should wrap, is %d'):format(ui.fw_sel));
-- Left and right stay the client's even in focus mode: the widget is a single
-- column, and taking them would leave no way to work the menu behind it.
check(not key(VK.left), 'left should stay the client\'s in focus mode');
check(not key(VK.right), 'right should stay the client\'s in focus mode');

-- Enter sends the lit row, and the widget gets out of the way behind it.
reset();
ui.fw_on, favs_n, ui.fw_key, ui.gp_active = true, 3, true, true;
check(key(VK.enter), 'Enter should be taken in focus mode');
check(ui.sent == 1, ('Enter should send the row once, sent %d'):format(ui.sent));

-- Escape in focus mode hands the arrows back and goes no further: the widget
-- stays up, so the F that got here is one press away again.
reset();
ui.fw_on, favs_n, ui.fw_key, ui.gp_active = true, 3, true, true;
check(key(VK.esc), 'Escape should be taken in focus mode');
check(not ui.fw_key, 'Escape should hand the arrows back');
check(not ui.fw_hide, 'Escape out of focus mode should leave the widget up');
-- And the next one dismisses it, now that focus mode is off.
check(key(VK.esc), 'the second Escape should be taken');
check(ui.fw_hide, 'the second Escape should put the widget away');

-- U at the widget is the way up to the full map, whether or not the arrows
-- were ever asked for: the widget puts itself away and the map is opened
-- rather than driven, so nothing is queued for it.
for _, focused in ipairs({ false, true }) do
    reset();
    ui.fw_on, favs_n, ui.fw_key = true, 3, focused;
    check(key(VK.u), 'U should be taken by the widget');
    check(ui.fw_hide, 'U should put the widget away');
    check(not ui.fw_key, 'U should hand the arrows back');
    check(ui.opened == 1, ('U should open the map once, opened %d'):format(ui.opened));
    check(#ui.gp_q == 0, 'U should queue nothing for the map it just opened');
    check(ui.fw_sel == 1, ('U should not step the row, is %d'):format(ui.fw_sel));
end

-- The mouse had the map.  The press that takes it back is still the map's --
-- the client must not see it -- but it is spent lighting the selection again
-- rather than walking off one nothing on screen was showing.
reset();
ui.is_open[1] = true;
check(key(VK.down), 'the waking press should still be taken');
check(#ui.gp_q == 0, 'the waking press should queue nothing');
check(ui.gp_active, 'the waking press should mark the keys as driving');
check(key(VK.down), 'the press after the wake should be taken');
check(#ui.gp_q == 1,
      ('the press after the wake should queue, queued %d'):format(#ui.gp_q));

-- Escape is the exception: it is the one way out of a map covering most of the
-- screen, so it acts on the first press however the map was being driven.
reset();
ui.is_open[1] = true;
check(key(VK.esc), 'Escape off the mouse should be taken');
check(#ui.gp_q == 1 and ui.gp_q[1] == 'b',
      'Escape should act on the waking press rather than be spent on it');

-- The same at the widget, whose row the mouse puts out the same way.
reset();
ui.fw_on, favs_n, ui.fw_key = true, 3, true;
check(key(VK.down), 'the widget should take the waking press');
check(ui.fw_sel == 1,
      ('a waking press should not step the row, is %d'):format(ui.fw_sel));
key(VK.down);
check(ui.fw_sel == 2,
      ('the press after the wake should step the row, is %d'):format(ui.fw_sel));

-- A map that is open but not being drawn -- no texture, or a window ImGui
-- collapsed -- has nothing to drain the queue, so a press there is lost.
-- Escape still has to work out of one, or the map could not be shut.
reset();
ui.is_open[1], ui.gp_ready, ui.gp_active = true, false, true;
check(not key(VK.down), 'an undrawn map should leave the arrows to the client');
check(#ui.gp_q == 0, 'an undrawn map should queue nothing');
check(key(VK.esc), 'Escape should still be taken by an undrawn map');
check(not ui.is_open[1], 'Escape should close a map that is not being drawn');

-- A queue nothing is draining is worse than losing presses: a hundred landing
-- at once when the map comes back is not what any of them meant.
reset();
ui.is_open[1], ui.gp_active = true, true;
for _ = 1, 20 do
    key(VK.up);
end
check(#ui.gp_q == QUEUE_MAX,
      ('the queue should cap at %d, holds %d'):format(QUEUE_MAX, #ui.gp_q));

-- An empty widget reads no key at all: it is off screen, and the list the
-- arrows would walk is not there.
reset();
ui.fw_on, favs_n = true, 0;
for _, vk in ipairs({ VK.up, VK.down, VK.enter, VK.esc, VK.u, VK.f }) do
    check(not key(vk), ('key 0x%02X should be the client\'s with an empty widget'):format(vk));
end

if (fails == 0) then
    print('ok: typing wins, the widget wins, F takes the arrows, Escape always acts');
else
    print(('%d check(s) failed'):format(fails));
    os.exit(1);
end
