--[[
* Self-check for the EXP Guide errand: the walk-past that asks a guide for an
* Instant Warp scroll and backs out of the talk it arrives in.
*
* Drives the real lib/guide.lua rather than a copy of it, so a change to the
* errand that breaks one of these contracts fails here.  Everything the errand
* reads or does to the world arrives through the six calls in `world` below,
* which is a fake one this file winds forward a frame at a time.
*
* Two contracts here.  One ask per line-up of the three conditions - no scroll
* carried, a slot free for one, a guide in reach - and no ask at all while any
* of them is false.  And an Escape that lands on the talk rather than in front
* of it: the guide answers a couple of seconds after the ask, and puts its talk
* up a moment after the scroll it hands over, so the exit waits for the talk to
* be on screen rather than pressing the moment the bag changes.
*
* Run from the addon directory with any Lua 5.1+:
*     lua test/test_guide.lua
--]]

local g = assert(loadfile('lib/guide.lua'))();

-- The two timings measured by hand in game, in seconds: how long the guide takes
-- to answer an ask, and how long after the scroll reaches the bag its talk
-- reaches the screen.  The checks run against these rather than an instant
-- reply, since instant is the one shape the timing bug never showed up in - the
-- press went out into the gap the skew opens and the talk was left sitting.
local REPLY, TALK_SKEW = 2.0, 0.5;

--[[
* The world the errand reads, as plain fields the checks below set and read,
* plus the six calls lib/guide.lua actually takes it through.  Every ask and
* every Escape press lands back here as a count.
--]]
local function world()
    local w = {
        in_event   = false,
        guide      = nil,      -- server id of a guide in reach, or nil
        has_warp   = false,
        bag_full   = false,
        bag_ok     = true,     -- the inventory read worked; false while zoning
        pending    = nil,      -- a warp command waiting on a menu to close
        esc_frames = 0,        -- an Escape the map is already holding down
        pokes      = 0,
        presses    = 0,
    };
    w.calls = {
        in_event   = function () return w.in_event; end,
        bag        = function () return w.has_warp, w.bag_full, w.bag_ok; end,
        near_guide = function () return w.guide, 0x705; end,
        blocked    = function () return w.pending ~= nil or w.esc_frames > 0; end,
        -- press_escape refuses to start a second press while one is still held,
        -- and reports back that it did nothing.
        press      = function ()
            if (w.esc_frames > 0) then
                return false;
            end
            w.presses = w.presses + 1;
            return true;
        end,
        poke       = function () w.pokes = w.pokes + 1; end,
    };
    return w;
end

local fails = 0;
local function check(name, got, want)
    if (got ~= want) then
        print(('FAIL %s: got %s, wanted %s'):format(name, tostring(got), tostring(want)));
        fails = fails + 1;
    end
end

-- Frame timing puts an exact press count on a knife edge, so a repeat that is
-- meant to be paced rather than counted is checked as a band.
local function between(name, got, lo, hi)
    if (got < lo or got > hi) then
        print(('FAIL %s: got %s, wanted %d..%d'):format(name, tostring(got), lo, hi));
        fails = fails + 1;
    end
end

-- Runs the pump over a span of frames, 1/30s apart, starting at t0.
local function run(st, w, t0, frames)
    for i = 0, frames - 1 do
        g.pump(st, w.calls, t0 + i / 30);
    end
    return t0 + frames / 30;
end

local GUIDE_A, GUIDE_B = 17774597, 17782790;

--[[
* A whole errand against a server that answers `reply` seconds after the ask,
* puts its talk on screen `skew` seconds after the scroll reaches the bag, and
* closes that talk `close` seconds after an Escape reaches it.  A nil close is a
* talk that never closes; a nil reply is a guide that never answers at all.
--]]
local function errand(opts)
    local st, w = g.state(), world();
    w.guide = GUIDE_A;
    local scroll_at, talk_at, close_at;
    for i = 0, 30 * (opts.secs or 20) do
        local now = 100 + i / 30;
        if (scroll_at and now >= scroll_at) then
            w.has_warp, scroll_at = true, nil;
        end
        if (talk_at and now >= talk_at) then
            w.in_event, talk_at = true, nil;
        end
        if (close_at and now >= close_at) then
            w.in_event, close_at = false, nil;
        end
        local poked, pressed = w.pokes, w.presses;
        g.pump(st, w.calls, now);
        if (w.pokes > poked and opts.reply ~= nil) then
            scroll_at = now + opts.reply;
            talk_at   = now + opts.reply + (opts.skew or 0);
        end
        if (w.presses > pressed and opts.close ~= nil and w.in_event) then
            close_at = now + opts.close;
        end
    end
    return w, st;
