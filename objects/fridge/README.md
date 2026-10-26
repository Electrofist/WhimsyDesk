# Desktop Fridge

A skeuomorphic fridge that lives on your macOS desktop. Drag files in, shut the door, forget about them.

## Build and run

- Needs macOS 14 or later and Xcode 15+ (or the Command Line Tools: `xcode-select --install`)
- From this folder: `./build.sh run`
- The app lands in `build/DesktopFridge.app`
- First build has never been compiled by the author. If the compiler complains, send the error text back.

## Use it

- Grab the door anywhere and pull sideways to swing it. It stays where you leave it, and only drifts shut when barely open
- Double-click the door to swing it open or shut
- Drag a file or folder from the desktop onto the fridge. The door swings open by itself; drop it on a shelf
- It moves into `~/Fridge`. Position and timestamp are kept in `~/Fridge/.fridge-index.json`
- Double-click an item to open it. Take it out by dragging it onto the desktop or any folder, or right-click it and choose Put Back to return it where it came from
- Hold ⌥ (Option) and drag to resize the fridge: up or right grows it, down or left shrinks it. The feet stay put
- Hold ⌥⌘ (Option-Command) and drag to move the fridge. Size and position are remembered
- Right-click for Quit and Open Fridge Folder
- First time you store a file from the Desktop, macOS asks for Automation access to Finder. Say no and everything still works, only the exact icon position is not restored

### Sticky notes and photo magnets

⌘ (Command) is the "stick it on the door" key for clicks. Drops need no key. All of it works on a shut door.

- ⌘-click the door: a new sticky note, ready to type on. Return finishes it, ⌥Return adds a line, Esc throws a new note away
- Double-click a note to rewrite it
- ⌘-click a note to change its color. ⌘-drag to move it. ⌘-drag it off the door to peel it off
- Drop a picture on the door: it is pinned under a magnet. The original stays where it was; a small copy goes in `~/Fridge/.magnets`
- Want the picture inside instead? Hold it over the door for a moment and the door springs open, like a spring-loaded folder
- Drop text on the door: it becomes a note
- Right-click a note or photo for Edit, Color, Peel Off, Open Original and Take Photo Down
- Notes live in `~/Fridge/.fridge-notes.json`, up to 16 per door

## Check the frost

Frost builds over days. To see it quickly, run with time sped up:

`FRIDGE_TIME_SCALE=3600 build/DesktopFridge.app/Contents/MacOS/DesktopFridge`

Now one real minute counts as 60 hours.

## Layout

- `Sources/FridgeCore`: door physics, frost model, `~/Fridge` store, shelf math. Foundation only
- `Sources/DesktopFridge`: window, layers, art, fog, sound, lock and sleep handling
- `Tests/FridgeCoreTests`: run with `swift test`
- `tools/sim_door.py`: the physics model in Python, used to tune the constants
- `tools/gen_fog.py`: regenerates the 40 fog frames and the asset catalog
- `tools/gen_sounds.py`: regenerates the two sounds

## Battery

- Closed fridge: no timers, no display link, no polling
- Display link runs only while the door moves, 120 Hz while held or fast, 60 Hz while drifting shut
- Fog is a Core Animation frame swap run by the render server, skipped in Low Power Mode and with Reduce Motion
- Frost is computed once per open and baked into the item bitmap
- Lock, screen sleep and system sleep pause everything and leave the door where it is
