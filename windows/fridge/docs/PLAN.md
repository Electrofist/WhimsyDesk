# Desktop Fridge for Windows: plan

Goal: the same fridge as `objects/fridge`, with every feature, as a native Windows app written in Rust. Behaviour is defined in [PORT-SPEC.md](PORT-SPEC.md).

## Shape

A Cargo workspace with three crates, so most of the work can be built and tested on a Mac:

| Crate | What | Runs on |
|---|---|---|
| `core` | door physics, frost model, shelf layout, file store (move, put back, unique names, index), notes and magnets model, seeded random | any OS, unit tested |
| `art` | every drawing recipe, the perspective door, frost bake, the scene compositor that turns the current state into one RGBA frame | any OS, renders PNGs for checking against the Mac app |
| `app` | the Windows shell: layered window at the bottom of the z-order, mouse and keys, drag and drop with Explorer, menus, dialogs, sounds, shell icons, desktop icon positions, note editor, settings, start with Windows | Windows only, built on GitHub |

Drawing: software rendering with `tiny-skia` into a premultiplied BGRA buffer, shown with `UpdateLayeredWindow`. This gives per-pixel transparency and click-through on empty pixels. Static layers are rendered once per scale; per frame only doors, fog and moving items are composed, and only while something moves.

Win32 through the `windows` crate. No runtime dependencies for users: one `.exe` plus its assets, shipped in a zip.

## Phases

1. Core logic with the Swift tests ported. (Mac)
2. Art: every layer, the perspective doors, rendered to PNGs at several door angles and compared with the Mac fridge. (Mac)
3. Window: the fridge on the desktop, doors that drag, swing and double-click, sounds, move and resize, saved position. GitHub workflow builds a test zip. First test on a real PC.
4. Files: drop in from Explorer, shelf icons, drag out, open, Put Back, Show in Explorer, Move Everything to Desktop, desktop icon positions, menus.
5. Fog and frost.
6. Sticky notes and photo magnets, with the in-place editor.
7. Polish: lock and sleep, battery saver, reduced motion, light and dark mode, start with Windows, release workflow, README, website download.

Each phase ends with a build you can try.

## Folder

`windows/fridge/` in the repo, separate from `objects/` so the Mac tooling (`check-objects.sh`, release workflow) is not affected. Storage folder on Windows: `%USERPROFILE%\Fridge`.
