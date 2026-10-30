# Desktop Vending Machine

A retro snack machine that stands on your desktop. Your files are the snacks, each on its own spiral coil behind the glass. Type a code, the coil turns, and the file drops into the tray.

The art is a placeholder drawn in code for now. Painted art can replace it piece by piece; see `Resources/Art/README.md`.

Made by [Electrofist](https://github.com/Electrofist). Part of [Desktop Objects](../../README.md).

## Use it

- Drag files or folders onto the glass. Each one goes into the next free coil, A1 first, and moves into `~/Vending Machine`. Twenty coils; when they are full, the display says SOLD OUT.
- Type a code on the keypad, for example B then 3, and press OK. The coil turns and the file falls into the tray.
- Double-click a file behind the glass to vend it straight away.
- Drag a file out of the tray onto the desktop or any folder to take it out. Files left in the tray stay there.
- Click a file to see its name. Press Space to look at it in Quick Look.
- Right-click a file and choose Put Back to send it back where it came from.
- Right-click anywhere for Vend, Open Vending Machine Folder, Put Back All, Sound and Quit.
- Hold Option and Command and drag to move the machine. It remembers where you left it.
- Hold Option and drag to make it bigger or smaller.

## Build

```sh
./build.sh run
```

Needs macOS 14 or later and Swift 5.9 or later.
