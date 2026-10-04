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

## Retrying a failed call

On the night Inkwell re-uploads ten thousand covers, S3 starts answering
`SlowDown`. Retrying at once makes it worse, and retrying forever lets one
slow service hold every worker. `RetryStrategy` is the policy that settles
both, the one the AWS SDK for JavaScript v3 calls its standard mode: a
throttling or transient failure is retried after a random wait, and a client
that has already retried a lot stops retrying.

```bit
import {
  Body,
  Invocation,
  RetryDecision,
  RetryErrorType,
  RetryMode,
  RetryStrategy,
  StopReason,
  classifyError,
  isReplayable,
  retryAfterHint,
} from "s3"

fn nightlyStrategy(): RetryStrategy! {
  return RetryStrategy(RetryMode.Standard, 5)?
}

fn uploadCover(strategy: RetryStrategy, body: Body, send: (Invocation) => Option<S3Error>): string {
  let call = strategy.begin()
  let outcome = ""
  while (outcome == "") {
    match (send(call)) {
      None => {
        call.succeeded()
        outcome = "stored after ${call.attempt()} of ${strategy.maxAttempts} attempts (call ${call.id})"
      }
      Some(e) => {
        let step: RetryDecision = call.decide(e, isReplayable(body))
        match (step) {
          Retry(delay) => call.pause(delay)
          Stop(why) => outcome = "gave up (${describe(why)}): ${e.message()}"
        }
      }
    }
  }
  return outcome
}

fn describe(why: StopReason): string {
  return match (why) {
    NotRetryable => "not a retryable error"
    NotReplayable => "the body cannot be sent twice"
    AttemptsExhausted => "out of attempts"
    QuotaExhausted => "the retry quota is spent"
  }
}
```

`strategy.begin()` starts one call and returns an `Invocation`. Every attempt
of the call sends `call.headers()`: `amz-sdk-invocation-id`, one UUID for the
whole call (`call.id`), so S3's logs tie the attempts together, and
`amz-sdk-request: attempt=2; max=5` (`call.requestValue()`), which says which
attempt this is. After a failed attempt, `call.decide(e, replayable)` answers
`Retry(delay)`, with the wait in nanoseconds, or `Stop(why)`. A `Retry` has
already taken its price from the quota; `call.pause(delay)` waits it, and
`call.totalDelay` adds up the waits.

The rules `decide` follows:

| Rule | Value |
| ---- | ----- |
| attempts | `maxAttempts`, 3 by default, the first included; below 1 is refused when the strategy is built |
| what is retried | throttling (`SlowDown`, `ThrottlingException`, status 429, ...) and transient (`InternalError`, `RequestTimeout`, 500, 502, 503 and 504, a refused connection or a timeout); not the other 5xx, not a client error, never a cancelled call |
| the wait | a random time between 0 and `min(20 s, 100 ms * 2^n)` before retry `n`, counted from 0; 500 ms in place of 100 ms after throttling |
| the server's hint | `retryAfterHint(headers, nowNs)` reads `Retry-After` (seconds or a date) and `x-amz-retry-after` (milliseconds) from a response's header block and gives the instant to come back; the wait is raised to the hint, but never more than 5 s above the random draw |
| the quota | 500 tokens per strategy, shared by every call that uses it; a retry costs 5, 10 after a transient failure; a success gives back the cost of its last retry, or 1 if it needed none; at zero, errors are returned |
| a body read once | `isReplayable(body)` is false for a `Stream`, and `decide` then never retries |

`classifyError(e)` is the verdict for one error, as a `RetryErrorType`:

```bit
fn worthWaiting(e: S3Error): bool {
  let kind: RetryErrorType = classifyError(e)
  return match (kind) {
    Throttling => true
    Transient => true
    Server => false
    Client => false
  }
}
```

```bit
fn serverWaitMs(headers: string, nowNs: int): int {
  return match (retryAfterHint(headers, nowNs)) {
    Some(at) => (at - nowNs) / 1000000
    None => 0
  }
}
```

An error that says the client's clock is wrong (`RequestTimeTooSkewed`) is a
`Client` error until the client has moved its clock; pass `skewCorrected =
true` to `classifyError` or `decide` for the response that made it do so, and
the same error is retried. `strategy.tokens()` reads what is left in the quota;
a strategy that sits at 0 for long is talking to a service that is down, and
its callers see the first error at once instead of waiting on retries.

