--[[
* Self-check for the NPC interaction packets the map opens on.  0x032 and 0x033
* carry the NPC's target index at 0x08; 0x034 puts 32 bytes of menu parameters
* first and carries it at 0x28.  Any other packet is ignored, the index is a
* little-endian short, and a packet too short to hold one is dropped rather
* than read past.  Mirrors the packet_in handler in ubermap.lua.  Run with any
* Lua 5.1+:
*     lua test/test_npcevent.lua
--]]

local NPC_EVENT = { [0x032] = 0x08, [0x033] = 0x08, [0x034] = 0x28 };

-- The handler's read, with the entity lookup left to the caller.
local function event_index(id, data)
    local at = NPC_EVENT[id];
    if (at == nil) then
        return nil;
    end
    local lo, hi = data:byte(at + 1), data:byte(at + 2);
    if (lo == nil or hi == nil) then
        return nil;
    end
    return lo + hi * 256;
end

-- A packet of `size` bytes holding `index` as a little-endian short at `at`.
local function packet(size, at, index)
    local b = {};
    for i = 1, size do
        b[i] = string.char(0xEE);  -- filler, so a read at a wrong offset fails
    end
    b[at + 1] = string.char(index % 256);
    b[at + 2] = string.char(math.floor(index / 256));
    return table.concat(b);
end

-- Each watched packet reads its index from its own offset.
assert(event_index(0x032, packet(0x14, 0x08, 0x0123)) == 0x0123,
       '0x032 carries the index at 0x08');
assert(event_index(0x033, packet(0x70, 0x08, 0x0045)) == 0x0045,
       '0x033 carries the index at 0x08');
assert(event_index(0x034, packet(0x34, 0x28, 0x02F0)) == 0x02F0,
       '0x034 carries the index at 0x28, past its menu parameters');

-- 0x034 read at 0x08 is the bug this guards: that offset is menu parameters.
assert(event_index(0x034, packet(0x34, 0x28, 0x02F0)) ~= 0xEEEE,
       '0x034 must not be read at the offset the other two use');

-- The low byte comes first.
assert(event_index(0x032, packet(0x14, 0x08, 0x0100)) == 256, 'the short is little-endian');

-- Everything else is left alone, including the neighbouring event packets.
assert(event_index(0x036, packet(0x14, 0x08, 0x0123)) == nil, 'NPC chat is not an interaction');
assert(event_index(0x05C, packet(0x40, 0x28, 0x0123)) == nil, 'a menu update is not an interaction');

-- A truncated packet is dropped rather than read past its end.
assert(event_index(0x034, packet(0x14, 0x08, 0x0123)) == nil,
       'a packet too short to hold the index must be ignored');

print('test_npcevent: ok');
