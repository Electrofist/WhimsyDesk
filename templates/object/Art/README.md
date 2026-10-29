# Art

Two PNG files. Replace them with your own and keep the names.

- `closed.png`: the object when it is shut.
- `open.png`: the object when it is open. Stored files are drawn on top of it, inside `look.itemsArea` from `object.json`.

## Rules

- Draw at 2x: a 560 x 480 px image shows as 280 x 240 points on screen.
- Both images must be the same size.
- Use a transparent background so the desktop shows around the object.
- Draw the object's shadow into the art. The window adds none.
- Leave a calm, light area in `open.png` where files will sit, so their icons and names stay readable.

## Placing the files area

`look.itemsArea` in `object.json` is four numbers: x, y, width, height, as fractions of the image, measured from the bottom left.

For example, `[0.1, 0.2, 0.8, 0.6]` starts 10% in from the left and 20% up from the bottom, and covers 80% of the width and 60% of the height.

To work it out from pixels: x = left edge / image width, y = bottom edge / image height (counting up from the bottom), and the same for width and height.
