# Releasing

Each object is released on its own, as a DMG and a zip on the [Releases](https://github.com/Electrofist/desktop-objects/releases) page.

## Release an object

1. Set the new version in the object's `object.json` (and its `Info.plist` if it has its own version there).
2. Add a line to `CHANGELOG.md`.
3. Commit and push.
4. Tag and push the tag. The tag is the object's id, `-v`, and the version:

```sh
git tag fridge-v1.1
git push origin fridge-v1.1
```

GitHub then builds the object, packages it, and publishes the release with install notes. Watch it on the Actions tab. If the tag and `object.json` disagree on the version, the release stops and says so.

To try the packaging on your own Mac first: `scripts/release.sh fridge`. The files land in `dist/`.

## Signed or not

The workflow works in two modes and picks one by itself.

### Without an Apple Developer account (now)

The app keeps the free ad-hoc signature from its build script. People can use it, but macOS blocks the first launch. The release notes walk them through it:

1. Try to open the app once and click Done on the warning.
2. Open System Settings, then Privacy & Security.
3. Click Open Anyway next to the app, then confirm.

On macOS 15 and later, right-click and Open no longer gets past this; the steps above are the only way.

### With an Apple Developer account (99 USD per year)

The app is signed with your Developer ID and notarized by Apple. It opens like any normal app, with no warning. One membership covers every object.

To switch it on, add five secrets in the repo under Settings, Secrets and variables, Actions:

| Secret | What it is |
|---|---|
| `MACOS_CERTIFICATE` | Your Developer ID Application certificate exported as `.p12`, then base64 encoded: `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | The password you set when exporting the `.p12` |
| `APPLE_ID` | Your Apple ID email |
| `APPLE_APP_PASSWORD` | An app-specific password from [account.apple.com](https://account.apple.com), under Sign-In and Security |
| `APPLE_TEAM_ID` | Your 10-character Team ID from [developer.apple.com/account](https://developer.apple.com/account) |

Getting the certificate: in Xcode, Settings, Accounts, Manage Certificates, add a Developer ID Application certificate, then export it from Keychain Access as `.p12`. Without Xcode, create it at developer.apple.com under Certificates.

The next tag you push is signed and notarized. Nothing else changes. The hardened runtime needs the Apple Events entitlement so Put Back can ask Finder for icon positions; it is in `scripts/release/entitlements.plist`.

## Notes

- Bundle IDs: the fridge uses `in.krisby.desktopfridge`, the drawer `app.desktopdrawer.DesktopDrawer`. Changing one later resets users' saved positions and Finder permission, so settle them before many people install.
- The fridge and drawer builds are universal (Apple silicon and Intel). The release notes state which Macs each download supports, so a new object that builds for one kind only is still labelled correctly.
