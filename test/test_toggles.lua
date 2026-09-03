--[[
* Self-check for the layer toggles.  Dimming a toggle drops its rows from a
* zone's popup and, once anything is dimmed, fades back the markers left with no
* row at all -- so filtering down to Home Points leaves only the zones that have
* one lit.  Mirrors warp_lit/warps_filtered/warps_lit/icon_dim in ubermap.lua
* against the real data.  Run with any Lua 5.1+:
*     lua test/test_toggles.lua
--]]

local WARP_ICON = { home = 'Crystal.png', guide = 'Guide.png', unity = 'Unity.png',
                    abyssea = 'Maw.png' };

local WARPS  = assert(loadfile('lib/warps.lua'))();
local POINTS = assert(loadfile('lib/points.lua'))();

local toggle = {};  -- stands in for cfg.toggle: file name -> true when dimmed

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

-- Counts the markers whose zone carries a row of one type, checking as it goes
-- that those are exactly the ones the filter leaves lit.
local function only(kind)
    local n = 0;
    for _, ic in ipairs(POINTS.points) do
        local has = false;
        for _, w in ipairs(WARPS[ic.label] or {}) do
            has = has or w.type == kind;
        end
        assert(point_lit(ic.label) == has,
               ('%s: lit %s with a %s row %s'):format(
                   ic.label, tostring(point_lit(ic.label)), kind, tostring(has)));
        n = n + (has and 1 or 0);
    end
    return n;
end

-- Abyssea warps only: the five cities whose teleporter offers them, and only
-- those -- which is also what catches a zone key that names no marker.
toggle['Crystal.png'], toggle['Guide.png'], toggle['Unity.png'] = true, true, true;
assert(warps_filtered(), 'a dimmed warp toggle must read as filtered');
assert(only('abyssea') == 5, 'five cities must offer the Abyssea warp');
toggle['Crystal.png'], toggle['Guide.png'], toggle['Unity.png'] = nil, nil, nil;

-- Home Points only: every marker left lit has one, and every zone with one is
-- left lit.
toggle['Guide.png'], toggle['Unity.png'], toggle['Maw.png'] = true, true, true;
local homes = only('home');
assert(homes > 0 and homes < total, 'the Home Point filter must cut something');
print(('Home Points only: %d of %d markers lit'):format(homes, total));

-- Every toggle dimmed: no row survives anywhere, so no zone marker stays lit.
toggle['Crystal.png'] = true;
assert(lit() == 0, 'dimming every toggle must fade back every zone marker');

-- ...and lighting them all again puts the map back.
toggle['Crystal.png'], toggle['Guide.png'] = nil, nil;
toggle['Unity.png'],   toggle['Maw.png']   = nil, nil;
assert(lit() == total, 'relighting every toggle must restore the map');

print(('ok: %d zone markers, %d warp zones'):format(total, (function()
    local n = 0;
    for _ in pairs(WARPS) do n = n + 1; end
    return n;
end)()));

--[[
* Group markers answer for the zones they stand for.  Mirrors group_warps_lit
* in ubermap.lua: an overview marker is lit while any point carrying its label
* as a group, on the same map, still has a row; a marker no point carries the
* group of stays lit, having nothing to say.
--]]
local ICONS, OVERVIEW = {}, {};
for _, g in ipairs(POINTS.groups) do
    OVERVIEW[g.name] = true;
    for _, ic in ipairs(g.icons) do
        ic.group = g.name;
        table.insert(ICONS, ic);
    end
end
for _, ic in ipairs(POINTS.points) do
    table.insert(ICONS, ic);
end

local time = 'present';

local function group_warps_lit(name)
    local any = false;
    for _, ic in ipairs(ICONS) do
        if (ic.group == name and ic.time == time) then
            if (warps_lit(ic.label)) then
                return true;
            end
            any = true;
        end
    end
    return not any;
end

-- The overview markers on the map being checked, in draw order.
local overview = {};
for _, ic in ipairs(ICONS) do
    if (OVERVIEW[ic.group] and ic.time == time) then
        table.insert(overview, ic);
    end
end
assert(#overview > 0, 'the present map must carry overview markers');

-- The half of icon_dim the toggles decide, for a group marker: an unfiltered
-- map never dims, whatever the zones below hold.
local function group_lit(name)
    return not (warps_filtered() and not group_warps_lit(name));
end

-- Nothing dimmed: every group marker is lit, childless ones and ones whose
-- zones carry no warp at all included.
for _, ic in ipairs(overview) do
    assert(group_lit(ic.label),
           ('%s: an unfiltered map must leave every group marker lit'):format(ic.label));
end

-- Home Points only: a group marker is lit exactly when one of its zones has a
-- Home Point, or when no zone carries it at all.
toggle['Guide.png'], toggle['Unity.png'], toggle['Maw.png'] = true, true, true;
local dimmed = 0;
for _, ic in ipairs(overview) do
    local has, any = false, false;
    for _, p in ipairs(ICONS) do
        if (p.group == ic.label and p.time == time) then
            any = true;
            for _, w in ipairs(WARPS[p.label] or {}) do
                has = has or w.type == 'home';
            end
        end
    end
    local want = has or not any;
    assert(group_warps_lit(ic.label) == want,
           ('%s: lit %s with a Home Point below %s'):format(
               ic.label, tostring(group_warps_lit(ic.label)), tostring(want)));
    dimmed = dimmed + (want and 0 or 1);
end
assert(dimmed > 0, 'the Home Point filter must fade back some group marker');
print(('Home Points only: %d of %d group markers faded back'):format(dimmed, #overview));

-- Every toggle dimmed: only the childless markers are left lit.
toggle['Crystal.png'] = true;
for _, ic in ipairs(overview) do
    local any = false;
    for _, p in ipairs(ICONS) do
        any = any or (p.group == ic.label and p.time == time);
    end
    assert(group_warps_lit(ic.label) == (not any),
           ('%s: dimming every toggle must fade back a group with zones'):format(ic.label));
end
toggle['Crystal.png'], toggle['Guide.png'] = nil, nil;
toggle['Unity.png'],   toggle['Maw.png']   = nil, nil;

print(('ok: %d group markers on the %s map'):format(#overview, time));
