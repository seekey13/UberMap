--[[
* Self-check for the saved settings.  The map keeps its Multisend gate, its
* layer toggles and its three colours between sessions; everything else in ui is
* read from the world.  The settings library hands back the default table itself
* for a key the file has no entry for, so applying them has to copy rather than
* share, or the first drag of a colour picker would edit the defaults.  Mirrors
* apply_settings and save_settings in ubermap.lua.  Run with any Lua 5.1+:
*     lua test/test_settings.lua
--]]

local SAVED = { 'mss', 'toggle', 'col_text', 'col_outline', 'col_hover' };

local function defaults()
    return {
        mss         = false,
        toggle      = { },
        col_text    = { 0.0, 0.0, 0.0, 1.0 },
        col_outline = { 1.0, 1.0, 1.0, 0.5 },
        col_hover   = { 1.0, 1.0, 1.0, 0.18 },
    };
end

local function copy_setting(v)
    if (type(v) ~= 'table') then
        return v;
    end
    local t = { };
    for k, tv in pairs(v) do
        t[k] = tv;
    end
    return t;
end

local function apply_settings(ui, s)
    for _, k in ipairs(SAVED) do
        ui[k] = copy_setting(s[k]);
    end
end

local function save_settings(ui, cfg)
    for _, k in ipairs(SAVED) do
        cfg[k] = copy_setting(ui[k]);
    end
end

-- A file with nothing of its own reads as the defaults, and moving a picker
-- afterwards leaves those defaults where they were.
do
    local def = defaults();
    local ui  = { };
    apply_settings(ui, def);

    assert(ui.mss == false, 'Multisend starts off');
    assert(ui.col_hover[4] == 0.18, 'the hover colour comes across');

    ui.col_hover[4] = 0.5;
    ui.toggle['Crystal.png'] = true;
    assert(def.col_hover[4] == 0.18, 'the default colour is not edited through ui');
    assert(def.toggle['Crystal.png'] == nil, 'the default toggles are not edited either');
end

-- What a hand change writes out, and what comes back on the next session.
do
    local cfg = defaults();
    local ui  = { };
    apply_settings(ui, cfg);

    ui.mss = true;
    ui.toggle['Unity.png'] = true;
    ui.col_text[1] = 1.0;
    save_settings(ui, cfg);

    local back = { };
    apply_settings(back, cfg);
    assert(back.mss == true, 'the Multisend gate is remembered');
    assert(back.toggle['Unity.png'] == true, 'a dimmed toggle is remembered');
    assert(back.toggle['Crystal.png'] == nil, 'a lit one stays lit');
    assert(back.col_text[1] == 1.0, 'the text colour is remembered');
end

-- The proximity filter moves the toggles on its own, and that is the world
-- talking rather than a choice: it does not call save_settings, so what was set
-- by hand is still what comes back next session.
do
    local WARP_ICON = { hp = 'Crystal.png', sg = 'Guide.png', uc = 'Unity.png' };
    local cfg = defaults();
    local ui  = { };
    apply_settings(ui, cfg);

    ui.toggle['Guide.png'] = true;   -- dimmed by hand
    save_settings(ui, cfg);

    for t, file in pairs(WARP_ICON) do   -- filter_to('hp'), walking up to a Home Point
        ui.toggle[file] = (t ~= 'hp') or nil;
    end
    assert(ui.toggle['Crystal.png'] == nil, 'the kind in reach is lit');

    local back = { };
    apply_settings(back, cfg);
    assert(back.toggle['Guide.png'] == true, 'the hand toggle survives the filter');
    assert(back.toggle['Unity.png'] == nil, 'the filter itself is not saved');
end

print('test_settings: ok');
