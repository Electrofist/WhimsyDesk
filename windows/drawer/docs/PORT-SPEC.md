# Desktop Drawer for Windows: behaviour spec

The Windows drawer is a Rust port of `objects/drawer` (Swift, macOS). This file is the spec it follows. Every number comes from the Swift sources in `objects/drawer/Sources/DesktopDrawer`. When the two disagree, the Swift code wins and this file should be fixed.

Source map: `DrawerController.swift` (window, physics, system events), `DrawerView.swift` (artwork, layout, mouse, drag and drop, menu), `DrawerStore.swift` (files and index), `Material.swift` (wood and felt textures), `SoftSound.swift` (sounds).

Units: design points, origin top-left, y down (the Swift view is flipped). Actual pixels = points x `scale`, where `scale` is the monitor DPI scale. There is no user resize in the Mac drawer, so there is none here.

## 1. Window

- Artwork size: `viewWidth` 780 x `viewHeight` 300 pt. Built from `width` 720, `margin` 30 (shadow room each side), `topPad` 16, `faceHeight` 60, `interiorHeight` 224.
- The artwork is rendered once per scale into a fixed 780 x 300 bitmap and never redrawn while sliding. It only redraws when the file list changes or light/dark mode changes.
- The window shows only the visible slice: `height = topPad + faceHeight + position x interiorHeight`, minimum `topPad + 8`, rounded to whole pixels. The artwork is pinned to the TOP of the window and shifted up as the window shrinks. `sag` is 1.5 pt when the drawer holds any item, else 0, and shifts the artwork down.
- Position on screen: horizontally centred on the primary monitor (`x = monitor centre - 390`). The window's bottom edge sits on the bottom of the work area, so it rises from above the taskbar. Re-place on display changes.
- Borderless, transparent, never takes focus, no taskbar button, not in Alt-Tab, on every virtual desktop. Same window recipe as `windows/fridge` (layered window kept at `HWND_BOTTOM`, above the desktop icons, below normal windows). Clicks on fully transparent pixels fall through.
- Quitting only from the right-click menu.

### Shadows (drawn into the visible slice each frame, with `p = clamp(position, 0, 1)`)
- Cast shadow of the visible outline: the front panel (rounded rect, corner radius 4) plus, if the panel is above the bottom, the cabinet slot (`x = margin + boxInset` = 46, width `720 - 2 x 16` = 688, from the window bottom up to `faceBottom + 2`). Radius `7 + 9p`, opacity `0.34 + 0.16p`, offset down by `3 + 5p`.
- Cabinet darkness: a vertical black gradient over the slot, height `min(60, faceBottom)`, alpha 0.85 at the bottom edge, 0.35 at 30% of the way up, 0 at the top.

## 2. Art (drawn in code, no image assets)

Port `Material.swift` and the drawing functions in `DrawerView.swift` (`drawBox`, `drawFloor`, `drawDust`, `drawEmptyHint`, `drawItems`, `drawFace`, `drawCupPull`). Compare against the Mac screenshot (`objects/drawer/media/closed.png`); exact pixels need not match.

Themes (switch with Windows light/dark mode):

| | front wood | box wood | felt | metal (top to bottom) | dust | label alpha |
|---|---|---|---|---|---|---|
| light | oak | birch | 0x2F4A3B | 54585A 8F9496 F4F6F6 B4B8BA 4A4D4F (nickel) | E6E0D3 | 0.95 |
| dark | walnut | walnutPly | 0x2A2A2D | 4A3510 9C7A34 F3D892 C09A4C 3E2C0E (brass) | B9B1A2 | 0.88 |

Woods (`base, dark, light, worn`): oak B48659 6E4B2C D3AE80 E4CCA6; birch CDAE84 8F6E48 E3CBA5 EEDDC0; walnut 53331F 24140B 775036 9C7656; walnutPly 6E4C34 3B2516 8B6649 A88768.

