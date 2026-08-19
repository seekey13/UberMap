--[[
* Self-check for the Instant Warp icon.  The scroll is found by item id in bag
* slots 1..80 and nowhere else, gil in slot 0 is not an item, an unreadable
* inventory reads as "not carried" rather than throwing, and the icon only
* sends its command while one is carried.  Mirrors have_warp_item and the
* icon's press gate in ubermap.lua.  Run with any Lua 5.1+:
*     lua test/test_warpitem.lua
--]]

local WARP_ITEM_ID   = 4181;
local BAG, BAG_SLOTS = 0, 80;

-- Stands in for AshitaCore's inventory: slots is a slot index -> { Id, Count }.
local function inventory(slots)
    return {
        GetContainerItem = function (_, container, i)
            assert(container == BAG, 'the bag is the only container /item reads');
            return slots[i];
        end,
    };
end

local function have_warp_item(inv)
    local ok, found = pcall(function()
        for i = 1, BAG_SLOTS do
            local it = inv:GetContainerItem(BAG, i);
            if (it ~= nil and it.Id == WARP_ITEM_ID and it.Count > 0) then
                return true;
            end
        end
        return false;
    end);
    return ok and found;
end

-- An empty bag, and one holding something else, carry no scroll.
assert(not have_warp_item(inventory({})), 'an empty bag must not read as carrying one');
assert(not have_warp_item(inventory({ [1] = { Id = 4151, Count = 12 } })),
       'Echo Drops must not read as an Instant Warp');

-- One in the first slot, one in the last, and one past the end of the bag.
assert(have_warp_item(inventory({ [1] = { Id = WARP_ITEM_ID, Count = 1 } })),
       'a scroll in the first slot must be found');
assert(have_warp_item(inventory({ [BAG_SLOTS] = { Id = WARP_ITEM_ID, Count = 1 } })),
       'a scroll in the last slot must be found');
assert(not have_warp_item(inventory({ [BAG_SLOTS + 1] = { Id = WARP_ITEM_ID, Count = 1 } })),
       'nothing past the last slot is in the bag');

-- Gil sits in slot 0, which the walk skips: a stack of 4181 gil is not a scroll.
assert(not have_warp_item(inventory({ [0] = { Id = WARP_ITEM_ID, Count = 4181 } })),
       'slot 0 is gil, not an item');

-- An emptied stack is not carried, and an inventory that cannot be read - which
-- is what zoning looks like - reads the same way instead of erroring.
assert(not have_warp_item(inventory({ [1] = { Id = WARP_ITEM_ID, Count = 0 } })),
       'an empty stack must not read as carrying one');
local broken = { GetContainerItem = function () error('inventory not loaded') end };
assert(not have_warp_item(broken), 'an unreadable inventory must not throw');

-- The press gate: the icon sends its command only while one is carried and no
-- warp popup lies over it.
local function sends(has_warp, warp_hot)
    return has_warp and not warp_hot;
end
assert(sends(true, false), 'a carried scroll must send');
assert(not sends(false, false), 'a dimmed icon must not send');
assert(not sends(true, true), 'a popup over the icon must eat the press');

print('test_warpitem: ok');
