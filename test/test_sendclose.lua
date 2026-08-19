--[[
* Self-check for what happens after the map sends a command: the window, the
* warp popup and the credits panel all go away, and the NPC talk the command
* itself starts does not open the map straight back up.  Mirrors send_cmd, the
* packet_in gate and SEND_QUIET in ubermap.lua.  Run with any Lua 5.1+:
*     lua test/test_sendclose.lua
--]]

local SEND_QUIET = 3.0;

local ui, sent = {}, nil;
local now = 0;

-- send_cmd, with the chat queue left to the caller.
local function send_cmd(cmd)
    sent          = cmd;
    ui.is_open    = false;
    ui.warp       = nil;
    ui.thanks     = false;
    ui.sent_at    = now;
end

-- The packet_in handler's decision, once the NPC is known to be a warp NPC.
local function npc_event()
    if (now - ui.sent_at > SEND_QUIET) then
        ui.is_open = true;
    end
end

-- Sending from a warp popup puts everything away at once.
ui = { is_open = true, warp = { label = 'Sandoria' }, thanks = true, sent_at = 0 };
send_cmd('/uw hp Southern San d\'Oria');
assert(sent == '/uw hp Southern San d\'Oria', 'the command still goes out');
assert(ui.is_open == false, 'the map closes');
assert(ui.warp == nil, 'the warp popup closes with it');
assert(ui.thanks == false, 'the credits panel closes with it');

-- The talk the command starts arrives right after and must not reopen the map.
now = 0.4;
npc_event();
assert(ui.is_open == false, 'the NPC event the command triggered is ignored');

-- A talk after the window is a real Home Point visit and opens the map again.
now = SEND_QUIET + 0.1;
npc_event();
assert(ui.is_open == true, 'a later talk still opens the map');

print('test_sendclose: ok');
