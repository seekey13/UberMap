--[[
* UberMap warp destinations, indexed by zone name.
*
* The key matches a point's 'label' in points.lua.  Each row is one place the
* player can warp to, in the order the popup lists them: Home Points, then
* Survival Guides, then the Unity Concord.  'type' picks the icon - 'home' is
* Crystal.png, 'guide' is Guide.png, 'unity' is Unity.png.  'pos' is the grid
* reference, kept out of the label so the popup draws it in a column of its own
* and every row's lines up; a row with none simply leaves it out.
*
* Clicking a row sends '/uw <hp|sg|uc> <zone><number>', with the zone taken from
* the key.  A row whose key is not the game's own name for the zone - a marker
* covering two zones, or a name the map spells differently - carries a 'zone' of
* its own for the command to use.
--]]

-- Windurst Waters is one zone in game, but points.lua draws its north and south
-- halves as separate markers.  Held aside so both can point at the same rows.
local windurst_waters = {
    { type = 'home', label = 'Home Point #1 (E)', pos = '(G-7)',  zone = 'Windurst Waters' },
    { type = 'home', label = 'Home Point #2 (M)', pos = '(K-11)', zone = 'Windurst Waters' },
    { type = 'home', label = 'Home Point #3',     pos = '(J-8)',  zone = 'Windurst Waters' },
    { type = 'home', label = 'Home Point #4',     pos = '(E-9)',  zone = 'Windurst Waters' },
};

