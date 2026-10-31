#!/usr/bin/env python3
"""Build the search-engine side of whimsydesk.art from the object cards.

Run from the repo root after scripts/website-objects.py:  python3 scripts/website-seo.py
Writes:
  website/<slug>/index.html   one page per object (title, description, screenshot, features, download)
  website/sitemap.xml         every public page
  website/index.html          refreshes the structured data and the plain-HTML object list between markers
Uses only the standard library.
"""
import html
import json
import os
import re
from datetime import date

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = os.path.join(ROOT, 'website')
BASE = 'https://whimsydesk.art/'
REPO = 'https://github.com/Electrofist/whimsydesk'
TODAY = date.today().isoformat()

# Page address for each object. Short, readable, and the words people search for.
SLUGS = {
    'fridge': 'desktop-fridge',
    'drawer': 'desktop-drawer',
    'mailbox': 'desktop-mailbox',
    'vending': 'desktop-vending-machine',
    'vending-keypad': 'desktop-vending-machine-keypad',
}
# Objects without their own README: features from the main README.
FALLBACK_FEATURES = {
    'drawer': [
        '<b>A wooden drawer along the bottom of your screen.</b> Slide it out, drop files in, push it shut.',
        '<b>Weight.</b> Friction, soft bumpers and a little bounce when it hits the stop.',
        '<b>Sound.</b> Wooden knocks and a sliding rumble that follows your hand.',
        '<b>Put Back.</b> Files go back to their exact spot on your desktop.',
    ],
}
# A line that says what the object is in plain search words, used in titles.
KIND = {
    'fridge': 'a fridge on your Mac desktop that holds your files',
    'drawer': 'a wooden drawer on your Mac desktop that holds your files',
    'mailbox': 'a post box on your Mac desktop with letters and file storage',
    'vending': 'a vending machine on your Mac desktop that holds your files',
    'vending-keypad': 'a keypad vending machine on your Mac desktop that holds your files',
}

esc = html.escape


# Makers with a site of their own.
SITES = {'Krrish Parmar': 'https://krisby.in'}


def maker(name):
    return f'<a href="{SITES[name]}">{esc(name)}</a>' if name in SITES else esc(name)

def load_objects():
    text = open(os.path.join(SITE, 'objects.js')).read()
    return json.loads(text[text.index('['):text.rindex(']') + 1])


def md_inline(s):
    s = esc(s, quote=False)
    s = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', s)
    s = re.sub(r'`([^`]+)`', r'<code>\1</code>', s)
    s = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', lambda m: m.group(1), s)   # keep link text only
    return s


def features(oid):
    """The bullets of the 'Use it' section of the object's README."""
    path = os.path.join(ROOT, 'objects', oid, 'README.md')
    if not os.path.exists(path):
        return FALLBACK_FEATURES.get(oid, [])
    lines = open(path).read().splitlines()
    out, on = [], False
    for line in lines:
        if re.match(r'^##\s+(Use it|Using it)\b', line):
            on = True
            continue
        if on and line.startswith('## '):
            break
        if on and line.startswith('- '):
            out.append(md_inline(line[2:].strip()))
    return out[:12]


def hero_image(o):
    for cand in (f"media/shots/{o['id']}.webp", o.get('art') or ''):
        if cand and os.path.exists(os.path.join(SITE, cand)):
            return cand
    return 'media/og.png'


def app_jsonld(o, url):
    data = {
        '@context': 'https://schema.org',
        '@type': 'SoftwareApplication',
        'name': o['name'],
        'description': o['description'],
        'applicationCategory': 'UtilitiesApplication',
        'operatingSystem': f"macOS {o['minMacOS'].removesuffix('.0')} or later",
        'softwareVersion': o['version'],
        'url': url,
        'image': BASE + hero_image(o),
        'license': 'https://opensource.org/licenses/MIT',
        'isAccessibleForFree': True,
        'offers': {'@type': 'Offer', 'price': '0', 'priceCurrency': 'USD'},
        'author': {'@type': 'Person', 'name': o['author'], 'url': SITES.get(o['author'], f"https://github.com/{o['github']}")},
        'publisher': {'@type': 'Organization', 'name': 'WhimsyDesk', 'url': BASE},
        'codeRepository': o['source'],
    }
    if o.get('download'):
        data['downloadUrl'] = o['download']
    return data


