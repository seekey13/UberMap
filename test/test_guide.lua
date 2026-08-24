--[[
* Self-check for the EXP Guide errand: the walk-past that asks a guide for an
* Instant Warp scroll and backs out of the talk it arrives in.  Mirrors
* pump_guide in ubermap.lua, driven by a fake world instead of the entity array
* and the bag.
*
* The contract these check is one ask per line-up of the three conditions - no
* scroll carried, a slot free for one, a guide in reach - and no ask at all
* while any of them is false.  Run with any Lua 5.1+:
*     lua test/test_guide.lua
--]]

local NEAR_POLL  = 0.5;
local GUIDE_WAIT = 5.0;
local ESCAPE_RETRY, ESCAPE_WAIT = 0.5, 2.0;

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
        pending     = nil,
        esc_frames  = 0,
    };
end

-- pump_guide, with the reads it makes of the game replaced by w.
local function pump_guide(ui, w, now)
    if (now - ui.bag_at >= NEAR_POLL) then
        ui.bag_at = now;
        ui.has_warp, ui.bag_full = w.has_warp, w.bag_full;
        ui.guide_id, ui.guide_ix = nil, nil;
        if (not (ui.has_warp or ui.bag_full)) then
            ui.guide_id, ui.guide_ix = w.guide, 0x705;
        end
    end

    if (ui.guide == 'exit') then
        if ((ui.guide_esc > 0 and not w.in_event)
            or now - ui.guide_at > ESCAPE_WAIT) then
            ui.guide = nil;
        elseif (ui.esc_frames == 0 and now - w.esc_at > ESCAPE_RETRY) then
            w.presses, w.esc_at = w.presses + 1, now;
            ui.guide_esc = ui.guide_esc + 1;
        end
        return;
    end

    if (ui.guide == 'wait') then
        if (ui.has_warp) then
            ui.guide, ui.guide_at, ui.guide_esc = 'exit', now, 0;
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

-- Runs the pump over a span of frames, 1/30s apart, starting at t0.
local function run(ui, w, t0, frames)
    for i = 0, frames - 1 do
        pump_guide(ui, w, t0 + i / 30);
    end
    return t0 + frames / 30;
end

local GUIDE_A, GUIDE_B = 17774597, 17782790;

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

-- The scroll arriving inside the talk moves the errand on to leaving it, and
-- Escape repeats no faster than ESCAPE_RETRY while the talk is still up.
local ui, w = ui_new(), world();
w.guide = GUIDE_A;
local t = run(ui, w, 100, 2);
check('asked', w.pokes, 1);
w.in_event, w.has_warp = true, true;
t = run(ui, w, t, 15);
check('exit', ui.guide, 'exit');
check('press once', w.presses, 1);
-- A second more: one more press, not one a frame.
t = run(ui, w, t, 30);
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

-- The defect this was written for: a guide whose talk the client never marks as
-- an event.  The scroll landing is what says there is something to leave, so the
-- first press goes out regardless, and one press is enough to end the errand.
local ui, w = ui_new(), world();
w.guide = GUIDE_A;
local t = run(ui, w, 100, 2);
w.has_warp = true;             -- scroll lands, but in_event stays false
t = run(ui, w, t, 30);
check('press without event', w.presses, 1);
check('press without event done', ui.guide, nil);

-- And it is one press, not one a frame, however long the errand is left to run.
t = run(ui, w, t, 30 * 5);
check('press without event once', w.presses, 1);

-- An Escape already held by the map is not counted as this errand's press: the
-- errand waits for the key to come back up rather than finishing on a press
-- that never went out.
local ui, w = ui_new(), world();
w.guide = GUIDE_A;
local t = run(ui, w, 100, 2);
w.has_warp, ui.esc_frames = true, 3;
t = run(ui, w, t, 15);
check('held escape presses none', w.presses, 0);
check('held escape still exiting', ui.guide, 'exit');
ui.esc_frames = 0;
t = run(ui, w, t, 15);
check('held escape presses after', w.presses, 1);

-- A talk that will not close is given up on rather than pressed forever.
local ui, w = ui_new(), world();
ui.guide, ui.guide_at, ui.guide_asked, ui.guide_esc = 'exit', 100, true, 0;
w.guide, w.in_event, w.has_warp = GUIDE_A, true, true;
run(ui, w, 100, 30 * 3);
check('exit gives up', ui.guide, nil);

-- A guide that answers with nothing: the wait runs out, and the ask is not
-- repeated for as long as the player stands there.
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
