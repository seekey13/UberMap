--[[
* Self-check for the Size box and the face pulldown.  Run with any Lua 5.1+ /
* LuaJIT:
*     lua test/test_fonts.lua
*
* ImGui's font atlas is shared with every other addon and outlives '/addon
* reload'.  Adding to it from d3d_present mutates it while draw lists are
* pending render, which is an access violation -- and is what the map's first
* font picker did.  The picker is back, so the checks below are as much about
* where the atlas may be touched as about what the boxes take.
--]]

local src = assert(io.open('ubermap.lua')):read('*a');

-- The bounds the box clamps to, read out of the file so the check cannot drift
-- from what the code actually allows.
local function bound(name)
    local v = src:match('local FONT_PX%s*=%s*{[^}]-' .. name .. '%s*=%s*(%-?%d+)');
    assert(v, 'FONT_PX.' .. name .. ' not found in ubermap.lua');
    return tonumber(v);
end

local MIN, MAX, OWN = bound('min'), bound('max'), bound('own');

assert(MIN > 0, 'a minimum of zero would allow a map with no labels on it');
assert(MAX > MIN, 'the size bounds are the wrong way round');
-- OWN is the stand-in for "whatever ImGui's own font measures", resolved on the
-- first frame.  It has to sit outside the clamp, or a real size could collide
-- with it and be re-resolved every frame.
assert(OWN < MIN or OWN > MAX, 'the "own size" stand-in is inside the clamp');

-- The box takes a typed number as well as its step buttons, so the write back
-- to cfg has to clamp rather than trust it.
assert(src:find('math.min(math.max(ui.font_px[1], FONT_PX.min)', 1, true),
       'the Size box no longer clamps what it is given');

-- A settings file that has never been near the box carries OWN, which only a
-- frame can resolve; the resolved number is written back so the box opens
-- showing it rather than a nought.
assert(src:find('if (cfg.font_px == FONT_PX.own) then', 1, true),
       'the "own size" stand-in is no longer resolved on the first frame');

-- The atlas may only be written to from bake_all, and bake_all may only be
-- called from the load event.  A second AddFontFromFileTTF anywhere else is the
-- crash the first picker shipped with.
local adds = select(2, src:gsub('AddFontFromFileTTF', ''));
assert(adds == 1,
       ('AddFontFromFileTTF appears %d times, not 1; the atlas is shared and'
        .. ' may only be baked in FONT_PX.bake_all'):format(adds));
local _, bake_at = src:find('function FONT_PX.bake_all()', 1, true);
local add_at     = src:find('AddFontFromFileTTF', 1, true);
local _, body_end = src:find('\nend\n', bake_at, true);
assert(add_at > bake_at and add_at < body_end,
       'AddFontFromFileTTF is outside FONT_PX.bake_all');
assert(src:find("ashita.events.register('load', 'ubermap_load'", 1, true)
       and src:find('FONT_PX.bake_all();', 1, true),
       'the faces are no longer baked from the load event');

-- Every face the pulldown offers has to be baked, or picking it would fall back
-- to ImGui's own font with no way to tell why.  bake_all walks FONT_PX.list, so
-- the check is that it still does, rather than a second copy of the list here.
assert(src:find('for _, name in ipairs(FONT_PX.list) do', 1, true),
       'bake_all no longer bakes the whole list the pulldown offers');
local list = src:match('list%s*=%s*T{(.-)}');
assert(list, 'FONT_PX.list not found in ubermap.lua');
local faces = {};
for name in list:gmatch("'([^']*)'") do faces[#faces + 1] = name; end
assert(#faces >= 2, 'FONT_PX.list is empty');
assert(faces[1] == '',
       'FONT_PX.list must lead with the empty name, which is ImGui\'s own font'
       .. ' and the only way back off a picked face');
-- '' is what the settings file stores for that row, not what the row reads as:
-- an empty row looks like a gap rather than a choice.
assert(src:match("own_name%s*=%s*'([^']+)'"),
       'FONT_PX.own_name is gone; the default row would draw as a blank');
assert(src:find("(name ~= '') and name or FONT_PX.own_name", 1, true),
       'the pulldown no longer names ImGui\'s own font on its row');
-- The name goes on the end of a Windows font path, so a settings file naming
-- something the pulldown could never produce has to be rejected, not appended.
assert(src:find('if (not FONT_PX.list:contains(cfg.font or \'\')) then', 1, true),
       'cfg.font is no longer checked against the list it must come from');

-- Both helpers put the face and the scale back before they return: both are
-- context state, so one left on would take every widget on the toolbar with it.
for _, fn in ipairs({ 'text_size', 'outlined_text' }) do
    local head = ('local function %s%%b()'):format(fn);
    local i, j = src:find(head);
    assert(i, fn .. ' not found in ubermap.lua');
    local _, stop = src:find('\nend\n', j, true);
    local body = src:sub(i, stop);
    local sets = select(2, body:gsub('imgui%.SetWindowFontScale%(', ''));
    assert(sets == 2, ('%s sets the window font scale %d times, not 2'):format(fn, sets));
    assert(body:find('imgui.SetWindowFontScale(1.0);', 1, true),
           fn .. ' does not put the window font scale back');
    local pushes = select(2, body:gsub('imgui%.PushFont%(', ''));
    local pops   = select(2, body:gsub('imgui%.PopFont%(', ''));
    assert(pushes == 1 and pops == 1,
           ('%s pushes the face %d times and pops it %d; they must pair')
           :format(fn, pushes, pops));
end

-- A baked face measures FONT_PX.bake, not whatever ImGui's own font measures,
-- so the Size box would mean two different things without this.
assert(src:find('if (FONT_PX.face()) then base = FONT_PX.bake; end', 1, true),
       'the font scale no longer divides by the bake size when a face is up');

print(('ok: sizes clamp to %d..%d, %d faces bake once on load, and nothing'
       .. ' touches the atlas after that'):format(MIN, MAX, #faces - 1));
