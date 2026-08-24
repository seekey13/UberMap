--[[
* Self-check for the /um quiet chat filter.  Uberwarp stamps every line it
* writes '[Uberwarp:<module>]', with a colour byte between each part, so the
* filter looks for the plugin name and a module name apart rather than as one
* string.  Mirrors UW_MODULE and the text_in handler in ubermap.lua.  Run with
* any Lua 5.1+:
*     lua test/test_quiet.lua
--]]

local UW_MODULE = {
    'TaskHelper', 'HomePoint', 'SurvivalGuide', 'UnityWarp', 'CrystalWarp',
    'AbysseaConflux', 'AbysseaWarp', 'CastoffPoint', 'CavernousMaw', 'Elvorseal',
    'EschaEnter', 'EschanPortal', 'ProtoWaypoint', 'RunicPortal', 'ScalableArea',
    'Waypoint', 'WaitForZone', 'Wait',
};

local function contains(s, sub)
    return s:find(sub, nil, true) ~= nil;
end

local function blocked(msg)
    if (not contains(msg, 'Uberwarp')) then
        return false;
    end
    for _, m in ipairs(UW_MODULE) do
        if (contains(msg, m)) then
            return true;
        end
    end
    return false;
end

-- The plugin's own format: \30<colour> before each part of the stamp.
local function uw_line(module, text)
    return ('\30\5[\30\2Uberwarp\30\5:\30\3%s\30\5]\30\1 %s'):format(module, text);
end

local fails = 0;
local function check(want, msg, why)
    if (blocked(msg) ~= want) then
        print(('FAIL: %s'):format(why));
        fails = fails + 1;
    end
end

for _, m in ipairs(UW_MODULE) do
    check(true, uw_line(m, 'Task initialized.'), ('%s line not blocked'):format(m));
end
check(true, uw_line('HomePoint', 'Could not locate origin NPC.'),
    'an error line is blocked along with the rest');

-- Anything that only says the word stays: the map itself talks about Uberwarp,
-- and so does anyone typing it in a shell.
check(false, '\30\1[UberMap]\30\1 read Uberwarp\'s unlock data', 'UberMap own line blocked');
check(false, 'Player says: uberwarp is down again', 'chat mentioning it blocked');
check(false, uw_line('HomePoint', ''):gsub('Uberwarp', 'Something'),
    'a stamp from another plugin blocked');
check(false, '\30\1[UberMap]\30\1 Home Points hidden', 'a module word alone blocked');

if (fails == 0) then
    print(('ok: %d modules filtered, plain mentions left alone'):format(#UW_MODULE));
else
    print(('%d failed'):format(fails));
    os.exit(1);
end
