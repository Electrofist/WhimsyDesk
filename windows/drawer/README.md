# Desktop Drawer for Windows

Work in progress: a Windows port of `objects/drawer` (Swift, macOS), written in Rust like `windows/fridge`.
Behaviour is defined in [docs/PORT-SPEC.md](docs/PORT-SPEC.md). When the spec and the Swift code disagree, the Swift code wins.

## Status

- [x] `core`: sliding physics, geometry, item layout, synthesized sounds, file store. No dependencies, runs and tests on any OS.
- [x] `art`: wood, felt, box, floor, dust, front panel, cup pull and shadows, in both themes. Software rendering, no dependencies.
- [ ] items (icons with shadows) and label text: drawn by the `app` crate between the `back` and `front` layers
- [ ] `app`: layered window, mouse, drag and drop, menu, sound output

## Build and test

```
cd windows\drawer
cargo test --workspace
```

Render the artwork to PNGs, to compare with the Mac app (`objects/drawer/media/closed.png`):

```
cargo run --release -p drawer-art --example snapshots -- out 2
```
