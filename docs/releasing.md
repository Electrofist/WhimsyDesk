# Releasing

How to turn an object into a download people can run without building it. Not automated yet. One decision is open: whether to sign and notarize.

## Option A: ad-hoc signed zip (free)

What the build scripts produce today.

1. Build the object, for example `cd objects/fridge && ./build.sh`.
2. `cd build && ditto -c -k --keepParent DesktopFridge.app DesktopFridge-1.0.zip`
3. Attach the zip to a GitHub Release.

What people see: macOS blocks the first launch because the app is not notarized. On macOS 15 and later, right-click and Open no longer gets past this. They have to:

1. Double-click the app once and close the warning.
2. Open System Settings, then Privacy & Security.
3. Click Open Anyway next to the app, then confirm.

It works, but some people will stop at step 2.

## Option B: Developer ID and notarization (99 USD per year)

Needs the Apple Developer Program. No warning on first launch. One membership covers every object.

1. Create a Developer ID Application certificate.
2. Sign with the hardened runtime and an entitlements file that includes `com.apple.security.automation.apple-events`. Both objects ask Finder for icon positions, and the hardened runtime blocks that without it.
3. Submit with `xcrun notarytool submit <zip> --wait`, then `xcrun stapler staple <app>`.

In CI this needs four repository secrets: the certificate as base64, its password, an Apple ID app-specific password, and the Team ID. Without them the release would fall back to Option A.

## Before the first public release

- Bundle IDs: the fridge uses `in.krisby.desktopfridge`, the drawer `app.desktopdrawer.DesktopDrawer`. Changing one later resets users' saved positions and Finder permission, so settle them first.
- The fridge build is universal (Apple silicon and Intel). The drawer build is for the Mac it is built on only.
