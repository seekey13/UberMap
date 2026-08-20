--[[
* Self-check for lib/unlocks.lua, the bit test behind a red warp row.
*
* Two things can go wrong quietly here.  The bit maths can land on the wrong
* byte, which reads back somebody else's destination; and an alias in
* lib/warps.lua can stop matching the name Uberwarp files that destination
* under, which loses the unlock test and the /uw with it.  Both are checked,
* the second against the real Uberwarp data when this is run from inside an
* Ashita install and skipped when it is not.  Run with any Lua 5.1+:
*     lua test/test_unlocks.lua
--]]

local unlocks = assert(loadfile('lib/unlocks.lua'))();

local fails = 0;
local function check(name, got, want)
    if (got ~= want) then
        print(('FAIL %s: got %s, wanted %s'):format(name, tostring(got), tostring(want)));
        fails = fails + 1;
    end
end

-- A 64 byte mask block with every bit down, so a test can raise just the one
-- it means.  Indexed from 1, the way Ashita hands the array back.
local function blank()
    local m = {};
    for i = 1, 64 do m[i] = 0; end
    return m;
end

--[[
* Rows copied from the shipped Uberwarp files, with the bases they are counted
* from: Home Points 96, Survival Guides 160.  Enough of each to catch a base or
* a byte that has slipped, including the ends of both blocks.
--]]
local HP_XML = [[
<uberwarp>
    <entry alias="Southern San d'Oria" bitflag="96" param="0" />
    <entry alias="Southern San d'Oria2" bitflag="97" param="1" />
    <entry alias="Bastok Mines" bitflag="105" param="9" />
    <entry alias="Tavnazian Safehold" bitflag="160" param="64" />
    <entry alias="Uleguerand Range" bitflag="172" param="76" />
    <entry alias="Misareaux Coast" bitflag="213" param="117" />
    <entry alias="Riverne - Site #B01" bitflag="169" param="73" />
    <entry alias="Nowhere In Particular" param="200" />
</uberwarp>
]];

local SG_XML = [[
<uberwarp>
    <entry alias="West Ronfaure" bitflag="160" param="6" />
    <entry alias="Valkurm Dunes" bitflag="161" param="11" />
    <entry alias="Lufaise Meadows" bitflag="176" param="66" />
    <entry alias="Carpenters' Landing" bitflag="215" param="15" />
    <entry alias="Misareaux Coast" bitflag="217" param="67" />
</uberwarp>
]];

-- The byte and bit each of those should land on, worked out by hand.  A Home
-- Point's bit number is its own index, so byte = index / 8 from the top of the
-- block; a Survival Guide's is (group - 1) * 32 + groupIndex - 1, and its block
-- starts sixteen bytes in.
local hp = unlocks.parse(HP_XML, 96, 0);
local sg = unlocks.parse(SG_XML, 160, 16);

check('hp first byte',   hp["Southern San d'Oria"].byte,  0);
check('hp first mask',   hp["Southern San d'Oria"].mask,  1);
check('hp second mask',  hp["Southern San d'Oria2"].mask, 2);
check('hp 9 byte',       hp['Bastok Mines'].byte,         1);
check('hp 9 mask',       hp['Bastok Mines'].mask,         2);
check('hp 64 byte',      hp['Tavnazian Safehold'].byte,   8);
check('hp 64 mask',      hp['Tavnazian Safehold'].mask,   1);
check('hp 76 byte',      hp['Uleguerand Range'].byte,     9);
check('hp 76 mask',      hp['Uleguerand Range'].mask,     16);
check('hp 117 byte',     hp['Misareaux Coast'].byte,      14);
check('hp 117 mask',     hp['Misareaux Coast'].mask,      32);
-- No bitflag at all, so nothing to gate on.
check('hp flagless',     hp['Nowhere In Particular'],     nil);
-- Filed under both spellings: Uberwarp writes the hash, the /uw that works
-- leaves it out, and the same bit has to answer either way.
check('hp hashed byte',  hp['Riverne - Site #B01'].byte,  9);
check('hp hashed mask',  hp['Riverne - Site #B01'].mask,  2);
check('hp unhashed',     hp['Riverne - Site B01'].mask,   2);
-- Home Points stop at byte 15; Survival Guides pick up at 16.
check('sg first byte',   sg['West Ronfaure'].byte,        16);
check('sg first mask',   sg['West Ronfaure'].mask,        1);
check('sg second mask',  sg['Valkurm Dunes'].mask,        2);
check('sg 16 byte',      sg['Lufaise Meadows'].byte,      18);
check('sg 16 mask',      sg['Lufaise Meadows'].mask,      1);
check('sg 55 byte',      sg["Carpenters' Landing"].byte,  22);
check('sg 55 mask',      sg["Carpenters' Landing"].mask,  128);
check('sg 57 byte',      sg['Misareaux Coast'].byte,      23);
check('sg 57 mask',      sg['Misareaux Coast'].mask,      2);

-- Every parsed row inside the block its type owns.  A byte past the end would
-- be reading somebody else's flags.
for alias, b in pairs(hp) do
    check('hp block ' .. alias, b.byte >= 0 and b.byte <= 15, true);
end
for alias, b in pairs(sg) do
    check('sg block ' .. alias, b.byte >= 16 and b.byte <= 31, true);
end

-- known() against a real block.  Loaded through the module's own reader so the
-- lookup runs the same way it does in game.
local dir = 'test/';
local function write(name, text)
    local fh = assert(io.open(dir .. name, 'w'));
    fh:write(text);
    fh:close();
