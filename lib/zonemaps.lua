--[[
* UberMap zone maps, indexed by a point's label in points.lua.
*
* A zone with an entry here, and whose art is on disk, opens into its own map
* when its point is chosen; one without either keeps the warp list on the
* world map, so zones can gain art one at a time.
*
*   id     - the game's zone id
*   span   - how many world-map pixels wide the zone map lands, centred on the
*            point: what lines the zoom in up with the world map beneath it
*   start  - which sheet a zone opens on when nothing else says, by index
*   sheets - the zone's maps, in tab order.  Each is the game's own map index
*            and, for a sheet of another zone, that zone's id: the confluxes
*            are inside an Abyssea area, so its map is a sheet of the zone the
*            maw stands in.  Only sheets a warp lands on are listed.
*
* Files are assets/zones/<zone>_<map>.png unless a sheet names its own 'file'.
* The pilot art is the Remapster pack (github.com/AkadenTK/remapster_maps),
* CC BY-SA 4.0 -- see assets/zones/NOTICE.md.  'grid' is where the 15x15 grid
* sits on the art, as fractions of the image, and only needs setting for art
* that does not keep the in-game map's layout.
--]]

return {
    dir  = 'zones',
    span = 120,
    grid = { ox = 1 / 32, oy = 1 / 32, cell_w = 1 / 16, cell_h = 1 / 16, n = 15 },

    zones = {
        ["Konschtat Highlands"] = { id = 108, sheets = {
            { map = 0 },
            { zone = 15, map = 0, name = 'Abyssea - Konschtat' },
        } },
        ["La Theine Plateau"] = { id = 102, sheets = {
            { map = 0 },
            { zone = 132, map = 0, name = 'Abyssea - La Theine' },
        } },
        ["Tahrongi Canyon"] = { id = 117, sheets = {
            { map = 0 },
            { zone = 45, map = 0, name = 'Abyssea - Tahrongi' },
        } },
        ["Caedarva Mire"] = { id = 79, sheets = {
            { map = 1, name = 'Map 1' },
            { map = 2, name = 'Map 2' },
        } },
        -- One zone in game, two points on the world map.  Both open the same
        -- two sheets; each starts on its own half.
        ["North Windurst Waters"] = { id = 238, start = 1, sheets = {
            { map = 1, name = 'North' },
            { map = 2, name = 'South' },
        } },
        ["South Windurst Waters"] = { id = 238, start = 2, sheets = {
            { map = 1, name = 'North' },
            { map = 2, name = 'South' },
        } },
    },
};
