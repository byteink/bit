# std/crypto

The cryptographic hash contract. `Hash` is the streaming interface every digest
in the library satisfies; concrete algorithms — SHA-256, SHA-512 — are separate
types that conform to it structurally, so code can hash against `Hash` without
naming a specific algorithm.

Because interfaces are structural, a type is a `Hash` simply by having the five
methods below. The example is a stand-in digest — it counts bytes rather than
hashing them — but a real one plugs in exactly the same way.

```bit
import { Hash, digest } from "std/crypto"

// A stand-in "digest": it remembers how many bytes it saw and returns a fixed
// 4-byte tag. A real SHA-256 satisfies `Hash` the same way — by its methods.
struct ByteCounter {
  seen: int
}

function (c: ByteCounter) write(data: []byte) {
  c.seen = c.seen + len(data)
}

function (c: ByteCounter) sum(): []byte {
  let out = []byte(4)
  out[0] = 1
  out[1] = 2
  out[2] = 3
  out[3] = 4
  return out
}

function (c: ByteCounter) reset() {
  c.seen = 0
}

function (c: ByteCounter) size(): int {
  return 4
}

function (c: ByteCounter) blockSize(): int {
  return 64
}

// Streaming: reset, feed bytes across as many `write`s as you like, read `sum`.
function streamed(c: ByteCounter): []byte {
  c.reset()
  c.write([]byte("ab"))
  c.write([]byte("c"))
  return c.sum()
}

// One-shot: `digest` does the reset / write / sum for a single buffer.
function oneShot(c: ByteCounter): []byte {
  return digest(c, []byte("abc"))
}
```

## The interface

### `Hash`

The streaming hash contract, modelled on Go's `hash.Hash`:

```bit ignore
interface Hash {
  write(data: []byte)   // absorb more input
  sum(): []byte         // the digest of everything written since the last reset
  reset()               // return to the empty state
  size(): int           // digest length in bytes (e.g. 32 for SHA-256)
  blockSize(): int      // internal block size in bytes (HMAC needs it)
}
```

Feed input with any number of `write` calls, then read the digest with `sum`.
`reset` rewinds to the empty state so one value can hash many messages. `size` is
the digest length and `blockSize` the algorithm's internal block size — HMAC keys
that block, so it must be able to ask.

## Helpers

### `digest(h: Hash, data: []byte): []byte`

Hashes a single buffer: resets `h`, writes `data`, and returns `h.sum()`. A
convenience over the streaming methods for the common one-buffer case.
