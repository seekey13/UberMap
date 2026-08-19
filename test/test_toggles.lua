--[[
* Self-check for the layer toggles.  Dimming a toggle drops its rows from a
* zone's popup and, once anything is dimmed, fades back the markers left with no
* row at all -- so filtering down to Home Points leaves only the zones that have
* one lit.  Mirrors warp_lit/warps_filtered/warps_lit/icon_dim in ubermap.lua
* against the real data.  Run with any Lua 5.1+:
*     lua test/test_toggles.lua
--]]

local WARP_ICON = { home = 'Crystal.png', guide = 'Guide.png', unity = 'Unity.png' };

local WARPS  = assert(loadfile('lib/warps.lua'))();
local POINTS = assert(loadfile('lib/points.lua'))();

local toggle = {};  -- stands in for ui.toggle: file name -> true when dimmed

local function warp_lit(w)
    local file = WARP_ICON[w.type];
    return file ~= nil and not toggle[file];
end

local function warps_filtered()
    for _, file in pairs(WARP_ICON) do
        if (toggle[file]) then
            return true;
        end
    end
    return false;
end

local function warps_lit(label)
    for _, w in ipairs(WARPS[label] or {}) do
        if (warp_lit(w)) then
            return true;
        end
    end
    return false;
end

-- The half of icon_dim the toggles decide, for a zone point.  Nothing is
-- focused here, so this is the whole of it.
local function point_lit(label)
    return not (warps_filtered() and not warps_lit(label));
end

local function lit()
    local n = 0;
    for _, ic in ipairs(POINTS.points) do
        if (point_lit(ic.label)) then
            n = n + 1;
        end
    end
    return n;
end

local total = #POINTS.points;

-- Nothing dimmed: the map is untouched, every marker still lit.
assert(not warps_filtered(), 'no toggle dimmed must not read as filtered');
assert(lit() == total, 'an unfiltered map must leave every marker lit');

-- Maw.png names no type, so dimming it filters nothing.
toggle['Maw.png'] = true;
assert(not warps_filtered(), 'Maw.png must not filter the map');
assert(lit() == total, 'dimming Maw.png must leave every marker lit');
toggle['Maw.png'] = nil;

-- Home Points only: every marker left lit has one, and every zone with one is
-- left lit.
toggle['Guide.png'], toggle['Unity.png'] = true, true;
assert(warps_filtered(), 'a dimmed warp toggle must read as filtered');
local homes = 0;
for _, ic in ipairs(POINTS.points) do
    local has = false;
    for _, w in ipairs(WARPS[ic.label] or {}) do
        has = has or w.type == 'home';
    end
    assert(point_lit(ic.label) == has,
           ('%s: lit %s with a Home Point %s'):format(
               ic.label, tostring(point_lit(ic.label)), tostring(has)));
    homes = homes + (has and 1 or 0);
end
assert(homes > 0 and homes < total, 'the Home Point filter must cut something');
print(('Home Points only: %d of %d markers lit'):format(homes, total));

-- Every toggle dimmed: no row survives anywhere, so no zone marker stays lit.
toggle['Crystal.png'] = true;
assert(lit() == 0, 'dimming every toggle must fade back every zone marker');

-- ...and lighting them all again puts the map back.
toggle['Crystal.png'], toggle['Guide.png'], toggle['Unity.png'] = nil, nil, nil;
assert(lit() == total, 'relighting every toggle must restore the map');

print(('ok: %d zone markers, %d warp zones'):format(total, (function()
    local n = 0;
    for _ in pairs(WARPS) do n = n + 1; end
    return n;
end)()));
