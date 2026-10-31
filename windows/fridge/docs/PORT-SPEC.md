# Desktop Fridge for Windows: behaviour spec

The Windows fridge is a Rust rewrite of `objects/fridge` (Swift, macOS). This file is the spec it follows. Every number here comes from the Swift sources (paths relative to `objects/fridge`). When the two disagree, the Swift code wins and this file should be fixed.

Coordinates: points, origin bottom-left, y up, as in AppKit. "Scene" space has its origin at the bottom-left of the cabinet body. View (window) coordinates = scene + body origin (190, 170).

Notes on the source:
- The fridge has no colour themes. The only "Color" menu is the sticky-note colour. The fridge changes only with light and dark mode.
- `tools/sim_door.py` is out of date. Port `Sources/FridgeCore/DoorPhysics.swift`.
- Reconcile with disk runs only at launch. There is no file watcher.
- Three Swift door tests do not match the Swift physics, and the port follows the physics: an ajar door closes in about 2.5 s (test says 4 to 8 s); the item-drag lock parks a door near 31° (test says 34 ± 1°); double-click swings coast on to the 105° stop.

## 1. Window

- Design size 520 x 800 pt. Actual size is `round(520·scale) x round(800·scale)`, user scale 0.45 to 1.6. Geometry and hit tests stay in design points.
- Body rect in the window: origin (190, 170), size 280 x 563. The window is larger than the fridge so the open door, fog and shadows fit.
- Borderless, transparent, no system shadow, never activates (except while a note is edited), allowed to hang off screen.
- Level: above the desktop icons, below every normal window. On Windows: layered window kept at `HWND_BOTTOM`, re-asserted on `WM_WINDOWPOSCHANGING`. Do not parent into WorkerW (that would put it behind the icons).
- Click-through: fully transparent pixels pass clicks through (layered window with per-pixel alpha does this).
- Shown on every virtual desktop, not in the taskbar or Alt-Tab (`WS_EX_TOOLWINDOW`, `WS_EX_NOACTIVATE`).
- Quitting only from the menu.

Placement:
- Saved origin is used if the body rect intersects any monitor.
- Otherwise default: on the primary monitor's work area, body right edge 36 pt from the right, feet 24 pt above the bottom. `x = work.right − 190 − 280 − 36`, `y = work.bottom + 24 − 170` (in y-up terms).
- On display changes, if the body is off every monitor, re-place at the default.

Moving and resizing (Mac modifiers → Windows modifiers):
- Mac ⌥⌘-drag = move. Windows: Ctrl+Alt+drag. The window follows the mouse; a lift shadow fades in (0.15 s) and the scene rises 4 pt; position saved on release.
- Mac ⌥-drag = resize. Windows: Alt+drag. `d = dy_up + 0.5·dx`, `scale = startScale·exp(d/320)`, clamp 0.45…1.6, feet stay planted at view point (330, 170). Re-render art on release; save scale and origin.
- Cursors: open hand over a door, closed hand while dragging a door, note or the window, resize cursor while Alt is held over the fridge, arrow otherwise.

Pause on screen lock, sleep or display off: end note editing, freeze doors, cancel fog, stop sounds. Resume when all reasons clear.

## 2. Art and rendering

Assets (copy from `objects/fridge/Assets`):

| File | Size | Use |
|---|---|---|
| `Door/door_fridge.png` | 872 x 1170, opaque | lower door front, stretched to 272 x 365 pt |
| `Door/door_freezer.png` | 872 x 610, opaque | freezer door front, stretched to 272 x 190 pt |
| `Assets.xcassets/Fog/fog_00…fog_39` | 256 x 192 and @2x 512 x 384, straight alpha | 40-frame fog |
| `Sounds/open_click.wav` | 0.09 s | door opens |
| `Sounds/seal_click.wav` | 0.22 s | door seals |

Everything else is drawn in code at `scale = dpi scale × user scale`, once per scale change, never per frame.

