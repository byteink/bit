# Limitations, and where each one is going

What this driver does not do yet, stated plainly rather than as a caveat at
the end of a chapter.

- **Typed decoding is `#3989`.** Columns arrive as text bytes with their
  type OIDs; `asInt` on an `int4` column fails today, `asText` works.
- **Transactions are the rest of `#3986`.** `begin` fails naming the epic;
  `std/sql` runs transactions through a closure (`stdlib/sql/tx.bit`).
- **`Conn.prepare` does not name a statement on the server.** It holds the
  text and runs the ordinary path, so a `Stmt` is unnamed unless
  `statementCache` turned the cache on. A name is meaningful only on the
  one backend that parsed it, which is the same reason the cache is
  opt-in.
- **`verify-ca` checks the chain against the trust store and deliberately
  does not check the name.** It does that by handing `x509VerifyChain` the
  leaf's own first SubjectAltName, so the name test is vacuous by
  construction rather than by omission. See [TLS](tls.md).
- **SASLPrep (RFC 4013) is not applied to the password.** It is the
  identity function for an ASCII password. A password whose normalized
  form differs from its raw form would derive a different key here than
  libpq derives.
- **`SCRAM-SHA-256-PLUS` (channel binding) is not offered.**
- **TLS client certificates are not sent.** `std/tls` does not request or
  present them.
