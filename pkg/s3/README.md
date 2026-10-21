# pkg/s3

An object storage client for the S3-compatible protocol, written in Bit over
`std/http`. One client for the protocol most of the world already speaks:
AWS S3, Cloudflare R2, MinIO, Backblaze B2, DigitalOcean Spaces, and Google
Cloud Storage's XML API.

## Install

`bit add bitlang.org/pkg/s3@v0.2.0` writes:

```json
{
  "dependencies": {
    "s3": "bitlang.org/pkg/s3@v0.2.0"
  }
}
```

The request signing, the credential types and providers and the shared config
profiles are [`pkg/aws`](../aws/README.md); `bit add` fetches it as a dependency
of this package, and a program that builds its own credential imports
`AwsCredential` and `Credentials` from `"aws"`.

## Usage

```bit
import { Client, Config, list } from "s3"

fn main(): ()! {
  let client = Client(
    Config{
      endpoint = "http://127.0.0.1:9000",
      region = "us-east-1",
      bucket = "photos",
      accessKeyId = "minioadmin",
      secretKey = "minioadmin",
    },
  )

  client.put("cats/mine.jpg", "raw image bytes", "image/jpeg")?
  let meta = client.head("cats/mine.jpg")?
  println("${meta.contentLength} bytes, ${meta.etag}")

  let it = list(client, "cats/")
  let entry = it.next()?
  match (entry) {
    Some(e) => println(e.key)
    None => println("(empty)")
  }

  client.delete("cats/mine.jpg")?
  return
}
```

Addressing is path-style only (`${endpoint}/${bucket}/${key}`), which every
target this package is built for accepts. Requests are signed with AWS
Signature Version 4 (`pkg/aws`), checked against AWS's own published test
suite (`pkg/aws/sigv4.test.bit`, `pkg/aws/sigv4suite.test.bit`).

The full method surface (put/get/head/delete, `list`'s paginated iterator,
multipart upload, `presignGet`/`presignPut`, and bounded browser upload forms
with `presignPost`), streaming large objects, and
what this package does not implement (virtual-hosted addressing, bucket
policies, lifecycle rules) are in [`docs/`](docs/README.md).

For how first-party packages in this repository are laid out, gated,
versioned and released, see [`pkg/README.md`](../README.md).

## Prepare or save an article cover

Inkwell can prepare a retryable file body or save a body without collecting
the cover in memory. [`Body` and `ByteStream`](docs/models.md#prepare-and-save-an-article-cover)
shows bounded reads, an explicit buffer limit, a sink, and atomic file replacement.
These library helpers also serve custom transports. The modeled request pipeline
does not yet connect them to network operations; the existing client streaming
methods remain described in [Storing article covers](docs/guide.md).
