# Storing article covers

Inkwell, a blogging API, lets a writer attach a cover image to an article.
The image has to live somewhere that is not this process's own disk (a
second instance would not see it, and a redeploy would lose it), and it has
to come back out by URL when a reader loads the article. That is what
`pkg/s3` is for: one client for the S3-compatible protocol, so the same
code works against a self-hosted MinIO bucket in development and a real
cloud bucket in production.

## Install

```json
{
  "dependencies": {
    "s3": "bitlang.org/pkg/s3@v0.2.0"
  }
}
```

## Uploading and reading a cover image

`Config` names one bucket and one credential; `Client(config)` is the client
against it. `put` sends the whole object in one request - the simplest
thing that works for a cover image, which is a few hundred KB, not a video.

```bit
import { Client, Config, list, presignGet, presignPut, UploadedPart } from "s3"

fn main(): ()! {
  let client = Client(
    Config{
      endpoint = "http://127.0.0.1:9000",
      region = "us-east-1",
      bucket = "inkwell-covers",
      accessKeyId = "minioadmin",
      secretKey = "minioadmin",
    },
  )

  client.put("articles/42/cover.jpg", "raw image bytes", "image/jpeg")?
  let body = client.get("articles/42/cover.jpg")?
  println("read back ${len(body)} bytes")
}
```

`endpoint` carries the scheme (`http://` or `https://`); this package
addresses objects path-style (`${endpoint}/${bucket}/${key}`), which every
target it is built for accepts - AWS S3, Cloudflare R2, MinIO, Backblaze B2,
DigitalOcean Spaces, and Google Cloud Storage's XML API. Requests are signed
with AWS Signature Version 4 automatically; nothing about the credential or
the signing shows up in the calls above.

## Checking and removing an object

Before serving an article, Inkwell wants to know the cover exists and its
size, without downloading it - `head` asks for exactly that. When an article
is deleted, its cover goes with it.

```bit
fn describeAndRemove(client: Client, key: string): ()! {
  let meta = client.head(key)?
  println("${key}: ${meta.contentLength} bytes, type ${meta.contentType}, etag ${meta.etag}")
  client.delete(key)?
}
```

`delete` is idempotent - deleting a key that is already gone still succeeds,
so a caller never has to check existence first just to avoid an error.

## Listing every cover under an article

`list` returns an iterator rather than a slice: `next()` fetches another
page from the server only when the current one runs out, so scanning a
prefix with ten objects and one with ten million cost the same amount of
memory.

```bit
fn printAllCovers(client: Client): ()! {
  let it = list(client, "articles/42/")
  while (true) {
    let entry = it.next()?
    match (entry) {
      Some(e) => println("${e.key} (${e.size} bytes)")
      None => return
    }
  }
}
```

## Uploading straight from the browser

Routing a reader's upload through this process just to relay it to the
bucket doubles the bandwidth and ties up a request for as long as the
upload takes. `presignPut` hands back a URL that is valid to PUT against for
a limited time, with the signature already embedded in it - the browser
uploads directly, and this process never sees the bytes.

```bit
fn uploadUrlFor(client: Client, key: string): string! {
  return presignPut(client.cfg, key, 900)?
}
```

`presignGet` is the read-side twin, for serving a private object to a
browser without a credential of its own.

```bit
fn downloadUrlFor(client: Client, key: string): string! {
  return presignGet(client.cfg, key, 300)?
}
```

## Multipart upload for large exports

A cover image never needs this, but an export of every article a writer has
published might run past what is sensible to hold in memory as one buffer.
Multipart upload sends it in parts: start the upload, send each part, then
tell the server how to assemble them.

```bit
fn uploadInParts(client: Client, key: string, part1: string, part2: string): ()! {
  let uploadId = client.createMultipartUpload(key, "application/zip")?
  let etag1 = client.uploadPart(key, uploadId, 1, part1)?
  let etag2 = client.uploadPart(key, uploadId, 2, part2)?
  client.completeMultipartUpload(
    key,
    uploadId,
    [
      UploadedPart{ partNumber = 1, etag = etag1 },
      UploadedPart{ partNumber = 2, etag = etag2 },
    ],
  )?
}
```

