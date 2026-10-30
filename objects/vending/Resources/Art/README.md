# Painted art for the vending machine

Put PNG files here with these exact names and rebuild. Any piece that is missing falls back to the art drawn in code, so you can add them one at a time.

All sizes are in pixels, at 2x. Everything is seen from the front with a little of the right side and the top showing, lit from the top left. Leave everything outside the object transparent.

## The pieces

| File | Size | What it is |
|---|---|---|
| `cabinet.png` | 792 × 1120 | The whole machine without its moving parts: body, sign, feet, and the inside behind the glass with its empty shelves, shelf edges and blank paper labels. The tray opening can be dark. |
| `shadow.png` | 792 × 1120 | Optional. The soft shadow on the ground under the feet. |
| `glass.png` | 424 × 672 | Only the reflections on the window. Mostly transparent. |
| `coil-back.png` | 88 × 88 | The part of one spiral coil behind the file: every loop but the first, shrinking toward the back. |
| `coil-front.png` | 88 × 88 | The first loop of the same coil, which passes in front of the file, with the cut end of the wire. |
| `panel.png` | 176 × 672 | The control panel: steel plate, display frame and all keys up. Leave the display area dark; the code lights it. |
| `keys-pressed.png` | 176 × 672 | Optional. The same panel with every key pushed in. Each key's pressed look is cut out of it. |
| `tray.png` | 336 × 104 | The inside of the pickup tray. |
| `flap.png` | 336 × 104 | The flap over the tray, hinged at its top edge. Make it see-through enough that files in the tray show. |

The app icon is `Resources/AppIcon.icns`.

## Where things go on the 792 × 1120 canvas

Measured from the top left corner, in pixels.

- Cabinet front: x 44 to 728, y 60 to 1060. The right side shows about 28 px deep, the top about 18 px.
- Sign: x 76 to 696, y 76 to 132.
- Window (`glass.png` sits here): x 76 to 500, y 148 to 820.
- Control panel (`panel.png` sits here): x 524 to 700, y 148 to 820.
- Tray opening (`tray.png` and `flap.png` sit here): x 120 to 456, y 900 to 1004.

## Inside the window

Four rows, A at the top to D at the bottom, five coils each.

- Shelf edges (where the labels go): row A y 292 to 316, B y 448 to 472, C y 604 to 628, D y 760 to 784.
- Coil centres: x 122, 205, 288, 371, 454. Row A y 244, B y 400, C y 556, D y 712.
- Each label is 76 × 18, centred under its coil on the shelf edge. The code writes the text, so paint them blank.
- Below row D is a 36 px gap where files fall through to the tray.

## Coils

Both coil pictures are turned around their centre to make the coil spin, so paint them seen exactly end on, centred, about 76 px across at the front loop. Files sit inside the coil at about 60 × 60.

## The panel

Measured from the top left of `panel.png`.

- Display: x 12 to 164, y 20 to 104.
- Keys A, B, C, D: y 138 to 168, at x 12, 52, 92 and 132, each 32 wide.
- Keys 1, 2, 3: y 178 to 208. Keys 4, 5, CLR: y 214 to 244. At x 12, 65 and 119, each 45 wide.
- OK: x 12 to 164, y 258 to 288.

No coin slot, no prices, no money anywhere.

## Tips

- Paint one front view of the whole machine first, then cut it into pieces in your editor.
- Keep it original: your own drawing, a commissioned piece, or generated art you have the rights to use.
