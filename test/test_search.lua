--[[
* Self-check for the search box.  Typing fades back every marker whose label
* does not match, and a group marker answers for the zones it stands for so the
* overview still points at a zone searched for from zoomed out.  Mirrors
* search_hit in ubermap.lua against the real data.  Run with any Lua 5.1+:
*     lua test/test_search.lua
--]]

local POINTS = assert(loadfile('lib/points.lua'))();

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

-- Mirrors search_hit in ubermap.lua.
local function search_hit(ic)
    local q = search[1]:lower();
    if (q == '') then
        return true;
    end
    if ((ic.label or ''):lower():find(q, 1, true) ~= nil) then
        return true;
    end
    if (OVERVIEW[ic.group]) then
        for _, p in ipairs(ICONS) do
            if (p.group == ic.label and p.time == time
                and (p.label or ''):lower():find(q, 1, true) ~= nil) then
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

-- A search nothing answers fades the whole map back rather than leaving it lit.
search[1] = 'zzz no such place zzz';
assert(lit() == 0, 'a search nothing matches must fade every marker back');

search[1] = '';
assert(lit() == total, 'clearing the search must restore the map');

print(('ok: %d markers searched, %q lit %d of them'):format(
    total, zone.label, (function()
        search[1] = zone.label;
        local n = lit();
        search[1] = '';
        return n;
    end)()));
