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
    'fridge': 'a fridge for your Mac files',
    'drawer': 'a wooden drawer for your Mac files',
    'mailbox': 'a post box for your Mac files',
    'vending': 'files on shelves for your Mac',
    'vending-keypad': 'type a code to get a file',
}

# Search descriptions, 155 characters or fewer so Google shows them whole.
DESC = {
    'fridge': 'A retro fridge on your Mac desktop that holds your files, with a heavy door, cold fog and frost. Free and open source, for macOS 14 or later.',
    'drawer': 'A wooden drawer that slides up from the bottom of your Mac screen and holds your files. Put Back returns them. Free and open source, for macOS 14+.',
    'mailbox': 'A red post box for your Mac desktop. Letters arrive now and then, and it holds your files behind its door. Free and open source, for macOS 14+.',
    'vending': 'A vending machine for your Mac desktop. Your files sit on little shelves; press a button and one drops. Free and open source, for macOS 14+.',
    'vending-keypad': 'The vending machine with a keypad: type a code like B2 and your file drops. It holds your files on your Mac desktop. Free and open source, macOS 14+.',
}

esc = html.escape


# Objects with a Windows beta: the installer from the GitHub pre-release.
WINDOWS_BETA = {
    'fridge': 'https://github.com/Electrofist/WhimsyDesk/releases/download/windows-fridge-beta.1/Desktop-Fridge-Setup.exe',
}

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
    desc = DESC.get(o['id']) or f"{o['tagline']} Free and open source, for macOS {o['minMacOS'].removesuffix('.0')} or later."
    if len(desc) > 155:
        desc = desc[:152].rsplit(' ', 1)[0] + '...'
    img = hero_image(o)
    feats = features(o['id'])
    feat_html = '\n'.join(f'        <li>{f}</li>' for f in feats)
    get = (f'<a class="btn btn--olive" href="{esc(o["download"])}">Download {esc(o["name"])}</a>'
           if o.get('download') else '<span class="btn btn--soon">Coming soon</span>')
    win = WINDOWS_BETA.get(o['id'])
    if win:
        get += f'<a class="btn btn--line-dark" href="{esc(win)}">Windows beta</a>'
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
  <link rel="icon" href="../media/favicon-32.png?v=2" sizes="32x32" type="image/png">
  <link rel="icon" href="../media/favicon-192.png?v=2" sizes="192x192" type="image/png">
  <link rel="apple-touch-icon" href="../media/apple-touch-icon.png?v=2">
  <link rel="preload" href="../fonts/instrument-sans.woff2" as="font" type="font/woff2" crossorigin>
  <link rel="stylesheet" href="../object-page.css">
  <script type="application/ld+json">{json.dumps(app_jsonld(o, url), ensure_ascii=False)}</script>
  <script type="application/ld+json">{json.dumps(crumbs, ensure_ascii=False)}</script>
</head>
<body>
  <header class="top">
    <a class="top__mark" href="../">WhimsyDesk</a>
    <nav aria-label="Main"><a href="../#objects">Library</a><a href="../make-your-own/">Make your own</a><a href="../faq/">FAQ</a><a href="{REPO}">GitHub</a></nav>
  </header>
  <main>
    <nav class="crumbs" aria-label="Breadcrumb"><a href="../">WhimsyDesk</a> <span aria-hidden="true">/</span> {esc(o['name'])}</nav>
    <article class="obj">
      <div class="obj__text">
        <p class="obj__kind">Free Mac app &middot; macOS {esc(o['minMacOS'].removesuffix('.0'))} or later{' &middot; Windows in beta' if o['id'] in WINDOWS_BETA else ''} &middot; Version {esc(o['version'])}</p>
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
        <dt>Works on</dt><dd>macOS {esc(o['minMacOS'].removesuffix('.0'))} or later, Apple silicon and Intel{'. Windows 10 and 11 in beta' if o['id'] in WINDOWS_BETA else ''}</dd>
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
  <footer class="foot"><a href="../">WhimsyDesk</a>: little objects for your Mac desktop that hold your files. Free and open source. <a href="../faq/">FAQ</a> &middot; <a href="{REPO}">GitHub</a></footer>