### Slowing down before S3 has to say it again

The quota stops a client that retries too much; it does not make the whole
night's job send less. For that the strategy has a second mode,
`RetryMode.Adaptive`, the SDK's adaptive mode: everything above, plus a
client-side rate limiter. It stays out of the way until S3 has answered
`SlowDown` once. From then on every attempt first waits for a send token, and
every outcome moves the sending rate: a throttling answer cuts it to 70% of the
rate the client was really sending, any other answer lets it climb back along
a cubic curve, never above twice the measured rate.

```bit
import { RateLimiter, RateLimiterOptions, RetryMode, RetryStrategy } from "s3"

fn gentleNightly(): (RetryStrategy, RateLimiter)! {
  let limiter = RateLimiter(RateLimiterOptions(beta = 0.5, minFillRate = 1.0))?
  let strategy = RetryStrategy(RetryMode.Adaptive, 5, limiter = limiter)?
  return (strategy, limiter)
}

fn pacing(limiter: RateLimiter): string {
  if (!limiter.active()) {
    return "S3 has not pushed back, nothing is paced"
  }
  return "sending at most ${limiter.rate()} requests a second"
}

fn sendOnce(strategy: RetryStrategy, throttled: bool) {
  strategy.limiter.getSendToken()
  strategy.limiter.updateClientSendingRate(throttled)
}
```

The loop of the section above does not change: `strategy.begin()` waits for the
call's first token, `call.decide(e, ...)` tells the limiter how the attempt
failed before it answers, `call.pause(delay)` waits for a token and then the
backoff, and `call.succeeded()` tells it the attempt worked. `sendOnce` shows
the two limiter calls by themselves, for a client that paces something the
strategy does not see. A strategy that is not given a limiter builds its own and shares it between
every call it serves, so ten thousand uploads on a client slow down together.

The curve is the SDK's, constant for constant: `beta` 0.7, `scaleConstant` 0.4,
`smooth` 0.8 for the measured rate, a fill rate of at least `minFillRate` 0.5
tokens a second and a bucket of at least `minCapacity` 1 token.
`RateLimiterOptions` changes them, and `RateLimiter(...)` refuses a value that
would make the curve divide by zero or a send wait forever (a `beta` outside
0 to 1, a `minCapacity` below 1, a `minFillRate` or `scaleConstant` that is not
above 0). A `Standard` strategy never reads its limiter.

#### One limiter for several clients

S3 throttles an account and a prefix, not a client object. Two clients of one
process that each paced themselves would each learn about a `SlowDown` only from
their own requests, and the one that has not been throttled yet keeps sending at
full speed into the limit the other found. Give both strategies the same limiter
and a throttle seen by either slows both.

The `limiter` option takes a `SendLimiter`, the SDK's `RateLimiter` interface:
`getSendToken()`, called before every attempt, and
`updateClientSendingRate(throttling)`, called once for every attempt's outcome,
with `true` when the answer was a throttling one. `RateLimiter` is the built-in
one; anything else with those two methods works, such as the counter below that
only watches. It is called from many tasks at once, so it guards its own state.

```bit
import { Mutex } from "std/sync"
import { RateLimiter, RetryMode, RetryStrategy, SendLimiter } from "s3"

class Pushback {
  mu: Mutex
  sent: int
  throttled: int

  init() {
    this.mu = Mutex()
    this.sent = 0
    this.throttled = 0
  }

  export getSendToken() {
    this.mu.lock()
    this.sent = this.sent + 1
    this.mu.unlock()
  }

  export updateClientSendingRate(throttling: bool) {
    if (!throttling) {
      return
    }
    this.mu.lock()
    this.throttled = this.throttled + 1
    this.mu.unlock()
  }
}

fn shareOne(): (RetryStrategy, RetryStrategy)! {
  let limiter = RateLimiter()?
  let uploads = RetryStrategy(RetryMode.Adaptive, 5, limiter = limiter)?
  let reports = RetryStrategy(RetryMode.Adaptive, 5, limiter = limiter)?
  return (uploads, reports)
}

fn watched(): RetryStrategy! {
  let watcher: SendLimiter = Pushback()
  return RetryStrategy(RetryMode.Adaptive, 5, limiter = watcher)?
}
```

