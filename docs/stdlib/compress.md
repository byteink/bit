# std/compress

A compressed draft takes less space in an export or HTTP response. When you
read one back, set a limit on its expanded size before trusting the input.

This complete example saves an Inkwell draft as gzip, reads it back with a
64 KiB limit, and does the same with a raw DEFLATE stream:

```bit
import { deflate, inflate, gzip, gunzip } from "std/compress"

fn main(): ()! {
  let draft = []u8("Inkwell draft: a small note worth keeping.")
  let archive = gzip(draft, 6)?
  let restored = gunzip(archive, 65536)?
  println(string(restored))

  let raw = deflate(draft, 6)?
  let restoredRaw = inflate(raw, 65536)?
  assert(string(restoredRaw) == string(draft), "draft changed")
}
```

## Choose the format

### `gzip(src: []u8, level: int): []u8!`

Use `gzip` for a file or response whose receiver expects gzip. It wraps
compressed bytes with a header, checksum, and original size.

### `gunzip(src: []u8, maxOut: int): []u8!`

Use `gunzip` to restore a gzip archive. It checks the header and both trailer
fields before returning the restored bytes. Optional extra data, file names,
comments, and header checksums are supported.

### `deflate(src: []u8, level: int): []u8!`

Use `deflate` when a protocol calls for raw DEFLATE. Its output has no header,
checksum, or size field.

### `inflate(src: []u8, maxOut: int): []u8!`

Use `inflate` to read raw DEFLATE bytes, rather than `gunzip`. Neither decoder
accepts a zlib container.

Both encoders accept levels `0..9`. Level `0` skips match searching; level `6`
is a useful starting point; level `9` searches harder. An invalid level fails.
The encoder chooses fixed Huffman coding or an uncompressed block for each
32 KiB block. Both decoders also accept dynamic Huffman coding from other tools.

## Bound incoming drafts

Choose `maxOut` from your application's draft size limit. Both decoders require
a positive value and fail before writing any byte beyond it. They allocate
output storage for that limit, so avoid passing an unnecessarily large value.
A stream that expands to exactly the limit succeeds.

Malformed or truncated streams fail. `gunzip` also fails when the expanded
bytes disagree with the stored checksum or size. Raw DEFLATE has no checksum;
use your protocol's integrity check when decoding it.

Only one complete stream is accepted. Trailing bytes and concatenated gzip
members fail. If your format contains several records, separate their compressed
bytes before calling a decoder. Compression does not encrypt a draft or make
untrusted content safe.

For sending a compressed draft, continue with [HTTP](/stdlib/http). For reading
or writing an archive file, see [Files](/stdlib/fs).