Seeded random (`Art.swift:85-107`), port exactly:
```
state = seed wrapping_add 0x9E3779B97F4A7C15
next: state wrapping_add= 0x9E3779B97F4A7C15; z = state
      z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
      z = (z ^ (z >> 27)) * 0x94D049BB133111EB
      return z ^ (z >> 31)
unit = (next >> 11) / 2^53
range(a, b) = a + (b − a)·unit
```

### Geometry
- Body 280 x 563. Door inset 4. Door split y 369.
- Fridge door frame (4, 4, 272, 365), shelves [0, 1], bins y [36, 146, 256], bottom corners rounded.
- Freezer door frame (4, 369, 272, 190), shelf [2], bin y [46], top corners rounded.
- Door half thickness 9. Door corner radius 24. Bin depth 22, lip 22 (first fridge bin 30), bin inset 26. Hinge plate bottoms y [505, 349, 30].
- Opening (14, 14, 252, 535). Vanishing point in scene (140, 500). Eye distance E = 1150. Cabinet depth 404.
- Shelf front y (opening space) [118, 238, 414]. Shelf x 8 to 244. Row depth [0.25, 0.65]. Base icon 60.
- Angles: interactive on at 40°, off below 36°. "Opened" at 8° (sound, fog, frost; notes only below this). Sealed below 0.6°.
- Fog frames: spill (120, −40+170… see §4), floor; view-space frames below.

### Perspective
For a scene point (x, y, z), z toward the viewer:
```
w = 1 − z/1150
X = 140 + (x − 140)/w
Y = 500 + (y − 500)/w
```
Door point (px from the hinge, py, pz): `x = 4 + px·cos a − pz·sin a`, `y = frame.minY + py`, `z = 9.5 + px·sin a + pz·cos a`. Front face pz = +9, liner pz = −9 (mirrored). Cull faces by projected winding.

Hit testing uses pz = 0 and no 9.5 lift. Door quad = 4 projected corners, convex containment. Over both doors, the more open door wins.

Dragging a door: on press, `doorX = max(70, bisect 24 iterations so sceneX(doorX) = pointer x at mid height)`. While dragging, target angle = 28-iteration bisection on [0, max] putting `doorX` under the pointer.

Shut door front face (notes): z = 18.5. Door space → scene: `s = vp + (frame.min + p − vp)/w`, `w = 1 − 18.5/1150`. Inverse: `p = vp + (s − vp)·w − frame.min`.

### Draw order (back to front)
1. Lift shadow 460 x 150 at (body centre − 230, 87). Opacity 0 except while moving.
2. Contact shadow 380 x 70 centred on the body at y 138.
3. Scene:
   - cabinet, interior, static frost, items
   - per door (fridge, then freezer): darkness (black) and glow over that door's slice of the opening
   - divider (12, 363, 256, 12), radius 3, vertical gradient `#C9D0D2` 0, `#F4F7F7` .35, `#DDE3E4` .7, `#A9B2B5` 1
   - doors, depth sorted: front face (with notes, then front shade), liner (back shade), free edge strip, bins
   - 3 hinge plates at z 20, x −1.2, 13 x 40
4. Fog above everything.
5. Note editor while editing.

Slices (opening space): fridge y 0…355, freezer y 355…535.

Bins (door local, liner at pz −9, only drawn when open):
- Floor 220 x 22, pz −9 to −31, colour (0.86, 0.93, 0.96, 0.95), 1 pt border white .8.
- Lip 220 x lipH at pz −31, vertical gradient (0.97,0.99,1,.96) 0 → (0.80,0.90,0.95,.90) .55 → (0.66,0.80,0.88,.92) 1, radius 3, border white .9.
- Cheeks at px 26 and 246, 22 x lipH, colour (0.78, 0.88, 0.93, 0.92).

Free edge: 18 pt strip at px = width − 2, height = door height − insets (12 at a rounded end, 1 where doors meet): fridge 352, freezer 177. Radius 7.2. Gradient front → liner: `#505006` 0, `#9DA716` .10, `#E4E57A` .28, `#B6BD21` .55, `#7D8202` .72, `#2B2E2A` .76, `#3A3D38` 1.

