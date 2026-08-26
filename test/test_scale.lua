--[[
* Self-check for the scale boxes on the config panel.  Run with any Lua
* 5.1+ / LuaJIT:
*     lua test/test_scale.lua
*
* The boxes multiply sizes the map draws every frame, so a nil or a zero reaching
* one is a map with no markers rather than a small one.  The checks below cover
* the three places a scale has to line up: its default, the clamp it goes through
* on load, and the draw that reads it.
--]]

local src = assert(io.open('ubermap.lua')):read('*a');

local body = src:match('local SCALE%s*=%s*{(.-)\n};');
assert(body, 'the SCALE table is no longer written as one block in ubermap.lua');

local function bound(name)
    local v = body:match(name .. '%s*=%s*(%-?%d+)');
    assert(v, 'SCALE.' .. name .. ' not found');
    return tonumber(v);
end

local MIN, MAX = bound('min'), bound('max');
assert(MIN > 0, 'a minimum of zero would be a marker with no pixels in it');
assert(MAX > MIN, 'the scale bounds are the wrong way round');
assert(MIN <= 100 and MAX >= 100,
       '100 is what the map has always drawn at, so it has to be reachable');

-- Every row needs a default under its key, or a settings file from before these
-- boxes existed multiplies a size by nil on the first frame.
local rows = {};
for key, label in body:gmatch("{%s*'([%w_]+)'%s*,%s*'([%w%s]-)'%s*}") do
    rows[#rows + 1] = { key = key, label = label };
end
-- Points, nations, the toolbar row, and the search box's width -- its height
-- rides the toolbar with everything else on that line.
assert(#rows == 4, ('SCALE.rows lists %d rows, not the 4 the panel offers'):format(#rows));

local defaults = src:match('local default_settings%s*=%s*T{(.-)\n};');
assert(defaults, 'default_settings is no longer written as one block');
for _, row in ipairs(rows) do
    local v = defaults:match('%f[%w]' .. row.key .. '%s*=%s*(%d+)');
    assert(v, ('%s has no entry in default_settings'):format(row.key));
    assert(tonumber(v) == 100,
           ('%s defaults to %s, not the 100 the map has always drawn at')
           :format(row.key, v));
    assert(row.label ~= '', ('%s has no name for its panel row'):format(row.key));
end

-- The clamp walks the same list, so a row added above cannot skip it.
assert(src:find('for _, row in ipairs(SCALE.rows) do', 1, true),
       'the load-time clamp no longer walks SCALE.rows');
assert(src:find('math.min(math.max(math.floor(tonumber(cfg[row[1]]) or 100),', 1, true),
       'a hand-edited or missing scale is no longer clamped on load');

-- Marker sizes go through SCALE.px, the one place the point and nation scales
-- are told apart.  A raw read left behind would draw at one size and hit test at
-- another.
assert(not src:find('or ICON_SIZE) / 2', 1, true),
       'a marker size is still read raw rather than through SCALE.px');
-- Less the definition, which the same pattern matches.
local pxs = select(2, src:gsub('SCALE%.px%(', '')) - 1;
assert(pxs == 3,
       ('SCALE.px is called %d times, not the 3 the map draws, hit tests and'
        .. ' anchors the warp popup with'):format(pxs));

-- The toolbar and the search box are sized off cfg directly, once each.  The
-- box's height rides the toolbar's scale rather than carrying one of its own.
for _, want in ipairs({ 'ROW_H_MULT %* cfg%.scale_tool / 100',
                        'SEARCH_H_MULT%s+%* cfg%.scale_tool / 100',
                        '%* cfg%.scale_searchw / 100' }) do
    assert(src:find(want), ('nothing reads ' .. want));
end

-- Scaling the search box's font is a window property, so it has to be put back
-- or the toggles sharing that row go with it.
-- Counted inside the toolbar row alone: text_size and outlined_text put the
-- scale back too, so a whole-file count would stay green with the box's own
-- restore deleted.
local row = assert(src:match('local search_h(.-)%-%- Config panel'),
                   'the toolbar row no longer runs from the search box to the'
                   .. ' config panel');
local ups   = select(2, row:gsub('SetWindowFontScale%(cfg%.scale_tool / 100%)', ''));
local downs = select(2, row:gsub('SetWindowFontScale%(1%.0%)', ''));
assert(ups == 1, 'the search box font scale is set more than once');
assert(downs == ups, 'the search box font scale is not put back');

-- The boxes are filled from cfg once, at load.  Logging in swaps cfg for that
-- character's file, so the callback has to fill them again -- or the panel shows
-- the last character's numbers and the first arrow press writes them back.
local resync = assert(src:match("'settings_update'(.-)end%);"),
                      'the settings_update callback is no longer one block');
assert(resync:find('ui.scale[row[1]][1] = cfg[row[1]];', 1, true),
       'a character switch no longer refreshes the scale boxes');

print(('ok: %d scales clamp to %d..%d, all default to 100, and the map reads'
       .. ' every one of them'):format(#rows, MIN, MAX));
