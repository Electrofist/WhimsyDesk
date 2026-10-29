# Make your own object

From nothing to your own object on your desktop in about 15 minutes, then as long as you like on the art. No Swift needed.

You start from a template: a wooden crate that already opens, closes, stores files, gives them back and remembers where it sits. You swap in your art, describe it, and send it in.

## What you need

- A Mac with macOS 14 or later.
- Apple's Command Line Tools. In Terminal, run `xcode-select --install` and follow the prompt. If it says they are already installed, you are set.
- A free [GitHub](https://github.com) account.
- Any image editor that exports PNG with transparency: Figma, Sketch, Photoshop, Pixelmator, Procreate.

## Recommended: Phoenix Code

You can use any editor, but [Phoenix Code](https://phcode.dev) with the [Desktop Objects Studio](https://github.com/Electrofist/desktop-objects-phoenix) extension makes the visual parts easier:

- A side panel shows your object's art, icon, name and colour while you work.
- The files area is drawn over your open art. Drag it into place instead of working out numbers (step 5).
- Mistakes in `object.json` are marked as you type, with the same rules GitHub checks.
- File, New Desktop Object… does step 2 for you.

To install it, open the Extension Manager in Phoenix Code (the building-block icon in the right-hand toolbar), search for **Desktop Objects Studio**, and click Install. Then click the fridge icon in the same toolbar to open the panel.

## 1. Get your own copy

1. Open [github.com/Electrofist/desktop-objects](https://github.com/Electrofist/desktop-objects) and click **Fork**. This makes your own copy on GitHub.
2. In Terminal, download your copy (replace `your-username`):

```sh
git clone https://github.com/your-username/desktop-objects.git
cd desktop-objects
```

## 2. Create your object

Pick a name and run (replace the name and username):

```sh
scripts/new-object.sh "Toaster" your-username
```

This creates `objects/toaster/` with everything inside, ready to build.

## 3. See it on your desktop

```sh
cd objects/toaster
./build.sh run
```

The first build takes a minute or two. A wooden crate appears at the lower left of your screen, behind your windows, just above the desktop icons.

Try it:

- Click it to open and close.
- Drag a file from your desktop onto it. The file moves into `~/Desktop Objects/Toaster`.
- Drag the file back out, or right-click it and choose **Put Back**.
- Hold **Option + Command** and drag to move the object.
- Right-click and choose **Quit** when you are done.

## 4. Draw your art

Your object is two pictures: `Art/closed.png` and `Art/open.png`.

- Design at 1x and export at **2x**. In Figma, make a 280 x 240 frame and export it as PNG at 2x, which gives 560 x 480 px. Any size works, as long as both images are the same size.
- Use a **transparent background**, so the desktop shows around your object.
- Draw the **shadow** into the art.
- In `open.png`, leave a calm, light area where files will sit, so their icons and names stay readable.

Replace the two files, keep their names, then quit the object and run `./build.sh run` again.

## 5. Tell it where files go

When your object is open, stored files are laid out inside one rectangle. Set it in `object.json`:

```json
"look": {
  "itemsArea": [0.12, 0.12, 0.76, 0.74],
  "iconSize": 48
}
```

The four numbers are x, y, width and height, as fractions of your image, measured from the **bottom left**.

Working it out from your design: if your image is 560 x 480 px and the inside of your toaster starts 60 px from the left, 120 px up from the bottom, and is 440 px wide and 200 px tall, then:

- x = 60 / 560 = 0.11
- y = 120 / 480 = 0.25
- width = 440 / 560 = 0.79
- height = 200 / 480 = 0.42

`iconSize` is the size of file icons in points, from 24 to 128.

## 6. Add an app icon (optional, but people love it)

Design a square icon on a plain background (any colour) and save it as PNG or JPG. Then, from the top folder of the repo:

```sh
swift scripts/make-icon.swift ~/Desktop/my-icon.png objects/toaster/Art
```

It removes the background, places the icon on Apple's icon grid with a soft shadow, and writes `Art/AppIcon.icns`. The next `./build.sh run` uses it.

## 7. Add sounds (optional)

Put `open.wav` and `close.wav` in the `Sounds` folder. Keep them short and quiet. Leave them out for a silent object.

## 8. Describe it

In `object.json`, write your own `tagline` (one line) and `description` (a few sentences). In `README.md`, describe how to use it.

Record a short clip: press **Shift + Command + 5**, choose **Record Selected Portion**, and capture your object opening and taking a file. Turn the video into a GIF with a free tool like [Gifski](https://gif.ski), save it as `media/hero.gif` in your object's folder, and add `"media/hero.gif"` to `screenshots` in `object.json`.

## 9. Check it

From the top folder of the repo:

```sh
scripts/check-objects.sh
```

Fix anything it lists. It catches missing details, template text you forgot to replace, and art or build files that are missing.

## 10. Send it in

```sh
git checkout -b add-toaster
git add objects/toaster .github/CODEOWNERS
git commit -m "Add Toaster"
git push -u origin add-toaster
```

Open your fork on GitHub. Click **Compare & pull request**, fill in the checklist, attach your GIF, and submit. GitHub checks and builds your object automatically. If something fails, the pull request shows what, and you can push a fix to the same branch.

## Going further

The template covers the basics. Anything beyond it, like a door that swings with weight, frost, or a drawer that slides, is Swift code. The fridge (`objects/fridge`) and the drawer (`objects/drawer`) show how, and an AI coding assistant can help you change the template's code in `Sources/`.

Whatever you add, keep the rules in [CONTRIBUTING.md](../CONTRIBUTING.md): files are moved, never lost; Put Back works; nothing runs while nobody is touching the object; no network or tracking.

## Troubleshooting

- **`xcrun: error` or `swift: command not found`**: the Command Line Tools are missing. Run `xcode-select --install`.
- **`permission denied: ./build.sh`**: run `chmod +x build.sh` once, or use `bash build.sh run`.
- **I cannot see my object**: it sits behind your windows. Show the desktop with a four-finger spread on the trackpad, or press F11 (Fn + F11 on some keyboards).
- **My art looks blurry**: export at 2x.
- **My changes do not show up**: right-click the object, Quit, then run `./build.sh run` again.
- **macOS says the app cannot be opened**: this does not happen for apps you build yourself. If it does, see the [FAQ](faq.md).
