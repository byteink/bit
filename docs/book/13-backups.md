# Backups

<!-- doctest: per-block -->

Inkwell's drafts live as files on your disk. A failing drive, a bad `rm`, or a
stolen laptop loses them for good unless there is a backup somewhere else -
and a backup you cannot trust is barely better than no backup: it should
resist a bit of corruption in storage or transit, and it should not be
plain text sitting wherever you put it. This part builds one file that is
encrypted, checked for corruption, and restorable.

## Catching corruption cheaply, before decrypting

`std/hash`'s `crc32c` is a fast checksum for accidental corruption - a torn
write, a flipped bit on the wire. It is not a security primitive: anyone
who can change the data can recompute a matching checksum. Use it to fail
fast and clearly on an obviously broken file, before reaching for something
more expensive:

```bit
import { crc32c } from "std/hash"

fn checkedRead(data: []byte, wantSum: u32): []byte! {
  if (crc32c(data) != wantSum) {
    fail newError("corrupted: checksum mismatch")
  }
  return data
}

fn main() {
  let data = []byte{ 1, 2, 3 }
  let sum = crc32c(data)
  let ok = checkedRead(data, sum) catch _ {
    println("rejected")
    return
  }
  println("accepted ${len(ok)} byte(s)")
}
```

## Encrypting and authenticating together

A checksum alone does not stop a tamperer, and it does nothing for
confidentiality. `std/crypto`'s AES-GCM does both in one pass: `seal`
encrypts and appends an authentication tag; `open` recomputes that tag and
*fails* on any mismatch, so tampered ciphertext or the wrong key never
produces plaintext:

```bit
import { newGcm, randomBytes } from "std/crypto"

fn roundTrip(key: []byte, plaintext: []byte): []byte! {
  let nonce = randomBytes(12)
  let cipher = newGcm(key)?
  let ciphertext = cipher.seal(nonce, plaintext, []byte(0))
  return cipher.open(nonce, ciphertext, []byte(0))?
}

fn main() {
  let key = randomBytes(32)
  let back = roundTrip(key, []byte("a draft's body")) catch e {
    println("failed: ${e.message()}")
    return
  }
  println("recovered ${len(back)} byte(s)")
}
```

`key` here is 32 bytes (AES-256-GCM); `nonce` must never repeat under the
same key - see std/crypto's AES-GCM section for what goes wrong if it does.

## Compressing for cold storage

`std/compress`'s `gzip` shrinks a backup before it leaves the machine. It is
**encoding only** - there is no decoder in `std/compress` - so a compressed
export is for archiving outside Inkwell, decoded later with a standard tool
(`gzip -d`), not for Inkwell to read back itself:

```bit
import { gzip } from "std/compress"

fn coldExport(data: []byte): []byte! {
  return gzip(data, 6)?
}

fn main() {
  let out = coldExport([]byte("draft one, draft two")) catch e {
    println("failed: ${e.message()}")
    return
  }
  println("gzip magic: ${out[0]} ${out[1]}")
}
```

Because of that one-way limit, the backup Inkwell itself restores from is
encrypted but *not* compressed - compressing after encryption would not
help anyway, since ciphertext looks like noise and does not compress.

## Wired into Inkwell

`ink/backup.bit` puts the three together. `serializeDrafts` packs every
draft's id and body into one buffer with a length prefix on each field, so
neither can be confused with the other on the way back. `backupDrafts`
encrypts that buffer with AES-256-GCM and stores a CRC-32C of the
*ciphertext* ahead of it - a cheap check `restoreDrafts` runs before the
more expensive authenticated decrypt, so a truncated or bit-flipped file
fails with a clear "corrupted" message rather than the AEAD's generic
authentication error. `exportCompressed` is the separate, gzip-compressed
cold copy for archiving outside Inkwell.

