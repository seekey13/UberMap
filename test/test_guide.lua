--[[
* Self-check for the EXP Guide errand: the walk-past that asks a guide for an
* Instant Warp scroll and backs out of the talk it arrives in.  Mirrors
* pump_guide in ubermap.lua, driven by a fake world instead of the entity array
* and the bag.
*
* Two contracts here.  One ask per line-up of the three conditions - no scroll
* carried, a slot free for one, a guide in reach - and no ask at all while any
* of them is false.  And an Escape that lands on the talk rather than in front
* of it: the guide answers a couple of seconds after the ask, and puts its talk
* up a moment after the scroll it hands over, so the exit waits for the talk to
* be on screen rather than pressing the moment the bag changes.
*
* Run with any Lua 5.1+:
*     lua test/test_guide.lua
--]]

local NEAR_POLL  = 0.5;
local GUIDE_WAIT = 5.0;
local GUIDE_EXIT = 1.0;
local ESCAPE_RETRY = 0.5;

-- The two timings measured by hand in game, in seconds: how long the guide takes
-- to answer an ask, and how long after the scroll reaches the bag its talk
-- reaches the screen.  The checks run against these rather than an instant
-- reply, since instant is the one shape the timing bug never showed up in - the
-- press went out into the gap the skew opens and the talk was left sitting.
local REPLY, TALK_SKEW = 2.0, 0.5;

-- The world the errand reads: whether the player is in a talk, whether a guide
-- is in reach, and what the bag holds.  Every ask and every Escape press lands
-- back here, which is what the checks below count.
local function world()
    return {
        in_event = false,
        guide    = nil,      -- server id of a guide in reach, or nil
        has_warp = false,
        bag_full = false,
        esc_at   = -ESCAPE_RETRY,
        pokes    = 0,
        presses  = 0,
    };
end

local function ui_new()
    return {
        has_warp    = false,
        bag_full    = true,
        bag_at      = 0,
        guide       = nil,
        guide_at    = 0,
        guide_id    = nil,
        guide_ix    = nil,
        guide_asked = false,
        guide_esc   = 0,
        guide_seen  = false,
        pending     = nil,
        esc_frames  = 0,
    };
end

-- pump_guide, with the reads it makes of the game replaced by w.
local function pump_guide(ui, w, now)
    local poll = now - ui.bag_at >= NEAR_POLL;
    if (poll or ui.guide == 'wait') then
        ui.bag_at = now;
        ui.has_warp, ui.bag_full = w.has_warp, w.bag_full;
    end
    if (poll) then
        ui.guide_id, ui.guide_ix = nil, nil;
        if (not (ui.has_warp or ui.bag_full)) then
            ui.guide_id, ui.guide_ix = w.guide, 0x705;
        end
    end

    if (ui.guide == 'exit') then
        local talking = w.in_event;
        ui.guide_seen = ui.guide_seen or talking;

        if (ui.guide_seen and not talking) then
            ui.guide = nil;
            return;
        end

        if (now - ui.guide_at > GUIDE_EXIT) then
            if (ui.guide_esc == 0) then
                w.presses, w.esc_at = w.presses + 1, now;
            end
            ui.guide = nil;
            return;
        end

        if (talking and ui.esc_frames == 0 and now - w.esc_at > ESCAPE_RETRY) then
            w.presses, w.esc_at = w.presses + 1, now;
            ui.guide_esc = ui.guide_esc + 1;
        end
        return;
    end

    if (ui.guide == 'wait') then
        if (ui.has_warp) then
            ui.guide, ui.guide_at = 'exit', now;
            ui.guide_esc, ui.guide_seen = 0, false;
        elseif (now - ui.guide_at > GUIDE_WAIT) then
            ui.guide = nil;
        end
        return;
    end

    if (ui.guide_id == nil) then
        ui.guide_asked = false;
        return;
    end
    if (ui.guide_asked) then
        return;
    end
    if (ui.pending ~= nil or ui.esc_frames > 0 or w.in_event) then
        return;
    end

    w.pokes = w.pokes + 1;
    ui.guide, ui.guide_at, ui.guide_asked = 'wait', now, true;
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
local function run(ui, w, t0, frames)
    for i = 0, frames - 1 do
        pump_guide(ui, w, t0 + i / 30);
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
    local ui, w = ui_new(), world();
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
        pump_guide(ui, w, now);
        if (w.pokes > poked and opts.reply ~= nil) then
            scroll_at = now + opts.reply;
            talk_at   = now + opts.reply + (opts.skew or 0);
        end
        if (w.presses > pressed and opts.close ~= nil and w.in_event) then
            close_at = now + opts.close;
        end
    end
    return w, ui;
end

-- The real shape of it, on the timings measured in game: ask, the scroll lands
-- two seconds later, the talk half a second after that, one Escape closes it.
local w, ui = errand({ reply = REPLY, skew = TALK_SKEW, close = 0.2 });
check('real ask',    w.pokes, 1);
check('real press',  w.presses, 1);
check('real seen',   ui.guide_seen, true);
check('real done',   ui.guide, nil);

