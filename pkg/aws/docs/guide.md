# Signing Inkwell's requests

<!-- doctest: per-block -->

Inkwell stores article covers in S3 and sends its newsletter through SES. Both
services want the same thing from every request: proof of who is calling,
computed from a secret that never leaves the process. This chapter builds that
proof from the outside in: first who Inkwell signs as, then the signature
itself, then where the request goes. Nothing here is S3 specific; `pkg/s3`
calls exactly these functions.

## Who Inkwell signs as

An `AwsCredential` is one resolved identity: an access key id, its secret and,
for temporary credentials, a session token and the instant they expire. Building
one checks it, so a secret read from a file with a trailing newline fails when
the value is made, not as a signature the server rejects at 02:00.

```bit
import { AwsCredential } from "aws"

fn main(): ()! {
  let key = AwsCredential(
    accessKeyId = "AKIDEXAMPLE",
    secretAccessKey = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
  )?
  println(key.show())
  println(key.accessKeyId)
  return
}
```

`show()` is `AwsCredential(AKIDEXAMPLE)`: the secret and the token have no
accessor outside this package, and appear in no error message.

## Where the identity comes from

`Credentials` is the choice a client is configured with. `Default` reads the
environment (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and optionally
`AWS_SESSION_TOKEN`), `Static` holds one credential, `Profile` reads a profile
of the shared config and credentials files, and `Provider` calls a function
whenever a refresh is due. `resolver()` turns the choice into a
`CredentialCache`, and fails at that point on a choice that cannot work, such
as a profile that does not exist.

```bit
import { Credentials, envCredentials, Refresh } from "aws"

fn main(): ()! {
  let fromEnv = Credentials.Default.resolver()?
  let fromProfile = Credentials.Profile("inkwell").resolver()?
  let fromFunction = Credentials.Provider(envCredentials).resolver()?
  println(fromEnv.resolve(Refresh.IfNeeded)?.show())
  println(fromProfile.resolve(Refresh.IfNeeded)?.show())
  println(fromFunction.resolve(Refresh.Force)?.show())
  return
}
```

`resolve` serves the cached credential until it expires within five minutes,
then one task calls the provider while every other caller waits for that one
outcome (single flight). A caller holding still-valid credentials is not made to
wait behind a refresh somebody else is running. `Refresh.Force` skips the cache,
for the moment a server answers `ExpiredToken`. A profile that names a file the
parser cannot read fails with a `ProfileFileError` carrying `path`, `line` and
`reason`.

## Signing a request

A signed request needs the credential's view for one region and service, and
the request itself: method, raw path, query pairs, every header the transport
will send (`host` included) and the payload hash. `signV4` returns the headers
to add.

```bit
import { AwsCredential, SigHeader, SigV4Request, sha256Hex, signV4 } from "aws"

fn main(): ()! {
  let key = AwsCredential(
    accessKeyId = "AKIDEXAMPLE",
    secretAccessKey = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
  )?
  let req = SigV4Request{
    method = "PUT",
    path = "/covers/draft-1.jpg",
    query = [](string, string)(0),
    headers = [SigHeader{ name = "host", value = "inkwell.s3.us-east-1.amazonaws.com" }],
    payloadHash = sha256Hex("raw image bytes"),
  }
  let signed = signV4(key.sigV4Config("us-east-1", "s3"), req, "20260101T000000Z")?
  for h of signed.headers {
    println("${h.name}: ${h.value}")
  }
  return
}
```

The headers come back lowercase: `x-amz-content-sha256`, `x-amz-date`,
`x-amz-security-token` when the credential has a session token, and
`authorization`. A caller mistake (no host header, a malformed date, a payload
hash that is neither 64 lowercase hex digits nor a documented marker) fails
before anything is signed, with `aws: InvalidInput: ...` naming the field.

A body that is not hashed up front is signed as `unsignedPayload`
(`UNSIGNED-PAYLOAD`); `isPayloadHash` says whether a value is one of the
spellings AWS accepts, and `streamingUnsignedTrailer`, `streamingSigned`,
`streamingSignedTrailer`, `streamingSigV4a` and `streamingSigV4aTrailer` are the
markers of an aws-chunked body.

