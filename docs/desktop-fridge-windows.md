# Desktop Fridge for Windows

A retro fridge for your Windows desktop that holds your files. Drag files in, shut the heavy door, and your desktop is clear. It is free, open source, and in beta for Windows 10 and 11.

[Download the installer](https://github.com/Electrofist/WhimsyDesk/releases/download/windows-fridge-beta.1/Desktop-Fridge-Setup.exe) (64-bit Windows 10 or 11).

## What it does

- **A door with weight.** Drag a door to swing it open, or double-click it. It stays where you leave it.
- **Files on the shelves.** Drop files from the Desktop or File Explorer onto an open shelf. Drag them back out when you need them, or right-click and choose **Put Back** to return a file to where it came from.
- **Notes and magnets.** Ctrl-click a shut door for a sticky note. Drop a picture on a shut door to pin it under a magnet.
- **Resize and move.** Alt-drag to resize the fridge, Ctrl+Alt-drag to move it.

Files are only ever moved, never copied or deleted. Nothing goes online, and there are no accounts.

## Where your files go

Into a normal folder called **Fridge**, next to your Desktop folder. If OneDrive syncs your Desktop, the Fridge folder sits inside OneDrive too, so moving files in never asks to delete them from the cloud.

Right-click the fridge and choose **Open Fridge Folder** to see them in File Explorer, or **Move Everything to Desktop** to empty it in one go.

## Install it

1. Download **Desktop-Fridge-Setup.exe**.
2. Open it. Windows may warn that the app is from an unknown publisher, because it is not signed yet. Click **More info**, then **Run anyway**.
3. The installer needs no admin rights. It adds Desktop Fridge to the Start menu and can start it with Windows.

The fridge sits on your desktop, behind your windows. Press **Win+D** to see it.

Prefer no installer? There is also a [portable zip](https://github.com/Electrofist/WhimsyDesk/releases/tag/windows-fridge-beta.1): unzip it anywhere and run `DesktopFridge.exe`.

## It is a beta

It works, but it is new, so expect a few rough edges. If something goes wrong, [open an issue](https://github.com/Electrofist/WhimsyDesk/issues) and attach the log from `%LOCALAPPDATA%\WhimsyDesk\Desktop Fridge\fridge.log`.

On a Mac? The [Mac version](https://whimsydesk.art/desktop-fridge/) is finished, and comes with a drawer, a mailbox and two vending machines.
