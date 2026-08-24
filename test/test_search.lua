--[[
* Self-check for the search box.  Typing fades back every marker whose label
* does not match, and a group marker answers for the zones it stands for so the
* overview still points at a zone searched for from zoomed out.  Mirrors
* search_hit in ubermap.lua against the real data.  Run with any Lua 5.1+:
*     lua test/test_search.lua
--]]

local POINTS = assert(loadfile('lib/points.lua'))();
local fz     = assert(loadfile('lib/fuzzy.lua'))();

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

local time   = 'present';
local search = { '' };

-- Mirrors search_hit in ubermap.lua: spelling is forgiven only once nothing on
-- the map answers the query as typed.
local function fuzzy_on(q)
    for _, ic in ipairs(ICONS) do
        if ((ic.label or ''):lower():find(q, 1, true) ~= nil) then
            return false;
        end
    end
    return true;
end

local function search_hit(ic)
    local q = search[1]:lower();
    if (q == '') then
        return true;
    end
    local fuzzy = fuzzy_on(q);
    if (fz.match(q, (ic.label or ''):lower(), fuzzy)) then
        return true;
    end
    if (OVERVIEW[ic.group]) then
        for _, p in ipairs(ICONS) do
            if (p.group == ic.label and p.time == time
                and fz.match(q, (p.label or ''):lower(), fuzzy)) then
                return true;
            end
        end
    end
    return false;
end

local function lit()
    local n = 0;
    for _, ic in ipairs(ICONS) do
        if (search_hit(ic)) then
            n = n + 1;
        end
    end
    return n;
end

local total = #ICONS;
assert(total > 0, 'lib/points.lua must carry markers to search');

-- An empty box matches everything, so the map is untouched until something is
-- typed.
assert(lit() == total, 'an empty search must leave every marker lit');

-- A zone point to search for, and the group marker standing for it.
local zone;
for _, ic in ipairs(POINTS.points) do
    if (ic.time == time and ic.label ~= nil and ic.group ~= nil) then
        zone = ic;
        break;
    end
end
assert(zone ~= nil, 'the present map must carry a zone point with a group');

local marker;
for _, ic in ipairs(ICONS) do
    if (OVERVIEW[ic.group] and ic.label == zone.group) then
        marker = ic;
        break;
    end
end
assert(marker ~= nil, ('no overview marker labelled %q'):format(zone.group));

-- The zone itself is lit, and so is the region holding it: the overview is all
-- that is drawn zoomed out, so the region has to stay clickable.
search[1] = zone.label;
assert(search_hit(zone), ('%s: its own name must light it'):format(zone.label));
assert(search_hit(marker),
       ('%s: must stay lit for a zone below it'):format(marker.label));
assert(lit() < total, ('%s: a search must fade something back'):format(zone.label));

-- Case is ignored, both ways round.
search[1] = zone.label:upper();
assert(search_hit(zone), 'an upper-case search must still match');
search[1] = zone.label:lower();
assert(search_hit(zone), 'a lower-case search must still match');