end

-- The real shape of it, on the timings measured in game: ask, the scroll lands
-- two seconds later, the talk half a second after that, one Escape closes it.
local w, ui = errand({ reply = REPLY, skew = TALK_SKEW, close = 0.2 });
check('real ask',    w.pokes, 1);
check('real press',  w.presses, 1);
check('real seen',   ui.seen, true);
check('real done',   ui.step, nil);

-- The same errand with the talk already up when the scroll lands: still one
-- press, so waiting for the talk has not cost the case that never needed it.
local w = errand({ reply = REPLY, skew = 0, close = 0.2 });
check('no skew press', w.presses, 1);

-- The window has to outlast the skew with room over, and the wait the reply.
check('exit outlasts skew',  g.GUIDE_EXIT > TALK_SKEW * 2, true);
check('wait outlasts reply', g.GUIDE_WAIT > REPLY * 2, true);

-- A guide that hands the scroll over without its talk ever registering as an
-- event: one press still goes out on the way past, and the errand ends rather
-- than hanging on a talk the client never admits to.
local u, x = g.state(), world();
x.guide = GUIDE_A;
local t = run(u, x, 100, 2);
x.has_warp = true;
t = run(u, x, t, 30 * 5);
check('no talk press', x.presses, 1);
check('no talk done',  u.step, nil);

-- A talk that will not close is pressed at ESCAPE_RETRY across the window and
-- then given up on, rather than pressed forever.
local w, ui = errand({ reply = REPLY, skew = TALK_SKEW, close = nil, secs = 12 });
between('stuck talk presses', w.presses, 3, 7);
check('stuck talk done', ui.step, nil);

-- Standing at a guide with an empty slot and no scroll: asked once, and once
-- only however many frames go by.
local ui, w = g.state(), world();
w.guide = GUIDE_A;
run(ui, w, 100, 60);
check('ask', w.pokes, 1);
check('ask state', ui.step, 'wait');

-- The three reasons not to ask, each on its own.
for _, case in ipairs({
    { 'carrying', function (x) x.has_warp = true end },
    { 'full',     function (x) x.bag_full = true end },
    { 'talking',  function (x) x.in_event = true end },
}) do
    local u, x = g.state(), world();
    x.guide = GUIDE_A;
    case[2](x);
    run(u, x, 100, 60);
    check('no ask ' .. case[1], x.pokes, 0);
    check('no ask ' .. case[1] .. ' idle', u.step, nil);
end

-- No guide in reach is the same nothing, whatever the bag says.
local u, x = g.state(), world();
run(u, x, 100, 60);
check('no guide', x.pokes, 0);

-- A warp command already waiting on a menu, and an Escape already held, each
-- hold the ask off rather than landing in the middle of it.  Held, not spent:
-- the line-up is still armed when the gate clears.
for _, case in ipairs({
    { 'pending',  function (x) x.pending = '/gtp Bastok' end,
                  function (x) x.pending = nil end },
    { 'escaping', function (x) x.esc_frames = 3 end,
                  function (x) x.esc_frames = 0 end },
}) do
    local u, x = g.state(), world();
    x.guide = GUIDE_A;
    case[2](x);
    local t = run(u, x, 100, 60);
    check('no ask ' .. case[1], x.pokes, 0);
    case[3](x);
    run(u, x, t, 30);
    check('ask after ' .. case[1], x.pokes, 1);
end

-- An Escape already held by the map is not spent as this errand's press: the
-- errand waits for the key to come back up rather than counting one that never
-- went out.
local ui, w = g.state(), world();
w.guide = GUIDE_A;
local t = run(ui, w, 100, 2);
w.has_warp, w.in_event, w.esc_frames = true, true, 3;
t = run(ui, w, t, 10);
check('held escape presses none', w.presses, 0);
check('held escape still exiting', ui.step, 'exit');
w.esc_frames = 0;
t = run(ui, w, t, 10);
check('held escape presses after', w.presses, 1);

