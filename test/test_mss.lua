--[[
* Self-check for the Multisend toggle.  A lit toggle puts '/mss ' in front of
* whatever the map sends and a dimmed one leaves the line alone, the prefix goes
* on once rather than per call site, and a credit with two links flattens to one
* name row followed by both of them.  Mirrors send_cmd and the THANKS_ROWS build
* in ubermap.lua.  Run with any Lua 5.1+:
*     lua test/test_mss.lua
--]]

local MSS_PREFIX = '/mss ';

-- Stands in for AshitaCore's chat manager: keeps every line it was queued.
local function chat()
    local sent = {};
    return sent, function (_, mode, cmd)
        assert(mode == -1, 'commands are queued at the addon parse level');
        table.insert(sent, cmd);
    end;
end

local function send_cmd(ui, queue, cmd)
    queue(nil, -1, ui.mss and (MSS_PREFIX .. cmd) or cmd);
end

do
    local ui = { mss = false };
    local sent, queue = chat();

    send_cmd(ui, queue, '/uw hp Bastok Markets');
    assert(sent[1] == '/uw hp Bastok Markets', 'off sends the line untouched');

    ui.mss = true;
    send_cmd(ui, queue, '/uw hp Bastok Markets');
    assert(sent[2] == '/mss /uw hp Bastok Markets', 'on prefixes the same line');

    -- The item command travels the same gate, so the scroll follows the toggle.
    send_cmd(ui, queue, '/item "Instant Warp" <me>');
    assert(sent[3] == '/mss /item "Instant Warp" <me>', 'the scroll is sent too');

    -- Once, not once per gate: a line already carrying the prefix would go out
    -- as '/mss /mss ...' and Multisend would swallow the wrong command.
    ui.mss = false;
    send_cmd(ui, queue, sent[2]);
    assert(sent[4] == '/mss /uw hp Bastok Markets', 'the gate does not stack');
end

-- The credits flatten: heading, blank, then per credit a name and each of its
-- links, with a blank between credits.  Only link rows are clickable.
do
    local THANKS_HEAD = 'head';
    local THANKS = {
        { 'Thorny / Uberwarp / Multisend', 'url/Uberwarp', 'url/Multisend' },
        { 'FFXI Remapster Project', 'url/remapster' },
    };

    local rows = { { text = THANKS_HEAD }, { text = '' } };
    for i, c in ipairs(THANKS) do
        if (i > 1) then
            table.insert(rows, { text = '' });
        end
        table.insert(rows, { text = c[1] });
        for j = 2, #c do
            table.insert(rows, { text = c[j], url = c[j] });
        end
    end

    local want = { 'head', '', 'Thorny / Uberwarp / Multisend', 'url/Uberwarp',
                   'url/Multisend', '', 'FFXI Remapster Project', 'url/remapster' };
    assert(#rows == #want, 'a two-link credit adds a row rather than replacing one');
    for i, text in ipairs(want) do
        assert(rows[i].text == text, ('row %d reads %q'):format(i, rows[i].text));
    end
    for _, i in ipairs({ 4, 5, 8 }) do
        assert(rows[i].url == rows[i].text, 'a link row carries its url');
    end
    for _, i in ipairs({ 1, 2, 3, 6, 7 }) do
        assert(rows[i].url == nil, 'a heading, blank or name row is not clickable');
    end
end

print('test_mss: ok');
