#!/usr/bin/env python3
"""Build website/objects.js from objects/*/object.json, and copy each object's art and icon.

Run from the repo root after adding or changing an object:  python3 scripts/website-objects.py
Uses only the standard library and macOS `sips` for resizing.
"""
import glob
import json
import os
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = os.path.join(ROOT, 'website')
RELEASES = 'https://github.com/Electrofist/whimsydesk/releases/download/downloads/'

# Objects with a published download. Add an id here once its .dmg is on the release.
RELEASED = {'fridge': 'Desktop-Fridge.dmg', 'drawer': 'Desktop-Drawer.dmg', 'mailbox': 'Desktop-Mailbox.dmg', 'vending': 'Desktop-Vending-Machine.dmg', 'vending-keypad': 'Desktop-Vending-Machine-Keypad.dmg'}


def resize(src, dst, size):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    subprocess.run(['sips', '-Z', str(size), src, '--out', dst], check=True, capture_output=True)


def pixel_size(path):
    out = subprocess.run(['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', path], check=True, capture_output=True, text=True).stdout
    nums = [int(line.split(':')[1]) for line in out.splitlines() if 'pixel' in line]
    return nums[0], nums[1]


def added(object_dir):
    out = subprocess.run(['git', '-C', ROOT, 'log', '--diff-filter=A', '--format=%ad', '--date=short', '--',
                          os.path.join(object_dir, 'object.json')], capture_output=True, text=True).stdout.split()
    return out[-1] if out else ''


items = []
for card in sorted(glob.glob(os.path.join(ROOT, 'objects', '*', 'object.json'))):
    folder = os.path.dirname(card)
    o = json.load(open(card))
    oid = o['id']
    shots = o.get('screenshots') or []
    art_src = os.path.join(folder, shots[0]) if shots else ''
    art = icon = ''
    width = height = 1
    if art_src and os.path.exists(art_src):
        art = f'media/art/{oid}.png'
        resize(art_src, os.path.join(SITE, art), 560)
        width, height = pixel_size(os.path.join(SITE, art))
    icon_src = os.path.join(folder, 'media', 'icon.png')
    if os.path.exists(icon_src):
        icon = f'media/icons/{oid}.png'
        resize(icon_src, os.path.join(SITE, icon), 256)
    items.append({
        'id': oid,
        'name': o['name'],
        'tagline': o['tagline'],
        'description': o['description'],
        'author': o['author']['name'],
        'github': o['author'].get('github', ''),
        'version': o['version'],
        'minMacOS': o['minMacOS'],
        'folder': o['storesFilesIn'],
        'accent': o.get('accent', '#A3B020'),
        'license': o.get('license', 'MIT'),
        'art': art,
        'aspect': round(width / height, 3),
        'icon': icon or 'media/icons/your-object.png',
        'download': RELEASES + RELEASED[oid] if oid in RELEASED else '',
        'source': f'https://github.com/Electrofist/whimsydesk/tree/main/objects/{oid}',
        'added': added(folder),
    })

with open(os.path.join(SITE, 'objects.js'), 'w') as f:
    f.write('// Every object in the library, built from objects/*/object.json by scripts/website-objects.py.\n'
            '// Do not edit by hand; change the object and run the script again.\n')
    f.write('export default ' + json.dumps(items, indent=2, ensure_ascii=False) + ';\n')
print(f'{len(items)} objects written to website/objects.js')