Each client builds its own `RetryStrategy` (its quota stays its own) and hands
it the same `limiter`. When `uploads` is told `SlowDown`, the limiter's rate
drops, and the next `reports.begin()` waits for its token at the lower rate
without `reports` having been throttled itself. Leave the option out and the
strategy builds a `RateLimiter()` of its own.

## Checking a cover arrived intact

A cover that is damaged on the way to the bucket is worse than one that never
arrived: it is stored, served and noticed by a reader. S3 can catch it when
the request carries a checksum of the body, because S3 calculates its own and
refuses the upload when the two differ. The AWS SDK sends one by default, and
so does this package: CRC32 unless the caller names another algorithm.

`planChecksum` is the decision for one request. It takes the operation, the
client's mode, the algorithm the caller asked for (if any), the headers the
request already has and the body, and answers with a `ChecksumPlan`.
`checksumHeaders` turns a plan into the headers to add.

```bit
import {
  Body,
  ChecksumAlgorithm,
  ChecksumPlacement,
  ChecksumPlan,
  Checksums,
  SigHeader,
  checksumHeaders,
  checksumOf,
  parseChecksums,
  planChecksum,
} from "s3"

fn describePlan(plan: ChecksumPlan): string {
  return match (plan.placement) {
    Skip => "no checksum"
    Header => "${plan.header} before sending"
    Trailer => "${plan.header} after the last chunk"
  }
}

fn checksumReport(): ()! {
  let mode = parseChecksums("WHEN_SUPPORTED")?
  let cover = Body.Bytes([]byte("cover bytes"))
  let none = Option<ChecksumAlgorithm>.None
  let plan = planChecksum("PutObject", mode, none, []SigHeader(0), cover)?
  println(describePlan(plan))
  for h of checksumHeaders(plan, cover)? {
    println("${h.name}: ${h.value}")
  }
  println(checksumOf(ChecksumAlgorithm.Sha256, []byte("cover bytes"))?)
  return
}
```

The rules `planChecksum` follows, which are the AWS SDK's:

| Case | Result |
| ---- | ------ |
| the operation has no `ChecksumAlgorithm` member | no checksum |
| the request already has an `x-amz-checksum-*` header | left alone, the value goes out as given |
| the caller named an algorithm | that algorithm, in either mode |
| `Checksums.WhenSupported`, the default | CRC32 for every operation that can carry a checksum |
| `Checksums.WhenRequired` | CRC32 only for the operations that require one, such as `DeleteObjects` and `PutBucketPolicy` |
| a body in memory (`Empty`, `Text`, `Bytes`) | `ChecksumPlacement.Header`: `x-amz-checksum-crc32` |
| a file or a stream with a known length | `ChecksumPlacement.Trailer`: sent aws-chunked, the checksum after the last chunk |
| a stream of unknown length | an `InvalidInput` error, because S3 needs the decoded length to read aws-chunked |

The mode is `parseChecksums` of `AWS_REQUEST_CHECKSUM_CALCULATION` or the
`request_checksum_calculation` profile key, `WHEN_SUPPORTED` or
`WHEN_REQUIRED` in any case; any other text is refused, so a typo fails at
startup. The ten algorithms are the ones S3 names: `CRC32`, `CRC32C`,
`CRC64NVME`, `SHA1`, `SHA256`, `SHA512`, `MD5`, `XXHASH64`, `XXHASH3` and
`XXHASH128`, each sent as `x-amz-checksum-` and its lower-case name.

A body that is sent in pieces is hashed in pieces. `checksumHasher` gives a
streaming hasher for an algorithm: write the bytes in order, in chunks of any
size, and `checksumValue` reads the base64 value S3 expects.

```bit
import { ChecksumAlgorithm, checksumHasher, checksumValue } from "s3"

fn pieceChecksum(pieces: []string): string! {
  let h = checksumHasher(ChecksumAlgorithm.Crc32c)?
  for piece of pieces {
    h.write([]byte(piece))
  }
  return checksumValue(h)
}
```

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
