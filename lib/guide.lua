--[[
* The EXP Guide errand: the walk-past that asks a guide for an Instant Warp
* scroll and backs out of the talk it arrives in, without the player stopping.
*
* Out here rather than in ubermap.lua so the self-check drives the real thing.
* Everything this reads or does to the world arrives as `w`, a table of six
* calls; ubermap.lua fills them with the entity array, the bag and user32, and
* test/test_guide.lua fills them with a fake world it can wind forward by hand.
* Nothing in this file touches Ashita, so it loads under plain Lua 5.1+.
*
*   w.in_event()   -> true while the client says a talk or scene is up
*   w.bag()        -> carried, full, ok -- an Instant Warp scroll is held, every
*                     slot is taken, and whether the read worked at all
*   w.near_guide() -> server id and target index of a guide in reach, or nil
*   w.blocked()    -> true while something else owns Escape: a warp command
*                     waiting on a menu, or a press still held down
*   w.press(now)   -> press Escape; returns whether one actually went out
*   w.poke(id, ix) -> ask that guide for what it hands out
*
* `st` is the state that has to live between frames.  M.state() makes a fresh
* one; ubermap.lua keeps it on its own ui table so the rest of the addon can
* see the errand is running.
--]]

local M = {};

-- How often the world is read, in seconds.  Walking up to a guide happens on a
-- human timescale, so twice a second is plenty and the reads are not cheap.
M.NEAR_POLL = 0.5;

-- How long to wait for the scroll after asking before giving up, in seconds.  A
-- give-up rather than a retry: the ask goes out once each time the conditions
-- line up, so a guide that answers with nothing cannot strand the state and is
-- not asked again for the same walk-up either.
M.GUIDE_WAIT = 5.0;

-- How long the exit has to see the guide's talk come up and go away again, in
-- seconds.  The scroll can land a moment before the talk it came in is up, so
-- this covers the wait for it as well as the backing out afterwards.
--
-- Two seconds is three presses: the talk lands about half a second after the
-- scroll, and ESCAPE_RETRY spaces the presses after it.  A shorter window buys
-- exactly one press, which is a talk more than one level deep left sitting open.
M.GUIDE_EXIT = 2.0;

-- How long to leave between presses at a talk that has not closed yet.
M.ESCAPE_RETRY = 0.5;

function M.state()
    return {
        step     = nil,      -- nil, 'wait' for the scroll, or 'exit' the talk
        at       = 0,        -- when the current step started
        asked    = false,    -- this line-up has had its one ask
        seen     = false,    -- a talk registered as an event during the exit
        presses  = 0,        -- Escapes actually sent during the exit
        esc_at   = -M.ESCAPE_RETRY,
        bag_at   = 0,
        has_warp = false,
        bag_full = true,     -- until a read says otherwise, ask for nothing
        id       = nil,
        ix       = nil,
    };
end

--[[
* One frame of the errand.  Safe to call every frame whether the map is up or
* not: the errand has nothing to do with the map being open, and the walk that
* starts it is one the player takes on the way past.
--]]
function M.pump(st, w, now)
    -- What the errand reads of the world, twice a second rather than per frame:
    -- what the bag holds, and - only while the bag is short a scroll and has
    -- room for one - whether a guide is in reach.  That gate is what keeps the
    -- entity walk off the frames of a character already carrying one, and it
    -- leaves st.id nil for every reason not to ask rather than only for the
    -- guide being out of reach.
    local poll = now - st.bag_at >= M.NEAR_POLL;
    -- While an ask is in flight the bag is read every frame instead of twice a
    -- second.  The scroll landing is what starts the exit, so latency here is
    -- the guide's talk left open, and a bag walk for the second or two an
    -- errand lasts is cheaper than that.
    local bag_ok = true;
    if (poll or st.step == 'wait') then
        st.bag_at = now;
        local carried, full, ok = w.bag();
        bag_ok = ok;
        -- A read that failed says nothing, so it is held as carried and full:
        -- the one pair of answers that asks a guide for nothing.  The wait
        -- below reads bag_ok rather than this, because there the same pair
        -- would read as a scroll that arrived.
        st.has_warp, st.bag_full = carried, full;
    end
    -- The entity scan stays on the slower cadence whatever the errand is doing.
    if (poll) then
        st.id, st.ix = nil, nil;
        if (not (st.has_warp or st.bag_full)) then
            st.id, st.ix = w.near_guide();
        end
    end

    -- The scroll landed, so back out of the talk it came in.  Escape is only
    -- pressed while the client says there is a talk to leave: the scroll can
    -- land a moment before the talk is up, and a press into that gap is a press
    -- the client never has anything to spend on - which is exactly how this
    -- managed to fire once, land early and leave the talk sitting open.
    --
    -- So the exit watches instead: presses while in an event, and finishes once
    -- one has been seen and is gone.  Presses repeat because a talk can be more
    -- than one level deep.
    if (st.step == 'exit') then
        local talking = w.in_event();
        st.seen = st.seen or talking;

        if (st.seen and not talking) then
            st.step = nil;                  -- the talk came up and closed
            return;
        end

        if (now - st.at > M.GUIDE_EXIT) then
            -- Out of time.  If no talk ever registered as an event, one press
            -- still goes out on the way past: a server can put the scroll up in
            -- something the client does not mark, and a press into nothing
            -- costs nothing.
            if (st.presses == 0) then
                w.press(now);
            end
            st.step = nil;
            return;
        end

        if (talking and now - st.esc_at > M.ESCAPE_RETRY) then
            -- A press refused because one is still held leaves esc_at alone, so
            -- the retry comes back next frame rather than being spent here.
            if (w.press(now)) then
                st.esc_at, st.presses = now, st.presses + 1;
            end
        end
        return;
    end

    if (st.step == 'wait') then
        -- bag_ok gates the arrival: a read that failed reports carried, which
        -- would otherwise read as the scroll landing and start pressing Escape
        -- at a talk that was never opened.  Zoning is exactly when the
        -- inventory goes unreadable, and exactly when a stray press is worst.
        if (st.has_warp and bag_ok) then
            st.step, st.at = 'exit', now;
            st.presses, st.seen = 0, false;
        elseif (now - st.at > M.GUIDE_WAIT) then
            -- Out of time without a scroll.  A guide that answered with a menu
            -- rather than the item -- a slot filled since the bag was read, a
            -- server that asks before it hands over -- has left its talk on
            -- screen, and dropping the errand here would leave the player
            -- standing in an event they never opened.  The exit backs out of
            -- one that is up; a guide that answered with nothing at all has no
            -- talk to leave, and is dropped as before rather than spending a
            -- press on an empty screen.
            if (w.in_event()) then
                st.step, st.at = 'exit', now;
                st.presses, st.seen = 0, false;
            else
                st.step = nil;
            end
        end
        return;
    end

    -- No scroll, a slot free and a guide in reach is one line-up, and it gets
    -- one ask.  Any of the three going false re-arms it, so spending a scroll
    -- or walking off and back asks again, while standing at a guide that
    -- answered with nothing does not.
    if (st.id == nil) then
        st.asked = false;
        return;
    end
    if (st.asked) then
        return;
    end

    -- Already talking to something, or a warp command is waiting on a menu to
    -- close: an ask now would land in the middle of either.  Left un-asked
    -- rather than skipped, so it goes out on a later frame instead.
    if (w.blocked() or w.in_event()) then
        return;
    end

    w.poke(st.id, st.ix);
    st.step, st.at, st.asked = 'wait', now, true;
end

return M;
