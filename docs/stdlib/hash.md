# std/hash

CRC-32C (Castagnoli) - a fast checksum for detecting accidental corruption: a
torn write, a flipped bit on the wire. **Not an integrity or security
primitive** - CRC is linear, so anyone able to modify the data can trivially
recompute a matching checksum. For anything that must resist a tamperer, use
`std/crypto`'s HMAC or a signature instead; that split is why this lives in
its own module rather than beside SHA-256 in `std/crypto`.

Uses the Castagnoli polynomial (0x1EDC6F41, reflected 0x82F63B78) - the one
ext4 metadata, Btrfs, iSCSI, SCTP, LevelDB and RocksDB checksum with, not the
older zlib/Ethernet polynomial. Table-driven, software only.

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