Door lighting each frame, `light = smoothstep(3°, 28°, angle)`:
- front shade opacity `(1 − cos a)·0.40`
- back shade opacity `(1 + cos a)·0.12`
- darkness opacity `darknessPeak·(1 − light)`
- glow opacity `light`

### Art recipes
Cabinet (280 x 563):
- Feet: rounded rects x 22 and 230, y 0, 28 x 14, r 4, `#262A2D`.
- Body (0, 8, 280, 555) r 28, horizontal gradient `#C9CF3A` 0, `#9DA716` .5, `#6E7303` 1. Clipped: right shade black-green (0.05, 0.12, 0.10) 0 → .34 over the last 16 pt; top highlight white 0 → .55 over the top 12 pt; bottom plinth black .30 → 0 over the bottom 14 pt.
- Liner rim (7, 15, 266, 541) r 14, horizontal gradient `#DDE2E2`, `#F6F8F7`, `#D2D8D9`, stroke black .18 1 pt.
- Opening outline inset −1.5 r 6, stroke (0.3, 0.36, 0.38, .35) 1.2 pt.
- Bevel: black .22 1 pt on the body path, white .45 1 pt at inset 1.2 r 27.

Door front: PNG stretched into the door rect, clipped (r 24 on the outer corners only), fallback fill `#9DA716`. Stroke black .35 1 pt. Inner stroke (1, 1, 0.8, .30) 1 pt at inset 1.3 r 23.

Door liner:
- Vertical gradient `#DCE8EE` → `#F3F8FA`.
- Panel inset 18 r 12, horizontal gradient `#C9D8E0` → `#E6EFF3`, stroke (0.2, 0.3, 0.36, .25) 1.2 pt, white .6 1 pt at inset 19.5 r 11.
- Under each bin y: rect (26, y − 18, 220, 18), gradient (0, 0.1, 0.15) alpha 0 at bottom → .22 at top.
- Gasket: outline inset 7 r 18 stroked `#3A4449` 13 pt; white .18 1.2 pt at inset 10.5 r 15; black .35 1 pt at inset 3.5 r 21. Outer stroke black .25.

Hinge (drawn on 20 x 64, scaled to 13 x 40): plate (1, 2, 18, 60) r 4, fill `#9AA9A3`, shadow (1, −1.5) blur 2.5 black .5; steel gradient `#6D7E78` 0, `#F2F8F6` .35, `#B0C0BA` .7, `#72847D` 1; stroke black .35 0.8. Knuckle lines at y 22, 32, 42 (x 2 to 18) black .3 0.8. Screws 6 x 6 at y 10 and 54, x centre 10, `#5A6B65`, white .6 slot.

Shadows:
- Contact (380 x 70): radial black .55 → .22 at .55 → 0, radius 190, squashed y x 0.18. Plus AO: .70 → .30 at .8 → 0, radius 146, y x 0.06, 1 pt higher.
- Lift (460 x 150): radial .42 → .18 at .5 → 0, radius 230, y x 0.30.
- Item (64 x 18): radial (0, 0.05, 0.1) .55 → .22 at .6 → 0, elliptical.

Interior (252 x 535), corners via `project(x, y, depth)`:
- Base `#9DB8C2`. Floor gradient `#9DBAC5` front → `#D3E4EA` back. Floor sheen quad (30,0,0)(110,0,0)(120,0,1)(60,0,1) white .10.
- Left wall `#B5CFD8` → `#DCEAF0`. Right wall `#A9C5CF` → `#D6E6EC`. Back wall vertical `#E0EEF3` → `#F6FBFD`.
- Corner seams (0.1, 0.25, 0.32, .22) 1.4 pt round cap.
- Per shelf: rails 3 pt (0.1, 0.25, 0.32, .35) plus white .45 1 pt 2 pt above; glass top fill (0.80, 0.93, 0.97, .9) with shadow (0, −5) blur 9 (0, 0.1, 0.18, .32), then gradient (0.86, 0.97, 1, .92) front → (0.70, 0.88, 0.95, .88) back; glare quads white .20 (front x+40 → +78, back x+70 → +48) and white .12 (+130/+150, +138/+124); front lip 7 pt below the front edge, gradient (0.45, 0.72, 0.80, .95) → (0.75, 0.93, 0.98, .98) .5 → (0.96, 1, 1, 1), bottom line (0.1, 0.3, 0.38, .45) 0.9 pt; back edge white .55 1 pt.
- Vignette: radial centre (126, 278.2) radius 363.8, clear until .62, (0, 0.05, 0.1, .30) at 1.

