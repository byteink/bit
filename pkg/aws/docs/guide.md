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

### A web identity for Inkwell

An EKS pod or another workload with an identity token can exchange that token
for temporary AWS credentials. Give the token-file provider to the same cache:

```bit
import { Credentials, Refresh, webIdentityCredentials } from "aws"

fn main(): ()! {
  let identity = Credentials.Provider(webIdentityCredentials).resolver()?
  println(identity.resolve(Refresh.IfNeeded)?.show())
  println(identity.resolve(Refresh.Force)?.show())
  return
}
```

Set `AWS_WEB_IDENTITY_TOKEN_FILE` and `AWS_ROLE_ARN` before the program starts.
The provider reopens the token file on every refresh, including when the
workload replaces the file behind a symlink. It accepts tokens from 4 to
20,000 bytes and closes the file before the exchange.

`AWS_ROLE_SESSION_NAME` names the session; otherwise its name is
`aws-sdk-js-session-<milliseconds since the Unix epoch>`. STS uses
`AWS_REGION`, then the selected profile's region, then `us-east-1`.

For a named profile, set `web_identity_token_file` and `role_arn` together
and use `Credentials.Profile("inkwell")`. Static keys in that profile take
precedence. Its `role_session_name` takes precedence over
`AWS_ROLE_SESSION_NAME`. Profile construction performs one exchange and
keeps the result in its cache. A configured token-file or STS failure is an
error; the provider does not silently choose another identity.

### A workstation identity for Inkwell

When Inkwell runs on a developer's workstation, use its IAM Identity Center
profile rather than copying temporary keys into the application. The existing
profile resolver reads the token cache created by AWS's sign-in tools:

```ini
[profile inkwell]
sso_session = workplace
sso_account_id = 123456789012
sso_role_name = Developer

[sso-session workplace]
sso_start_url = https://example.awsapps.com/start
sso_region = eu-west-1
```

```bit
import { Credentials } from "aws"

fn main()! {
  let identity = Credentials.Profile("inkwell").resolver()?
  let credential = identity.resolve()?
  println(credential.show())
}
```

The resolver reads `~/.aws/sso/cache/<SHA1 of the session name>.json`.
Session tokens inside the five-minute refresh window use OIDC's refresh grant
and replace the cache atomically with owner-only permissions. The application
never starts a browser or an interactive login. If a session cannot refresh
and its token has expired, the error directs the operator to `aws sso login`.
A still-valid token remains usable when a proactive refresh fails.

Legacy profiles put `sso_start_url`, `sso_region`, `sso_account_id` and
`sso_role_name` together in the profile. Their cache name hashes the start URL;
legacy tokens must be renewed externally after expiration. Existing static
keys and web identity retain their precedence over SSO settings.

### A task role for Inkwell

Inkwell deployed as an ECS task or EKS pod uses the task's temporary identity
instead of a key in its configuration. Give the container provider to the
same cache; forced refresh reads a rotated authorization token file again.

```bit
import { Credentials, Refresh, containerCredentials } from "aws"

fn main(): ()! {
  let identity = Credentials.Provider(containerCredentials).resolver()?
  println(identity.resolve(Refresh.IfNeeded)?.show())
  println(identity.resolve(Refresh.Force)?.show())
  return
}
```

`AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` takes precedence over
`AWS_CONTAINER_CREDENTIALS_FULL_URI`. Relative paths use `169.254.170.2`.
An HTTP full URI must name `localhost`, IPv4 loopback, IPv6 loopback,
`169.254.170.2`, `169.254.170.23` or `fd00:ec2::23`; HTTPS can name any host.
Invalid hosts fail before a request. Redirects are refused, so another
endpoint never receives the authorization header.

`AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE` takes precedence over
`AWS_CONTAINER_AUTHORIZATION_TOKEN`. The file is reopened on each attempt,
following rotating symlinks while refusing devices, pipes and directories.
Tokens with control characters fail before a request. Each HTTP attempt has
a one-second deadline, with three retries separated by one second. URI text
has an 8 KiB budget; token files and responses have a 16 KiB budget each.
These are this provider's resource limits. Errors name fields or HTTP status
without copying tokens, credentials, response bodies or endpoint URLs.

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