Seeded random (`Material.swift` `RNG`; note it is NOT the fridge's SplitMix):
```
state = (seed + 1) * 0x9E3779B97F4A7C15        (wrapping)
next: state ^= state << 13; state ^= state >> 7; state ^= state << 17
      return (state >> 11) / 2^53
range(a, b) = a + (b - a) * next
```

## 3. Geometry

- `faceRect` = (30, 16, 720, 60). `boxRect` = (46, 68, 688, 232). `wallTop` 5, `floorTop` = 76, `floorBottom` = 300 - 5 - 5 = 290.
- Floor is a trapezoid narrowing towards the back: top edge from `x = 46+5+9` to `734-5-9` at `floorTop`; bottom edge from `46+5+5` to `734-5-5` at `floorBottom`.

## 4. Item layout (`relayout`)

- Icon size 52, label width 76 x 16.
- `perRow` = 8 if count <= 8, else `max(5, ceil(count / 2))`. At most two rows are expected; more items keep wrapping every `perRow`.
- `areaX` = 46 + 28 = 74. `step = min(80, (688 - 56 - 76) / (perRow - 1))` (items overlap when crowded).
- For item `i`: `row = i / perRow`, `col = i % perRow`, `cx = areaX + 38 + col x step`, `top = 76 + 26 + row x 92`. Icon rect `(cx - 26, top, 52, 52)`. Label rect `(cx - 38, top + 57, 76, 16)`.
- Order: by date added to the folder (fallback modified date), oldest first.
- Tilt: item `i` is rotated by `sin(i x 12.9898 + 1.7) x 3.5` degrees about its centre.
- Contact shadow: dark oval under the icon, rect `(left + 6, bottom - 8, width - 12, 10)`, alpha 0.45. Icon drop shadow: offset (0.5, 2.5) down, blur 3.5, alpha 0.55.
- Label: 10.5 pt semibold, white at the theme's label alpha, centred, truncated in the MIDDLE, soft black shadow. Use the Windows system UI font.
- Item being dragged out is drawn at alpha 0.3.
- Hit test: topmost (last) item whose icon rect inflated by 4 pt, or label rect, contains the point.
- Empty drawer shows a faint hint text (`drawEmptyHint`).
- Item icons come from the Windows shell (`SHGetFileInfo` / `IShellItemImageFactory`), like the fridge.

## 5. Sliding physics (`DrawerController`)

State: `position` (0 closed, 1 fully open, slightly negative = pressed into the bumpers), `velocity` in full-travels per second.

Constants: `interactiveThreshold` 0.6, `driftZone` 0.16, `driftAccel` 0.9, `viscous` 3.0, `coulomb` 1.2, `bumperStiffness` 1500, `bumperDamping` 48, `bumperLimit` -0.05, `stopRestitution` 0.22, `handStiffness` 240, `handDamping` 27.

Frame: `dt` = frame time clamped to [1/240, 1/20] s; `substeps = ceil(dt x 480)`; run `step(dt / substeps)` that many times, then update the window and sound.

`step(dt)`:
1. `wasOut = position >= 0`.
2. If grabbed: `velocity += (handStiffness x (grabTarget - position) - handDamping x velocity) x dt`.
   Else: `velocity *= exp(-viscous x dt)`. If `driftActive`: `velocity -= driftAccel x dt`. Else if `position > 0` and `velocity != 0`: subtract `coulomb x dt` toward zero (if `|velocity| <= coulomb x dt` set 0). If a file drag is in progress and `velocity < 0`, set `velocity = 0`.
3. If `position < 0`: `velocity += (-bumperStiffness x position - bumperDamping x velocity) x dt`.
4. `position += velocity x dt`.
5. If `wasOut`, `position < 0`, `velocity < 0`: play the close knock, volume `min(0.6, 0.1 + (-velocity) x 0.16)`.
6. If `position < bumperLimit`: `position = bumperLimit`, `velocity = max(0, velocity)`.
7. If `position >= 1`: `position = 1`; if `velocity > 0`: play the open knock (volume `min(0.45, 0.08 + velocity x 0.14)`) only if `velocity > 0.12`; then `velocity = grabbed ? 0 : -velocity x stopRestitution`.
8. If not grabbed: if `|position| < 0.002` and `|velocity| < 0.05`: snap `position = 0`, `velocity = 0`. Else if `position > 0`, not drifting, and `|velocity| < 0.004`: `velocity = 0`.

Definitions:
- `driftActive` = `0 < position < driftZone`, no file drag in progress, not grabbed, not in battery saver. (A barely-open unattended drawer is pulled shut.)
- `needsMotion` = if grabbed: `|grabTarget - position| > 0.0005` or `|velocity| > 0.001`; else `velocity != 0` or `driftActive` or `position < 0`.
- `isInteractive` = `position >= 0.6` (items usable, drops accepted).
- Knock sounds are rate-limited: at most one per 0.35 s.

Input:
- Press on the front panel: `isGrabbed = true`, `grabTarget = position`, remember the grab offset (distance from the window's top edge to the mouse). Drag: the window top follows the mouse; `grabTarget = clamp((work.bottom - windowTopY - 76) / 224, -0.02, 1)` where `windowTopY = mouseY - grabOffset` in screen y-down. Read the mouse with `GetCursorPos`, not window-relative coordinates, because the window moves under the mouse. Release: `isGrabbed = false`, `velocity = clamp(velocity, -6, 6)`; the drawer keeps its momentum.
- Double-click the front panel: `toggle`. If `position > 0.5`: `velocity = -launchSpeed(position + 0.05)`; else `velocity = launchSpeed(1 - position + 0.04)`.
- `launchSpeed(d)`: initial speed that coasts exactly `d` travels under viscous plus dry friction. Stopping distance for speed `v` is `v/k - (c/k^2) x ln(1 + k v / c)` with `k = viscous`, `c = coulomb`. Bisection on `v` in [0, 30], 40 iterations, return the upper bound.
- A file hovering over the drawer while `position < 0.6`: `velocity = max(velocity, launchSpeed(1 - position + 0.03))` (spring-loaded open). While a file drag is in progress (in or out) the drawer never moves toward closed.
- After a drop completes: play the close knock at volume 0.25.
- Cursor: open hand over the front panel, closed hand while grabbing, arrow elsewhere.

Quiet at rest: no timer, no polling, no sound engine while the drawer is not moving. The frame clock (reuse `win/ticker.rs`) runs only while `needsMotion`.

Battery saver (Mac: Low Power Mode): drift off, frame rate 30 instead of 120/display rate.

Pause on screen lock, system sleep, display off: stop the clock, set `velocity = 0`, keep the position; if `position < 0` set it to 0. Resume on unlock/wake (drift continues if it was barely open). Nothing is forced shut.

## 6. Files (`DrawerStore`)

- Folder: `%USERPROFILE%\Desktop Drawer` (created if missing). Index: `%APPDATA%\WhimsyDesk\Desktop Drawer\index.json`, a map from stored file name to `{ originalName, originalDirectory, desktopPosition? }`. Written atomically.
- `reload` (at launch and each time the drawer opens past 0.6): list the folder, skip hidden files, sort by date added; forget index entries whose files are gone.
- `stash(paths)`: for each path: skip if already inside the drawer folder; skip if it is an ancestor of the drawer folder; remember its parent folder, and its Desktop icon position if the parent is the Desktop; move it into the drawer using a unique name (`name 2.ext`, `name 3.ext`, ...); record the index entry. Files are moved, never copied or deleted. If a move fails, log it and continue with the rest.
- `putBack(names)`: move each file to `originalDirectory` if that folder still exists, otherwise the Desktop, under a unique name based on `originalName`; drop the index entry; if it lands on the Desktop and a saved position exists, restore the icon position (best effort, retry up to 6 times, 0.2 s apart; reuse the fridge's `shell.rs` Desktop icon code).
- `moveAllToDesktop`: same as put back but always to the Desktop; returns how many failed.
- All disk work happens off the UI thread; the file list is read on the UI thread only. The fridge's `core/src/store.rs` already has `unique_path`, `move_item`, `write_atomic` and index handling: reuse it and drop the fridge's slot limit (the drawer has none).

## 7. Mouse, drag and drop, menu

- Press on an item (only when interactive): remember it. Moving more than 4 pt starts dragging that file out (OLE drag, like `win/dnd.rs`); the item fades to alpha 0.3 until the drag ends. Double-click an item: Put Back that item.
- Dragging out: the destination may move the file a moment later, so reload on drag end and again 0.6 s later if the drop was accepted.
- Dropping in: accept only files, only when interactive, and never from the drawer itself. Answer "no effect" and move the files yourself afterwards (as the fridge does), so the source never deletes anything.
- Right-click menu:
  - on an item: "Put Back on Desktop", "Show in Explorer", separator
  - always: "Put Everything Back", "Open Drawer Folder", separator, "Move Everything to Desktop" (disabled when empty; asks "Move everything to your Desktop?" with a count first; afterwards reports "N files could not be moved. They are still in the drawer." if any failed), then "Quit Desktop Drawer".

## 8. Sounds (all synthesized, no audio files)

Knocks, rendered once to 44.1 kHz mono 16-bit PCM (peak 24000):
```
close: duration 0.26 s; modes (freq Hz, decay/s, amp): (98,20,1.0) (214,30,0.42) (377,48,0.22) (611,75,0.10)
       hits (start s, gain): (0, 1) and (0.062, 0.22); impact noise factor 0.5
open:  duration 0.16 s; modes: (176,38,0.7) (402,60,0.35) (835,95,0.16); hits: (0, 1); impact noise factor 0.7
per sample (t = time):  noise = LCG white in [-1, 1], seed 12345, x = x*1664525 + 1013904223 (u32 wrapping)
  soft += 0.12 * (noise - soft)
  for each hit with t >= start: u = t - start; attack = min(1, u / 0.0018)
    body = sum(sin(2 pi f u) * exp(-u * decay) * amp)
    impact = soft * exp(-u * 160) * factor
    sample += (body * 0.55 + impact) * attack * gain
```
Slide rumble: filtered noise whose loudness follows speed, only while moving.
`target = min(1, speed x 0.5) x 0.22` with `speed = |velocity|` while grabbed or `position > 0`, else 0. Per sample at 44.1 kHz: `level += (target - level) x 0.0012`; `white` = LCG noise (seed 0x2545F491, same LCG); `rumble += 0.03 x (white - rumble)`; `scrape += 0.22 x (white - scrape)`; `wobble += 0.0004 x (white - wobble)`; if `white > 0.99975` then `catchEnv = 1`; `catchEnv *= 0.9965`; `sample = (rumble x 2.4 x (1 + wobble x 40) + (scrape - rumble) x 0.16 + catchEnv x scrape x 0.6) x level`. Stop the audio device 0.35 s after the drawer comes to rest.

## 9. Not in the Mac drawer (do not add)
No settings file, no resize, no notes, no fog, no slot limit, no start-with-Windows (the fridge has it; add later only if the author wants it).

## 10. Build plan (workspace `windows/drawer/`: `core`, `art`, `app`, same as the fridge)
1. `core`: physics (section 5), layout (4), store (6), RNG, with unit tests ported from the ideas in `objects/drawer` and checked by hand against this spec. Runs on any OS.
2. `art`: wood, felt, face, cup pull, floor, items; render PNGs and compare with the Mac screenshot.
3. `app` window: layered window, slice rendering, sliding by mouse and double-click, knock sounds. First test on a real PC.
4. Files: drop in, drag out, Put Back, menu, desktop icon positions.
5. Slide rumble sound, lock/sleep/battery saver, light/dark mode, README, installer script, `object.json` is not needed (that file is for Mac objects), docs.
