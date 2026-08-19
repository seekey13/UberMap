--[[
* Self-check for leaving an NPC's menu before a command goes out.  A command
* asked for outside an event goes straight away; one asked for inside is held,
* Escape is pressed, the press is released a few frames later, and the command
* follows once the game says the event is over.  A menu that will not close
* gives up rather than stranding the command, presses never overlap, and the
* key is always released as many times as it was pressed.  Mirrors send_cmd and
* pump_escape in ubermap.lua.  Run with any Lua 5.1+:
*     lua test/test_escape.lua
--]]

local ESCAPE_HOLD                = 3;
local ESCAPE_RETRY, ESCAPE_WAIT  = 0.5, 2.0;

-- The addon, with the game and the keyboard replaced by counters.  `event` is
-- what the client reports as the player's status, flipped by the test.
local function addon(has_user32)
    local a = {
        event = false, pending = nil, pend_at = 0, esc_at = 0, esc_frames = 0,
        now = 0, sent = {}, down = 0, up = 0, gave_up = false,
    };

    local function press(now)
        if (not has_user32 or a.esc_frames > 0) then
            return;
        end
        a.down       = a.down + 1;
        a.esc_frames = ESCAPE_HOLD;
        a.esc_at     = now;
    end

    function a.send(cmd)
        if (has_user32 and a.event) then
            a.pending = cmd;
            a.pend_at = a.now;
            press(a.now);
        else
            table.insert(a.sent, cmd);
        end
    end

    -- One frame of pump_escape.
    function a.frame()
        if (a.esc_frames > 0) then
            a.esc_frames = a.esc_frames - 1;
            if (a.esc_frames == 0) then
                a.up = a.up + 1;
            end
            return;
        end
        if (a.pending == nil) then
            return;
        end
        if (not a.event) then
            table.insert(a.sent, a.pending);
            a.pending = nil;
            return;
        end
        if (a.now - a.pend_at > ESCAPE_WAIT) then
            a.pending = nil;
            a.gave_up = true;
            return;
        end
        if (a.now - a.esc_at > ESCAPE_RETRY) then
            press(a.now);
        end
    end

    -- `secs` of frames, so a test can advance the clock and the frame count at
    -- once the way the game does.
    function a.run(secs, frames)
        for _ = 1, frames do
            a.now = a.now + secs / frames;
            a.frame();
        end
    end

    return a;
end

-- Outside an event the command goes at once and no key is touched.
local a = addon(true);
a.send('/uw hp Bastok');
assert(a.sent[1] == '/uw hp Bastok', 'a command sent outside an event goes straight away');
assert(a.down == 0, 'nothing outside an event presses Escape');

-- Inside one it is held, and Escape goes down.
a = addon(true);
a.event = true;
a.send('/uw hp Bastok');
assert(#a.sent == 0, 'a command sent inside an event is held back');
assert(a.pending == '/uw hp Bastok', 'the held command is the one that was asked for');
assert(a.down == 1 and a.up == 0, 'Escape is pressed and still held');

-- The press is released once the client has had its frames to see it, and not
-- before: a press and release inside one frame is never read.
a.frame();
a.frame();
assert(a.up == 0, 'the press is held for the frames the client needs');
a.frame();
assert(a.up == 1, 'the press is released after ESCAPE_HOLD frames');

-- The menu closes; the command follows on the next frame and only once.
a.event = false;
a.frame();
assert(a.sent[1] == '/uw hp Bastok', 'the held command goes once the event is over');
a.frame();
assert(#a.sent == 1, 'it is sent once, not once per frame');

-- A menu more than one deep gets another press, but not before the retry.
a = addon(true);
a.event = true;
a.send('/uw sg Rabao');
a.run(0.4, 24);
assert(a.down == 1, 'a second press waits for ESCAPE_RETRY');
a.run(0.3, 18);
assert(a.down == 2, 'a menu still up after ESCAPE_RETRY is pressed again');

-- Presses never overlap, and every one is released.
a = addon(true);
a.event = true;
a.send('/uw uc Jeuno');
a.run(ESCAPE_WAIT * 2, 400);
assert(a.down == a.up, 'every press is released, so Escape is never left down');
assert(a.gave_up and a.pending == nil, 'a menu that will not close gives up');
assert(#a.sent == 0, 'and the command is not sent into the menu anyway');

-- Without user32 there is no way to press anything, so the command goes as it
-- always did and the player closes the menu themselves.
a = addon(false);
a.event = true;
a.send('/uw hp Bastok');
assert(a.sent[1] == '/uw hp Bastok', 'without user32 the command is not held back');
assert(a.down == 0, 'and nothing is pressed');

print('test_escape: ok');
