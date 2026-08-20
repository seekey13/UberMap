--[[
* Self-check for the Warp Ring icon's steps.  The ring is the one item on the
* toggle row that cannot be used straight out of the bag, so its icon walks
* through three states and only one of them warps.  Mirrors ring_step in
* ubermap.lua, and the tint and tooltip the draw picks off it.  Run with any
* Lua 5.1+:
*     lua test/test_ring.lua
--]]

local RING_EQUIP_WAIT = 9;
local COL_ICON, COL_ICON_OFF = 0xFFFFFFFF, 0x40FFFFFF;

local function ring_step(held, worn, waiting)
    if (not held) then
        return 'none';
    elseif (waiting) then
        return 'wait';
    end
    return worn and 'use' or 'equip';
end

-- The tint, tooltip and press the draw takes from that step.
local function ring_draw(step, left)
    local tip = step == 'use'   and 'Use Warp Ring'
             or step == 'equip' and 'Equip Warp Ring to ring1'
             or step == 'wait'  and string.format('Equipping Warp Ring (%ds)',
                                                  math.max(math.ceil(left), 0))
             or 'No Warp Ring in inventory or Mog Wardrobe';
    return (step == 'use') and COL_ICON or COL_ICON_OFF, tip;
end

local fails = 0;
local function check(name, got, want)
    if (got ~= want) then
        print(('FAIL %s: got %s, wanted %s'):format(name, tostring(got), tostring(want)));
        fails = fails + 1;
    end
end

-- No ring anywhere: dead and dim, whatever else is true.
check('none',      ring_step(false, false, false), 'none');
check('none worn', ring_step(false, true,  false), 'none');
check('none wait', ring_step(false, false, true),  'none');

-- Held but not worn: the press equips it.
check('equip', ring_step(true, false, false), 'equip');

-- The wait after that press outranks both held states, so neither a second
-- equip nor a use goes out while the ring is still landing.
check('wait',      ring_step(true, false, true), 'wait');
check('wait worn', ring_step(true, true,  true), 'wait');

-- Worn and settled: the press warps.
check('use', ring_step(true, true, false), 'use');

-- Only the usable step is drawn at full tint; the other three are dimmed.
local tint = select(1, ring_draw('use', 0));
check('use lit', tint, COL_ICON);
for _, step in ipairs({ 'none', 'equip', 'wait' }) do
    check(step .. ' dim', (select(1, ring_draw(step, RING_EQUIP_WAIT))), COL_ICON_OFF);
end

-- Every step names itself, and the countdown never reads below zero however
-- late the frame that draws it lands.
check('tip use',    select(2, ring_draw('use',   0)), 'Use Warp Ring');
check('tip equip',  select(2, ring_draw('equip', 0)), 'Equip Warp Ring to ring1');
check('tip none',   select(2, ring_draw('none',  0)), 'No Warp Ring in inventory or Mog Wardrobe');
check('tip wait',   select(2, ring_draw('wait',  RING_EQUIP_WAIT)), 'Equipping Warp Ring (9s)');
check('tip wait 1', select(2, ring_draw('wait',  0.2)),  'Equipping Warp Ring (1s)');
check('tip wait 0', select(2, ring_draw('wait',  -0.5)), 'Equipping Warp Ring (0s)');

if (fails == 0) then
    print('test_ring: ok');
else
    os.exit(1);
end
