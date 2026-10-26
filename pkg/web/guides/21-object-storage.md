# Keep cover bytes in object storage

An article belongs in the database; its cover is an object with a key and
content type. Keeping only that key on the article lets every app instance
read the same cover without sharing a local upload directory. It also means
you must handle two systems failing at different points in one save.

<!-- doctest: deps s3 -->

## Configure a private bucket

Create a bucket on your S3-compatible service and give Inkwell credentials
that can put, read and delete its cover objects. Keep the bucket private:
the app's public read issues a short signed URL instead of requiring public
bucket access. The credentials belong in your secret configuration, not in
source files or curl commands.

Set these alongside the [finished app's existing settings](README.md#run-the-finished-app):

```sh
export S3_ENDPOINT='https://YOUR-STORAGE-ENDPOINT'
export S3_REGION='YOUR-BUCKET-REGION'
export S3_BUCKET='inkwell-covers'
# Supply S3_ACCESS_KEY_ID and S3_SECRET_KEY through your secret configuration.
```

Use the actual endpoint and region of your service. `loadConfig` reads the
settings once; `S3_REGION` defaults to `us-east-1` only when you omit it.
Other routes can run without cover storage, but a cover request returns
`503` when its required settings are absent.

The real [configuration](inkwell/config.bit) and
[client helper](inkwell/images.bit) use the `Client(Config{...})` constructor.
This copies the app's settings class and complete helper, with their imports:

```bit
import { httpError } from "web"
import { Client as CoverClient, Config as CoverConfig } from "s3"

export class AppConfig {
  export databaseUrl: string,
  export redisUrl: string,
  export secret: string,
  export host: string,
  export port: int,
  export jwtSecret: string,
  export jwtIssuer: string,
  export jwtAudience: string,
  export googleClientId: string,
  export googleClientSecret: string,
  export googleRedirectUrl: string,
  export s3Endpoint: string,
  export s3Region: string,
  export s3Bucket: string,
  export s3AccessKeyId: string,
  export s3SecretKey: string,
}

fn coverClient(cfg: AppConfig): CoverClient! {
  if (cfg.s3Endpoint == "" ||
    cfg.s3Bucket == "" ||
    cfg.s3AccessKeyId == "" ||
    cfg.s3SecretKey == "") {
    fail httpError(503, "cover storage is not configured")
  }
  return CoverClient(
    CoverConfig{
      endpoint = cfg.s3Endpoint, region = cfg.s3Region, bucket = cfg.s3Bucket,
      accessKeyId = cfg.s3AccessKeyId, secretKey = cfg.s3SecretKey,
    },
  )
}
```

The `s3` dependency is already in the finished app's manifest. The client
uses those settings to sign the actual request; it does not create the
bucket or invent a storage API. Read [S3](../../s3/README.md) when selecting
credentials or extending its use beyond this cover flow.

## Write a fresh key, then update the article

[File uploads](19-file-uploads.md) already produced a checked `CoverUpload`.
This is the complete `storeCover` body in its app context:

```text
fn storeCover(client: CoverClient, upload: CoverUpload, db: Db, actorId: i64): ()! {
  client.put(upload.key, upload.body, upload.contentType)?
  upload.article.coverImageKey = Option<string>.Some(upload.key)
  upload.article.updatedAt = now().ns
  db.tx((tx) => {
    tx.table<Article>().update(upload.article)?
    recordAudit(tx, actorId, "article.cover", "article/${upload.article.id}")?
  })?
}
```

`Client.put` sends the already bounded bytes with their checked content
type. `coverImageKey` is nullable, so old articles need no object until
someone uploads a cover. The migration adds that optional column; apply
the app's normal migrations before you start the new code.

The route supplies the authenticated actor id. The article update and its
`article.cover` audit row commit in one database transaction; an audit insert
error rolls both back. The object upload remains outside that transaction,
so the failure path must still compensate an unreferenced new object.

Every upload uses a fresh generated key. The ORM's existing version check
refuses a stale article instead of silently replacing a concurrent edit.
The old cover key is captured before the save. Only after a successful
update does the route delete that old object and invalidate the article-list
cache. A concurrent edit returns `412` when the outcome can be checked.

This small endpoint uses `put`, not `putStream`: its bounded body is already
in memory. The [S3 package](../../s3/README.md) documents `Client.putStream`
for a stream-based caller. Changing only the storage call cannot make this
buffered multipart handler a large-file streaming upload.

## A failed response can follow a committed write

A database refusal and a lost database response have different outcomes.
If the UPDATE committed before its response was lost, the article already
references the new key. Deleting that key as unconditional compensation
would break the cover that was successfully saved.

The production failure path therefore locks and reads the current article
before it decides whether to remove the new object:

```text
fn removeUnreferencedCover(client: CoverClient, upload: CoverUpload, db: Db): ()! {
  db.tx((tx) => {
    let current = tx.table<Article>().lock().find(upload.article.id)?
    if (isSome(current.coverImageKey) && unwrap(current.coverImageKey) == upload.key) {
      return
    }
    client.delete(upload.key)?
  })?
}
```

The delete happens while that row lock is held, and only if the current
reference differs from the generated key. When the row references the key,
the object stays. An unreadable, missing or soft-deleted row cannot prove
that the key is unreferenced, so the app keeps the object and returns the
original operation error. A cleanup failure also leaves the request failed.
This can retain an orphan for later inspection; it avoids destroying a
possibly live cover. Do not turn that uncertainty into a successful response.

The [integration tests](inkwell/images.test.bit) exercise a definite
constraint refusal, an injected response loss after a real committed save,
and a database state that cannot be read. They verify both the stored key
and the actual object bytes. They check that `coverSaveFailure` preserves
the original cause for the app's error handler. The normal HTTP error mapper
still hides internal details behind its generic `500` response.

An old-object deletion can fail after the new reference commits too. The
new cover remains valid, but the request reports the failure. Before retrying,
read the article's current cover; this endpoint does not promise that an
error means nothing changed, or that a repeated POST has the same key.

## Let storage serve the download

The [public read](20-serving-and-streaming-files.md) loads the visible
article's key and calls `presignGet` with the app's five-minute lifetime.
It redirects the client; storage serves the object and byte ranges. The app
keeps no second copy of the download body. A previously issued URL can stay
usable after an article is hidden until the URL expires or the object goes away.

Keep ordinary small metadata in the database. Use object storage for bytes
that need their own transfer path. For a local application asset that ships
with the binary, a trusted static-file mount can be simpler than managing
an object key and a signed URL.

Previous: [Read a cover without buffering the download](20-serving-and-streaming-files.md).
Continue: [Run a nightly article digest](25-scheduled-jobs.md).
