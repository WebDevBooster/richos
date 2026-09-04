# The company registry — `entities.json`

RichOS files every conversation under a **company** (an *entity*, in the architecture's
words). That is not a folder or a label: it is a hard scope and privacy boundary. One
company's records never render inside another company's thread, and when RichOS cannot tell
which company a piece of work belongs to it refuses to file it rather than guessing.

This page is the format, the path, and a working example of the file that says which
companies you have.

---

## Where it is

```
~/Library/Application Support/com.richos.app/entities.json
```

It sits beside `config.json`, in the same directory as your conversation ledger.

**RichOS prints the exact path every time it starts**, and that printed line is the value to
trust — this page can go stale and the app cannot:

```
[richos] company registry: 2 compan(ies), /Users/you/Library/Application Support/com.richos.app/entities.json (file)
```

---

## You do not have to edit it

The ordinary way to add a company is in the window: RichOS asks which company this copy is
for the first time you open it, and the same panel has a control to add one. Everything below
is for the case where you would rather edit the file, or where somebody is setting RichOS up
for you.

**If the file is not there, nothing is wrong.** That is what a fresh install looks like. The
registry is empty, RichOS asks, and it writes your answer here.

---

## The format

```json
{
  "version": 1,
  "entities": [
    {
      "id": "northwind",
      "display_name": "Northwind Traders",
      "roots": ["/Users/example/Projects/northwind"]
    },
    {
      "id": "harbor",
      "display_name": "Harbor Analytics",
      "status": "active",
      "roots": [
        "/Users/example/Projects/harbor",
        "/Users/example/Projects/harbor-private"
      ]
    }
  ]
}
```

That example is not typed out here twice. It is `EXAMPLE_ENTITY_REGISTRY_JSON` in
`app/crates/richos-core/src/entity.rs`, and a test parses that exact string — so a documented
example the parser would reject cannot survive a build.

| field | required | what it is |
|---|---|---|
| `version` | yes | `1`. A file with any other version is refused rather than read as something it is not. |
| `id` | yes | A short, file-safe label: 1–64 characters of `a`–`z`, `0`–`9` and `-`, starting with a letter or digit. It reaches the filesystem, which is why the character class is narrow. When you add a company in the window, RichOS derives this from the name you type. |
| `display_name` | yes | What you want to see on a button. Anything you would recognize. |
| `status` | no | `active` (the default) or `archived`. This is about whether the company is *selectable in this install* — it is not a statement about the business. |
| `roots` | no | Absolute paths to folders this company owns. Every path must be absolute. Omit it, or leave it empty, if you do not want RichOS to pick this company automatically. |

### What `roots` actually does

If you start RichOS from a terminal inside one of those folders — or anywhere underneath one
— it selects that company for you. Nothing else. A company with no roots works completely;
you just pick it yourself instead of RichOS noticing.

Matching is by **path component**, never by text prefix. `/Projects/harb` is a text prefix of
`/Projects/harbor` and is *not* inside it, so it does not match. That is why `harbor-private`
in the example above needs its own line: it is a separate folder, listed on the same company,
and both resolve to `harbor`.

**Two companies must not own overlapping folders.** If one company's root contains another's,
every path underneath is ambiguous and RichOS blocks the turn rather than picking one. The
window refuses to create that situation; a hand-edited file can, and you will see it as a
refusal to file anything from that folder.

---

## When something is wrong with the file

**RichOS refuses the whole file rather than loading part of it**, and says so on the line it
prints at startup:

```
[richos] company registry at /Users/you/Library/.../entities.json is not valid: expected `,` or `}` at line 9 column 5. Nothing was loaded from it — no company is registered until it parses.
```

One bad entry does not quietly disappear. That is deliberate: a company that silently stopped
existing would take its conversations out of reach while the app carried on looking like it
was working, and nobody would notice for weeks. A file that refuses to load says which file
and what is wrong with it, and everything is still there once it is fixed.

The refusals, in full: not valid JSON; a `version` this build does not read; a field name it
does not recognize (`"root"` for `"roots"` is the common one); an `id` outside the character
class; an empty `display_name`; a root that is not an absolute path; the same `id` listed
twice.

While the file is unreadable, RichOS registers nothing and asks — it never falls back to a
company you did not name.

---

## Upgrading from an older RichOS

Builds before 2026-09-04 carried a fixed list of companies compiled into the app. When you
first run a newer build, RichOS reads which companies your existing conversations are already
filed under and writes them here, so nothing you have becomes unreachable:

```
[richos] company registry: this install already had threads under 6 compan(ies)
         (femcboost, deeply, prospects, richos, gpt-exporter, webinar-booster).
         They have been written to /Users/you/Library/.../entities.json so they keep
         resolving. No folder was guessed for any of them — open the company settings
         to add one.
```

**It does not guess folders**, because nothing on your Mac knows where those companies live
and a wrong folder is a wrong company. So after the upgrade, add the folder for any company
you want selected automatically — either in the window or by adding a `roots` line here. The
display names are derived from the ids (`gpt-exporter` becomes `Gpt Exporter`); edit
`display_name` to whatever you actually call them.

This runs **once**, only when the file does not exist at all. An empty `entities.json` is an
answer, and RichOS will not overwrite it.

---

## For whoever set RichOS up

`RICHOS_ENTITY=<id>` still overrides everything, and it is still validated against this file:
a value naming a company that is not registered is refused rather than falling through to
something else. It is an explicit statement made from outside the app, so the window renders
it as a statement and names who owns it, rather than a control that would not work.

`RICHOS_LORO_LANES=<id>=<lane>,...` still narrows the company-memory compile. Its default is
now derived from this file — one lane per registered company, named after it — which is the
same list first-run provisioning creates the corpus partitions from.

---

## Related

- `app/crates/richos-core/src/entity.rs` — the scope boundary itself, and the loader.
- `app/crates/richos-core/examples/fresh_user_first_run.rs` — a runnable walk through a
  profile with no configuration reaching a working conversation.
  `cargo run -p richos-core --example fresh_user_first_run`
