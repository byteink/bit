# Add a cover image to an article

You have an article and a picture that belongs beside its title. Accepting
that picture means handling bytes from a client, not trusting a path on
your own disk. Inkwell accepts one bounded image, checks who may change the
article, and gives storage a key the client cannot choose.

## Upload through the finished app

Start the [finished Inkwell app](README.md#run-the-finished-app), including
its cover-storage settings. Use an account and article you created in the
earlier chapters. Replace `42` with that article's id and `cover.png` with
a PNG file on your machine. The completed app uses `/v1` routes.

```sh
ARTICLE_ID=42
COOKIE_JAR=$(mktemp)
curl -i -c "$COOKIE_JAR" -X POST http://127.0.0.1:8080/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"sara","password":"correct horse battery"}'
curl -i -b "$COOKIE_JAR" \
  -F 'cover=@cover.png;type=image/png' \
  "http://127.0.0.1:8080/v1/articles/$ARTICLE_ID/cover"
```

Login returns `204` and sets the session cookie. A successful upload also
returns `204`, with no response body. Let curl set the multipart boundary;
manually setting only `Content-Type: multipart/form-data` omits the
boundary that the parser needs. Keep the cookie file private and remove it
when you finish the examples.

A different author's upload returns `403`; a request without authentication
returns `401`. An administrator can replace another author's cover. These
checks run before the route reads or parses the body or contacts storage.

## Bound the body before parsing it

The app's request-body limit is `2 * 1024 * 1024 + 4096` bytes. The image
itself may use at most `2 * 1024 * 1024` bytes. The extra space holds the
multipart framing, not a larger image. An excessive whole request returns
`413`; a form that exceeds its own bounds returns `400`.

[parseCover in images.bit](inkwell/images.bit) reads `c.rawBody()` and
`c.header("Content-Type")`, then passes these exact bounds to
`std/http.parseMultipart`:

```text
let limits = CoverLimits{
  maxBodyBytes = coverMaxBytes + 4096, maxFileBytes = coverMaxBytes, maxParts = 1,
  maxHeaderLineBytes = 1024, maxPartHeaderBytes = 2048,
}
```

That is an excerpt inside `parseCover`, not a separate program. The
complete app contains its imports, article lookup and error handling.
`defaultLimits()` supplies general upload defaults; this endpoint uses
stricter `Limits` because it accepts one small cover. `multipartField`
reads a field when handling a multipart body yourself. Here the parsed
`Form.file("cover")` selects the required file and returns a `FormFile`.
The route has no text-field requirement.

## Check the boundary and the declared image type

These are the app's complete boundary and image-signature helpers. The
imports make this excerpt typecheck on its own:

```bit
import { httpError } from "web"
import { FormFile as CoverFile } from "std/http"
import {
  split as coverParts, trimSpace as coverTrim, toLower as coverLower,
  indexOf as coverIndex, hasPrefix as coverPrefix,
} from "std/strings"

fn coverBoundary(contentType: string): string {
  let parts = coverParts(contentType, ";")
  if (coverLower(coverTrim(parts[0])) != "multipart/form-data") {
    return ""
  }
  for part of parts {
    let eq = coverIndex(part, "=")
    if (eq < 0) {
      continue
    }
    if (coverLower(coverTrim(part[:eq])) != "boundary") {
      continue
    }
    let value = coverTrim(part[eq + 1:])
    if (len(value) >= 2 && value[0] == '"' && value[len(value) - 1] == '"') {
      return value[1:len(value) - 1]
    }
    return value
  }
  return ""
}

fn coverExtension(file: CoverFile): string! {
  let body = string(file.content)
  if (file.contentType == "image/png" && coverPrefix(body, "\x89PNG\r\n\x1a\n")) {
    return "png"
  }
  if (file.contentType == "image/jpeg" && coverPrefix(body, "\xff\xd8\xff")) {
    return "jpg"
  }
  if (file.contentType == "image/webp" &&
    len(body) >= 12 &&
    body[:4] == "RIFF" &&
    body[8:12] == "WEBP") {
    return "webp"
  }
  fail httpError(415, "cover must be a PNG, JPEG or WebP image")
}
```

The multipart parser checks the boundary's allowed bytes. A client filename
and content type are both untrusted. The route accepts a PNG, JPEG or WebP
only when its declared type agrees with the signature. A mismatch, including
an SVG labeled as PNG, returns `415`. A signature check is not a full image
decode or a promise that every byte of the image is valid.

The filename never becomes an object key. The real `parseCover` builds
`articles/<article id>/covers/<random UUID>.<checked extension>`. Changing a
filename to `../../another-user.png` cannot select another article's key.

## Know where the bytes go

This route buffers a bounded body before calling `Client.put`. It does not
stream arbitrarily large uploads. Keep this endpoint for small covers;
choose a separate bounded streaming flow when your application needs large
files. The [object-storage chapter](21-object-storage.md) follows the save
and its failure paths.

The [live app tests](inkwell/images.test.bit) upload a complete PNG, read
its signed bytes back, and check authentication, bounds, replacement and
failed saves against real storage. The next chapter follows that public
read without copying the object through the app.

Previous: [Operations](17-operations.md).
Next: [Read a cover without buffering the download](20-serving-and-streaming-files.md).