Static interior frost (seed `0xF2057ED`, above interior, below items): grain along seams (`count = int(length·2.6)`, reach 20, colour (0.95, 0.99, 1)), 90 six-armed ferns (arm 2 to 5.5, 0.6 pt, white .25 to .6) within ±7 pt of seams, 70 beads on the back wall (r 1.1 to 3, fill (0.82, 0.94, 1, .2), stroke white .42 0.6, white .85 highlight). Opacity 0.95 dark mode, 0.80 light mode. Follow `InteriorArt.swift:146-219` for exact draw order.

Light and dark mode (Windows: `AppsUseLightTheme`):
- Dark: glow (0.08, 0.80, 1.0, 0.46) → clear, darkness peak 0.48, frost 0.95.
- Light: glow (0.55, 0.85, 0.96, 0.28) → clear, darkness peak 0.60, frost 0.80.
- Glow: radial over each slice, centre (0.5, 0.82) of the slice, radii 0.65·w and 0.82·h.

## 3. Door physics

Units radians, rad/s, inertia 1. Angle 0 closed, positive open.

Constants: freeDamping 1.6, hingeFriction 0.9, driftZone 22°, driftTorque 0.16, driftDamping 2.2, handStiffness 150, handDamping 19, maxAngle 105°, stopStiffness 900, stopDamping 42, maxStopDamping 34, magnetRange 7°, magnetStrength 14, itemFloor 34°, itemFloorStiffness 18, itemFloorDamping 6.

Step: fixed h = 1/240 s with an accumulator, frame delta clamped to [0, 0.05]. Semi-implicit Euler: `v += torque·h`; if not held and driftZone ≤ angle ≤ maxAngle, dry friction `0.9·h` toward zero (never reversing); `angle += v·h`.

Torque:
```
if held: t = 150·(clamp(target, 0, max) − a) − 19·v
else:    t = −1.6·v
         if !itemDrag:
            if 0 < a < 22°: fade = min(1, (22° − a)/4°); t −= 0.16·fade + 2.2·v·fade
            if a < 7°: x = 1 − max(a, 0)/7°; t −= 14·x²
if a < 0:     t += 900·(−a) − 42·v
if a > 105°:  t += −900·(a − 105°) − 34·v
if itemDrag && a < 34°: t += 18·(34° − a) − 6·v
```
At rest: |v| < 0.01 and either (not held, in the friction zone, |t| < 0.9) or |t| < 0.005. Visual angle = clamp(angle, 0, max + 0.2).

Driver: runs only while not at rest. Frame dt ≤ 0 or > 0.1 becomes 1/60. 120 Hz while held or |v| > 0.9, else 60 Hz. `hold(target)`, `release()` (keeps momentum), `swing(to)` (invisible hand, lets go within 1.5°), `set_item_drag(bool)`.

Interaction:
- Press on a door, drag beyond 3 pt: hold at the current angle, target follows the pointer. Release keeps momentum. A plain click does nothing.
- Double-click a door: if angle > 30° swing to 0, else swing to 96°.
- Each frame: crossing above 8° the first time → play open_click, re-bake item frost, play fog. Below 0.6° after opening → play seal_click. Interactive: on at ≥ 40°, off below 36°; open shelves = shelves of interactive doors.
- Item drag lock applies only to doors that have opened (plus a door being sprung open).
- Files hovering over a compartment (or its door) when not full: spring that door to 96° with the lock.

## 4. Fog

- Trigger: a door passes 8°. Not while already playing. Skipped with reduced motion. Low power: every other frame at 1x, no shadow.
- Two plumes in view coordinates, each 1.7 s, 40 frames evenly spaced:
  - spill: frame (120, 130, 420, 315), starts at once
  - floor: frame (90, −40, 480, 360), starts after 0.18 s, mirrored horizontally
