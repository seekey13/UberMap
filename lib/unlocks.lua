--[[
* Which warp destinations the player has actually registered.
*
* The server hands the client a 64 byte block of teleport masks (packet 0x63,
* type 6): four uint32 of Home Points, then four of Survival Guides, then the
* rest.  Ashita exposes it as Player:GetHomepointMasks(), a 64 entry table of
* bytes.  A destination's bit goes up the first time the player stands at it,
* which is exactly what the NPC's own menu greys its rows on, so a clear bit is
* a warp the server will refuse.
*
* The bit a destination sits on comes out of Uberwarp's data files under
* Ashita/resources/ashitahelper/uberwarp, keyed by the same alias the /uw line
* carries -- so the map's answer and the command it would send are the same
* name by construction.  Uberwarp counts its bitflags from the start of the
* NPC's event parameters rather than from the mask block, which puts Home
* Points 96 bits in and Survival Guides 160; both bases are taken back off
* here.
*
* Unity Concords carry no bitflag at all -- every Unity destination is open to
* a member -- so nothing gates them.
--]]

local unlocks = {};

-- Per warp type: the Uberwarp file listing it, the bit its first flag sits on,
-- and the byte its mask block starts at inside GetHomepointMasks().
unlocks.REGION = {
    home  = { file = 'homepoint.xml',     base = 96,  byte = 0  },
    guide = { file = 'survivalguide.xml', base = 160, byte = 16 },
};

-- alias -> { byte, mask }, per warp type.  Empty until load() reads the files,
-- and an empty one gates nothing.
local BITS = { home = {}, guide = {} };

--[[
* Pulls the alias and bitflag out of one Uberwarp file.  Read by pattern rather
* than as XML: every destination is one self-closing <entry> tag on a line of
* its own, so a line at a time is the whole grammar.
*
* A row with no bitflag, or one carrying Uberwarp's 0x4000 (test reversed) or
* 0x8000 (do not test) markers, is left out and so is never gated -- those are
* flags the map has no business second-guessing.
*
* Each destination is filed twice where the two spellings differ: as written,
* and with any '#' taken out.  Uberwarp writes two of the Riverne sites
* 'Riverne - Site #A01' but takes the /uw for them without the hash and not
* with it, so the name that travels is not the name in the file; keying both
* lets the row that works still find its bit.
--]]
function unlocks.parse(text, base, byte)
    local out = {};
    for line in text:gmatch('[^\r\n]+') do
        local alias = line:match('alias="([^"]*)"');
        local flag  = tonumber(line:match('bitflag="(%d+)"'));
        if (alias ~= nil and flag ~= nil and flag < 0x4000 and flag >= base) then
            local b   = flag - base;
            local hit = { byte = byte + math.floor(b / 8), mask = 2 ^ (b % 8) };
            out[alias] = hit;
            out[(alias:gsub('#', ''))] = hit;
        end
    end
    return out;
end

--[[
* Reads both files out of the Uberwarp resource directory, which is handed in
* with a trailing separator.  A file that will not open leaves its type
* ungated, the same as a row the file does not list: Uberwarp is what performs
* the warp, so if its data is gone the /uw was never going to land anyway.
--]]
function unlocks.load(dir)
    for kind, r in pairs(unlocks.REGION) do
        local fh = io.open(dir .. r.file, 'r');
        if (fh ~= nil) then
            local text = fh:read('*a');
            fh:close();
            BITS[kind] = unlocks.parse(text, r.base, r.byte);
        end
    end
end

--[[
* Whether the player has registered the destination this alias names, given the
* mask block read off the client.
*
* Fails open on every doubt -- a type with no file, an alias the file does not
* list, no mask block back yet -- because the two mistakes are not the same
* size: a wrong 'no' takes away a warp the player owns and offers no way past
* it, while a wrong 'yes' only sends a /uw the server was going to turn down.
*
* Tested with arithmetic rather than a bit library so the same code runs under
* the addon's LuaJIT and under a plain Lua for the self-check.
--]]
function unlocks.known(kind, alias, masks)
    local bits = BITS[kind];
    local b    = bits and bits[alias];
    if (b == nil or masks == nil or masks[b.byte + 1] == nil) then
        return true;
    end
    return math.floor(masks[b.byte + 1] / b.mask) % 2 == 1;
end

return unlocks;
