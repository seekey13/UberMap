--[[
* UberMap - gamepad and keyboard navigation.
*
* Two halves.  The math: which marker a direction press lands on, and which
* one a fresh selection starts at.  All coordinates are source-map pixels, y
* growing downwards, so 'up' is towards the smaller y.  And the dispatch: who
* a press belongs to -- the favorites widget, the map, or the client -- which
* lives here rather than in ubermap.lua so test_gpad.lua and test_kbd.lua can
* drive the real thing instead of a copy that goes stale the moment the addon
* is edited.
*
* Kept free of Ashita and ImGui so it can be exercised outside the game, the
* same way lib/mapmath.lua is.  The dispatch reaches back into the addon
* through a table of four callbacks -- show, fw_confirm, fav_view, chat_open
* -- handed in at each call, and touches nothing else of it but the ui table
* whose fields it is reading and setting anyway.
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

--[[
* Where a press of 'act' leaves the warp list's lit row, and whether that press
* is a send.  A nil row is a list opened with the mouse, which lights none of
* its own: the first press lands on the top row rather than stepping off a
* selection nothing on screen is showing, and sends nothing.  The row is pulled
* back inside the list before it steps, since the toggles can empty rows out
* from under one that is already open.  Up and down wrap at both ends, the way
* the favorites widget and the game's own menus do.  An empty list has no row
* at all.
--]]
function M.row(row, n, act)
    if (n < 1) then
        return nil, false;
    end
    if (row == nil) then
        return 1, false;
    end
    row = math.max(1, math.min(row, n));
    if (act == 'up') then
        return (row - 2) % n + 1, false;
    elseif (act == 'down') then
        return row % n + 1, false;
    end
    return row, act == 'a';
end

--[[
* ---------------------------------------------------------------------------
* The dispatch: who a press belongs to.
* ---------------------------------------------------------------------------
--]]

-- The favorites widget reads five of the seven buttons below -- up, down, A, B
-- and Y, which swaps it for the full map -- and leaves left and right to the
-- client, since it is a single column and taking them would leave no way to
-- work the NPC's own menu behind it.
--
-- The map reads all seven.  It takes them only while it is on screen, which is
-- a place the player put it rather than one they walked into, so unlike the
-- widget it needs no toggle to justify swallowing them: the map is what a
-- press is for while it is up.  Y is the pad's right-click: on a warp row it
-- opens the same favorites menu the mouse's second button does.
--
-- Keyed by the XInput button index Ashita's xinput_button event delivers, so
-- one lookup answers both questions the handler has: whether the button is
-- read at all, and which of the seven it is.
M.GP = {
    [0]  = 'up',
    [1]  = 'down',
    [2]  = 'left',
    [3]  = 'right',
    [12] = 'a',
    [13] = 'b',
    [15] = 'y',
};

--[[
* The keyboard's half of the same seven: the arrows are the D-pad, Enter is A
* and Escape is B, so one set of actions serves both and nav.act needs to know
* nothing about which hand made the press.
*
* U is the widget's alone and has no pad twin: the Y press that swaps the
* widget for the map.  F is read twice over -- at the widget it hands it the
* arrows, and on the map it is the pad's Y, which opens the favorites menu on
* the lit warp row.  Tab is the map's alone and has no pad twin either: it
* moves the keyboard between the map and its own search box.
*
* Keyed by DirectInput scan code rather than by virtual key, because that is
* what the game reads.  The WNDPROC key event carries virtual keys and can be
* blocked, but blocking it only keeps a key out of the client's *text* fields:
* movement, the camera and the menus are all read straight off DirectInput
* underneath it.  So these are matched in key_data and key_state instead, and
* the arrows really do stop turning the camera.
--]]
M.KEY = {
    [0xC8] = 'up',    [0xD0] = 'down',
    [0xCB] = 'left',  [0xCD] = 'right',
    -- Both Enters, since a keyboard has two and only one of them is over by
    -- the letters.
    [0x1C] = 'a',     [0x9C] = 'a',
    [0x01] = 'b',
    [0x16] = 'u',     [0x21] = 'f',
    [0x0F] = 'tab',
};


--[[
* Marks the pad as what is driving, and answers whether this press is spent
* doing only that.  The mouse moving over the map or the widget puts the pad's
* highlights out, so the press that turns them back on lights what it left
* rather than acting on it: the next frame seats a selection under it, and the
* press after that is the one that walks, opens or sends.  A press that acted
* on the way back in would step off -- or worse, send -- something nothing on
* screen was showing.
--]]
local function wake(ui)
    local was = ui.gp_active;
    ui.gp_active = true;
    return not was;
end

--[[
* Whether a key is the map's or the widget's right now, and -- on the press
* edge -- what it does.  Both keyboard handlers come through here: M.key acts
* on it and blocks the edge, M.state asks it with down false and wipes the key
* out of the frame's state buffer.  One answer, so the two cannot come apart
* and leave a key half taken.
*
* Read in the same order the pad is: the widget is asked first and wins
* outright, then the map while it is on screen.  Unlike the pad the keys have
* to be handed back -- the arrows are how the player walks -- so the widget
* takes them only after an F and the map only while it is up.
--]]
function M.press(ui, act, down, h)
    -- Typing beats nearly all of it.  The game's own chat line or a bazaar
    -- comment has the keyboard first; the map's search box and its config
    -- numbers have it next, and the arrows, Enter and Escape are those boxes'
    -- own editing keys while a caret is in one.  ImGui is fed from WNDPROC,
    -- which none of this touches, so a key acted on here would land twice.
    -- Tab is the exception and is taken below, since a key that only ever gets
    -- the keyboard into the box would be a door with no handle on the inside.
    if (h.chat_open() or ui.cfg_typing) then
        return false;
    end

    -- Tab is the one key the search box does not keep for itself: it is how
    -- the keyboard is handed to that box and how it is taken back again, so it
    -- is read before the caret is asked about rather than after.  The map's
    -- alone, since the box is part of the map: the widget below never sees it,
    -- and with the map shut it goes back to the client, which targets with it.
    if (act == 'tab') then
        -- A frame the map did not draw has no box to hand the caret to, the
        -- same reason the slot below is not fed from one: a focus latched
        -- there would sit until the box came back and then take the keyboard
        -- out of nowhere.  Back to the client instead, the way the rest go.
        if (not ui.is_open[1] or not ui.gp_ready) then
            return false;
        end
        if (down) then
            -- One or the other and never both.  A blur still pending from a
            -- map that was put away mid-search would otherwise swallow the
            -- focus this press is asking for.
            ui.focus_next, ui.search_blur = not ui.kb_typing, ui.kb_typing;
        end
        return true;
    end

    if (ui.kb_typing) then
        return false;
    end

    -- The addon's own Escape, held down through user32 to back out of an NPC's
    -- menu, comes back round through DirectInput like any other.  Taking it
    -- would be the map answering a press it made itself -- and wiping it out of
    -- the state buffer would keep it from the very menu it was sent to close.
    if (act == 'b' and ui.esc_frames > 0) then
        return false;
    end

    -- The widget first, and outright: it is only ever up stood at a warp NPC,
    -- and there a press is for it.
    if (ui.fw_on) then
        local n = #h.fav_view();
        if (n == 0) then
            return false;
        end

        -- The way up to the full map, and what the auto-open checkbox leaves
        -- behind when it is turned off: the pad's Y, on a key that is free
        -- whether or not the widget has been given the arrows.  The widget
        -- goes with it rather than staying up over the map, or it would keep
        -- taking the keys the map now wants.
        if (act == 'u') then
            if (down) then
                ui.fw_key  = false;
                ui.fw_hide = true;
                h.show();
            end
            return true;
        end

        if (ui.fw_key) then
            if (act ~= 'up' and act ~= 'down' and act ~= 'a' and act ~= 'b') then
                -- Left and right stay the client's even here: the widget is a
                -- single column, and taking them would leave no way to work
                -- the NPC's menu behind it.
                return false;
            end
            if (not down) then
                return true;
            end
            -- Escape hands the keys back whatever the highlight is doing, so
            -- there is always one press out of this mode.  The rest wait for
            -- the row to be lit again, the same as the pad's do: a press that
            -- acted on the way back in would step off -- or worse, send --
            -- something nothing on screen was showing.
            if (wake(ui) and act ~= 'b') then
                return true;
            end
            if (act == 'up') then
                -- Wraps at both ends, the way the game's own menus do.
                ui.fw_sel = (ui.fw_sel - 2) % n + 1;
            elseif (act == 'down') then
                ui.fw_sel = ui.fw_sel % n + 1;
            elseif (act == 'a') then
                h.fw_confirm();
            else
                -- Out of focus mode and no further: the widget stays up, so
                -- the F that got here is one press away again.
                ui.fw_key = false;
            end
            return true;
        end

        -- The arrows are the player's until they are asked for, since walking
        -- up to a warp NPC is something done while moving.
        if (act == 'f') then
            if (down) then
                ui.fw_key = true;
                ui.fw_sel = math.max(1, math.min(ui.fw_sel, n));
                -- Lights the row on the way in, so the first arrow steps it
                -- rather than being spent turning the highlight back on.
                wake(ui);
            end
            return true;
        end

        -- Escape outside focus mode dismisses the widget, the way B does on
        -- the pad: the NPC's own menu is behind it, and a second Escape is
        -- what backs out of that.
        if (act == 'b') then
            if (down) then
                ui.fw_hide = true;
            end
            return true;
        end
        return false;
    end

    -- The map, while it is on screen.  U is the widget's alone, so with the
    -- widget off screen it goes back to the client rather than falling
    -- through.  F is the map's own Y -- the favorites menu on the lit warp
    -- row -- so past here it travels as one: nav.act knows nothing about which
    -- hand made the press, and 'y' is the name that half of it already answers
    -- to.  At the top of the map it steps nothing and is dropped, exactly as
    -- the pad's Y is there.
    if (not ui.is_open[1] or act == 'u') then
        return false;
    end
    if (act == 'f') then act = 'y'; end

    -- A frame that is not drawing the map has nothing to act on the press --
    -- no texture, or a window ImGui collapsed -- so one held there is lost.
    -- Escape still has to work out of one, or the map could not be shut.
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
    -- Escape is the one exception to the wake: it is the way out of a map
    -- covering most of the screen, so it acts on the first press however the
    -- map was being driven.  See M.pad for the rest of it.
    if (wake(ui) and act ~= 'b') then
        return true;
    end
    -- Held for the draw rather than acted on here: the zooms need the viewport
    -- size, and only the draw knows that.  The frame's first press wins; see
    -- nav.pump for why the second is the one to lose.  Escape is the exception
    -- twice over: exempt from the wake above, and here it takes the slot off a
    -- press that has not run yet, or the one way out of the map could be eaten
    -- by a D-pad press sharing its frame and still be swallowed from the game.
    if (ui.gp_act == nil or act == 'b') then
        ui.gp_act = act;
    end
    return true;
end

--[[
* One xinput_button event, and whether it is the addon's -- which is to say
* whether the client should be kept from seeing it.
*
* Two things read the pad, and only ever one at a time.  The favorites widget
* takes D-pad up and down, A, B and Y while it is on screen, which is only
* while a warp NPC is in reach.  The map takes those and the D-pad's other
* axis and Y while it is up: the D-pad walks the markers, A opens what is
* under it, B backs out, and Y is the right-click that opens the favorites
* menu on a warp row -- while at the widget Y is what swaps the widget for the
* map itself.  The widget is asked first, so walking up to an NPC puts it in
* front of a map that is already open and it has to be dismissed before the
* map answers again.  Every other button, and every button at all outside
* those two, is the client's.
--]]
function M.pad(ui, index, state, h)
    local act = M.GP[index];
    if (act == nil) then
        return false;
    end

    -- Both edges: the client never saw the press, so it is not handed the
    -- release either.  Which edge was taken is remembered rather than re-tested
    -- against ui.fw_on, because the press is what takes the widget off screen
    -- in two of the four cases -- B dismisses it and A warps out of range of
    -- the NPC holding it up -- and a release matched against the state after
    -- that would leak a button-up the client never got the button-down for.
    -- The map's own presses are held for the same reason: A on a warp row
    -- closes the map before the button comes back up.
    if (state ~= 1) then
        if (ui.pad_held[index]) then
            ui.pad_held[index] = nil;
            return true;
        end
        return false;
    end

    -- The widget first, and outright: it is only ever up stood at a warp NPC,
    -- and there it is what a press is for.  The two buttons it does not read
    -- go to the client rather than to the map behind it, or dismissing it
    -- would be the only way to reach the NPC's own menu.
    if (ui.fw_on) then
        local n = #h.fav_view();
        -- Left and right stay the client's: the widget is a single column, and
        -- taking them would leave no way to work the menu behind it short of
        -- dismissing it.
        if (act == 'left' or act == 'right' or n == 0) then
            return false;
        end
        ui.pad_held[index] = true;

        -- Marked here rather than at the head of the handler: what turns the
        -- pad's highlights back on is a press this widget took, not a pad
        -- being plugged in.  Anything else -- the other face buttons, a
        -- release, a trigger -- says nothing about which hand is on the map,
        -- and a player working the mouse with a controller still in reach had
        -- the highlight coming back on all of them.
        if (wake(ui)) then
            return true;
        end

        if (act == 'up') then
            -- Wraps at both ends, the way the game's own menus do.  ponytail:
            -- one step a press; a held-D-pad repeat if a list ever gets long
            -- enough to want one.
            ui.fw_sel = (ui.fw_sel - 2) % n + 1;
        elseif (act == 'down') then
            ui.fw_sel = ui.fw_sel % n + 1;
        elseif (act == 'a') then
            h.fw_confirm();
        elseif (act == 'y') then
            -- The way up to the full map from the widget, and what the
            -- auto-open checkbox leaves behind when it is turned off.  The
            -- widget goes with it rather than staying up over the map: it would
            -- otherwise keep taking the D-pad and A that the map now wants.
            ui.fw_hide = true;
            h.show();
        else
            -- The way back to the NPC's own menu: with A swallowed there would
            -- otherwise be no reaching it from a controller while stood here.
            ui.fw_hide = true;
        end
        return true;
    end

    -- The map, while it is on screen, has had a frame size the view, and is
    -- being drawn -- a frame that returns out early has nothing to act on the
    -- press.  Held for the draw rather than acted on here: the zooms need the
    -- viewport size, and only the draw knows that.
    if (not ui.is_open[1] or ui.zoom == nil or not ui.gp_ready) then
        return false;
    end
    ui.pad_held[index] = true;
    -- The map's own seven, on the press edge, while the map is up: the only
    -- thing that says the pad is what is driving it.  See the widget above.
    if (wake(ui)) then
        return true;
    end
    -- One press waits for the next frame, and the rest of that frame's are
    -- dropped here.  The first wins: see nav.pump for why the later press of
    -- a pair is the one that can go without moving a menu somewhere it does
    -- not belong.  It also means a map nothing is drawing -- the window
    -- collapsed, say -- holds one stale press rather than a hundred.  B is the
    -- exception, taking the slot off a press that has not run yet: it is the
    -- back-out, and it is blocked from the game whether it acts or not.
    if (ui.gp_act == nil or act == 'b') then
        ui.gp_act = act;
    end
    return true;
end

--[[
* One key_data event -- DirectInput's buffered stream, the edges as the game
* reads them -- and whether it is the addon's.
*
* Both edges are taken, and which one was is remembered rather than re-tested:
* the press is what closes the map in two of these cases, and a release
* matched against the state after that would leak a key-up the client never
* got the key-down for.
--]]
function M.key(ui, dik, down, h)
    local act = M.KEY[dik];
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

    if (not M.press(ui, act, true, h)) then
        return false;
    end
    ui.kb_held[dik] = true;
    return true;
end

--[[
* DirectInput's immediate state buffer, read once a frame: what the game polls
* a held key from, so blocking the edge above is not enough on its own -- the
* camera turns for as long as an arrow is down, and it never looks at the
* buffered stream to learn that.
*
* Two things are wiped out of it.  A key whose press was taken, for as long as
* it is held, which is the whole of the case above; and a key that is down and
* would be taken, which covers the frame the two buffers are read in the other
* order and the game would otherwise see one frame of it.
*
* 'keys' is indexed by scan code and written in place, so the one call serves
* both the ffi pointer at the real buffer and a plain table in a test.
--]]
function M.state(ui, keys, h)
    for dik, act in pairs(M.KEY) do
        if (keys[dik] == 0) then
            -- The release edge above is what normally clears this, but an
            -- alt-tab or a device re-acquire while the key is down loses that
            -- event, and a flag left set wipes the key out of this buffer on
            -- every later press -- a camera that will not turn for the whole
            -- of the next hold.  This buffer is the one place that can say a
            -- key is up whether or not its event ever arrived.
            ui.kb_held[dik] = nil;
        elseif (ui.kb_held[dik] or M.press(ui, act, false, h)) then
            keys[dik] = 0;
        end
    end
end

return M;
