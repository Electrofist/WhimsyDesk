# Painted art for the vending machine

Put PNG files here with these exact names and rebuild. Any piece that is missing falls back to the art drawn in code, so you can add them one at a time.

All sizes are in pixels, at 2x. Everything is seen from the front with a little of the right side showing, lit from the top left. Leave everything outside the object transparent.

The look sits between a toy and the real thing: a chunky, rounded yellow body, and a believable inside (white shelves, paper name tags, metal-ringed buttons) so the files look at home.

## The pieces

| File | Size | What it is |
|---|---|---|
| `body.png` | 720 × 1232 | The machine without its moving parts: body, feet, window frame, the inside with its empty shelves and blank paper tags, the screen surround, the lamp and the bin opening. |
| `shadow.png` | 720 × 1232 | Optional. The soft shadow on the ground under the feet. |
| `glass.png` | 532 × 768 | Only the reflections on the window. Mostly transparent. |
| `bin.png` | 492 × 148 | The inside of the pickup bin. |
| `flap.png` | 492 × 148 | The clear flap over the bin, hinged at its top edge. Files in the bin must show through it. |
| `button.png` | 28 × 28 | A push button with something to get: metal ring, red cap. |
| `button-empty.png` | 28 × 28 | The same button when its shelf spot is empty. |
| `button-hover.png` | 28 × 28 | The red button, a touch brighter, while the pointer is on it. |
| `button-pressed.png` | 28 × 28 | The red button pushed in. |

The app icon is `Resources/AppIcon.icns`.

## Where things go on the 720 × 1232 canvas

The machine grows 192 px taller for each extra shelf. These numbers are for four shelves.

Measured from the top left corner, in pixels.

- Body front: x 40 to 660, y 32 to 1172, corners about 76 px round. The right side shows about 18 px deep.
- Window (`glass.png` sits here): x 84 to 616, y 72 to 840.
- Screen: x 224 to 476, y 880 to 928. The code lights it; leave it dark.
- Bin opening (`bin.png` and `flap.png` sit here): x 104 to 596, y 968 to 1116.

## Inside the window

Four shelves, A at the top to D at the bottom, three spots each.

- Shelf fronts: y 208 to 264, 400 to 456, 592 to 648 and 784 to 840. Each shelf top shows 18 px above its front.
- Spot centres: x 173, 350 and 527.
- Paper tags: 116 × 20, centred on each spot, their top 2 px below the top of the shelf front. Paint them blank; the code writes the names.
- Buttons: 28 × 28, centred on each spot, their bottom 4 px above the bottom of the shelf front.
- Files stand on the shelf tops, about 88 px tall.

No coin slot, no prices, no money anywhere.

## Tips

- Paint one front view of the whole machine first, then cut it into pieces in your editor.
- Keep it original: your own drawing, a commissioned piece, or generated art you have the rights to use.
