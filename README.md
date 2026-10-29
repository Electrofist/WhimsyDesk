# Desktop Objects

Real-feeling objects that live on your Mac desktop and hold your files. Drag a file into the fridge, shut the door, and your desktop is clear. Open it again and everything is where you left it.

Each object is a small, standalone macOS app. Open source, free, and made to be remixed.

## The objects

| | Object | What it does |
|---|---|---|
| <!-- GIF: objects/fridge/media/hero.gif --> | [Desktop Fridge](objects/fridge) | A retro olive fridge with a freezer on top. Heavy door, cold fog, frost on things left too long, sticky notes and photo magnets. Files go to `~/Fridge`. |
| <!-- GIF: objects/drawer/media/hero.gif --> | [Desktop Drawer](objects/drawer) | A worn wooden drawer that slides out from the bottom of the screen. Files go to `~/Desktop Drawer`. |

More are on the way. Want an oven, an air fryer, a toolbox, something that is not in a house at all? [Make your own](#make-your-own).

## Download

No prebuilt downloads yet, so for now you build from source (about a minute each).

macOS 14 or later. Mac only.

## Build from source

You need macOS 14 or later and Apple's Command Line Tools (`xcode-select --install`).

```sh
git clone <this repo>
cd desktop-objects/objects/fridge
./build.sh run
```

For the drawer: `cd objects/drawer && bash build_app.sh`, then open `build/Desktop Drawer.app`.

Each object's own README covers its controls and details.

## What every object promises

- Your files are moved, never copied or deleted, into a normal folder you can open in Finder.
- Put Back returns a file to where it came from.
- Nothing runs in the background when the object is at rest: no timers, no polling.
- No network, no tracking, no accounts.

## Make your own

Every object lives in its own folder under `objects/`, with an `object.json` card that describes it. To add one, see [CONTRIBUTING.md](CONTRIBUTING.md). A full step-by-step guide is coming.

## Repo layout

```
objects/
  fridge/        Desktop Fridge (Swift package, its own README)
  drawer/        Desktop Drawer
scripts/
  check-objects.sh   checks every object.json
docs/            guides
```

## License

[MIT](LICENSE) for everything in this repo unless an object's `object.json` says otherwise.
