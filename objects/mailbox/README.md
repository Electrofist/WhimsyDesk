# Desktop Mailbox

A navy mailbox on a wooden post that lives on your desktop. Every now and then a letter arrives: a note, a movie for tonight, a book, a song, a few good words. The flag pops up when there is mail. You can write back.

It is also a hiding spot. Drop files in, close the door, and your desktop is clear.

## Using it

- **Open the door:** click the mailbox. Or grab the door and pull it down. It falls open on its hinge and bounces on its stop.
- **Close it:** click again, or push the door up. The latch catches it.
- **Read a letter:** open the door and click an envelope. Unread ones have a wax seal.
- **Write back:** press **Write back** on a letter. Your reply is kept on this Mac, in `~/Mailbox/.replies`. Nothing is sent anywhere.
- **Hide files:** drag files or folders onto the mailbox. The door opens for you. Drag them back out, or right-click and choose **Put Back** to return a file to where it came from, even its old spot on the desktop.
- **The flag:** it goes up when there is unread mail and down once you have read everything. Click it to flip it yourself.
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

Every sound is made in code, so there are no audio files to license. To use a recording instead, put a WAV file in `Resources/Sounds/` with one of these names and rebuild: `clunk` (door shuts), `thud` (door falls open), `creak` (hinge), `boing` (flag goes up), `flick` (flag goes down), `rustle` (paper), `drop` (something lands inside).

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
