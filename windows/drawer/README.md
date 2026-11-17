# Desktop Drawer for Windows

Work in progress: a Windows port of `objects/drawer` (Swift, macOS), written in Rust like `windows/fridge`.
Behaviour is defined in [docs/PORT-SPEC.md](docs/PORT-SPEC.md). When the spec and the Swift code disagree, the Swift code wins.

## Status

- [x] `core`: sliding physics, geometry, item layout, synthesized sounds, file store. No dependencies, runs and tests on any OS.
- [ ] `art`: wood, felt, cup pull, items
- [ ] `app`: layered window, mouse, drag and drop, menu, sound output

## Build and test

```
cd windows\drawer
cargo test --workspace
```
