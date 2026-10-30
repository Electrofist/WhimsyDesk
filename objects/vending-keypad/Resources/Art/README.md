# Painted art for the vending machine

Put PNG files here with these exact names and rebuild. Any piece that is missing falls back to the art drawn in code, so you can add them one at a time.

All sizes are in pixels, at 2x. Everything is seen from the front with a little of the right side showing, lit from the top left. Leave everything outside the object transparent.

The look sits between a toy and the real thing: a chunky, rounded yellow body, and a believable inside (white shelves, paper name tags, metal-ringed buttons) so the files look at home.

## The pieces

| File | Size | What it is |
|---|---|---|
| `body.png` | 720 × 1040 | The machine without its moving parts: body, feet, window frame, the inside with its empty shelves and blank paper tags, the screen surround, the lamp and the bin opening. |
| `shadow.png` | 720 × 1040 | Optional. The soft shadow on the ground under the feet. |
| `glass.png` | 532 × 576 | Only the reflections on the window. Mostly transparent. |
| `bin.png` | 492 × 148 | The inside of the pickup bin. |
| `flap.png` | 492 × 148 | The clear flap over the bin, hinged at its top edge. Files in the bin must show through it. |
| `button.png` | 28 × 28 | A push button with something to get: metal ring, red cap. |
| `button-empty.png` | 28 × 28 | The same button when its shelf spot is empty. |
| `button-hover.png` | 28 × 28 | The red button, a touch brighter, while the pointer is on it. |
| `button-pressed.png` | 28 × 28 | The red button pushed in. |

The app icon is `Resources/AppIcon.icns`.

## Where things go on the 720 × 1040 canvas

Measured from the top left corner, in pixels.

- Body front: x 40 to 660, y 32 to 980, corners about 76 px round. The right side shows about 18 px deep.
- Window (`glass.png` sits here): x 84 to 616, y 72 to 648.
- Screen: x 224 to 476, y 688 to 736. The code lights it; leave it dark.
- Bin opening (`bin.png` and `flap.png` sit here): x 104 to 596, y 776 to 924.

## Inside the window

Three shelves, four spots each.

- Shelf fronts: y 208 to 264, 400 to 456 and 592 to 648. Each shelf top shows 18 px above its front.
- Spot centres: x 150, 284, 416 and 550.
- Paper tags: 116 × 20, centred on each spot, their top 2 px below the top of the shelf front. Paint them blank; the code writes the names.
- Buttons: 28 × 28, centred on each spot, their bottom 4 px above the bottom of the shelf front.
- Files stand on the shelf tops, about 88 px tall.

No coin slot, no prices, no money anywhere.

## Tips

- Paint one front view of the whole machine first, then cut it into pieces in your editor.
- Keep it original: your own drawing, a commissioned piece, or generated art you have the rights to use.