## Presigning a URL

`presignV4` signs into the query string instead, so a browser can PUT the cover
straight to the bucket without a credential of its own. `PresignOptions.expiresIn`
is 900 seconds by default and at most `maxPresignExpiry`, seven days.

```bit
import { AwsCredential, PresignOptions, SigHeader, SigV4Request, presignV4, unsignedPayload } from "aws"

fn main(): ()! {
  let key = AwsCredential(
    accessKeyId = "AKIDEXAMPLE",
    secretAccessKey = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
  )?
  let req = SigV4Request{
    method = "GET",
    path = "/covers/draft-1.jpg",
    query = [](string, string)(0),
    headers = [SigHeader{ name = "host", value = "inkwell.s3.us-east-1.amazonaws.com" }],
    payloadHash = unsignedPayload,
  }
  let url = presignV4(
    key.sigV4Config("us-east-1", "s3"),
    req,
    "20260101T000000Z",
    PresignOptions{ expiresIn = 300 },
  )?
  println("https://inkwell.s3.us-east-1.amazonaws.com${req.path}?${url.queryString}")
  return
}
```

## The four steps, one at a time

`signV4` is four functions in a row, and a service that signs unusually (SES
and STS do not take `x-amz-content-sha256`) can run them itself:
`canonicalRequest`, `stringToSign`, `signingKey` and `signature`, with
`credentialScope`, `canonicalUri`, `canonicalQueryString`, `canonicalHeaders`,
`signedHeaders` and `authorizationHeader` as the pieces between.

```bit
import {
  SigHeader,
  authorizationHeader,
  canonicalQueryString,
  canonicalRequest,
  canonicalUri,
  credentialScope,
  sha256Hex,
  signature,
  signedHeaders,
  signingKey,
  stringToSign,
} from "aws"

fn main() {
  let headers = [SigHeader{ name = "host", value = "ses.us-east-1.amazonaws.com" }]
  let scope = credentialScope("20260101", "us-east-1", "ses")
  let creq = canonicalRequest(
    "POST",
    canonicalUri("/v2/email/outbound-emails"),
    [](string, string)(0),
    headers,
    sha256Hex("{}"),
  )
  let sts = stringToSign("20260101T000000Z", scope, creq)
  let sig = signature(signingKey("secret", "20260101", "us-east-1", "ses"), sts)
  println(authorizationHeader("AKIDEXAMPLE", scope, signedHeaders(headers), sig))
  println(canonicalQueryString([("b", "2"), ("a", "1")]))
}
```

## Where the request goes

A region belongs to a partition (`aws`, `aws-cn`, `aws-us-gov`, and the
isolated ones), and the partition decides the DNS suffix and whether FIPS and
dual stack exist. `awsPartition` answers for any region, an unknown one
included, which falls in `aws` as in every AWS SDK. `parseEndpoint` reads an
endpoint URL, and `signedHostValue` is the `Host` value the transport will send
for it, which is the one that has to be signed. `amzTimestamps` is the two UTC
spellings of now that SigV4 takes.

```bit
import { amzTimestamps, awsPartition, parseEndpoint, schemeOf, signedHostValue } from "aws"

fn main(): ()! {
  let p = awsPartition("cn-north-1")
  println("${p.name} ${p.dnsSuffix} ${p.supportsFIPS} ${p.supportsDualStack}")
  let parts = parseEndpoint("http://127.0.0.1:9000")?
  println("${schemeOf(parts)} ${parts.host} ${parts.port} ${signedHostValue(parts)}")
  let (dateStamp, amzDate) = amzTimestamps()
  println("${dateStamp} ${amzDate}")
  return
}
```

The partition table is generated from the pinned AWS `partitions.json` by
`tools/gens3`, so a new partition arrives as a regenerated file, not an edit.

## Where to go next

The S3 client built on all of this is [`pkg/s3`](../../s3/docs/README.md).
