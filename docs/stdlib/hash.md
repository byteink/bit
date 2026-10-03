# std/hash

CRC-32 (IEEE 802.3, the zlib polynomial), CRC-32C (Castagnoli) and CRC-64/NVME -
fast checksums for detecting accidental corruption: a torn write, a flipped bit on
the wire. **Not a tool for detecting tampering**
- CRC is linear, so anyone able to modify the data can trivially recompute a
matching checksum. For anything that must resist a tamperer, use
`std/crypto`'s HMAC or a signature instead; that split is why this lives in
its own module rather than beside SHA-256 in `std/crypto`.

`crc32c` uses the Castagnoli polynomial (0x1EDC6F41, reflected 0x82F63B78) -
the one ext4 metadata, Btrfs, iSCSI, SCTP, LevelDB and RocksDB checksum with.
Table-driven, software only.

`crc32` uses the zlib/Ethernet polynomial (0x04C11DB7, reflected 0xEDB88320) -
the one gzip, PNG, ZIP, Ethernet and the S3 `CRC32` checksum algorithm use.
Slicing-by-8, software only. The two are different functions that give
different values for the same input, so pick the one your peer or file format
names.

`crc64nvme` is the 64-bit NVMe polynomial (0xAD93D23594C93659, reflected
0x9A6C9329AC4BC9B5, init and xorout all-ones) - the one the NVMe end-to-end
protection CRC, the Linux kernel's `lib/crc64.c` and the S3 `CRC64NVME`
checksum algorithm use. Slicing-by-8, software only. It is the CRC RevEng
catalogue's CRC-64/NVME, not CRC-64/XZ or CRC-64/ECMA-182, which give
different values.

### `crc32(data: []byte): u32`

The CRC-32 of `data`, seeded fresh. Matches the published CRC-32/ISO-HDLC
check value: `crc32` of the nine ASCII bytes `"123456789"` is `0xCBF43926`,
and it equals zlib's `crc32()`. The empty slice checksums to `0x00000000`.

### `crc32Update(seed: u32, data: []byte): u32`

Extends a running CRC-32 by `data`. `seed` is the previous call's result - or
`0` to start a fresh checksum - so `crc32Update(crc32Update(0, a), b)` equals
`crc32(a ++ b)` for any split, including empty halves.

```bit
import { crc32, crc32Update } from "std/hash"

// A gzip-style trailer checksum over a payload that arrives in chunks.
fn chunkedChecksum(first: []byte, rest: []byte): u32 {
  return crc32Update(crc32Update(0, first), rest)
}

fn payloadChecksum(buf: []byte): u32 {
  return crc32(buf)
}
```

### `crc32c(data: []byte): u32`

The CRC-32C of `data`, seeded fresh. Matches the published CRC-32/ISCSI
check value: `crc32c` of the nine ASCII bytes `"123456789"` is `0xE3069283`.
The empty slice checksums to `0x00000000`.

### `crc32cUpdate(seed: u32, data: []byte): u32`

Extends a running CRC-32C by `data`. `seed` is the previous call's result -
or `0` to start a fresh checksum - so a value spread across several chunks
(a page header, then its body) can be checksummed without first
concatenating them into one allocation.

```bit
import { crc32c, crc32cUpdate } from "std/hash"

// A page checksum computed over a header and a body, with no allocation to
// join them first.
fn pageChecksum(header: []byte, body: []byte): u32 {
  return crc32cUpdate(crc32cUpdate(0, header), body)
}

fn wholeBufferChecksum(buf: []byte): u32 {
  return crc32c(buf)
}
```

### `crc64nvme(data: []byte): u64`

The CRC-64/NVME of `data`, seeded fresh. Matches the published check value:
`crc64nvme` of the nine ASCII bytes `"123456789"` is `0xAE8B14860A799888`.
The empty slice checksums to `0`. S3 sends the value as the big-endian
8 bytes of the `u64`, base64-encoded (`"123456789"` is `rosUhgp5mIg=`).

### `crc64nvmeUpdate(seed: u64, data: []byte): u64`

Extends a running CRC-64/NVME by `data`. `seed` is the previous call's
result - or `0` to start a fresh checksum - so
`crc64nvmeUpdate(crc64nvmeUpdate(0, a), b)` equals `crc64nvme(a ++ b)` for
any split, including empty halves.

```bit
import { crc64nvme, crc64nvmeUpdate } from "std/hash"

// An object checksum accumulated while a body streams in chunks, then
// compared with the one-shot value over the whole buffer.
fn streamedChecksum(chunks: [][]byte): u64 {
  let crc: u64 = 0
  for chunk of chunks {
    crc = crc64nvmeUpdate(crc, chunk)
  }
  return crc
}

fn matchesWhole(chunks: [][]byte, whole: []byte): bool {
  return streamedChecksum(chunks) == crc64nvme(whole)
}
```

## xxHash64

