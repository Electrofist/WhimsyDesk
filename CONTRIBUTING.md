# Contributing

Thanks for helping build Desktop Objects. There are three ways in:

- **Add a new object** (an oven, a toolbox, a mailbox, anything).
- **Improve an existing object** (a bug fix, a smoother animation, a better sound).
- **Suggest an idea** by opening an issue with the "Object idea" template.

## The rules every object follows

1. **Files are moved, never lost.** Stored files go into one plain folder the user can open in Finder. Never delete or copy behind the user's back.
2. **Put Back works.** Every stored file can go back to where it came from.
3. **Quiet at rest.** No timers, polling or animation while nobody is touching the object. Pause on lock, screen sleep and system sleep.
4. **Lives on the desktop.** Sits just above the desktop icons, on every Space, out of the way of normal windows.
5. **No network, no tracking, nothing commercial.** No analytics, ads, accounts or paywalls.
6. **Original work.** Art and sounds you made or have the right to share.
7. **Standalone.** Each object is its own app in its own folder and builds on its own.

## Add a new object

The full walkthrough, written for designers with no Swift experience, is in [docs/make-your-own.md](docs/make-your-own.md). In short:

1. Fork this repo.
2. `scripts/new-object.sh "Air Fryer" your-github-username` creates `objects/air-fryer/` from the template and adds you to `.github/CODEOWNERS`.
3. `cd objects/air-fryer && ./build.sh run` to see it on your desktop.
4. Replace `Art/closed.png` and `Art/open.png`, and fill in `object.json` and `README.md`.
5. Run `scripts/check-objects.sh` and fix anything it reports.
6. Use your object for a day on your own desktop.
7. Open a pull request using the "New object" checklist. Include a screen recording or GIF.

You can also start from scratch instead of the template, as the fridge and drawer did. Your object still needs its own folder, an `object.json`, a README, a CODEOWNERS line and a build script that produces a `.app`.

## object.json fields

| Field | Required | Example |
|---|---|---|
| `id` | yes | `"fridge"`, must equal the folder name |
| `name` | yes | `"Desktop Fridge"` |
| `tagline` | yes | One line, 100 characters max |
| `description` | yes | A few sentences |
| `author` | yes | `{ "name": "Krrish Parmar", "github": "Electrofist" }` |
| `version` | yes | `"1.0"` or `"1.0.0"` |
| `minMacOS` | yes | `"14.0"` or later |
| `license` | yes | `"MIT"`, or another open license for your art |
| `storesFilesIn` | yes | `"~/Fridge"` |
| `build.command` | yes | `"./build.sh"`, run from the object's folder |
| `build.app` | yes | `"build/DesktopFridge.app"`, the app the command produces |
| `screenshots` | no | Paths inside the object's folder, for example `"media/hero.gif"` |
| `accent` | no | `"#6CCBF0"`, the glow colour in your download window |
| `look.itemsArea` | template only | Where files appear when open: x, y, width, height as fractions from the bottom left |
| `look.iconSize` | template only | File icon size in points, 24 to 128 |

## Improve an existing object

- Keep pull requests small, one change each.
- Do not change how an object feels (its physics, sounds, timing) without talking to its author in an issue first.
- Test on your own desktop and describe how in the pull request.
- Delete `.build` and `build` when you are done. They get large.

## Code of conduct

Be kind. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## License

By contributing you agree your work is released under the [MIT license](LICENSE), unless your object's `object.json` declares a different open license for its art and sounds.
