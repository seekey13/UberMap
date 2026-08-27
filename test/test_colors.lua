--[[
* Self-check for the colour pickers.  Run with any Lua 5.1+ / LuaJIT:
*     lua test/test_colors.lua
*
* pack_col lives in ubermap.lua, which cannot be loaded outside Ashita, so the
* function's own source is sliced out of the file and run: the check reads the
* real code rather than a copy of it that would pass whatever the map does.
--]]

local src = assert(io.open('ubermap.lua')):read('*a');

local function slice(name)
    local head = ('local function %s%%b()'):format(name);
    local i, j = src:find(head);
    assert(i, name .. ' not found in ubermap.lua');
    -- Functions in this file are written flush to the left margin, so the first
    -- 'end' at column zero after the header closes it.
    local _, stop = src:find('\nend\n', j, true);
    assert(stop, name .. ' has no closing end');
    return src:sub(i, stop);
end

local pack_col = assert(loadstring or load)(
    slice('pack_col') .. '\nreturn pack_col;')();

-- The word the picker's defaults have to land on, read out of the file so a
-- default and the constant it stands for cannot drift apart unnoticed.
local function const(name)
    local hex = src:match('local ' .. name .. '%s*=%s*(0x%x+)');
    assert(hex, name .. ' not found in ubermap.lua');
    return tonumber(hex);
end

local function default(name)
    local body = src:match('    ' .. name .. '%s*=%s*T{([^}]*)}');
    assert(body, name .. ' default not found in ubermap.lua');
    local c = {};
    for v in body:gmatch('[%d%.]+') do
        c[#c + 1] = tonumber(v);
    end
    assert(#c == 4, name .. ' is not four floats');
    return c;
end

local DIM = tonumber(src:match('local DIM_ALPHA%s*=%s*([%d%.]+)'));
assert(DIM, 'DIM_ALPHA not found in ubermap.lua');

-- ImGui packs ABGR, so the channels have to come back out in that order.
assert(pack_col({ 1.0, 0.0, 0.0, 1.0 }) == 0xFF0000FF, 'red is the low byte');
assert(pack_col({ 0.0, 0.0, 1.0, 1.0 }) == 0xFFFF0000, 'blue is the high colour byte');

-- Out-of-range floats clamp rather than wrapping into another channel.
assert(pack_col({ 2.0, -1.0, 0.0, 1.0 }) == 0xFF0000FF, 'channels clamp to 0..1');

-- Every picker default packs to the constant it replaced, so a file that has
-- never been near a picker draws exactly what the map always did.
local pairs_ = {
    { 'col_text',    'COL_TEXT',  'COL_TEXT_DIM'  },
    { 'col_outline', 'COL_STAMP', 'COL_STAMP_DIM' },
    { 'col_bg',      'COL_BG',    'COL_BG_DIM'    },
    { 'col_hover',   'COL_HOVER', nil             },
};
for _, p in ipairs(pairs_) do
    local c = default(p[1]);
    assert(pack_col(c) == const(p[2]),
           ('%s does not pack to %s'):format(p[1], p[2]));
    if (p[3] ~= nil) then
        assert(pack_col(c, DIM) == const(p[3]),
               ('%s at DIM_ALPHA does not pack to %s'):format(p[1], p[3]));
    end
end

-- The dim pair only fades the alpha: the colour underneath is the same.
local stamp = default('col_outline');
assert(pack_col(stamp, DIM) % 0x1000000 == pack_col(stamp) % 0x1000000,
       'dimming changed more than the alpha');

-- The plate behind the text starts fully transparent, and outlined_text skips
-- drawing it - and the CalcTextSize that sizes it - on exactly that: an alpha
-- byte of zero, i.e. a packed word below 0x1000000.  Both halves are checked
-- here, since a default that crept above zero would put a black box behind
-- every label on the map and a per-label text measure into every frame.
assert(pack_col(default('col_bg')) < 0x1000000, 'the plate default is not transparent');
assert(src:find('if (bg >= 0x1000000) then', 1, true),
       'outlined_text no longer skips a fully transparent plate');

-- The settings file is hand-editable, which is the one place a colour row of
-- the wrong shape can come from.  pack_col would throw on a three-float row
-- during login, from inside the settings callback, so fill_defaults checks the
-- shape rather than only the nil.
assert(src:find("type(c[4]) == 'number'", 1, true),
       'fill_defaults no longer checks the shape of a saved colour row');

-- The two popup words no picker owns.  They are written as packed hex with
-- their float form in the comment beside them, so the check is that packing the
-- one lands on the other: a swapped pair of channels is otherwise only visible
-- in the game, and light red and light green differ by two bytes.
local FIXED = {
    { 'COL_POPUP_FAV',  { 0.7, 1.0, 0.7, 1.0 } },
    { 'COL_POPUP_LOCK', { 1.0, 0.7, 0.7, 1.0 } },
};
for _, p in ipairs(FIXED) do
    assert(pack_col(p[2]) == const(p[1]),
           ('%s is not the colour its comment names'):format(p[1]));
end

print(('ok: %d picker defaults and %d fixed words pack to their constants')
      :format(#pairs_, #FIXED));
