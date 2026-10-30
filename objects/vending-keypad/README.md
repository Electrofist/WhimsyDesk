<p align="center"><img src="media/logo.png" alt="Vending Machine" width="420"></p>

# Desktop Vending Machine Keypad

A little vending machine that stands on your desktop. Your files are the snacks, each standing on a shelf behind the glass with a code and its name on a tag. Type a code on the keypad and that file is pushed off its shelf and drops into the bin.

<p align="center">
  <img src="media/hero.gif" alt="Files dropped onto the vending machine stand on its shelves, then a code is typed on the keypad and a file drops into the bin" width="520">
</p>

The art is a placeholder drawn in code for now. Painted art can replace it piece by piece; see `Resources/Art/README.md`.

The keypad twin of [Desktop Vending Machine](../vending/README.md): same machine, but you type a code instead of pressing a button. Both can run at once; each keeps its own folder.

Made by [Electrofist](https://github.com/Electrofist). Part of [Desktop Objects](../../README.md).

## Use it

- Drag files or folders onto the window. Outlines show where they will stand, and each one moves into `~/Vending Machine Keypad`. Twelve spots, A1 to D3; when they are full, the screen says SOLD OUT.
- Point at a file to see its name on the screen.
- Type a code on the keypad, for example B then 2, and press OK. That file is pushed off its shelf and falls into the bin. An empty spot shows EMPTY; CLR starts again. Double-clicking a file does the same.
- Drag a file out of the bin onto the desktop or any folder to take it out. Files left in the bin stay there.
- Click a file to see its name. Press Space to look at it in Quick Look.
- Right-click a file and choose Put Back to send it back where it came from.
- Right-click anywhere for Vend, Open Vending Machine Keypad Folder, Put Back All, Sound and Quit.
- Hold Option and Command and drag to move the machine. It remembers where you left it.
- Hold Option and drag to make it bigger or smaller.

## Build

```sh
./build.sh run
```

Needs macOS 14 or later and Swift 5.9 or later.