-- The same errand with the talk already up when the scroll lands: still one
-- press, so waiting for the talk has not cost the case that never needed it.
local w = errand({ reply = REPLY, skew = 0, close = 0.2 });
check('no skew press', w.presses, 1);

-- The window has to outlast the skew with room over, and the wait the reply.
check('exit outlasts skew',  GUIDE_EXIT > TALK_SKEW * 2, true);
check('wait outlasts reply', GUIDE_WAIT > REPLY * 2, true);

-- A guide that hands the scroll over without its talk ever registering as an
-- event: one press still goes out on the way past, and the errand ends rather
-- than hanging on a talk the client never admits to.
local u, x = ui_new(), world();
x.guide = GUIDE_A;
local t = run(u, x, 100, 2);
x.has_warp = true;
t = run(u, x, t, 30 * 5);
check('no talk press', x.presses, 1);
check('no talk done',  u.guide, nil);

-- A talk that will not close is pressed at ESCAPE_RETRY across the window and
-- then given up on, rather than pressed forever.
local w, ui = errand({ reply = REPLY, skew = TALK_SKEW, close = nil, secs = 12 });
between('stuck talk presses', w.presses, 3, 7);
check('stuck talk done', ui.guide, nil);

-- Standing at a guide with an empty slot and no scroll: asked once, and once
-- only however many frames go by.
local ui, w = ui_new(), world();
w.guide = GUIDE_A;
run(ui, w, 100, 60);
check('ask', w.pokes, 1);
check('ask state', ui.guide, 'wait');

-- The three reasons not to ask, each on its own.
for _, case in ipairs({
    { 'carrying', function (x) x.has_warp = true end },
    { 'full',     function (x) x.bag_full = true end },
    { 'talking',  function (x) x.in_event = true end },
}) do
    local u, x = ui_new(), world();
    x.guide = GUIDE_A;
    case[2](x);
    run(u, x, 100, 60);
    check('no ask ' .. case[1], x.pokes, 0);
    check('no ask ' .. case[1] .. ' idle', u.guide, nil);
end

-- No guide in reach is the same nothing, whatever the bag says.
local u, x = ui_new(), world();
run(u, x, 100, 60);
check('no guide', x.pokes, 0);

-- A warp command already waiting on a menu, and an Escape already held, each
-- hold the ask off rather than landing in the middle of it.  Held, not spent:
-- the line-up is still armed when the gate clears.
for _, case in ipairs({
    { 'pending',  function (u) u.pending = '/gtp Bastok' end,
                  function (u) u.pending = nil end },
    { 'escaping', function (u) u.esc_frames = 3 end,
                  function (u) u.esc_frames = 0 end },
}) do
    local u, x = ui_new(), world();
    x.guide = GUIDE_A;
    case[2](u);
    local t = run(u, x, 100, 60);
    check('no ask ' .. case[1], x.pokes, 0);
    case[3](u);
    run(u, x, t, 30);
    check('ask after ' .. case[1], x.pokes, 1);
end

-- An Escape already held by the map is not spent as this errand's press: the
-- errand waits for the key to come back up rather than counting one that never
-- went out.
local ui, w = ui_new(), world();
w.guide = GUIDE_A;
local t = run(ui, w, 100, 2);
w.has_warp, w.in_event, ui.esc_frames = true, true, 3;
t = run(ui, w, t, 10);
check('held escape presses none', w.presses, 0);
check('held escape still exiting', ui.guide, 'exit');
ui.esc_frames = 0;
t = run(ui, w, t, 10);
check('held escape presses after', w.presses, 1);

-- Escape repeats no faster than ESCAPE_RETRY while a talk is still up.
local ui, w = ui_new(), world();
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
check('done', ui.guide, nil);

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

-- A guide that answers with nothing at all: the wait runs out, and the ask is
-- not repeated for as long as the player stands there.
local ui, w = ui_new(), world();
w.guide = GUIDE_A;
local t = run(ui, w, 100, 2);
check('first ask', w.pokes, 1);
t = run(ui, w, t, 30 * 6);       -- past GUIDE_WAIT
check('gave up', ui.guide, nil);
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
local ui, w = ui_new(), world();
w.guide = GUIDE_A;
local t = run(ui, w, 100, 2);
w.guide = GUIDE_B;
t = run(ui, w, t, 30 * 2);
check('one at a time', w.pokes, 1);

-- A fresh run asks on the first walk-up rather than sitting out a wait that
-- os.clock() starting near zero would otherwise put it inside.
local ui, w = ui_new(), world();
w.guide = GUIDE_A;
run(ui, w, 0.05, 60);
check('cold start asks', w.pokes, 1);

if (fails == 0) then
    print('test_guide: ok');
else
    os.exit(1);
end