```bit
export enum Status { Draft, Published, Archived }

export class Draft {
  export id: string,
  export title: string,
  export body: string,
  export tags: []string,
  export status: Status,
  export created: i64,
  export updated: i64,
}

import { crc32c } from "std/hash"
import { newGcm } from "std/crypto"
import { gzip } from "std/compress"

// Appends `s` as a 4-byte big-endian length followed by its bytes.
fn appendLenPrefixed(dst: []byte, s: string): []byte {
  let n = len(s)
  dst = append(dst, byte((n >> 24) & 0xff))
  dst = append(dst, byte((n >> 16) & 0xff))
  dst = append(dst, byte((n >> 8) & 0xff))
  dst = append(dst, byte(n & 0xff))
  dst = append(dst, s)
  return dst
}

// Reads one length-prefixed string starting at `pos`, returning it and the
// position just past it. Every length is checked against `len(data)` before
// it is trusted, the same discipline std/tz's own blob reader uses.
fn readLenPrefixed(data: []byte, pos: int): (string, int)! {
  if (pos + 4 > len(data)) {
    fail newError("backup: truncated length")
  }
  let n = (int(data[pos]) << 24) |
    (int(data[pos + 1]) << 16) |
    (int(data[pos + 2]) << 8) |
    int(data[pos + 3])
  let start = pos + 4
  if (n < 0 || start + n > len(data)) {
    fail newError("backup: truncated field")
  }
  return (string(data[start:start + n]), start + n)
}

// Serializes every draft's id and body into one buffer: each as a pair of
// length-prefixed strings, in order. Extending this to title, tags and
// status is the same pattern, one more `appendLenPrefixed` call.
export fn serializeDrafts(drafts: []Draft): []byte {
  let out = []byte(0)
  for d of drafts {
    out = appendLenPrefixed(out, d.id)
    out = appendLenPrefixed(out, d.body)
  }
  return out
}

// The inverse of `serializeDrafts`. Each recovered draft has only its id and
// body set; the fields `serializeDrafts` did not back up come back zeroed.
export fn deserializeDrafts(data: []byte): []Draft! {
  let out = []Draft(0)
  let pos = 0
  while (pos < len(data)) {
    let (id, afterId) = readLenPrefixed(data, pos)?
    let (body, afterBody) = readLenPrefixed(data, afterId)?
    out = append(
      out,
      Draft{
        id = id,
        title = "",
        body = body,
        tags = []string(0),
        status = Status.Draft,
        created = 0,
        updated = 0,
      },
    )
    pos = afterBody
  }
  return out
}

// Encrypts every draft into a backup blob: a 4-byte big-endian CRC-32C of
// the ciphertext (a cheap corruption check `restoreDrafts` runs before the
// more expensive authenticated decrypt), the 12-byte nonce `seal` needs,
// then the ciphertext itself. `key` is 16 or 32 bytes (AES-128/256-GCM) and
// `nonce` must never repeat under the same key.
export fn backupDrafts(drafts: []Draft, key: []byte, nonce: []byte): []byte! {
  let cipher = newGcm(key)?
  let ciphertext = cipher.seal(nonce, serializeDrafts(drafts), []byte(0))
  let sum = crc32c(ciphertext)
  let out = []byte(0)
  out = append(out, byte((sum >> 24) & 0xff))
  out = append(out, byte((sum >> 16) & 0xff))
  out = append(out, byte((sum >> 8) & 0xff))
  out = append(out, byte(sum & 0xff))
  out = append(out, string(nonce))
  out = append(out, string(ciphertext))
  return out
}

// The inverse of `backupDrafts`: checks the CRC-32C first, so an obviously
// corrupted (truncated or bit-flipped) backup fails with a clear "corrupted"
// message rather than the AEAD's generic authentication error - then
// verifies and decrypts with `key`, which fails on a wrong key or a
// tampered ciphertext the checksum did not happen to catch.
export fn restoreDrafts(blob: []byte, key: []byte): []Draft! {
  if (len(blob) < 4 + 12) {
    fail newError("backup: too short to be a backup")
  }
  let want = u32((int(blob[0]) << 24) | (int(blob[1]) << 16) | (int(blob[2]) << 8) | int(blob[3]))
  let nonce = blob[4:16]
  let ciphertext = blob[16:len(blob)]
  if (crc32c(ciphertext) != want) {
    fail newError("backup: corrupted (checksum mismatch)")
  }
  let cipher = newGcm(key)?
  let plaintext = cipher.open(nonce, ciphertext, []byte(0))?
  return deserializeDrafts(plaintext)?
}

// A compressed cold-storage export of every draft's id and body - not
// something `restoreDrafts` reads back. `std/compress` only encodes, so
// getting this back to bytes needs a standard gzip tool (`gzip -d`) outside
// Inkwell. Use it to archive a copy outside the encrypted backup, not as a
// second way to restore.
export fn exportCompressed(drafts: []Draft): []byte! {
  return gzip(serializeDrafts(drafts), 6)?
}

fn main() {
  let drafts = []Draft{
    Draft{
      id = "1", title = "", body = "first draft body", tags = []string(0),
      status = Status.Draft, created = 0, updated = 0,
    },
  }
  let key = []byte{
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
    17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
  }
  let nonce = []byte{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }

  let blob = backupDrafts(drafts, key, nonce) catch e {
    println("backup failed: ${e.message()}")
    return
  }
  let restored = restoreDrafts(blob, key) catch e {
    println("restore failed: ${e.message()}")
    return
  }
  println("restored ${len(restored)} draft(s)")
}
```

## Sharp edges

- `newGcm` accepts a 16- or 32-byte key only, and `seal`/`open` need a
  12-byte nonce - a wrong length panics. Generate both with
  `std/crypto.randomBytes` (never a hand-picked value like the fixed key
  above, which exists here only so this page's output does not change on
  every run) and never reuse a `(key, nonce)` pair.
- A one-byte change anywhere in a stored backup - even in the CRC-32C header
  itself - makes `restoreDrafts` fail: that is the checksum and the AEAD tag
  both doing their job, not a bug to work around.
- Losing the key loses the backup. Nothing here recovers a backup encrypted
  under a key you no longer have; keep the key somewhere separate from the
  backup file itself.

## When not to reach for encryption

A backup that never leaves a disk you already trust and control - a second
internal drive, say - gets most of its value from `serializeDrafts` and a
plain file copy; encryption matters most once the backup can leave your
machine (a USB drive, a cloud upload). Add it before you need it, not after
a backup has already left your hands unencrypted.

## What we built

Inkwell now backs up every draft into one encrypted file, checks it for
corruption before decrypting, and restores it back into `Draft` values. You
used `crc32c` for a cheap integrity check, AES-256-GCM for confidentiality
and authenticity together, and `gzip` for a separate, compressed cold
export.

Next: [Part 4, Inkwell goes online](../../pkg/web/guides/01-first-endpoint.md),
where Inkwell's drafts become articles served over HTTP.
