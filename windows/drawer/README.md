# Desktop Drawer for Windows

A wooden drawer along the bottom of your screen that holds your files. Pull it open, drop files in,
push it shut, and your desktop is clear. This is the Windows port of the macOS
[Desktop Drawer](../../objects/drawer), written in Rust like the [Windows fridge](../fridge).

## Using it

- **Pull** the front panel up to open the drawer, push it down to close it. It has weight: let go
  of a quick pull and it keeps sliding. **Double-click** the panel to slide it open or shut.
- **Drop** files or folders onto the open drawer (hovering over the closed drawer pulls it open).
  They are moved in, never copied or deleted.
- **Drag** an item out to the Desktop or any folder to take it out. **Double-click** an item to
  put it back where it came from.
- **Right-click** for Put Back on Desktop, Show in Explorer (on an item), Put Everything Back, Open
  Drawer Folder, Move Everything to Desktop and Quit.

Files live in the `Desktop Drawer` folder in your user folder (beside the Desktop when OneDrive
holds it). A small index at `%APPDATA%\WhimsyDesk\Desktop Drawer\index.json` remembers where each
file came from. Set `DRAWER_ROOT` to use another folder while testing.

It follows the object rules in [CONTRIBUTING](../../CONTRIBUTING.md): quiet at rest (the frame clock
only runs while the drawer moves, no sound device stays open), paused on lock, sleep and display
off, lighter on battery saver, no network, and it sits just above the Desktop icons. It follows the
Windows light or dark setting. All pictures and sounds are drawn or synthesized in code: there are no
asset files, so the single `DesktopDrawer.exe` is the whole app.

## Build

```
cd windows/drawer
cargo test --workspace
cargo run --release -p desktop-drawer
```

## Layout

| Crate | What it holds | Runs on |
|---|---|---|
| `core` | Slide physics, item layout, the file store and index, sound synthesis. No dependencies. | any OS |
| `art` | A small software renderer that paints the drawer (wood, felt, shadows). No dependencies. | any OS |
| `app` | The Win32 shell: window, mouse, drag and drop, menu, icons, text, sound output. | Windows (its pure parts are tested anywhere) |

[docs/PORT-SPEC.md](docs/PORT-SPEC.md) describes every behaviour carried over from the Mac version.

## Not done yet

An installer and an app icon (the fridge has both); putting a file back to the exact Desktop icon
position it had.
