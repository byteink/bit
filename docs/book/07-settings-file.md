<!-- doctest: deps toml -->

# A settings file

Inkwell reads and writes drafts from `~/.ink/drafts` and it assumes a reader
gets through 200 words a minute. Both of those are guesses, and a guess a
user cannot change is a bug waiting to be filed. This chapter gives Inkwell a
settings file, `ink.toml`, and reads it into a typed `Settings` value instead
of scattering `env()` calls through the rest of the program.

## Why TOML, and why typed

A settings file is edited by hand, so it has to read like a short list of
facts, not a data structure. TOML is exactly that:

```
[ink]
drafts_dir = "~/notes"
words_per_minute = 180
```

`bitlang.org/pkg/toml` turns that text into a `Toml` value - a tree of
tables, strings, integers and the rest - but a tree of `Toml` is still the
wrong shape to hand to the rest of Inkwell: every call site would need to
know that `words_per_minute` lives two levels down and match on whether it
parsed as an int. `loadSettings` does that matching once, at startup, and
hands back a `Settings` every other function can just use.

## The simplest thing that works

```bit
import { readFile } from "std/fs"
import { tomlAsInt, tomlAsString, tomlAsTable, tomlParse, Toml, TomlEntry } from "toml"

// Everything `ink` reads from its settings file, decoded once at startup.
export class Settings {
  draftsDir: string,
  wordsPerMinute: int,
}

fn defaultSettings(): Settings {
  return Settings{ draftsDir = "~/.ink/drafts", wordsPerMinute = 200 }
}

fn field(entries: []TomlEntry, key: string): Option<Toml> {
  for e of entries {
    if (e.key == key) {
      return Option.Some(e.value)
    }
  }
  return Option.None
}

fn requireTable(t: Option<[]TomlEntry>, path: string): []TomlEntry! {
  match (t) {
    Some(entries) => return entries
    None => fail newError("${path}: the document must be a table")
  }
}
```

`field` is a small linear search: `pkg/toml` has no `tomlGet`, so this is
the one line Inkwell writes for itself to look a key up by name in a
decoded table. `requireTable` turns the `Option` `tomlAsTable` hands back
into a fallible result, naming the file when the document at the top level
is not a table at all - an empty file, or one that is just a bare value.

## Reading each field, with its own default

Every setting Inkwell reads follows the same shape: look the key up, and if
it is there, insist on the right TOML type; if it is not, keep the default.
Three small functions do this once each, so `loadSettings` itself reads as a
list of fields, not a list of `match` blocks:

```bit
fn table(entries: []TomlEntry, key: string, path: string): []TomlEntry! {
  match (field(entries, key)) {
    Some(v) => {
      match (tomlAsTable(v)) {
        Some(t) => return t
        None => fail newError("${path}.${key} must be a table")
      }
    }
    None => return []TomlEntry(0)
  }
}

fn stringOr(entries: []TomlEntry, key: string, path: string, fallback: string): string! {
  match (field(entries, key)) {
    Some(v) => {
      match (tomlAsString(v)) {
        Some(s) => return s
        None => fail newError("${path}.${key} must be a string")
      }
    }
    None => return fallback
  }
}

fn intOr(entries: []TomlEntry, key: string, path: string, fallback: int): int! {
  match (field(entries, key)) {
    Some(v) => {
      match (tomlAsInt(v)) {
        Some(i) => return i
        None => fail newError("${path}.${key} must be an integer")
      }
    }
    None => return fallback
  }
}

// Reads `path` (usually "ink.toml") and decodes its `[ink]` table into a
// `Settings`. A missing `[ink]` table, or a missing key inside it, keeps the
// default; a key of the wrong TOML type fails, naming the key.
export fn loadSettings(path: string): Settings! {
  let src = readFile(path)?
  let root = requireTable(tomlAsTable(tomlParse(src)?), path)?
  let defaults = defaultSettings()
  let section = table(root, "ink", path)?
  return Settings{
    draftsDir = stringOr(section, "drafts_dir", "ink", defaults.draftsDir)?,
    wordsPerMinute = intOr(section, "words_per_minute", "ink", defaults.wordsPerMinute)?,
  }
}
```

A settings file with no `[ink]` table at all is not an error - a brand new
`ink` install has no `ink.toml`, and Inkwell should still run with sane
defaults rather than refuse to start.

## Using it

```bit
fn main(): ()! {
  let settings = loadSettings("ink.toml") catch _ {
    Settings{ draftsDir = "~/.ink/drafts", wordsPerMinute = 200 }
  }
  print("drafts live in ${settings.draftsDir}\n")
}
```

A missing `ink.toml` file itself is `readFile`'s own error, not one this
chapter adds - `main` treats "no file" the same as "file with no `[ink]`
table": fall back to the built-in defaults.

## Sharp edges

A `words_per_minute` written as `"180"` (quoted) is a TOML string, not an
integer, and `intOr` rejects it: `ink.words_per_minute must be an integer`.
That is deliberate - silently parsing a string as a number would also accept
`"18o"` and hand the rest of the program garbage. Fix the file, not the
loader.

## What you built

`ink.toml` now controls where drafts live and how fast Inkwell assumes you
read, decoded once into a `Settings` that the rest of the program uses
without ever touching TOML again.

Specification: [pkg/toml](/packages/toml).

Next: [Import and export](/book/08-import-and-export).
