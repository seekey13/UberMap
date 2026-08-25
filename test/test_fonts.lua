--[[
* Self-check for the Size box.  Run with any Lua 5.1+ / LuaJIT:
*     lua test/test_fonts.lua
*
* The map's text is sized with imgui.SetWindowFontScale, never by adding a face
* to ImGui's font atlas.  That atlas is shared with every other addon and
* outlives '/addon reload', so an addon that rebuilds it crashes the others --
* which is what the font picker that used to live here did, and why the checks
* below are as much about what the file must NOT contain as what it must.
--]]

local src = assert(io.open('ubermap.lua')):read('*a');

-- Nothing in the map may touch the shared atlas, at any size, on any path.
for _, banned in ipairs({ 'AddFontFromFileTTF', 'PushFont', 'PopFont' }) do
    assert(not src:find(banned, 1, true),
           banned .. ' is back in ubermap.lua; the font atlas is shared and'
                  .. ' rebuilding it takes down every other addon');
end

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

-- Both helpers put the scale back before they return: it is a window property,
-- so one left on would take every widget on the toolbar with it.
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
end

print(('ok: sizes clamp to %d..%d, and nothing touches the shared font atlas')
      :format(MIN, MAX));