-- A substring matches, not just the whole label.
search[1] = zone.label:sub(1, math.max(#zone.label - 1, 1));
assert(search_hit(zone), 'a substring of the label must match');

-- The text is taken literally, so Lua pattern characters search for themselves
-- rather than blowing up or matching everything.  '[S]' is how the Campaign
-- zones are spelled, and as a pattern it would match a bare 'S'.
search[1] = '[S]';
local campaign = 0;
for _, ic in ipairs(POINTS.points) do
    if ((ic.label or ''):find('[S]', 1, true) ~= nil) then
        campaign = campaign + 1;
    end
end
if (campaign > 0) then
    local hits = 0;
    for _, ic in ipairs(POINTS.points) do
        if (search_hit(ic)) then
            hits = hits + 1;
        end
    end
    assert(hits == campaign,
           ('[S]: %d zone points lit for %d spelled that way'):format(hits, campaign));
    print(('literal search: [S] lit %d zone points'):format(campaign));
end

--[[
* Fuzzy matching, against lib/fuzzy.lua on its own first.  The distance is to
* the closest run of the label rather than to the whole of it, so a query is
* free to name the middle of a long label.
--]]
assert(fz.distance('ronfar', 'east ronfaure') == 1,
       'a query is measured against the closest run of the label');
assert(fz.distance('', 'east ronfaure') == 0, 'an empty query is no edits away');
assert(fz.distance('east', 'east') == 0, 'an exact label is no edits away');

-- Two letters the wrong way round are one edit, not two, or the commonest typo
-- of all would need the whole of a short query's slack twice over.
assert(fz.distance('jueno', 'port jeuno') == 1, 'a transposition is one edit');
assert(fz.match('jueno', 'port jeuno', true), 'a transposition must match');
assert(fz.match('batsok', 'bastok mines', true), 'a transposition must match');

-- A four-letter query is forgiven too, since nothing on the map is spelled
-- that way: "juno" is one edit from Jeuno and has to reach it.
assert(fz.match('juno', 'port jeuno', true), 'a four-letter query must be forgiven');
search[1] = 'juno';
local juno = 0;
for _, ic in ipairs(ICONS) do
    if ((ic.label or ''):find('Jeuno', 1, true) ~= nil) then
        assert(search_hit(ic), ('juno: must light %s'):format(ic.label));
        juno = juno + 1;
    end
end
assert(juno > 0, 'the present map must carry a Jeuno marker');
assert(lit() < total, 'juno: a misspelling must still fade something back');
print(('fuzzy search: %q lit %d Jeuno markers'):format('juno', juno));

-- But a query that names something real is taken at its word, or "norg" would
-- drag in every Nor- zone one edit away from Norg.
local norg;
for _, ic in ipairs(ICONS) do
    if (ic.label == 'Norg') then
        norg = ic;
        break;
    end
end
if (norg ~= nil) then
    search[1] = 'Norg';
    assert(search_hit(norg), 'norg: must light Norg');
    for _, ic in ipairs(ICONS) do
        if (ic.label ~= nil and ic.label ~= 'Norg' and not OVERVIEW[ic.group]) then
            assert(not search_hit(ic),
                   ('norg: an exact name must not drag in %s'):format(ic.label));
        end
    end
    print('exact search: "Norg" lit Norg alone');
end

-- Three letters and under get no slack: at that length one edit reaches most
-- of the map, and typing is meant to narrow it.
assert(fz.tolerance('abc') == 0, 'three letters must match exactly');
assert(fz.tolerance('abcd') == 1, 'four letters get one edit');
assert(fz.tolerance('abcdef') == 1, 'six letters get one edit');
assert(fz.tolerance('abcdefg') == 2, 'seven letters get two edits');
assert(fz.tolerance(('a'):rep(40)) == 2, 'two edits is the cap however long');

assert(fz.match('win', 'windurst woods', true), 'a short query still matches as a substring');
assert(not fz.match('wnd', 'windurst woods', true), 'a short query gets no slack');
assert(fz.match('windhurst', 'windurst woods', true), 'a letter too many must still match');
assert(fz.match('windrst', 'windurst woods', true), 'a letter missed out must still match');
assert(fz.match('wnidurst', 'windurst woods', true), 'two letters swapped must still match');
assert(not fz.match('sandoria', 'windurst woods', true), 'a different name must not match');

-- With fuzzy off nothing is forgiven, however long the query.
assert(fz.match('windurst', 'windurst woods', false), 'an exact run matches with fuzzy off');
assert(not fz.match('windhurst', 'windurst woods', false), 'fuzzy off forgives nothing');

-- And through the search box: a misspelling lands on the zone it meant, and on
-- the region above it, exactly as the correct spelling does.
local typo = zone.label:gsub('^(...)(.)', '%1x', 1);
if (#zone.label >= 4 and typo ~= zone.label) then
    search[1] = typo;
    assert(search_hit(zone), ('%q: a misspelling must still light %s'):format(typo, zone.label));
    assert(search_hit(marker),
           ('%q: a misspelling must still light %s'):format(typo, marker.label));
    assert(lit() < total, ('%q: a misspelling must still fade something back'):format(typo));
    print(('fuzzy search: %q lit %s'):format(typo, zone.label));
end

-- A search nothing answers fades the whole map back rather than leaving it lit.
search[1] = 'zzz no such place zzz';
assert(lit() == 0, 'a search nothing matches must fade every marker back');

search[1] = '';
assert(lit() == total, 'clearing the search must restore the map');

--[[
* Framing a search.  Mirrors zoom_to_points/zoom_to_box in ubermap.lua: the
* matching zone points give a bounding box, which is centred at the zoom that
* fits it with ZOOM_PAD of margin, floored at ZOOM_POINTS and capped at
* MAX_ZOOM.  Overview markers are left out of the box.
--]]
local mm = assert(loadfile('lib/mapmath.lua'))();

local MAP_W, MAP_H   = 5504, 3072;   -- TIMES.present in ubermap.lua
local ZOOM_POINTS    = 1.0;
local MAX_ZOOM       = 2.0;
local ZOOM_PAD       = 100;
local VIEW_W, VIEW_H = 1920, 1080;

-- Mirrors zoom_to_search: a forgiven spelling frames only the group holding
-- the most of its matches, so one unrelated zone across the world cannot pull
-- the box out to cover everything.  An exact query frames all of its matches.
local function best_group()
    if (not fuzzy_on(search[1]:lower())) then
        return nil;
    end
    local n, best = { }, nil;
    for _, ic in ipairs(ICONS) do
        if (ic.time == time and not OVERVIEW[ic.group] and search_hit(ic)) then
            n[ic.group] = (n[ic.group] or 0) + 1;
            if (best == nil or n[ic.group] > n[best]) then
                best = ic.group;
            end
        end
    end
    return best;
end

local function search_box()
    local x0, y0, x1, y1;
    local best = best_group();
    for _, ic in ipairs(ICONS) do
        if (ic.time == time and not OVERVIEW[ic.group] and search_hit(ic)
            and (best == nil or ic.group == best)) then
            x0 = math.min(x0 or ic.x, ic.x);
            y0 = math.min(y0 or ic.y, ic.y);
            x1 = math.max(x1 or ic.x, ic.x);
            y1 = math.max(y1 or ic.y, ic.y);
        end
    end
    return x0, y0, x1, y1;
end

-- Returns the zoom and pan the box would be framed at, or nil when the search
-- matched no zone point on this map -- which leaves the view alone.
local function frame_search()
    local x0, y0, x1, y1 = search_box();
    if (x0 == nil) then
        return nil;
    end
    local floor_z = math.max(ZOOM_POINTS, mm.cover_zoom(MAP_W, MAP_H, VIEW_W, VIEW_H));
    local fit = mm.fit_zoom(x1 - x0 + ZOOM_PAD * 2, y1 - y0 + ZOOM_PAD * 2,
                            VIEW_W, VIEW_H);
    local zoom = mm.clamp(fit, floor_z, MAX_ZOOM);
    return zoom,
           (x0 + x1) / 2 * zoom - VIEW_W / 2,
           (y0 + y1) / 2 * zoom - VIEW_H / 2,
           fit, floor_z, x0, y0, x1, y1;
end

local function near(a, b)
    return math.abs(a - b) < 1e-6;
end

-- A search nothing matches frames nothing, so the view is left where it was.
search[1] = 'zzz no such place zzz';
assert(frame_search() == nil, 'a search with no match must leave the view alone');

-- A group name matches every zone under it, so this frames more than one point.
search[1] = zone.group;
local zoom, pan_x, pan_y, fit, floor_z, x0, y0, x1, y1 = frame_search();
assert(zoom ~= nil, ('%s: its own zones must frame'):format(zone.group));
assert(x1 > x0 or y1 > y0, ('%s: must frame more than one point'):format(zone.group));

-- The box lands in the middle of the viewport, whatever the zoom clamped to.
assert(near(mm.to_screen((x0 + x1) / 2, pan_x, zoom, 0), VIEW_W / 2),
       'the framed box must be centred across the viewport');
assert(near(mm.to_screen((y0 + y1) / 2, pan_y, zoom, 0), VIEW_H / 2),
       'the framed box must be centred down the viewport');

-- Never below the zoom the zone points are drawn at, or there would be nothing
-- on screen to have framed.
assert(zoom >= ZOOM_POINTS and zoom <= MAX_ZOOM,
       ('%s: framed at %g, outside [%g, %g]'):format(zone.group, zoom, ZOOM_POINTS, MAX_ZOOM));

-- The zone points are dense enough that a real search almost always fits
-- tighter than MAX_ZOOM and takes the cap, so the on-screen half of the framing
-- is checked on a span built to land between the floor and the cap.
local function frame_box(x0, y0, x1, y1)
    local floor_z = math.max(ZOOM_POINTS, mm.cover_zoom(MAP_W, MAP_H, VIEW_W, VIEW_H));
    local fit = mm.fit_zoom(x1 - x0 + ZOOM_PAD * 2, y1 - y0 + ZOOM_PAD * 2,
                            VIEW_W, VIEW_H);
    local z = mm.clamp(fit, floor_z, MAX_ZOOM);
    return z, (x0 + x1) / 2 * z - VIEW_W / 2, (y0 + y1) / 2 * z - VIEW_H / 2, fit;
end

do
    local bx0, by0, bx1, by1 = 1000, 900, 2400, 1600;   -- 1400 x 700 map pixels
    local z, px, py, fit = frame_box(bx0, by0, bx1, by1);
    assert(z > ZOOM_POINTS and z < MAX_ZOOM and z == fit,
           ('a %dx%d span must frame at its own fit, got %g'):format(
               bx1 - bx0, by1 - by0, z));
    -- Both corners on screen, and the margin really is ZOOM_PAD map pixels.
    for _, corner in ipairs({ { bx0, by0 }, { bx1, by1 } }) do
        local sx = mm.to_screen(corner[1], px, z, 0);
        local sy = mm.to_screen(corner[2], py, z, 0);
        assert(sx >= 0 and sx <= VIEW_W and sy >= 0 and sy <= VIEW_H,
               ('corner framed off screen at %d, %d'):format(sx, sy));
    end
    local pad_x = mm.to_screen(bx0, px, z, 0);
    assert(pad_x >= ZOOM_PAD * z - 1e-6,
           ('the framed box must keep its margin, got %g'):format(pad_x));
    print(('framed a 1400x700 span at zoom %.3f, %.0fpx of margin'):format(z, pad_x));
end

--[[
* A forgiven spelling frames what it meant, not what it happened to brush past.
* "juno" is a letter off "jung" as well as off "jeuno", so it lights two
* Elshimo jungles along with the three Jeuno zones -- and framing all five
* would span the world and zoom out rather than in.
--]]
do
    search[1] = 'juno';
    local groups, lit_zones = { }, 0;
    for _, ic in ipairs(ICONS) do
        if (ic.time == time and not OVERVIEW[ic.group] and search_hit(ic)) then
            groups[ic.group] = (groups[ic.group] or 0) + 1;
            lit_zones = lit_zones + 1;
        end
    end
    if (groups['Jeuno'] ~= nil) then
        assert(lit_zones > groups['Jeuno'],
               'juno: this check wants the stray jungle matches to be there');
        assert(best_group() == 'Jeuno',
               ('juno: framed %s rather than Jeuno'):format(tostring(best_group())));

        -- Every match stays lit; only the framing narrows.
        for _, ic in ipairs(ICONS) do
            if ((ic.label or ''):find('Jeuno', 1, true) ~= nil) then
                assert(search_hit(ic), ('juno: must light %s'):format(ic.label));
            end
        end

        -- And the box really is Jeuno's, so the view closes in instead of out.
        local x0, y0, x1, y1 = search_box();
        assert(x0 ~= nil, 'juno: must frame something');
        for _, ic in ipairs(ICONS) do
            if (ic.time == time and ic.group == 'Jeuno' and search_hit(ic)) then
                assert(ic.x >= x0 and ic.x <= x1 and ic.y >= y0 and ic.y <= y1,
                       ('juno: %s fell outside the framed box'):format(ic.label));
            end
        end
        local z = frame_search();
        assert(z > ZOOM_POINTS,
               ('juno: framed at %g, which is zoomed out rather than in'):format(z));
        print(('fuzzy framing: %q lit %d zones, framed Jeuno at zoom %.3f'):format(
            'juno', lit_zones, z));
    end
end

-- Nothing a real search frames is allowed outside the zoom range, however far
-- apart or close together the matches are.
for _, q in ipairs({ zone.group, zone.label, 'Ronfaure', 'a', 'e' }) do
    search[1] = q;
    local z = frame_search();
    if (z ~= nil) then
        assert(z >= ZOOM_POINTS and z <= MAX_ZOOM,
               ('%s: framed at %g, outside [%g, %g]'):format(q, z, ZOOM_POINTS, MAX_ZOOM));
    end
end

-- One point is a box of nothing, which fits at any zoom, so it takes the cap
-- rather than running away.
search[1] = zone.label;
local one = 0;
for _, ic in ipairs(ICONS) do
    if (ic.time == time and not OVERVIEW[ic.group] and search_hit(ic)) then
        one = one + 1;
    end
end
if (one == 1) then
    local z = frame_search();
    assert(near(z, MAX_ZOOM),
           ('%s: a lone match must frame at MAX_ZOOM, got %g'):format(zone.label, z));
    print(('framed %q: lone match at zoom %.3f'):format(zone.label, z));
end

search[1] = '';

print(('ok: %d markers searched, %q lit %d of them'):format(
    total, zone.label, (function()
        search[1] = zone.label;
        local n = lit();
        search[1] = '';
        return n;
    end)()));
