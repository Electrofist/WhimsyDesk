# Desktop Fridge for Windows

A fridge on your desktop that holds your files. It is the Windows version of the Mac fridge in `objects/fridge`, rewritten in Rust. It sits above your desktop icons and below every other window, and it stays quiet when nothing moves.

Status: first test build. It has not been tried on a real PC yet.

## Run it

1. Download `Desktop-Fridge-Windows.zip` from the latest run of the "Windows fridge" workflow (Actions tab) and unzip it anywhere.
2. Keep the `assets` folder next to `DesktopFridge.exe`.
3. Double-click `DesktopFridge.exe`.

The app is not signed, so Windows SmartScreen may warn about an unknown publisher. Click "More info", then "Run anyway".

Only one fridge runs at a time. To quit, right-click the fridge and choose "Quit Desktop Fridge".

Needs Windows 10 or 11.

## Controls

| Do this | What happens |
|---|---|
| Drag a door | Opens or closes it |
| Double-click a door | Swings it open or shut |
| Drop files on an open shelf | They go in the fridge |
| Hold a file over a shut door | The door swings open for it |
| Drag a file out | Moves it where you drop it |
| Double-click a file | Opens it |
| Ctrl-click a shut door | New sticky note |
| Double-click a note | Write on it. Enter finishes, Alt+Enter adds a line, Esc cancels |
| Ctrl-click a note | Changes its colour |
| Ctrl-drag a note | Moves it. Drag it off the door to peel it off |
| Drop a picture on a shut door | A photo magnet (PNG or JPEG; the picture itself is not moved) |
| Drop text on a shut door | A note with that text |
| Alt-drag | Resize the fridge |
| Ctrl+Alt-drag | Move the fridge |

Notes and magnets only go on a door while it is shut.

## Right-click menu

- On a note: Edit Note, Color, Peel Off Note.
- On a photo magnet: Open Original, Take Photo Down.
- On a file: Open, Put Back, Show in Explorer.
- Always: Open Fridge Folder, Move Everything to Desktop, Start with Windows, Quit Desktop Fridge.

Put Back moves a file to the folder it came from (or the Desktop if that folder is gone) and puts its Desktop icon back where it was when it can.

## Where things go

- Files in the fridge: `%USERPROFILE%\Fridge`. They are ordinary files; open the folder any time.
- Notes and magnets: `.fridge-notes.json` and `.magnets` in the same folder.
- Position and size: `%APPDATA%\WhimsyDesk\Desktop Fridge\settings.json`.
- Start with Windows adds a `Desktop Fridge` value under `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.

The app makes no network calls and collects nothing.

## Build

The workspace has three crates: `core` (physics, files, notes), `art` (drawing) and `app` (the Windows shell).

On Windows, with Rust installed:

```
cargo test --workspace
cargo build --release -p desktop-fridge
```

The exe is `target\release\DesktopFridge.exe`. Copy `assets` next to it, or run it from `target\release` inside the repo and it finds the repo's `assets` folder.

On a Mac, `core`, `art` and the app's logic build and test as usual (`cargo test --workspace`). To type-check the Windows code:

```
rustup target add x86_64-pc-windows-msvc
cargo check -p desktop-fridge --target x86_64-pc-windows-msvc
```

For development: `FRIDGE_ROOT` sets the fridge folder, `FRIDGE_TIME_SCALE` speeds up frost, `FRIDGE_DEBUG_ANGLE="fridge,freezer"` pins the doors open (degrees).

Behaviour and numbers follow [docs/PORT-SPEC.md](docs/PORT-SPEC.md). The plan is in [docs/PLAN.md](docs/PLAN.md).

## License

MIT. The note font is Caveat (SIL Open Font License, see `assets/fonts/OFL.txt`).