return {
    ["Aht Urhgan Whitegate"] = {
        { type = 'home',  label = 'Home Point #1',     pos = '(H-9)' },
        { type = 'home',  label = 'Home Point #2',     pos = '(L-9)' },
        { type = 'home',  label = 'Home Point #3 (A)', pos = '(F-6)' },
        { type = 'home',  label = 'Home Point #4 (M)', pos = '(F-10)' },
        { type = 'guide', label = 'Survival Guide',    pos = '(L-8)' },
    },
    ["Al'Taieu"] = {
        { type = 'home', label = 'Home Point #1', pos = '(H-4)' },
        { type = 'home', label = 'Home Point #2', pos = '(E-6)' },
        { type = 'home', label = 'Home Point #3', pos = '(L-6)' },
    },
    ["Alzadaal Undersea Ruins"] = {
        { type = 'unity', label = 'Unity Concord', pos = '(G-9)' },
    },
    ["Arrapago Reef"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(H-11)' },
    },
    ["Attohwa Chasm"] = {
        { type = 'home',  label = 'Home Point #1', pos = '(G-6)' },
        { type = 'unity', label = 'Unity Concord', pos = '(F-7)' },
    },
    ["Aydeewa Subterrane"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(H-10)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(H-10)' },
    },
    ["Bastok Markets"] = {
        { type = 'home', label = 'Home Point #1 (E)', pos = '(F-9)' },
        { type = 'home', label = 'Home Point #2 (A)', pos = '(E-7)' },
        { type = 'home', label = 'Home Point #3 (M)', pos = '(I-6)' },
        { type = 'home', label = 'Home Point #4',     pos = '(I-8)' },
    },
    ["Bastok Markets [S]"] = {
        { type = 'home',  label = 'Home Point #1',  pos = '(F-9)' },
        { type = 'guide', label = 'Survival Guide', pos = '(G-4)' },
    },
    ["Bastok Mines"] = {
        { type = 'home',  label = 'Home Point #1 (A)', pos = '(I-8)' },
        { type = 'home',  label = 'Home Point #2 (M)', pos = '(K-8)' },
        { type = 'home',  label = 'Home Point #3',     pos = '(K-7)' },
        { type = 'guide', label = 'Survival Guide',    pos = '(I-9)' },
    },
    ["Batallia Downs"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(H-5)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(K-8)' },
    },
    ["Batallia Downs [S]"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(F-9)' },
    },
    ["Beadeaux"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(E-7)' },
    },
    ["Beaucedine Glacier"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(H-9)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(I-9)' },
    },
    ["Beaucedine Glacier [S]"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(G-7)' },
    },
    ["Behemoth's Dominion"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(L-9)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(F-7)' },
    },
    ["Bhaflau Thickets"] = {
        { type = 'home', label = 'Home Point #1', pos = '(I-9)' },
    },
    ["Bibiki Bay"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(H-7)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(I-6)' },
    },
    ["Bostaunieux Oubliette"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(I-6)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(D-9)' },
    },
    ["Buburimu Peninsula"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(E-7)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(F-6)' },
    },
    ["Caedarva Mire"] = {
        { type = 'home',  label = 'Home Point #1',  pos = '(E-9)' },
        { type = 'guide', label = 'Survival Guide', pos = '(G-6)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(H-9)' },
    },
    ["Cape Teriggan"] = {
        { type = 'home',  label = 'Home Point #1',  pos = '(F-5)' },
        { type = 'guide', label = 'Survival Guide', pos = '(G-8)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(H-7)' },
    },
    ["Carpenters' Landing"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(J-10)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(I-11)' },
    },
    ["Castle Oztroja"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(F-8)' },
    },
    ["Castle Zvahl Baileys"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(J-8)' },
    },
    ["Castle Zvahl Baileys [S]"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(J-8)' },
    },
    ["Castle Zvahl Keep"] = {
        { type = 'home', label = 'Home Point #1', pos = '(G-7)' },
    },
    ["Castle Zvahl Keep [S]"] = {
        { type = 'home', label = 'Home Point #1', pos = '(G-7)' },
    },
    ["Ceizak Battlegrounds"] = {
        { type = 'home', label = 'Home Point #1', pos = '(H-6)' },
    },
    ["Crawlers' Nest"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(M-8)' },
    },
    ["Crawlers' Nest [S]"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(M-8)' },
    },
    ["Dangruf Wadi"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(K-10)' },
    },
    ["Davoi"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(J-7)' },
    },
    ["Den of Rancor"] = {
        { type = 'home',  label = 'Home Point #1', pos = '(E-4)' },
        { type = 'home',  label = 'Home Point #2', pos = '(I-8)' },
        { type = 'unity', label = 'Unity Concord', pos = '(G-12)' },
    },
    ["Dragon's Aery"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(F-9)' },
    },
    ["East Ronfaure"] = {
        { type = 'unity', label = 'Unity Concord', pos = '(G-9)' },
    },
    ["East Ronfaure [S]"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(J-11)' },
    },
    ["East Sarutabaruta"] = {
        { type = 'unity', label = 'Unity Concord', pos = '(J-8)' },
    },
    ["Eastern Adoulin"] = {
        { type = 'home',  label = 'Home Point #1',     pos = '(G-6)' },
        { type = 'home',  label = 'Home Point #2 (M)', pos = '(H-10)' },
        { type = 'guide', label = 'Survival Guide',    pos = '(H-11)' },
    },
    ["Eastern Altepa Desert"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(F-10)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(J-8)' },
    },
    ["Fei'Yin"] = {
        { type = 'home',  label = 'Home Point #1', pos = '(K-8)' },
        { type = 'home',  label = 'Home Point #2', pos = '(I-5)' },
        { type = 'unity', label = 'Unity Concord', pos = '(F-11)' },
    },
    ["Foret de Hennetiel"] = {
        { type = 'home', label = 'Home Point #1', pos = '(F-10)' },
    },
    ["Fort Ghelsba"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(F-8)' },
    },
    ["Fort Karugo-Narugo [S]"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(I-5)' },
    },
    ["Garlaige Citadel"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(G-7)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(G-6)' },
    },
    ["Garlaige Citadel [S]"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(G-7)' },
    },
    ["Giddeus"] = {
        { type = 'home', label = 'Home Point #1', pos = '(G-12)' },
    },
    ["Grand Palace of Hu'Xzoi"] = {
        { type = 'home', label = 'Home Point #1', pos = '(H-8)' },
    },
    ["Grauberg [S]"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(L-4)' },
    },
    ["Gusgen Mines"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(H-9)' },
    },
    ["Gustav Tunnel"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(K-7)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(H-10)' },
    },
    ["Halvung"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(N-5)' },
    },
    ["Ifrit's Cauldron"] = {
        { type = 'home',  label = 'Home Point #1',  pos = '(G-6)' },
        { type = 'guide', label = 'Survival Guide', pos = '(K-9)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(K-7)' },
    },
    ["Inner Horutoto Ruins"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(I-7)' },
    },
    ["Jugner Forest"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(I-8)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(I-8)' },
    },
    ["Jugner Forest [S]"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(G-11)' },
    },
    ["Kamihr Drifts"] = {
        { type = 'home', label = 'Home Point #1', pos = '(I-7)' },
    },
    ["Kazham"] = {
        { type = 'home',  label = 'Home Point #1',  pos = '(I-9)' },
        { type = 'guide', label = 'Survival Guide', pos = '(G-9)' },
    },
    ["King Ranperre's Tomb"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(G-5)' },
    },
    ["Konschtat Highlands"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(G-3)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(G-7)' },
    },
    ["Korroloka Tunnel"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(C-9)' },
    },
    ["Kuftal Tunnel"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(H-9)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(G-3)' },
    },
    ["La Theine Plateau"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(M-8)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(H-8)' },
    },
    ["Labyrinth of Onzozo"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(G-11)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(G-6)' },
    },
    ["Leafallia"] = {
        { type = 'home', label = 'Home Point #1', pos = '(H-8)' },
    },
    ["Lower Delkfutt's Tower"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(H-10)' },
    },
    ["Lower Jeuno"] = {
        { type = 'home', label = 'Home Point #1 (E)', pos = '(G-11)' },
        { type = 'home', label = 'Home Point #2 (M)', pos = '(I-5)' },
    },
    ["Lufaise Meadows"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(E-8)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(K-8)' },
    },
    ["Mamook"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(J-7)' },
    },
    ["Marjami Ravine"] = {
        { type = 'home', label = 'Home Point #1', pos = '(H-7)' },
    },
    ["Maze of Shakhrami"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(C-9)' },
    },
    ["Meriphataud Mountains"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(E-5)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(F-11)' },
    },
    ["Meriphataud Mountains [S]"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(L-8)' },
    },
    ["Metalworks"] = {
        { type = 'home', label = 'Home Point #1', pos = '(I-8)' },
        { type = 'home', label = 'Home Point #2', pos = '(F-8)' },
    },
    ["Mhaura"] = {
        { type = 'home', label = 'Home Point #1', pos = '(H-8)' },
    },
    ["Misareaux Coast"] = {
        { type = 'home',  label = 'Home Point #1',  pos = '(G-5)' },
        { type = 'guide', label = 'Survival Guide', pos = '(G-7)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(F-7)' },
    },
    ["Morimar Basalt Fields"] = {
        { type = 'home', label = 'Home Point #1', pos = '(E-5)' },
    },
    ["Mount Zhayolm"] = {
        { type = 'home',  label = 'Home Point #1', pos = '(D-8)' },
        { type = 'unity', label = 'Unity Concord', pos = '(C-7)' },
    },
    ["Nashmau"] = {
        { type = 'home',  label = 'Home Point #1',  pos = '(G-8)' },
        { type = 'guide', label = 'Survival Guide', pos = '(G-8)' },
    },
    ["Newton Movalpolos"] = {
        { type = 'home', label = 'Home Point #1', pos = '(M-9)' },
    },
    ["Norg"] = {
        { type = 'home',  label = 'Home Point #1',     pos = '(H-9)' },
        { type = 'home',  label = 'Home Point #2 (A)', pos = '(G-7)' },
        { type = 'guide', label = 'Survival Guide',    pos = '(H-9)' },
    },
    ["North Gustaberg"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(D-10)' },
    },
    ["North Gustaberg [S]"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(F-7)' },
    },
    ["Northern San d'Oria"] = {
        { type = 'home',  label = 'Home Point #1 (E)', pos = '(E-8)' },
        { type = 'home',  label = 'Home Point #2',     pos = '(J-7)' },
        { type = 'home',  label = 'Home Point #3 (M)', pos = '(K-9)' },
        { type = 'home',  label = 'Home Point #4',     pos = '(F-5)' },
        { type = 'guide', label = 'Survival Guide',    pos = '(E-8)' },
    },
    ["Oldton Movalpolos"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(F-10)' },
    },
    ["Ordelle's Caves"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(G-3)' },
    },
    ["Palborough Mines"] = {
        { type = 'home', label = 'Home Point #1', pos = '(H-10)' },
    },
    ["Pashhow Marshlands"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(K-6)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(E-12)' },
    },
    ["Pashhow Marshlands [S]"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(K-11)' },
    },
    ["Phomiuna Aqueducts"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(J-10)' },
    },
    ["Port Bastok"] = {
        { type = 'home', label = 'Home Point #1 (E)', pos = '(J-7)' },
        { type = 'home', label = 'Home Point #2 (M)', pos = '(J-13)' },
        { type = 'home', label = 'Home Point #3',     pos = '(E-6)' },
    },
    ["Port Jeuno"] = {
        { type = 'home', label = 'Home Point #1 (E)', pos = '(J-8)' },
        { type = 'home', label = 'Home Point #2 (M)', pos = '(F-8)' },
    },
    ["Port San d'Oria"] = {
        { type = 'home', label = 'Home Point #1',     pos = '(G-9)' },
        { type = 'home', label = 'Home Point #2 (M)', pos = '(J-9)' },
        { type = 'home', label = 'Home Point #3 (A)', pos = '(H-10)' },
    },
    ["Port Windurst"] = {
        { type = 'home',  label = 'Home Point #1',     pos = '(C-7)' },
        { type = 'home',  label = 'Home Point #2 (E)', pos = '(B-4)' },
        { type = 'home',  label = 'Home Point #3 (M)', pos = '(L-4)' },
        { type = 'guide', label = 'Survival Guide',    pos = '(B-5)' },
    },
    ["Pso'Xja"] = {
        { type = 'home', label = 'Home Point #1' },
    },
    ["Qufim Island"] = {
        { type = 'home',  label = 'Home Point #1',  pos = '(G-7)' },
        { type = 'guide', label = 'Survival Guide', pos = '(G-6)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(I-8)' },
    },
    ["Quicksand Caves"] = {
        { type = 'home',  label = 'Home Point #1', pos = '(D-5)' },
        { type = 'home',  label = 'Home Point #2', pos = '(C-8)' },
        { type = 'unity', label = 'Unity Concord', pos = '(J-5)' },
    },
    ["Ra'Kaznar Inner Court"] = {
        { type = 'home', label = 'Home Point #1', pos = '(I-8)' },
    },
    ["Rabao"] = {
        { type = 'home',  label = 'Home Point #1',  pos = '(F-10)' },
        { type = 'home',  label = 'Home Point #2',  pos = '(G-6)' },
        { type = 'guide', label = 'Survival Guide', pos = '(G-11)' },
    },
    ["Ranguemont Pass"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(F-11)' },
    },
    ["Riverne - Site A01"] = {
        { type = 'home', label = 'Home Point #1', pos = '(I-9)', zone = 'Riverne - Site A01' },
    },
    ["Riverne - Site B01"] = {
        { type = 'home', label = 'Home Point #1', pos = '(E-8)', zone = 'Riverne - Site B01' },
    },
    ["Ro'Maeve"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(H-6)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(H-11)' },
    },
    ["Rolanberry Fields"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(G-6)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(D-11)' },
    },
    ["Rolanberry Fields [S]"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(I-14)' },
    },
    ["Ru'Aun Gardens"] = {
        { type = 'home',  label = 'Home Point #1',  pos = '(H-4)' },
        { type = 'home',  label = 'Home Point #2',  pos = '(E-7)' },
        { type = 'home',  label = 'Home Point #3',  pos = '(F-10)' },
        { type = 'home',  label = 'Home Point #4',  pos = '(K-7)' },
        { type = 'home',  label = 'Home Point #5',  pos = '(J-10)' },
        { type = 'guide', label = 'Survival Guide', pos = '(H-12)' },
    },
    ["Ru'Lude Gardens"] = {
        { type = 'home',  label = 'Home Point #1',     pos = '(H-8)' },
        { type = 'home',  label = 'Home Point #2 (M)', pos = '(I-9)' },
        { type = 'home',  label = 'Home Point #3 (A)', pos = '(F-9)' },
        { type = 'guide', label = 'Survival Guide',    pos = '(I-10)' },
    },
    ["Sacrarium"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(E-7)' },
    },
    ["Sauromugue Champaign"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(J-10)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(J-6)' },
    },
    ["Sauromugue Champaign [S]"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(K-11)' },
    },
    ["Sea Serpent Grotto"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(M-3)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(L-5)' },
    },
    ["Selbina"] = {
        { type = 'home', label = 'Home Point #1', pos = '(I-8)' },
    },
    ["South Gustaberg"] = {
        { type = 'unity', label = 'Unity Concord', pos = '(E-7)' },
    },
    ["Southern San d'Oria"] = {
        { type = 'home', label = 'Home Point #1 (E)', pos = '(G-10)' },
        { type = 'home', label = 'Home Point #2 (A)', pos = '(J-9)' },
        { type = 'home', label = 'Home Point #3 (M)', pos = '(M-5)' },
        { type = 'home', label = 'Home Point #4',     pos = '(E-8)' },
    },
    ["Southern San d'Oria [S]"] = {
        { type = 'home',  label = 'Home Point #1',  pos = '(G-10)' },
        { type = 'guide', label = 'Survival Guide', pos = '(K-10)' },
    },
    ["Tahrongi Canyon"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(G-4)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(J-8)' },
    },
    ["Tavnazian Safehold"] = {
        { type = 'home',  label = 'Home Point #1',  pos = '(I-6)' },
        { type = 'home',  label = 'Home Point #2',  pos = '(H-8)' },
        { type = 'home',  label = 'Home Point #3',  pos = '(J-7)' },
        { type = 'guide', label = 'Survival Guide', pos = '(H-6)' },
    },
    ["Temple of Uggalepih"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(F-6)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(I-5)' },
    },
    ["The Boyahda Tree"] = {
        { type = 'home',  label = 'Home Point #1', pos = '(J-12)' },
        { type = 'unity', label = 'Unity Concord', pos = '(F-6)' },
    },
    ["The Eldieme Necropolis"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(J-9)' },
    },
    ["The Eldieme Necropolis [S]"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(J-9)' },
    },
    ["The Garden of Ru'Hmet"] = {
        { type = 'home', label = 'Home Point #1', pos = '(H-9)' },
    },
    ["The Sanctuary of Zi'Tah"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(H-9)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(K-12)' },
    },
    ["The Shrine of Ru'Avitau"] = {
        { type = 'home', label = 'Home Point #1', pos = '(H-7)' },
    },
    ["Toraimarai Canal"] = {
        { type = 'home',  label = 'Home Point #1',  pos = '(G-8)' },
        { type = 'guide', label = 'Survival Guide', pos = '(F-5)' },
    },
    ["Uleguerand Range"] = {
        { type = 'home',  label = 'Home Point #1', pos = '(H-7)' },
        { type = 'home',  label = 'Home Point #2', pos = '(J-9)' },
        { type = 'home',  label = 'Home Point #3', pos = '(K-7)' },
        { type = 'home',  label = 'Home Point #4', pos = '(H-5)' },
        { type = 'home',  label = 'Home Point #5', pos = '(G-9)' },
        { type = 'unity', label = 'Unity Concord', pos = '(E-9)' },
    },
    ["Upper Delkfutt's Tower"] = {
        { type = 'home', label = 'Home Point #1', pos = '(F-9)' },
    },
    ["Upper Jeuno"] = {
        { type = 'home', label = 'Home Point #1 (E)', pos = '(F-5)' },
        { type = 'home', label = 'Home Point #2 (M)', pos = '(I-11)' },
        { type = 'home', label = 'Home Point #3 (A)', pos = '(G-9)' },
    },
    ["Valkurm Dunes"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(H-7)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(G-8)' },
    },
    ["Valley of Sorrows"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(F-8)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(F-8)' },
    },
    ["Vunkerl Inlet [S]"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(E-7)' },
    },
    ["Wajaom Woodlands"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(C-8)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(I-10)' },
    },
    ["West Ronfaure"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(G-9)' },
    },
    ["West Sarutabaruta"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(H-6)' },
    },
    ["West Sarutabaruta [S]"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(I-5)' },
    },
    ["Western Adoulin"] = {
        { type = 'home', label = 'Home Point #1 (A)', pos = '(E-9)' },
        { type = 'home', label = 'Home Point #2 (M)', pos = '(H-12)' },
    },
    ["Western Altepa Desert"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(K-7)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(I-7)' },
    },
    ["Windurst Walls"] = {
        { type = 'home', label = 'Home Point #1',     pos = '(F-7)' },
        { type = 'home', label = 'Home Point #2 (M)', pos = '(C-12)' },
        { type = 'home', label = 'Home Point #3 (A)', pos = '(I-11)' },
    },
    ["Windurst Waters"] = windurst_waters,
    ["Windurst Waters [S]"] = {
        { type = 'home',  label = 'Home Point #1',  pos = '(G-7)' },
        { type = 'guide', label = 'Survival Guide', pos = '(F-5)' },
    },
    ["Windurst Woods"] = {
        { type = 'home', label = 'Home Point #1',     pos = '(H-9)' },
        { type = 'home', label = 'Home Point #2 (E)', pos = '(K-10)' },
        { type = 'home', label = 'Home Point #3 (M)', pos = '(F-7)' },
        { type = 'home', label = 'Home Point #4 (A)', pos = '(J-12)' },
        { type = 'home', label = 'Home Point #5',     pos = '(G-13)' },
    },
    ["Xarcabard"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(H-9)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(J-9)' },
    },
    ["Xarcabard [S]"] = {
        { type = 'home', label = 'Home Point #1', pos = '(H-9)' },
    },
    ["Yhoator Jungle"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(I-8)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(J-7)' },
    },
    ["Yorcia Weald"] = {
        { type = 'home', label = 'Home Point #1', pos = '(E-9)' },
    },
    ["Yughott Grotto"] = {
        { type = 'home', label = 'Home Point #1', pos = '(J-6)' },
    },
    ["Yuhtunga Jungle"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(G-11)' },
        { type = 'unity', label = 'Unity Concord',  pos = '(F-11)' },
    },
    ["Zeruhn Mines"] = {
        { type = 'guide', label = 'Survival Guide', pos = '(I-7)' },
    },

    -- Out of order on purpose: markers whose granularity does not match the
    -- wiki's zones.  points.lua splits Windurst Waters in two and draws
    -- Delkfutt's Tower as one marker where the wiki has a zone per floor, so
    -- each marker is pointed at the rows a player standing there can reach.
    ["North Windurst Waters"] = windurst_waters,
    ["South Windurst Waters"] = windurst_waters,
    ["Delkfutt Tower"] = {
        { type = 'home',  label = 'Home Point #1 (Upper)',  pos = '(F-9)',  zone = "Upper Delkfutt's Tower" },
        { type = 'guide', label = 'Survival Guide (Lower)', pos = '(H-10)', zone = "Lower Delkfutt's Tower" },
    },
};
