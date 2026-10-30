# Desktop Mailbox

A red post box that lives on your desktop. Every now and then a letter arrives: a note, a movie for tonight, a book, a song, a few good words. It slides in through the slot and waits there, sticking out, until you read it. You can write back.

<p align="center">
  <img src="media/closed.png" alt="Desktop Mailbox: a red post box with a letter sticking out of its slot" height="360">
  <img src="media/open.png" alt="The post box with its door open: letters and files on a shelf and on the floor" height="360">
  <img src="media/letter-opening.png" alt="A letter sliding out of an opened green envelope" height="360">
</p>

It is also a hiding spot. Drop files in, close the door, and your desktop is clear.

## Using it

- **Open the door:** click the box. Or grab the door and swing it. It slows on its hinges and bounces off its stop.
- **Close it:** click again, or push the door shut. The latch catches it.
- **Read a letter:** click the letter sticking out of the slot. It comes out in its envelope: the wax seal pops, the flap opens and the letter slides out. Older letters are inside the box; open the door and click one.
- **Write back:** press **Write back** on a letter. Your reply is kept on this Mac, in `~/Mailbox/.replies`. Nothing is sent anywhere.
- **Hide files:** drag files or folders onto the mailbox. The door opens for you. Drag them back out, or right-click and choose **Put Back** to return a file to where it came from, even its old spot on the desktop.
- **Move it:** hold Option and Command and drag.
- **Everything else:** right-click the mailbox. Sound on or off, open the folder, see when more mail is coming, quit.

## How the mail works

All letters ship inside the app, in [`Resources/letters.json`](Resources/letters.json). There is no internet, no account and no tracking. The first letter arrives on first launch. After that, a new one arrives at a random time, usually within a day, during the daytime. Each letter comes once. When all of them have arrived, the deliveries stop.

The mailbox keeps one alarm for the next delivery and does nothing else while you are not touching it.

### Adding your own letters

Each letter looks like this:

```json
{
  "id": "totoro",
  "from": "Someone who still believes in forest spirits",
  "kind": "movie",
  "title": "My Neighbor Totoro (1988)",
  "body": "If you have had a long week, this is the cure.",
  "signoff": "Bring an umbrella."
}
```

- `id`: short and unique. Never reuse an id; it is how the mailbox remembers what it already delivered.
- `kind`: `note`, `movie`, `book`, `song` or `quote`. It sets the stamp colour.
- `title` and `signoff` are optional. Use `\n` for a new line.
- One letter can have `"welcome": true` to arrive first.

Rebuild after editing.

## Build

```sh
./build.sh        # builds "build/Desktop Mailbox.app" for Apple silicon and Intel
./build.sh run    # builds and opens it
```

To try deliveries quickly, run the app with `MAILBOX_DELIVERY_SECONDS=20` set and a letter arrives every 20 seconds:

```sh
MAILBOX_DELIVERY_SECONDS=20 "build/Desktop Mailbox.app/Contents/MacOS/DesktopMailbox"
```

## Sounds

Every sound is made in code, so there are no audio files to license. To use a recording instead, put a WAV file in `Resources/Sounds/` with one of these names and rebuild: `clunk` (door shuts), `thud` (door hits its stop), `creak` (hinge), `arrive` (a letter comes through the slot), `seal` (the wax seal pops), `rustle` (paper), `drop` (something lands inside).

## Where things are kept

- `~/Mailbox`: your hidden files, as normal files you can open in Finder.
- `~/Mailbox/.mailbox-index.json`: where each file came from, for Put Back.
- `~/Mailbox/.mailbox-post.json`: which letters have arrived and when the next one is due.
- `~/Mailbox/.replies`: your replies, one text file per letter.

## Art

All art is drawn in code in `Sources/DesktopMailbox/MailboxArt.swift`. To export it:

```sh
swift build
.build/debug/DesktopMailbox --render-closed closed.png
.build/debug/DesktopMailbox --render-icon icon-art.png
swift ../../scripts/make-icon.swift icon-art.png Resources   # app icon
```
