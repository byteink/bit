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
