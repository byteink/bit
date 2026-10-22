# Read a cover without buffering the download

An article cover can be larger than the API's JSON response. Copying it
from storage into the app and then into the client adds another buffer and
keeps an application request busy for the transfer. Inkwell instead tells
the client where to fetch the bytes for a short time.

<!-- doctest: deps s3 -->

## Follow the public read

Use the article you gave a cover in [File uploads](19-file-uploads.md).
This read is public; it needs no login cookie:

```sh
ARTICLE_ID=42
curl -i "http://127.0.0.1:8080/v1/articles/$ARTICLE_ID/cover"
curl -L -o downloaded.png \
  "http://127.0.0.1:8080/v1/articles/$ARTICLE_ID/cover"
```

The first request returns `302` with a signed storage URL in `Location`.
The second follows it and saves the actual object. The app checks that the
article exists, is visible, and has a cover before it signs anything.
An absent article, a soft-deleted article, or an article without a cover
returns `404`. Missing storage configuration returns `503`.

The complete handler lives in [images.bit](inkwell/images.bit). This is
its final expression after those checks and client setup:

```text
return c.redirect(coverPresign(client.cfg, unwrap(article.coverImageKey), coverUrlSeconds)?)
```

The surrounding function is needed: the `article`, `client` and `c` values
come from that handler. This standalone extraction gives the signing and
redirect step explicit types. Its `key` parameter is the already checked
article key, in place of the full handler's `unwrap(article.coverImageKey)`:

```bit
import { Ctx, Res } from "web"
import { Client as CoverClient, presignGet as coverPresign } from "s3"

const coverUrlSeconds = 300

fn redirectCover(c: Ctx, client: CoverClient, key: string): Res! {
  return c.redirect(coverPresign(client.cfg, key, coverUrlSeconds)?)
}
```

`redirectCover` is an extraction for this page, not another app route. The
real `readCover` performs its database and configuration checks before this
step. The storage client signs `key` with a five-minute lifetime; `c.redirect`
returns the URL as the `302` response. A signing error propagates to the
request's normal error handler. The curl commands above exercise the full
route, including those checks, against the running app.

The lifetime limits one issued URL. Because this Inkwell read is public,
any reader who knows the article id can request another URL while its cover
remains visible. Expiry does not make the cover private. Do not put a
private document behind this public route.

## Request only the bytes you need

A client that needs the first eight bytes can ask storage for a range:

```sh
curl -L -D range.headers -H 'Range: bytes=0-7' -o cover-prefix.bin \
  "http://127.0.0.1:8080/v1/articles/$ARTICLE_ID/cover"
```

The final storage response is `206` when it honors that range. Its body
contains those eight bytes and `Content-Range` identifies them. The initial
API response is still a redirect; it is not the partial-content response.
The [live cover test](inkwell/images.test.bit) checks both status `206`
and the exact PNG signature bytes against the owned S3-compatible fixture.

[HTTP range requests](https://www.rfc-editor.org/rfc/rfc9110.html#section-14.2)
are optional. A different storage server may send the whole representation
with `200`. Check the final response before treating its body as a slice.
The API does not implement a proxy, a stream adapter, or its own range parser
for this route. Storage owns the transfer and its download buffers.

## Keep a signed URL out of logs

A signed URL grants its holder access until it expires or storage refuses
it. Treat its query string like a credential. Use HTTPS for a real storage
endpoint and avoid recording signed URLs in logs or analytics. See
[the S3 presigned URL contract](https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html)
for how credential expiry can shorten a URL's usable lifetime.

Deleting an article stops the app issuing new URLs; it does not revoke an
already issued URL by itself. That URL may still read the object until it
expires. Replacing a cover writes a new key and removes the old object
after the database update succeeds, so a URL for the removed object fails
at storage. A failed old-object delete remains an error, as described in
[Object storage](21-object-storage.md).

## Serve local assets when the files are local

For a checked directory of application assets, `web.static(prefix, root)`
serves GET and HEAD requests and applies its file validators. A matching
`If-None-Match` can produce `304` without a response body. Byte ranges and
`If-Range` apply to the selected file representation. Set a fixed, trusted
root; never derive it from a request or mount a secret directory.

Read [Operational middleware](../docs/operations.md) for that local-file
mount, and [Responses](../docs/response.md) for an individually chosen file.
Inkwell's cover route uses neither: its source of truth is a database key
and its bytes live in object storage. The [article caching chapter](31-conditional-client-caching.md)
shows the separate conditional-GET pattern for JSON article representations.

Previous: [Add a cover image](19-file-uploads.md).
Next: [Keep cover bytes in object storage](21-object-storage.md).
