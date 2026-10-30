# The letter library

Every `.json` file in this folder is a collection of letters. The mailbox reads them all, together with `../letters.json`, and delivers them one at a time.

## Collections

- `history.json`: short, warm moments from letters real people wrote long ago. A garden, the weather, a pet, a friend, a funny small thing.

## Letters from history

These must be real, word for word. The rules:

- **Exact words only.** Copy the text from the published book, never from memory or a quote website. Keep the original spelling and punctuation.
- **Cuts are marked.** You may trim the start or the end. A cut in the middle is shown as `...`.
- **Public domain.** The book, and the translation if there is one, must be published before 1930. Project Gutenberg is the easiest source. Modern translations are not allowed.
- **Short and sweet.** About 30 to 110 words, one small everyday moment. No grief, illness, money worries, politics or anything that needs a history lesson.
- **Say where it came from.** Every letter has a `source` line: place and date if the book gives them, the book and its year, and "Public domain, via Project Gutenberg". It is printed small at the bottom of the letter.

A letter from history looks like this:

```json
{
  "id": "history-austen-lilacs",
  "from": "Jane Austen",
  "kind": "history",
  "title": "To her sister Cassandra",
  "body": "Your lilacs are in leaf, ours are in bloom. ...",
  "source": "London. The Letters of Jane Austen (1908). Public domain, via Project Gutenberg"
}
```

Ids must be unique across every file. Never reuse or rename an id: the mailbox remembers what it already delivered by id.
