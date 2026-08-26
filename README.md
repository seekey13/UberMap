# UberMap

Ashita v4 addon by Seekey. A zoomable, pannable map of Vana'diel that pops up when you talk to a Home Point, Survival Guide or Unity Concord, and warps you (using [Uberwarp](https://github.com/ThornyFFXI/Uberwarp)).   This is created for ACE players on the [CatsEye[(https://catseyexi.com/) private server.
<img width="1748" height="977" alt="image" src="https://github.com/user-attachments/assets/bf20febe-6030-4eea-a17d-77ac633817c3" />


## Install

Drop the `UberMap` folder into `Ashita/addons/`, then `/addon load ubermap`.

| Command | Effect |
| --- | --- |
| `/ubermap`, `/um` | Toggle the map |
| `/ubermap edit` | Toggle the point editor |
| `/ubermap config` | Toggle the config panel: map font and size, plus text, outline, background and row hover colours |
| `/ubermap widget` | Toggle the gamepad friendly favorites widget (off by default) |
| `/ubermap guide` | Toggle the EXP Guide scroll pickup (on by default) |
| `/ubermap focus` | Toggle the search box taking the keyboard when the map opens (off by default) |

## The map

Mouse wheel zooms, left-drag pans, **shift**-drag moves the window/widget.  
A controller works it too — see [Gamepad map navigation](#gamepad-map-navigation).  
Talking to a warp NPC opens it; or use the command `/uw`.  
It closes itself once you walk away or a warp is used.  
The UberMap widget will open when approaching a warp point.

**Past**/**Present**.  

## Warp list

Left-click a zone point — for a panel of that zone's destinations. Clicking a row sends a Uberwarp command and closes the panel:

### Row states

| Look | Meaning |
| --- | --- |
| Normal | Travels now |
| Grey | Wrong kind of NPC for where you stand; the icon says what to walk up to |
| **Red** | Never registered; takes no click from anywhere, hover says why |

## Toolbar

| Icon | Where | Does |
| --- | --- | --- |
| **Search** | After the past/present switch | Type to fade back every marker whose name does not match, and frame what is left: the view zooms to fit the matching zones on every keystroke. Spelling is forgiven once nothing on the map is spelled the way you typed it, so `juno` and `windhurst` still land where they were meant to -- but `norg` finds Norg rather than every Nor- zone near it.  Clearing search pulls the view back out to the whole map. |
| **Crystal**, **Guide**, **Unity** | Right of search | Dim one to drop that kind of row. A zone with nothing left opens no panel |
| **Warp** | After them | `/item "Instant Warp" <me>` and closes the map. Lit only while the scroll (4181) is carried |
| **Warp Ring** | After that | Two steps, see below |
| **Multisend** | Bottom right | Prefixes every command the map sends with `/mss ` |
| **Heart** | Bottom left | Opens favorites. Hidden while the gamepad widget is on, since that lists the same rows.  Filters will completely hide results on this list |

`/um quiet` hides Uberwarp's chat lines. Off by default: `[Uberwarp:<module>]`, enable this if you want to clean up the chat log on warps.  Keep in mind you will no longer get error messages.

`/um focus` sets search to focus on open. Off by default: makes it feel better for users who plan on type filtering most of their navigation, you will need to click the map to pan/zoom.

**Warp Ring** works in two steps, since a ring must be worn before use. It looks for item 28540 in your bag and the eight Mog Wardrobes the client will equip out of, re-read twice a second like the scroll. Carrying none: dimmed and dead. Carrying one unworn: dimmed, and clicking sends `/equip ring1 "Warp Ring" <container>`, keeps the map open and goes dead for nine seconds while the ring lands. Wearing one: lit, and clicking sends `/item "Warp Ring" <me>` and closes the map. Hovering says which step it is on.  If you use LuAshitacast keep in mind they will battle each other.

While **Multisend** is lit every command — warp rows, scroll and ring alike — goes out through [Multisend](https://github.com/ThornyFFXI/Multisend) and repeats on every logged-in character. Off and dimmed until clicked.

**Favorites** are warp rows you saved, in your order. Right-click any row for *Add point to favorites list* — a row you cannot travel on right now works too, so a destination can be saved from anywhere. Each is named by its zone and row, e.g. `Windurst Woods - Home Point #2`. Clicking one warps exactly as its original row would. Stood at a Home Point, Survival Guide or Unity Concord the list narrows to the rows that NPC can send — the rest cannot be taken from there, so they are not listed — and stepping away brings the whole list back. A destination you have not registered still reads red. Drag a row up or down to reorder the list, including inside a narrowed one; right-click offers *Remove point from favorites list*.

## Config panel

`/um config` opens a small panel in the map's top-right corner: a font pulldown, a **Size** box, four scale boxes and four colour pickers, one to a row. Everything on it changes the map as you drag, and writes to your settings once you let go of the mouse or leave the box you are typing in — one write per edit rather than one per frame of it.

| Row | Edits |
| --- | --- |
| Font | The face the map's own text is drawn in: the zone marker labels, and the editor's hint and coordinate readout. `ProggyClean` is ImGui's own built-in font and the default; the rest are read out of `C:\Windows\Fonts` -- Arial, Calibri, Consola, Georgia, Segoeui, Tahoma, Times, Verdana. A face that will not load falls back to ProggyClean |
| Size | Height of that same text in screen pixels, 8 to 48, typed or stepped (±1 by the arrows, ±4 by ctrl-click). It opens showing whatever size ImGui is already drawing at, so a map that has never been near the box looks exactly as it always did |
| Points | Size of the zone point markers, as a percent |
| Nations | Size of the nation art on the world overview, as a percent |
| Tools | Height of everything on the search box's line — the past/present switch, the layer toggles, Instant Warp, Warp Ring and the search box itself, text included — and of the Favorites and Multisend icons in the bottom corners. The widths follow from each piece of art's own shape |
| Search W | Width of the search box. It will not grow into the room the toolbar icons beside it need. A large **Tools** still can: the row does not wrap, so icons sized past the viewport run off its edge |
| Text | The map's text itself. Black by default |
| Outline | The stamp behind that text that keeps it readable over the art. White, half alpha |
| Background | A plate drawn under it. Fully transparent by default, i.e. off -- raise its alpha for a solid label instead of an outlined one |
| Hover | Fill under the row the cursor is on: warp rows, favorites and the right-click menu. White, near-transparent |

The four scale rows are whole percents, 25 to 400, typed or stepped (±5 by the arrows, ±25 by ctrl-click). 100 is what the map has always drawn at, which is what a settings file that has never been near them carries.

The warp, favorites and right-click panels are ImGui widgets rather than map text, so they keep Ashita's own font and size; **Font** and **Size** move the text drawn onto the map itself.

Each picker has an alpha bar, so a colour can be faded rather than only changed; click a swatch to open the picker, and drag inside it to watch the map change under it. Dragging anywhere on the panel does not pan the map underneath.

Everything on the panel is yours alone and is saved with the rest of the per-character settings, so recolouring or resizing your map changes nothing anyone else sees.

## Scroll pickup

Walk within 7 yalms of an **EXP Guide** or **EXP Guide (S)** carrying no Instant Warp scroll and with a free inventory slot, and one is asked for and taken without you stopping: the guide is poked with the same packet pressing its target sends, and Escape backs out of the talk the scroll arrives in.

`/um guide` turns the pickup off, and it is on by default. All three have to be true — no scroll (4181) in the bag, a slot free for one, a guide in reach — and they get **one** poke between them. Any of the three going false arms the next one, so spending a scroll or walking off and back asks again, while standing at a guide that answered with nothing does not: it is given up on after five seconds and then left alone. So the packet count is one per scroll you actually collect, on no timer of its own.

The guides stand in **Ru'Lude Gardens** and **Lower Jeuno**, and the zone is checked before anything else.

## Gamepad favorites widget
<img width="414" height="118" alt="image" src="https://github.com/user-attachments/assets/eeb0dc76-6626-4547-a3e2-79f9441dd8ef" />

`/um widget` turns on a small window listing the same favorites, built for a controller. It comes up on its own the moment you walk up to a Home Point, Survival Guide or Unity Concord — map open or not — and goes away the moment you walk off. Never wider than that, because it swallows the buttons it reads and the D-pad belongs to the game's menus everywhere else.

| Button | Effect |
| --- | --- |
| D-pad up / down | Move the selection, wrapping at both ends |
| A | Warp to the selected row |
| B | Put the widget away until you walk off the NPC |

**Y** is left to the game while the widget is up: its rows are already favorites, so there is nothing for the menu to add.

The widget and the map's panel are one list drawn twice, so the mouse works the same in either: click a row to warp, drag it up or down to reorder, right-click for *Remove point from favorites list*. Turning the widget on hides the heart and its panel, so the list is on screen in one place, not two.

The list is narrowed the same way the panel's is, so every row on it is one the NPC holding it up can send; a destination you have not registered still reads red, and A refuses it. With nothing saved for that kind of NPC the widget stays down. The window has no title bar and sizes itself to the list; like the map, hold shift to drag it somewhere else. Off by default, and saved per character with the rest of the settings.

XInput only: an Xbox pad, or anything Windows presents as one. A DirectInput controller (DualShock, DualSense) still works by mouse.

## Gamepad map navigation

The map itself reads the pad whenever it is open — no toggle, because unlike the widget it is somewhere you deliberately went. Press any of its buttons and the marker nearest the middle of the view is hovered; from then on it is hovered the moment the map opens, and again each time **A** frames a nation, so there is always something on screen saying what the next press would act on.

| Button | Effect |
| --- | --- |
| D-pad | Move the hover to the marker that way. Nothing that way, nothing moves — it does not wrap round the world |
| A | Zoom into the nation or region under the hover, then open a zone point's warp list, then send the row |
| B | Back out one step: the warp list, then the whole map with the nation you came out of still hovered, then the map closes |
| Y | The pad's right-click: on a warp row it opens the same *Add / Remove point from favorites list* menu the mouse's second button does. **A** picks the item, **B** or a second **Y** dismisses it |

Three tiers, nested the way the game's own menus are, and the mouse walks the same ones: click a nation and **B** still backs out of it, click a zone point and the D-pad still walks the rows that come up. A list opened with the mouse lights no row until you press something, so the cursor's own hover is never argued with.

Only one of the two is ever in charge, and it is whichever you last used — the pad being plugged in counts for nothing. Move the mouse over the map or the widget and the pad's hover goes out, since the cursor's own hover now says what a click would open. Press one of the map's own buttons and it comes back on the marker nearest the middle again — that first press only relights, it does not walk or open.

The favorites widget wins while it is up. Walk to a Home Point with the map open and the widget takes the pad; dismiss it with **B** and the map answers again. The rows behave the same either way — a destination you have not registered reads red, a row saved off a different kind of NPC reads grey, and **A** refuses both.

## Filters set themselves

Stand at a warp NPC and the map narrows to it: only that kind of row stays lit, since it is the only one you can travel on from there. Walk away and all three light again. Your own clicks are not overridden — a toggle you set by hand stands until you move to a different kind of NPC.

A dimmed filter reaches the map itself: a zone marker with no row left fades back the way an unfocused group does and stops taking the cursor. Dim **Guide** and **Unity** and only Home Point zones stay lit.

The Multisend gate, your favorites, the three toggles and everything on the config panel are saved per character in `config/addons/UberMap/<name>_<server id>/settings.lua` the moment you change one.

## Credits

- Thorny — [Uberwarp](https://github.com/ThornyFFXI/Uberwarp) and
  [Multisend](https://github.com/ThornyFFXI/Multisend)
- The [FFXI Remapster Project](https://remapster.com/)

## License

MIT. See [LICENSE](LICENSE).