Each part but the last must be at least 5 MiB (S3's own minimum); call
`client.abortMultipartUpload(key, uploadId)` instead of `completeMultipartUpload`
to cancel and discard the parts already sent.

## When a call fails

A reader opens an article whose cover was never uploaded, and the page must
show a placeholder, not an error screen. Telling "there is no such object" from
"the bucket refused us" from "the network dropped" is the job of `S3Error`: a
request that S3 refuses fails with one, and it carries the whole answer.

```bit
fn coverSize(client: Client, key: string): int {
  let meta = client.head(key) catch e {
    println("no cover: ${e.message()}")
    return 0
  }
  return meta.contentLength
}
```

For a missing object this prints
`no cover: s3: NotFound (status 404, request id 4442587FB7D0A2F9)`. A `HEAD`
answer has no body, so the code comes from the status alone: 404 is
`NotFound`, 403 `AccessDenied`, 301 `PermanentRedirect`. A `GET` of a missing
key carries a body and says `NoSuchKey` with S3's own sentence.

What an `S3Error` holds, and what to do with each part:

| Field | What it is |
| ----- | ---------- |
| `kind` | an `ErrorKind` to `match` on: `NoSuchKey`, `NoSuchBucket`, `AccessDenied`, `SlowDown`, ..., and `Unknown(code)` for a code this table does not name |
| `code`, `message` | the service's `<Code>` and `<Message>`; `code` is empty for an error the client raised itself |
| `status` | the HTTP status, 0 when no response arrived |
| `requestId`, `extendedId` | `x-amz-request-id` and `x-amz-id-2`, what AWS support asks for |
| `bucketRegion` | `x-amz-bucket-region`, where the bucket lives when the call went to the wrong region |
| `resource` | the `<Resource>` the error names |
| `snippet` | the first 512 bytes of the response body |
| `retryable` | whether the SDK's retry rules would retry it: throttling and transient codes, and the statuses 429, 500, 502, 503 and 504 |

```bit
import { ErrorKind, S3Error } from "s3"

fn placeholderFor(e: S3Error): string {
  return match (e.kind) {
    NoSuchKey => "covers/placeholder.jpg"
    NotFound => "covers/placeholder.jpg"
    _ => ""
  }
}
```

A response that is not an S3 error at all, such as the HTML page a proxy
returns for a 502, is still an `S3Error`: kind `Unknown("")`, the status, and a
snippet that shows the page, so the log says what answered. It is never a
parse failure.

S3 can also answer `200 OK` and then fail while it writes the body, so a
`CopyObject`, `UploadPartCopy` or `CompleteMultipartUpload` that comes back
with an `<Error>` document, or with nothing, is an error with status 503 and
`retryable` set, as the AWS SDK treats it. A multipart upload is never reported
complete on the strength of a `200` alone.

## Sharp edges

- `put`/`get` hold the whole object in memory and are bounded by `std/http`'s
  default response budget (32 MiB). A larger single object needs multipart
  upload on the way in; a large download needs `std/http`'s own streaming
  primitives directly.
- Addressing is path-style only. A public AWS bucket that requires
  virtual-hosted addressing is not supported yet.
- Only `host`, `x-amz-content-sha256` and `x-amz-date` are signed - a
  `Content-Type` you pass to `put` rides along unsigned, which every
  S3-compatible server accepts.

## When not to use this

If the program already needs to abstract over storage backends that are not
S3-compatible (a local filesystem, an entirely different cloud API), reach
for an interface of your own with this package behind one implementation -
`pkg/s3` is one protocol client, not a storage abstraction layer.

## Specification

SigV4 signing follows AWS's "Signature Version 4 signing process"; this
package's own conformance is checked against AWS's published test suite.