- Shadow (not low power): colour (0.10, 0.20, 0.30), opacity 0.22, blur 9, offset (0, −5).
- Cancel on lock or sleep.

## 5. Frost on items

- `frost = 1 − exp(−t/(2 days))`. `burn = smoothstep(u)·0.55`, `u = clamp((t − 2 d)/(19 d), 0, 1)`. `t = max(0, now − placedAt)·timeScale`.
- `bucket = round(frost·8)·16 + round(burn·8)`.
- Re-bake only when a door opens past 8°, only items whose bucket changed. A scale change resets items to unfrosted until the next opening.
- Bake (item bitmap = icon plus 7% padding per side, premultiplied):
  1. frost < 0.03 and burn < 0.02: untouched.
  2. Per pixel with alpha > 0: desaturate toward luma (.299, .587, .114) by `burn·0.85`; tint toward (0.78a, 0.91a, 1.00a) by `burn·0.16`; haze toward (a, a, a) by `frost·0.50·max(0, 1 − 1.35·ty)^1.7`, ty = y/(h − 1) from the top.
  3. Specks: `int(frost·w·h·0.014)`, seed = item seed, x = range(0, w), y = int(unit()²·h), only where alpha ≥ 200, blend to white by range(0.4, 0.9).
  4. burn ≥ 0.05: glow of blur `w·0.035` px, colour (0.80, 0.94, 1.0, burn·1.4).

## 6. Files

- Folder `%USERPROFILE%\Fridge` (created if missing; env `FRIDGE_ROOT` overrides). If it cannot be created, show an error and quit.
- Index `.fridge-index.json`, atomic write, pretty, sorted keys, ISO 8601 dates in UTC seconds, optional fields omitted:
```json
{ "items": [ { "id": "UPPERCASE-UUID", "originalPath": "C:\\Users\\x\\Desktop\\a.txt",
  "originalX": 120, "originalY": 340, "placedAt": "2026-10-31T12:00:00Z",
  "shelf": 1, "slot": 0, "storedName": "a.txt" } ], "version": 1 }
```
- Capacity 3 shelves x 2 rows x 4 columns = 24. Local slot s: row = s / 4 (0 front, filled first), column = s % 4.
- First free slot for a preferred shelf: shelves in order preferred, −1, +1, −2, +2…, first free slot wins.
- Anchor: `xFront = 8 + (col + 0.5)/4·236`, then `s = 1150/(1150 + depth·404)`, `X = 126 + (x − 126)·s`, `Y = 486 + (shelfFrontY − 486)·s`, icon size 60·s.
- Item seed = first 8 bytes of the UUID as little-endian u64. Jitter x = range(−3, 3), then tilt = range(−0.045, 0.045) rad.
- Hit rect (ax − p/2, ay, p, p). Icon square p + 2·pad, pad 0.07p, bottom centre at (ax, ay), rotated. Shadow 0.95p x 0.26p at (ax, ay + 1). Order: shelf ascending, back row first, column ascending.
- Icons: shell file-type icon (not a thumbnail).
- Add: slide down from +28 pt over 0.30 s ease-out, fade in 0.2 s. Remove: fade 0.18 s. While dragging out: opacity 0.25.
- Items are clickable only on open shelves.

Drag in: file drops only (strings make notes). Valid when not full, inside the opening and the compartment's door is interactive. Shelf = nearest of that door's shelves. For files directly on the Desktop, read their icon position first. Store errors: already inside, missing source, full (checked before moving). Unique name Finder style: `name.ext`, `name 2.ext`, `name 3.ext`; no extension → `name 2`. Any error beeps.

Drag out: press on an item and move 4 pt starts a shell drag (CF_HDROP, move or copy). Cancel animates back. Doors locked at 34° during the drag. After a drop, check at 0.05 s, 1 s and 3 s whether the file left the fridge; if so forget it.

Double-click an item: open it.

Put Back: missing file → forget. Destination = original folder if it still exists, else Desktop. Unique name from the original name. Desktop icon position restored 0.4 s later if the destination is the Desktop and a position was recorded.

