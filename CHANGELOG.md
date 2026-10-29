# Changelog

Each object keeps its own version in its `object.json`. Entries are grouped by object.

## Unreleased

### Library
- Started the Desktop Objects library: one repo, one folder per object.
- Added `object.json` cards and `scripts/check-objects.sh`.
- Added a starter template object, `scripts/new-object.sh` and the [make-your-own guide](docs/make-your-own.md).
- Added an FAQ, a banner and screenshots.
- Added downloads: `scripts/release.sh` and a release workflow that publishes a DMG and zip per object when a tag like `fridge-v1.0` is pushed. Signs and notarizes once Apple Developer secrets are added.
- Added `scripts/make-icon.swift` and a Phoenix Code section in the guide, pointing to the Desktop Objects Studio extension.

### Desktop Fridge 1.2
- New green fridge icon.

### Desktop Fridge 1.1
- New app icon. Builds for Apple silicon and Intel.

### Desktop Fridge 1.0
- Joined the library with its full history. No changes to the app.

### Desktop Drawer 1.2
- New wooden drawer icon.

### Desktop Drawer 1.1
- New app icon. Now runs on Intel Macs too.

### Desktop Drawer 1.0
- Joined the library with its full history. No changes to the app.
