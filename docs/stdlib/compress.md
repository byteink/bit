# std/compress

DEFLATE (RFC 1951) and gzip (RFC 1952) compression. **Encoding only** -
there is no decoder in this module. Static (fixed) Huffman coding with
LZ77 matching over a 32KB window; no dynamic Huffman tree construction.

Incompressible input is never expanded by a percentage of its size: each
32KB block is written as either fixed-Huffman or stored (raw, RFC 1951
§3.2.4), whichever is smaller, so the worst case is a stored block's fixed
per-block overhead - a handful of bytes - never a multiplier on the input.

### `deflate(src: []u8, level: int): []u8!`

Raw DEFLATE-compresses `src` at `level` (0-9; 0 skips LZ77 matching
entirely and favors speed, 9 searches hardest for the best match). Fails
only when `level` is outside `0..9`. The output has no header or trailer -
just the RFC 1951 bitstream - so decoding it needs a "raw deflate" mode
(for example Python's `zlib.decompress(data, -15)`).

### `gzip(src: []u8, level: int): []u8!`

gzip-compresses `src` at `level` (see `deflate` above) and wraps the result
in a single-member RFC 1952 gzip container: the 10-byte header, the
DEFLATE body, then a CRC-32 and size trailer. The output decodes with any
standard gzip tool (`gzip -d`, `zlib.decompress(data, 16 + zlib.MAX_WBITS)`).

```bit
import { gzip, deflate } from "std/compress"

fn compressResponseBody(body: []u8): []u8! {
  return gzip(body, 6)?
}

fn compressRaw(body: []u8): []u8! {
  return deflate(body, 6)?
}
```
