--[[
* Self-check for the warp rows the player cannot take.  A row travels only from
* the kind of NPC being stood at, so the panel draws every other kind dim and
* takes no press on it: the destination still reads, it just is not reachable
* from here.  Mirrors warp_reachable and the row's hover and click gates in
* ubermap.lua.  Run with any Lua 5.1+:
*     lua test/test_warpreach.lua
--]]

-- warp_reachable, with ui.near_kind passed in rather than read off the addon.
local function warp_reachable(w, near_kind)
    return w.type == near_kind;
end

local home  = { type = 'home',  label = 'Home Point #1 (H-9)' };
local guide = { type = 'guide', label = 'Survival Guide (G-9)' };

-- Stood at a Home Point: its rows are live, the other kinds are not.
assert(warp_reachable(home, 'home'), 'a Home Point row must be live at a Home Point');
assert(not warp_reachable(guide, 'home'), 'a Survival Guide row must not be live at a Home Point');

-- Stood at nothing, and before the first poll, read the same way: nothing live.
assert(not warp_reachable(home, nil), 'nothing in reach must leave every row dim');
assert(not warp_reachable(home, false), 'an unpolled map must leave every row dim');

-- The hover gate: only a live row under the cursor becomes the hot row, so a
-- dim one neither highlights nor arms the click.
local function hot(w, near_kind, over)
    return warp_reachable(w, near_kind) and over;
end
assert(hot(home, 'home', true), 'a live row under the cursor is hot');
assert(not hot(home, 'home', false), 'a row the cursor is off is not hot');
assert(not hot(guide, 'home', true), 'a dim row under the cursor stays cold');

-- The click gate: the panel sends only what the hover left as the hot row, so a
-- press on a dim row sends nothing.
local function sends(hot_row)
    return hot_row ~= nil;
end
assert(sends(hot(home, 'home', true) and home or nil), 'clicking a live row sends');
assert(not sends(hot(guide, 'home', true) and guide or nil), 'clicking a dim row sends nothing');

print('test_warpreach: ok');
