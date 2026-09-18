# Limitations

What this driver does not do yet, and where each gap is tracked.

- **Single packets only.** A statement whose bound form would exceed
  16,777,215 bytes - the protocol's multi-packet payload form - fails naming
  its size. It is never split across packets or silently truncated.
- **TLS client certificates are not sent.** `std/tls`'s handshake configuration
  is built with no certificate and no key on every connection this driver
  opens; there is no way to request or present one.
- **`VERIFY_CA` checks the chain and deliberately not the name.** It does that
  by handing `x509VerifyChain` the leaf certificate's own first
  SubjectAltName, so the hostname test is vacuous by construction rather than
  by omission. Use `VERIFY_IDENTITY` for a real hostname check.
- **`LOAD DATA LOCAL` is never served.** The capability is not requested in the
  handshake, and a server that asks for it anyway gets a failure naming the
  request rather than a client that reads an arbitrary local path for it.
- **Neither stock Docker image verifies.** `mysql:8.4` and `mariadb:11.4` each
  generate a self-signed certificate on first start, so the no-`ssl-mode`
  ladder lands on `REQUIRED` against both - encrypted, not verified.
  `VERIFY_CA` and `VERIFY_IDENTITY` need a certificate chain your trust store
  can build, which is a server you configured yourself. See
  [MySQL and MariaDB](servers.md).
