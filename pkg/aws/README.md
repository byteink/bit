# pkg/aws

What every AWS client in Bit shares: who a request is signed as (credentials,
the environment, shared config profiles, STS), how it is signed (Signature
Version 4, in a header or in a presigned URL), and where it goes (partitions
and endpoint URLs). `pkg/s3` is built on it; so is any other AWS service
client, the SES transport of `pkg/mail` included, without importing an S3
client to get a signature.

## Install

`bit add bitlang.org/pkg/aws@v0.1.0` writes:

```json
{
  "dependencies": {
    "aws": "bitlang.org/pkg/aws@v0.1.0"
  }
}
```

## Usage

```bit
import { AwsCredential, Credentials, Refresh } from "aws"

fn main(): ()! {
  let key = AwsCredential(
    accessKeyId = "AKIDEXAMPLE",
    secretAccessKey = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
  )?
  let who = Credentials.Static(key).resolver()?.resolve(Refresh.IfNeeded)?
  println(who.show())
  return
}
```

A credential prints as its access key id only: the secret and the session
token appear in no `show()` and no error text. Requests are signed with AWS
Signature Version 4, checked against AWS's own published test suite
(`pkg/aws/sigv4.test.bit`, `pkg/aws/sigv4suite.test.bit`).

Signing a request, presigning a URL, resolving credentials from the
environment or a shared config profile, and finding a region's partition are
in [`docs/`](docs/README.md).

For how first-party packages in this repository are laid out, gated,
versioned and released, see [`pkg/README.md`](../README.md).
