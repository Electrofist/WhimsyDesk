# Painted art for the mailbox

Put PNG files here with these exact names and rebuild. Any piece that is missing falls back to the art drawn in code, so you can add them one at a time.

All sizes are in pixels, at 2x. Everything is seen straight from the front with a little of the right side showing, lit from the top left. Leave everything outside the object transparent.

## The pieces

| File | Size | What it is |
|---|---|---|
| `base.png` | 720 × 880 | The pole and its soft shadow on the ground. Nothing else. |
| `box.png` | 720 × 880 | The whole box without its door. The door opening must be transparent (see below). Include the slot opening (dark) but not the hood over it. |
| `hood.png` | 720 × 880 | Only the hood over the slot, with its shadow. It sits on top of the letter that sticks out of the slot. |
| `door-front.png` | 352 × 296 | The door, front side. Hinges on the left edge. |
| `door-back.png` | 352 × 296 | The door, inside face, mirrored: its hinge edge is on the right of the picture. |
| `interior.png` | 352 × 296 | The inside of the box, seen through the open door. Darker toward the back. |

## Where things go on the 720 × 880 canvas

Measured from the top left corner, in pixels.

- Box front: x 180 to 620, y 56 to 656. The side shows on the right, about 24 px deep.
- Door opening: x 224 to 576, y 340 to 636. This area of `box.png` must be fully transparent.
- Slot opening: x 240 to 560, y 218 to 244.
- Hood: x 220 to 580, y 188 to 222.
- Pole: x 364 to 436, from y 648 down to the ground at about y 840.

## Inside the box

The interior has a shelf. Its front edge is 144 px up from the bottom of `interior.png`. Letters and parcels sit on the floor and on the shelf, so leave those surfaces clear.

## Tips

- Make one front view of the closed box first, then cut it into `base`, `box` and `hood` in your editor. Paint the door separately so nothing is hidden behind it.
- Keep it original: your own drawing, a commissioned piece, or generated art you have the rights to use.
