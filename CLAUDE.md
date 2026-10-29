# Desktop Objects

An open source library of skeuomorphic macOS desktop objects that store files. Each object is a standalone AppKit app in `objects/<id>/`. Fridge and Drawer are the first two.

## Rules

- Do not change an existing object's code or behavior unless the task explicitly asks for it. The fridge and drawer are finished pieces.
- Every object follows the rules in `CONTRIBUTING.md`: files moved never lost, Put Back works, quiet at rest, desktop level, no network or tracking, original art, standalone.
- Nothing commercial: no paywalls, pricing, ads, analytics or tracking.
- Do not document a feature as available until it exists.
- The Phoenix Code extension lives in a separate repo.

## Build and test

- Requirements: macOS 14+, Swift 5.9+. `swift test` needs full Xcode; with only the Command Line Tools XCTest is missing and tests fail to build. CI runs them.
- Check cards: `scripts/check-objects.sh`
- Fridge: `cd objects/fridge && ./build.sh` (or `./build.sh run`), tests with `swift test`.
- Drawer: `cd objects/drawer && bash build_app.sh`. The script is not executable in its original repo; call it with `bash`.
- Clean up afterwards: `rm -rf objects/*/.build objects/*/build`. They reach several hundred MB.

## Layout

- `objects/<id>/object.json`: the card for each object. Fields are listed in `CONTRIBUTING.md`.
- `objects/<id>/CLAUDE.md` or `README.md`: object-specific notes.
- `scripts/`: repo tools. `docs/`: guides.

## Working style

- Small commits and pull requests, one concern each.
- Avoid heavy dependencies and large build artifacts.
- Be concise. No em dashes in docs or copy.