Move Everything to Desktop: confirm ("Move everything to your Desktop?" / "The file in the fridge goes back onto your Desktop." or "All N files in the fridge go back onto your Desktop.", buttons "Move to Desktop" and "Cancel"). Move each to the Desktop with a unique name; restore its position only if it came from the Desktop. Report failures: "1 file could not be moved." / "N files could not be moved.", "It is still in the fridge." / "They are still in the fridge."

Reconcile at launch: drop entries whose file is missing; adopt unknown non-dot names in sorted order into `firstFreeSlot(1)` until full, original path = Desktop\name, placedAt = creation time.

## 7. Sticky notes

- File `.fridge-notes.json`:
```json
{ "notes": [ { "color": 0, "createdAt": "…Z", "door": "fridge", "id": "UUID",
  "kind": "note", "text": "…", "tilt": 0.031, "x": 136.0, "y": 200.0 } ], "version": 1 }
```
  Photos add `"kind": "photo"`, `"photoName"`, `"originalPath"`. x, y = centre in door space. Array order = z order.
- Max 16 per door (notes and photos). Max 90 characters (UTF-16 units).
- Notes need the door shut (< 8°). Mac ⌘ is the "stick key"; Windows uses Ctrl.
- Ctrl-click a shut door away from notes: new note, colour = (last note colour + 1) mod 4 (first is 0), tilt ±0.07 rad, centre kept `size/2 + 6` inside the door, pop-in scale 0.6 → 1.08 → 1 over 0.22 s, then edit. Full door: beep.
- Edit: double-click a note or "Edit Note". Editor over the text rect (7, 6, 56, 51 in the 70 x 70 note), rotated by the tilt, all text selected. Enter finishes, Alt+Enter newline, Esc cancels (a new note is discarded). Clicking elsewhere ends editing. Trimmed; empty new note is removed, empty existing note is kept blank.
- Ctrl-drag a note (3 pt): bring to front, shadow lifts (.45, radius 4, offset (2, −4)) over 0.12 s; follows the pointer. On release, if the centre is outside the door rect + 4 pt, peel it (rotate 0.5 rad, move (10, −26), fade, 0.28 s ease-in) and delete; else clamp and save.
- Ctrl-click a note without moving: cycle colour. Also works on photos (magnet colour).
- Plain clicks on a note work the door. Double-click a photo toggles the door.
- Text dropped on a shut door: new note with that text.

Note art (70 x 70):

| Colour | Paper | Strip |
|---|---|---|
| Yellow | `#FFE873` | `#F2D649` |
| Pink | `#FFB3C7` | `#F297B0` |
| Mint | `#B8F0C8` | `#96DFAD` |
| Blue | `#B5DDFF` | `#92C8F5` |

Vertical gradient strip colour at 0, paper at .35 and 1. Top 10 pt band strip colour at .55. Curl triangle (57,0)(70,0)(70,11) white .32. Border black .10 0.5 pt. Text: handwriting font (Ink Free 11, fallback Segoe Print), ink (0.16, 0.17, 0.22, 0.92), wrapped, last line truncated. Shadow black .32, radius 1.6, offset (0.8, −1.6).

## 8. Photo magnets

- Dropping image files on a shut door (not full): thumbnail with EXIF orientation, longest side 480 px, PNG in `.magnets\<UUID>.png`. Original untouched. Up to 4 per drop, fanned +14 x, −10 y. Colour random 0…3, tilt ±0.049 rad.
- An image hovering on a door for 0.8 s springs it open; then the drop stores the file inside.
- Art: aspect clamped 0.4…2.5, inner longest side 84 pt, border 4, chin 11, plus 7 pt above for the magnet. Paper gradient `#EDEBE6` → `#FBFAF7`, stroke black .14 0.5. Picture aspect-fill in (4, 11, w − 8, h − 15). Gloss white 0 → 0 at .6 → .16 diagonal. Magnet at (w/2, printH − 1) r 6.5, colours `#E8453C`, `#2F7DE1`, `#2DB36B`, `#F2A516`, shadow (0, −1.5) blur 2.5 black .45, radial shine white .65 → .08 at .45 → black .25 at 1.1r.
- At launch, magnets with a missing PNG are dropped. Removing a magnet deletes its PNG.

