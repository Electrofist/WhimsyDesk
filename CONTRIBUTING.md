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

1. Fork this repo and create a branch.
2. Make a folder `objects/<id>/`. The id is lowercase with hyphens, for example `air-fryer`.
3. Put your object's app inside, with a build script that produces a `.app`.
4. Add an `object.json` card. Copy one from `objects/fridge/object.json` and fill in your own details.
5. Add a short `README.md` in your folder: what it does, how to use it, where it stores files.
6. Add a line for your folder to `.github/CODEOWNERS` with your GitHub username, so you are asked to review future changes to your object.
7. Run `scripts/check-objects.sh` and fix anything it reports.
8. Build and use your object for a day on your own desktop.
9. Open a pull request using the "New object" checklist. Include a screen recording or GIF.

A full step-by-step guide, a template object and a tutorial are on the way.

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
| `screenshots` | no | Paths inside the object's folder |

## Improve an existing object

- Keep pull requests small, one change each.
- Do not change how an object feels (its physics, sounds, timing) without talking to its author in an issue first.
- Test on your own desktop and describe how in the pull request.
- Delete `.build` and `build` when you are done. They get large.

## Code of conduct

Be kind. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## License

By contributing you agree your work is released under the [MIT license](LICENSE), unless your object's `object.json` declares a different open license for its art and sounds.