HEAD_TAGS = '''  <!-- Google tag (gtag.js) -->
  <script async src="https://www.googletagmanager.com/gtag/js?id=G-2DG23JLKP3"></script>
  <script>
    window.dataLayer = window.dataLayer || [];
    function gtag(){dataLayer.push(arguments);}
    gtag('js', new Date());
    gtag('config', 'G-2DG23JLKP3');
  </script>
  <!-- Microsoft Clarity -->
  <script type="text/javascript">
    (function(c,l,a,r,i,t,y){
        c[a]=c[a]||function(){(c[a].q=c[a].q||[]).push(arguments)};
        t=l.createElement(r);t.async=1;t.src="https://www.clarity.ms/tag/"+i;
        y=l.getElementsByTagName(r)[0];y.parentNode.insertBefore(t,y);
    })(window, document, "clarity", "script", "z6915i3wmu");
  </script>'''


def object_page(o, others):
    slug = SLUGS[o['id']]
    url = f'{BASE}{slug}/'
    title = f"{o['name']}: {KIND.get(o['id'], 'a desktop object for your Mac')} | WhimsyDesk"
    desc = f"{o['tagline']} {o['description']} Free and open source, for macOS {o['minMacOS'].removesuffix('.0')} or later."
    if len(desc) > 300:
        desc = desc[:297].rsplit(' ', 1)[0] + '...'
    img = hero_image(o)
    feats = features(o['id'])
    feat_html = '\n'.join(f'        <li>{f}</li>' for f in feats)
    get = (f'<a class="btn btn--olive" href="{esc(o["download"])}">Download {esc(o["name"])}</a>'
           if o.get('download') else '<span class="btn btn--soon">Coming soon</span>')
    more = '\n'.join(
        f'        <li><a href="../{SLUGS[x["id"]]}/"><img src="../{esc(x["icon"])}" alt="" width="48" height="48" loading="lazy"><span><b>{esc(x["name"])}</b>{esc(x["tagline"])}</span></a></li>'
        for x in others if x['id'] in SLUGS)
    crumbs = {
        '@context': 'https://schema.org', '@type': 'BreadcrumbList',
        'itemListElement': [
            {'@type': 'ListItem', 'position': 1, 'name': 'WhimsyDesk', 'item': BASE},
            {'@type': 'ListItem', 'position': 2, 'name': o['name'], 'item': url},
        ]}
    return f'''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
{HEAD_TAGS}
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{esc(title)}</title>
  <meta name="description" content="{esc(desc)}">
  <link rel="canonical" href="{url}">
  <meta property="og:type" content="website">
  <meta property="og:site_name" content="WhimsyDesk">
  <meta property="og:title" content="{esc(o['name'])} for Mac">
  <meta property="og:description" content="{esc(o['tagline'])} Free and open source.">
  <meta property="og:url" content="{url}">
  <meta property="og:image" content="{BASE}{img}">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="theme-color" content="#ffffff">
  <link rel="icon" href="../media/favicon-32.png" sizes="32x32" type="image/png">
  <link rel="apple-touch-icon" href="../media/apple-touch-icon.png">
  <link rel="preload" href="../fonts/instrument-sans.woff2" as="font" type="font/woff2" crossorigin>
  <link rel="stylesheet" href="../object-page.css">
  <script type="application/ld+json">{json.dumps(app_jsonld(o, url), ensure_ascii=False)}</script>
  <script type="application/ld+json">{json.dumps(crumbs, ensure_ascii=False)}</script>
</head>
<body>
  <header class="top">
    <a class="top__mark" href="../">WhimsyDesk</a>
    <nav aria-label="Main"><a href="../#objects">Library</a><a href="../#make">Make your own</a><a href="{REPO}">GitHub</a></nav>
  </header>
  <main>
    <nav class="crumbs" aria-label="Breadcrumb"><a href="../">WhimsyDesk</a> <span aria-hidden="true">/</span> {esc(o['name'])}</nav>
    <article class="obj">
      <div class="obj__text">
        <p class="obj__kind">Free Mac app &middot; macOS {esc(o['minMacOS'].removesuffix('.0'))} or later &middot; Version {esc(o['version'])}</p>
        <h1>{esc(o['name'])}</h1>
        <p class="obj__tag">{esc(o['tagline'])}</p>
        <p class="obj__desc">{esc(o['description'])}</p>
        <div class="obj__actions">{get}<a class="quiet" href="{esc(o['source'])}">View the source</a></div>
      </div>
      <figure class="obj__shot"><img src="../{esc(img)}" alt="{esc(o['name'])} on a Mac desktop" loading="eager"></figure>
    </article>

    <section class="block" aria-labelledby="use">
      <h2 id="use">How it works</h2>
      <ul class="feats">
{feat_html}
      </ul>
    </section>

    <section class="block" aria-labelledby="facts">
      <h2 id="facts">At a glance</h2>
      <dl class="facts">
        <dt>Keeps files in</dt><dd><code>{esc(o['folder'])}</code>, a normal folder you can open in Finder</dd>
        <dt>Works on</dt><dd>macOS {esc(o['minMacOS'].removesuffix('.0'))} or later, Apple silicon and Intel</dd>
        <dt>Price</dt><dd>Free. No ads, no accounts, no tracking in the app</dd>
        <dt>Licence</dt><dd>MIT, open source</dd>
        <dt>Made by</dt><dd>{maker(o['author'])}</dd>
      </dl>
    </section>

    <section class="block" aria-labelledby="install">
      <h2 id="install">Install</h2>
      <ol class="steps">
        <li>Download the .dmg and open it.</li>
        <li>Drag the app into Applications and open it from there.</li>
        <li>The first time, macOS may say it cannot be opened, because the app is not registered with Apple yet. Open System Settings, then Privacy &amp; Security, and click Open Anyway. You only do this once.</li>
      </ol>
    </section>

    <section class="block" aria-labelledby="more">
      <h2 id="more">More objects</h2>
      <ul class="more">
{more}
      </ul>
    </section>
  </main>
  <footer class="foot"><a href="../">WhimsyDesk</a>: little objects for your Mac desktop that hold your files. Free and open source. <a href="{REPO}">GitHub</a></footer>
</body>
</html>
'''