## 9. Menus

Right-click:
1. On a note (door shut): "Edit Note", "Color" ▸ Yellow / Pink / Mint / Blue (current checked), "Peel Off Note", separator.
2. On a photo (door shut): "Open Original" (only if it exists), "Take Photo Down", separator.
3. On an item (open shelf): "Open", "Put Back", "Show in Explorer", separator.
4. Always: "Open Fridge Folder", "Move Everything to Desktop" (greyed when empty), "Quit Desktop Fridge".

Inputs (Windows):

| Input | Effect |
|---|---|
| Drag | door, or drag an item out |
| Double-click | toggle door, open item, edit note |
| Ctrl-click | new note on a shut door, or cycle a note's colour |
| Ctrl-drag | move or peel a note |
| Alt-drag | resize |
| Ctrl+Alt-drag | move the fridge |

## 10. Sounds

open_click when a door passes 8°, seal_click when an opened door drops below 0.6°, per door. Restart on retrigger. No volume or mute settings. Stop on lock and sleep.

## 11. Settings

Saved in `%APPDATA%\WhimsyDesk\Desktop Fridge\settings.json`: `windowOrigin` (x, y), `fridgeScale` (0.45…1.6, default 1), `timeScale` (frost multiplier, default 1; env `FRIDGE_TIME_SCALE` wins).

Start with Windows: `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` entry.

## 12. Windows equivalents

| macOS | Windows |
|---|---|
| Finder desktop icon position | desktop `IFolderView` (`GetItemPosition`, `SelectAndPositionItems`) |
| `NSWorkspace.open` | `ShellExecuteW` |
| Show in Finder | `SHOpenFolderAndSelectItems` |
| File icon | `SHGetFileInfoW` / `IShellItemImageFactory` (icon only) |
| Lock and sleep | `WTSRegisterSessionNotification`, `WM_POWERBROADCAST` |
| Low Power Mode | battery saver (`GetSystemPowerStatus`) |
| Reduce Motion | `SPI_GETCLIENTAREAANIMATION` |
| Beep | `MessageBeep` |
| Alerts | `TaskDialogIndirect` |

Dev env vars: `FRIDGE_ROOT`, `FRIDGE_TIME_SCALE`, `FRIDGE_DEBUG_ANGLE="fridge,freezer"`.

Power: no timers when idle; the loop runs only while something moves.

## 13. Tests to port

From `Tests/FridgeCoreTests`:
- Door: ajar at 10/15/20° rests in 4 to 8 s under 0.5°; at 30/60/90/105° does not move (±0.01°) for 10 s; from 40° at 1.5 rad/s parks in under 2.5 s above 50° and at most max + 1°; seal stays above −2°; fling from 20° at 10 rad/s peaks 105° to 115°; hand ramp 0 → 60° over 0.15 s peaks 60 to 70° and ends 60 ± 0.2° at 2.5 s at rest; hand target 50° settles in under 3 s within 0.5°; item drag from 45° at −3 rad/s stays above 15° and ends 34 ± 1°; item drag at 70° does not creep; closed at rest; 60 Hz and 120 Hz agree within 0.5° from 80°.
- Store: store moves, records position and shelf, reopen keeps id and path; collision gives `a 2.txt`; restore to original folder, no position off-Desktop; deleted folder falls back to the Desktop; Desktop origin returns its position; 25th item is `full` and the source is untouched; reconcile drops missing and adopts strangers; storing an item already inside fails.
- Frost and layout: zero at t = 0; frost monotonic, above 0.99 at 30 days, never above 1; burn 0 at 1.9 days, above 0.1 at 10 days, 0.55 at 400 days; same bucket at 3 h and 3 h + 60 s, different at 10 days; time scale 100 gives more frost; capacity 24; empty fridge prefers (1, 0); full shelf fans out; full gives none; back row smaller and higher; every slot's icon inside 0…252 and below the next shelf.
