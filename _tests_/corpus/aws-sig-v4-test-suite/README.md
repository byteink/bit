# aws-sig-v4-test-suite corpus (vendored)

Source: https://github.com/awslabs/aws-c-auth, directory `tests/aws-signing-test-suite/v4`
Upstream commit: `c4bc791ac6985eedb503e882cd450cc5b344c2f2`
Retrieved: 2026-10-03
License: Apache-2.0 (`LICENSE`, `NOTICE`)

AWS's published SigV4 test suite as maintained by the AWS Common Runtime:
one directory per case with the request (`request.txt`), the signing context
(`context.json`: credentials, region, service, timestamp, `normalize`,
`sign_body`) and the expected canonical request, string to sign, signature
and signed request for the header flavour (`header-*.txt`) and the query
flavour (`query-*.txt`).

`pkg/aws/sigv4suite.test.bit` runs every case's `header-*` files through
`signV4` (#6582). The `query-*` files are consumed by the presign signer
(#6610).

Re-deriving: clone the repository at the commit above and copy
`tests/aws-signing-test-suite/v4` over `v4/`.