-- Escape repeats no faster than ESCAPE_RETRY while a talk is still up.
local ui, w = g.state(), world();
w.guide = GUIDE_A;
local t = run(ui, w, 100, 2);
w.has_warp, w.in_event = true, true;
t = run(ui, w, t, 3);
check('press once', w.presses, 1);
t = run(ui, w, t, 12);
check('press not per frame', w.presses, 1);
t = run(ui, w, t, 5);
check('press twice', w.presses, 2);

-- The talk closing ends the errand.
w.in_event = false;
t = run(ui, w, t, 2);
check('done', ui.step, nil);

-- Carrying the scroll, standing right there: no second ask.
t = run(ui, w, t, 30 * 10);
check('carrying after', w.pokes, 1);

-- Spending it lines the three up again, and that is worth exactly one ask -
-- the fetch is not on a cooldown of its own.
w.has_warp = false;
t = run(ui, w, t, 30);
check('respend asks', w.pokes, 2);
t = run(ui, w, t, 30 * 10);
check('respend asks once', w.pokes, 2);

-- Zoning mid-wait makes the inventory unreadable, and an unreadable bag reads
-- back as carried-and-full: the one pair of answers that asks for nothing.  The
-- wait has to tell that apart from the scroll actually landing, or it starts
-- pressing Escape at a talk that was never opened, during a zone transition.
local ui, w = g.state(), world();
w.guide = GUIDE_A;
local t = run(ui, w, 100, 2);
check('zoning asked', w.pokes, 1);
w.has_warp, w.bag_full, w.bag_ok = true, true, false;   -- the read failed
t = run(ui, w, t, 30 * 2);
check('zoning no exit',  ui.step, 'wait');
check('zoning no press', w.presses, 0);
-- The read comes back and the scroll really is there, so the errand goes on.
w.bag_ok = true;
t = run(ui, w, t, 3);
check('zoning resumes', ui.step, 'exit');

-- A guide that answers with a menu rather than the scroll -- a slot filled
-- since the bag was read, or a server that asks before it hands over.  The wait
-- runs out with a talk still on screen, so the errand backs out of it instead
-- of walking away and leaving the player standing in an event they never
-- opened.
local ui, w = g.state(), world();
w.guide = GUIDE_A;
local t = run(ui, w, 100, 2);
w.in_event = true;               -- the menu the guide put up
t = run(ui, w, t, 30 * 6);       -- past GUIDE_WAIT
check('menu pressed', w.presses > 0, true);
w.in_event = false;              -- the presses closed it
t = run(ui, w, t, 30 * 3);
check('menu done', ui.step, nil);
check('menu no repeat', w.pokes, 1);

-- A guide that answers with nothing at all: the wait runs out, and the ask is
-- not repeated for as long as the player stands there.  No talk ever came up,
-- so no Escape is spent on an empty screen either.
local ui, w = g.state(), world();
w.guide = GUIDE_A;
local t = run(ui, w, 100, 2);
check('first ask', w.pokes, 1);
t = run(ui, w, t, 30 * 6);       -- past GUIDE_WAIT
check('gave up', ui.step, nil);
check('gave up quietly', w.presses, 0);
t = run(ui, w, t, 30 * 300);     -- five minutes of standing there
check('never repeats', w.pokes, 1);

-- Walking out of reach and back is a fresh line-up, so it gets its own ask.
w.guide = nil;
t = run(ui, w, t, 30);
w.guide = GUIDE_A;
t = run(ui, w, t, 30);
check('walked back', w.pokes, 2);

-- Walking off mid-wait does not ask a second guide until the first errand is
-- over: the errand is one at a time.
local ui, w = g.state(), world();
w.guide = GUIDE_A;
local t = run(ui, w, 100, 2);
w.guide = GUIDE_B;
t = run(ui, w, t, 30 * 2);
check('one at a time', w.pokes, 1);

-- A fresh run asks on the first walk-up rather than sitting out a wait that
-- os.clock() starting near zero would otherwise put it inside.
local ui, w = g.state(), world();
w.guide = GUIDE_A;
run(ui, w, 0.05, 60);
check('cold start asks', w.pokes, 1);

if (fails == 0) then
    print('test_guide: ok');
else
    os.exit(1);
end