def site_jsonld(objs):
    graph = [
        {'@type': 'WebSite', '@id': BASE + '#site', 'url': BASE, 'name': 'WhimsyDesk',
         'description': 'Free, open source objects for your Mac desktop that hold your files.'},
        {'@type': 'Organization', '@id': BASE + '#org', 'name': 'WhimsyDesk', 'url': BASE,
         'logo': BASE + 'media/apple-touch-icon.png', 'sameAs': [REPO]},
        {'@type': 'ItemList', 'name': 'WhimsyDesk objects',
         'itemListElement': [{'@type': 'ListItem', 'position': i + 1, 'url': f"{BASE}{SLUGS[o['id']]}/", 'name': o['name']}
                             for i, o in enumerate(objs) if o['id'] in SLUGS]},
    ]
    return json.dumps({'@context': 'https://schema.org', '@graph': graph}, ensure_ascii=False)


def replace_between(text, start, end, body):
    a, b = text.index(start) + len(start), text.index(end)
    return text[:a] + body + text[b:]


def main():
    objs = load_objects()
    for o in objs:
        if o['id'] not in SLUGS:
            continue
        others = [x for x in objs if x['id'] != o['id']]
        folder = os.path.join(SITE, SLUGS[o['id']])
        os.makedirs(folder, exist_ok=True)
        open(os.path.join(folder, 'index.html'), 'w').write(object_page(o, others))

    urls = [BASE] + [f"{BASE}{SLUGS[o['id']]}/" for o in objs if o['id'] in SLUGS]
    sm = ['<?xml version="1.0" encoding="UTF-8"?>', '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
    sm += [f'  <url><loc>{u}</loc><lastmod>{TODAY}</lastmod></url>' for u in urls]
    sm.append('</urlset>')
    open(os.path.join(SITE, 'sitemap.xml'), 'w').write('\n'.join(sm) + '\n')

    p = os.path.join(SITE, 'index.html')
    s = open(p).read()
    s = replace_between(s, '<!-- seo:jsonld -->', '<!-- /seo:jsonld -->',
                        f'\n  <script type="application/ld+json">{site_jsonld(objs)}</script>\n  ')
    cards = '\n'.join(
        f'        <li><a href="{SLUGS[o["id"]]}/"><b>{esc(o["name"])}</b>: {esc(o["tagline"])}</a></li>'
        for o in objs if o['id'] in SLUGS)
    s = replace_between(s, '<!-- seo:objects -->', '<!-- /seo:objects -->',
                        f'\n      <ul class="lib-list">\n{cards}\n      </ul>\n      ')
    open(p, 'w').write(s)
    print(f'{len(urls) - 1} object pages, sitemap with {len(urls)} addresses, homepage refreshed')


main()