end
write('homepoint.xml', HP_XML);
write('survivalguide.xml', SG_XML);
unlocks.load(dir);
os.remove(dir .. 'homepoint.xml');
os.remove(dir .. 'survivalguide.xml');

local masks = blank();
check('nothing registered',   unlocks.known('home', 'Uleguerand Range', masks), false);
masks[10] = 16;  -- byte 9, bit 4: Uleguerand Range #1
check('that one registered',  unlocks.known('home', 'Uleguerand Range', masks), true);
check('and not its neighbour',
      unlocks.known('home', "Southern San d'Oria", masks), false);
-- The same bit number in the Survival Guide block, to catch the two blocks
-- being read off one another.
masks = blank();
masks[19] = 1;   -- byte 18, bit 0: the Lufaise Meadows guide
check('guide registered',     unlocks.known('guide', 'Lufaise Meadows', masks), true);
check('home of that name is not',
      unlocks.known('home', 'Misareaux Coast', masks), false);

--[[
* Pulling the block out of packet 0x63 type 6, which is where it comes from in
* game.  Mirrors the reader in ubermap.lua against a packet built to the
* server's own layout: a 4 byte header, the type word, a size word, then the
* Home Point masks and the Survival Guide masks.  An offset out by one here
* would read every destination off its neighbour, which is the kind of wrong
* that still looks plausible on screen.
--]]
local MASK_TYPE_AT, MASK_AT, MASK_BYTES = 0x04, 0x08, 64;

local function read_masks(data)
    if (data:byte(MASK_TYPE_AT + 1) ~= 6 or data:byte(MASK_TYPE_AT + 2) ~= 0) then
        return nil;
    end
    local m = {};
    for i = 1, MASK_BYTES do
        m[i] = data:byte(MASK_AT + i);
    end
    return (m[MASK_BYTES] ~= nil) and m or nil;
end

-- Uleguerand Range #1 is Home Point index 76: byte 9 of the block, bit 4.  Its
-- Survival Guide opposite number, Lufaise Meadows, is byte 18, bit 0.
local body = {};
for i = 1, MASK_BYTES do body[i] = string.char(0); end
body[10] = string.char(16);
body[19] = string.char(1);
local packet = string.char(0x63, 0x00, 0x00, 0x00)   -- header
            .. string.char(6, 0)                     -- type 6
            .. string.char(68, 0)                    -- size of the data
            .. table.concat(body);

local got = read_masks(packet);
check('packet read',        got ~= nil,                                 true);
check('packet home bit',    unlocks.known('home', 'Uleguerand Range', got),  true);
check('packet guide bit',   unlocks.known('guide', 'Lufaise Meadows', got),  true);
check('packet leaves rest', unlocks.known('home', 'Bastok Mines', got),      false);
-- Anything that is not type 6 is somebody else's data in the same packet id.
check('wrong type ignored',
      read_masks(string.char(0x63, 0, 0, 0, 5, 0, 68, 0) .. packet:sub(9)), nil);

-- Everything doubtful stays travellable: a wrong 'no' takes a warp away from
-- somebody who owns it, and there is no way past it from the map.
check('no masks yet',   unlocks.known('home', 'Uleguerand Range', nil),      true);
check('short block',    unlocks.known('home', 'Uleguerand Range', { 0 }),    true);
check('unlisted alias', unlocks.known('home', 'Somewhere Else', blank()),    true);
check('flagless row',   unlocks.known('home', 'Nowhere In Particular', blank()), true);
check('unity never gated',
      unlocks.known('unity', 'Windurst Woods', blank()), true);

--[[
* Every warp row's alias against the Uberwarp data actually installed, which is
* two directories up from the addon.  This is the check that catches a zone
* whose name in lib/warps.lua is not one Uberwarp knows it by - the row draws,
* and its unlock test quietly stops answering.  Hashed and unhashed spellings
* both count, since Uberwarp itself takes either.  Skipped when the files are
* not there, so the suite still runs on a checkout on its own.
--]]
local UW_DIR = '../../resources/ashitahelper/uberwarp/';
local probe  = io.open(UW_DIR .. 'homepoint.xml', 'r');
if (probe == nil) then
    print('skip: no Uberwarp data at ' .. UW_DIR);
else
    probe:close();
    -- One read per file, then every row looked up in what came back.
    local listed = {};
    for kind, region in pairs(unlocks.REGION) do
        local fh = assert(io.open(UW_DIR .. region.file, 'r'));
        listed[kind] = unlocks.parse(fh:read('*a'), region.base, region.byte);
        fh:close();
    end

    local warps   = assert(loadfile('lib/warps.lua'))();
    local checked = 0;
    for zone, list in pairs(warps) do
        for _, row in ipairs(list) do
            -- Unity Concords are not in this data and are never gated.
            if (listed[row.type] ~= nil) then
                -- warp_alias in ubermap.lua, spelled the same way.
                local n = (row.type == 'home')
                          and row.label:match('^Home Point #(%d+)') or nil;
                local alias = ((row.zone or zone):gsub('%(S%)$', '[S]'))
                              .. ((n ~= nil and n ~= '1') and n or '');
                check(('%s knows %q'):format(unlocks.REGION[row.type].file, alias),
                      listed[row.type][alias] ~= nil, true);
                checked = checked + 1;
            end
        end
    end
    print(('checked %d warp aliases against the installed Uberwarp data'):format(checked));
end

if (fails > 0) then
    print(('%d check(s) failed'):format(fails));
    os.exit(1);
end
print('unlocks ok');