Inkwell stores every draft under a key, and the backup tool wants to know
whether two drafts are identical without comparing them byte for byte - and
to spread them across shards. A CRC is the wrong tool for that: it is built to
catch corruption in a channel, not to mix its input evenly. xxHash64 is Yann
Collet's non-cryptographic 64-bit hash (the XXH64 of the
[xxHash](https://github.com/Cyan4973/xxHash) library): well mixed, faster than
`crc64nvme`, and the S3 `XXHASH64` checksum algorithm.
Like the CRCs it is **not** for detecting tampering - anyone who knows the
seed can build colliding inputs; use `std/crypto` for that. Its result is
bit-for-bit the reference library's `XXH64`: the one-shot and the streaming
hasher are both checked against the reference's own 8322 sanity vectors
(every length 0 to 4160, two seeds) and a 1 MiB buffer.

### `xxhash64(data: []byte, seed: u64 = 0): u64`

The xxHash64 of `data` under `seed`. The seed is the full 64 bits and defaults
to `0`. The empty slice hashes to `0xEF46DB3751D8E999` under seed `0`, and
`xxhash64([]byte("abc"))` is `0x44BC2CF5AD770999`. Different seeds give
unrelated hashes of the same bytes, which is how to derive several
independent hash functions from one.

```bit
import { xxhash64 } from "std/hash"

// Which of `shards` backup shards stores this draft.
fn shardFor(draftKey: string, shards: int): int {
  return int(xxhash64([]byte(draftKey)) % u64(shards))
}

// Two drafts are the same text with overwhelming probability when their
// hashes match; compare the bytes only on a match.
fn probablySame(a: []byte, b: []byte): bool {
  return xxhash64(a) == xxhash64(b)
}
```

### `Xxhash64(seed: u64 = 0)`

A streaming hasher, for a body that arrives in chunks and should not be
concatenated first. `Xxhash64()` starts a hash under seed `0`;
`Xxhash64(seed)` under that seed. Whatever the chunking - one byte at a time,
chunks of 7, 32 or 33 bytes, empty chunks in between - the result equals
`xxhash64` of the concatenation, so a streamed S3 upload and a one-shot hash
of the same object agree.

### `Xxhash64.update(data: []byte)`

Absorbs `data`. Bytes that do not yet fill a 32-byte stripe wait inside the
hasher, so no call allocates per chunk.

### `Xxhash64.digest(): u64`

The hash of everything absorbed so far. It does not consume the hasher: call
it after every chunk for a running value, and keep calling `update` after.

### `Xxhash64.reset()`

Rewinds to the empty input under the same seed, so one hasher can hash many
drafts in turn.

```bit
import { Xxhash64, xxhash64 } from "std/hash"

// Hash a draft that is read in chunks, then reuse the hasher for the next.
fn hashDrafts(first: [][]byte, second: [][]byte): bool {
  let h = Xxhash64()
  for chunk of first {
    h.update(chunk)
  }
  let firstHash = h.digest()
  h.reset()
  for chunk of second {
    h.update(chunk)
  }
  let secondHash = h.digest()
  return firstHash != secondHash
}

fn matchesOneShot(chunks: [][]byte, whole: []byte): bool {
  let h = Xxhash64(42)
  for chunk of chunks {
    h.update(chunk)
  }
  return h.digest() == xxhash64(whole, 42)
}
```

## XXH3-64

Inkwell's backup tool also shards short keys - a draft title is a dozen bytes
and a tag list a few dozen. XXH3, the hash the S3 `XXHASH3` checksum
algorithm names, is the newer hash from the same
[xxHash](https://github.com/Cyan4973/xxHash) library: it picks one of
several straight-line paths by input length (0 to 16, 17 to 128, 129 to 240
bytes) instead of looping over stripes, which is what makes it suit short
keys.
Like `xxhash64` it is **not** for detecting tampering - the 17 to 240 byte
path has documented collision weaknesses, and anyone who knows the seed can
build colliding inputs; use `std/crypto` for that. Its result is bit-for-bit
the reference library's `XXH3_64bits` (and `XXH3_64bits_withSeed` for a
nonzero seed).

### `xxh3_64(data: []byte, seed: u64 = 0): u64`

The XXH3 64-bit hash of `data` under `seed`. The seed is the full 64 bits and
defaults to `0`. The empty slice hashes to `0x2D06800538D394C2` under seed
`0`, and `xxh3_64([]byte("abc"))` is `0x78AF5F94892F3950`. The hash is
checked against the reference's own sanity vectors for every length from 0
to 240 under two seeds (482 vectors), plus seeds with high bits set.

Inputs of 241 bytes or more are not supported yet: `xxh3_64` panics with a
message naming the ticket that adds them, rather than return a hash that
would disagree with the reference. Hash only drafts that fit, or fall back to
`xxhash64`, until then.

```bit
import { xxh3_64 } from "std/hash"

// Which of `shards` backup shards stores this tag list. Tag lists are short,
// so they take XXH3's constant-time path.
fn tagShardFor(tags: string, shards: int): int {
  return int(xxh3_64([]byte(tags)) % u64(shards))
}

// A draft title is at most 240 bytes, so it always fits; a per-library seed
// keeps two libraries' hash tables unrelated.
fn titleKey(title: string, librarySeed: u64): u64 {
  return xxh3_64([]byte(title), librarySeed)
}
```