</body>
</html>
'''


# Guides from docs/, published on the site so they rank for whimsydesk.art, not github.com.
DOCS = [
    {'src': 'docs/faq.md', 'slug': 'faq', 'name': 'FAQ',
     'title': 'WhimsyDesk FAQ: where your files go, Put Back, battery and more',
     'desc': 'Answers about WhimsyDesk desktop objects for Mac: where your files are kept, Put Back, battery use, opening an unsigned app, and Windows.'},
    {'src': 'docs/make-your-own.md', 'slug': 'make-your-own', 'name': 'Make your own object',
     'title': 'Make your own Mac desktop object: a step-by-step guide | WhimsyDesk',
     'desc': 'Build your own desktop object for Mac from a template in about 15 minutes. Draw two pictures, set where files go, and send it in. No Swift needed.'},
]
DOC_LINKS = {'faq.md': '../faq/', 'make-your-own.md': '../make-your-own/'}


def doc_href(h):
    if re.match(r'^[a-z]+:', h) or h.startswith('#'):
        return h
    name = h.rsplit('/', 1)[-1]
    if name in DOC_LINKS:
        return DOC_LINKS[name]
    return f"{REPO}/blob/main/{h.removeprefix('../')}"


def doc_inline(s):
    s = esc(s, quote=False)
    s = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', s)
    s = re.sub(r'`([^`]+)`', r'<code>\1</code>', s)
    return re.sub(r'\[([^\]]+)\]\(([^)]+)\)', lambda m: f'<a href="{esc(doc_href(m.group(2)))}">{m.group(1)}</a>', s)


def slugify(t):
    return re.sub(r'[^a-z0-9]+', '-', t.lower()).strip('-')


def md_blocks(text):
    """A small Markdown reader for our own docs: headings, paragraphs, lists and code."""
    out, para, items, kind = [], [], [], None
    lines = text.splitlines()

    def flush():
        nonlocal para, items, kind
        if para:
            out.append(f'<p>{doc_inline(" ".join(para))}</p>')
            para = []
        if items:
            tag = 'ol' if kind == 'ol' else 'ul'
            out.append(f'<{tag}>' + ''.join(f'<li>{doc_inline(i)}</li>' for i in items) + f'</{tag}>')
            items, kind = [], None

    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith('```'):
            flush()
            code = []
            i += 1
            while i < len(lines) and not lines[i].startswith('```'):
                code.append(lines[i])
                i += 1
            out.append('<pre><code>' + esc('\n'.join(code), quote=False) + '</code></pre>')
        elif m := re.match(r'^(#{1,3})\s+(.*)', line):
            flush()
            lvl = len(m.group(1))
            if lvl > 1:
                out.append(f'<h{lvl} id="{slugify(m.group(2))}">{doc_inline(m.group(2))}</h{lvl}>')
        elif m := re.match(r'^(?:- |\d+\. )(.*)', line):
            if para:
                flush()
            k = 'ul' if line.startswith('- ') else 'ol'
            if items and k != kind:
                flush()
            kind = k
            items.append(m.group(1))
        elif not line.strip():
            flush()
        elif items:
            items[-1] += ' ' + line.strip()
        else:
            para.append(line.strip())
        i += 1
    flush()
    return '\n'.join(out)


def faq_jsonld(text):
    qa, q, a = [], None, []
    for line in text.splitlines() + ['## end']:
        if line.startswith('## '):
            if q:
                ans = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', ' '.join(a)).replace('`', '').replace('**', '')
                qa.append({'@type': 'Question', 'name': q,
                           'acceptedAnswer': {'@type': 'Answer', 'text': ans.strip()}})
            q, a = line[3:].strip(), []
        elif q and line.strip():
            a.append(line.strip())
    return {'@context': 'https://schema.org', '@type': 'FAQPage', 'mainEntity': qa}


def doc_page(d):
    text = open(os.path.join(ROOT, d['src'])).read()
    h1 = re.search(r'^#\s+(.*)', text, re.M).group(1)
    url = f"{BASE}{d['slug']}/"
    body = md_blocks(text)
    crumbs = {'@context': 'https://schema.org', '@type': 'BreadcrumbList', 'itemListElement': [
        {'@type': 'ListItem', 'position': 1, 'name': 'WhimsyDesk', 'item': BASE},
        {'@type': 'ListItem', 'position': 2, 'name': d['name'], 'item': url}]}
    ld = [crumbs] + ([faq_jsonld(text)] if d['slug'] == 'faq' else [])
    ld_html = '\n'.join(f'  <script type="application/ld+json">{json.dumps(x, ensure_ascii=False)}</script>' for x in ld)
    return f'''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
{HEAD_TAGS}
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{esc(d['title'])}</title>
  <meta name="description" content="{esc(d['desc'])}">
  <link rel="canonical" href="{url}">
  <meta property="og:type" content="article">
  <meta property="og:site_name" content="WhimsyDesk">
  <meta property="og:title" content="{esc(d['title'])}">
  <meta property="og:description" content="{esc(d['desc'])}">
  <meta property="og:url" content="{url}">
  <meta property="og:image" content="{BASE}media/og.png">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="theme-color" content="#ffffff">
  <link rel="icon" href="../media/favicon-32.png?v=2" sizes="32x32" type="image/png">
  <link rel="icon" href="../media/favicon-192.png?v=2" sizes="192x192" type="image/png">
  <link rel="apple-touch-icon" href="../media/apple-touch-icon.png?v=2">
  <link rel="preload" href="../fonts/instrument-sans.woff2" as="font" type="font/woff2" crossorigin>
  <link rel="stylesheet" href="../object-page.css">
{ld_html}
</head>
<body>
  <header class="top">
    <a class="top__mark" href="../">WhimsyDesk</a>
    <nav aria-label="Main"><a href="../#objects">Library</a><a href="../make-your-own/">Make your own</a><a href="../faq/">FAQ</a><a href="{REPO}">GitHub</a></nav>
  </header>
  <main>
    <nav class="crumbs" aria-label="Breadcrumb"><a href="../">WhimsyDesk</a> <span aria-hidden="true">/</span> {esc(d['name'])}</nav>
    <article class="doc">
      <h1>{doc_inline(h1)}</h1>
{body}
    </article>
  </main>
  <footer class="foot"><a href="../">WhimsyDesk</a>: little objects for your Mac desktop that hold your files. Free and open source. <a href="../faq/">FAQ</a> &middot; <a href="{REPO}">GitHub</a></footer>
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

    for d in DOCS:
        folder = os.path.join(SITE, d['slug'])
        os.makedirs(folder, exist_ok=True)
        open(os.path.join(folder, 'index.html'), 'w').write(doc_page(d))

    urls = [BASE] + [f"{BASE}{SLUGS[o['id']]}/" for o in objs if o['id'] in SLUGS]
    urls += [f"{BASE}{d['slug']}/" for d in DOCS]
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
    print(f'{len(urls) - 1 - len(DOCS)} object pages, {len(DOCS)} guides, sitemap with {len(urls)} addresses, homepage refreshed')


main()
