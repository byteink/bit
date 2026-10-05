# Limitations, and where each one is going

What this driver does not do yet, stated plainly rather than as a caveat at
the end of a chapter.

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
- **A `Listener` listens on the channels it was opened with.** There is no
  `UNLISTEN` and no adding a channel later; open another listener. It takes a
  URI, not the individual-field form, and applies no connect timeout of its
  own.
- **TLS client certificates are not sent.** `std/tls` does not request or
  present them.

## Where to go next

[TLS](tls.md) and [Authentication](authentication.md) cover the mechanisms
these gaps sit in.
