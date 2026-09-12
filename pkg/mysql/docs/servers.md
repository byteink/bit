# MySQL and MariaDB

One package serves both servers, because they share one wire protocol. The
differences are a version prefix, a second half of the capability field and
one extra authentication plugin (MariaDB's `client_ed25519`), each handled
where it occurs. Two packages would be two copies of everything else - the
handshake, the query protocol, the placeholder rewriter, the error format.

```
mysql://app:pw@localhost:3306/dev
mariadb://app:pw@db.internal/erp
```

Both URI schemes reach the same `Adapter`. Which one a program writes is a
label for the reader, not a switch this driver acts on.

## Two traps that only show up against MariaDB

**The version string.** MariaDB reports `5.5.5-10.11.2` in its greeting, a
compatibility hack from when old clients rejected a leading `10.`. A naive
parse reads MySQL 5.5.5 and takes every legacy path on a modern server. This
driver strips the prefix and decides the family explicitly: `serverInfo.family`
is `MariaDB` or `MySQL`, never a guess from a version number.

**The capability field.** MariaDB puts its own capability bits in the **upper
32 bits** of a 64-bit field, in four bytes MySQL leaves as zero filler after
the greeting's six-byte filler. They are read as such rather than assumed
zero.

## Which stock images verify

**Neither.** `mysql:8.4` and `mariadb:11.4` each generate a self-signed
certificate on first start, with no way to pass their own trust store in.
Against either one, [TLS](tls.md)'s no-`ssl-mode` ladder lands on `REQUIRED`:
encrypted, not verified. `VERIFY_CA` and `VERIFY_IDENTITY` both need a
certificate chain your trust store can build, which means a server you
configured yourself - it is not something a fresh container gives you.

```sh
docker run --rm -d --name my -e MYSQL_ROOT_PASSWORD=pw \
  -p 127.0.0.1:13306:3306 mysql:8.4
docker run --rm -d --name maria -e MARIADB_ROOT_PASSWORD=pw \
  -p 127.0.0.1:13307:3306 mariadb:11.4
```

A connection to either, with no `ssl-mode` set, is encrypted and unverified -
the one-rung-down case. Pinning `ssl-mode=VERIFY_CA` or `VERIFY_IDENTITY`
against a stock image fails; that failure is the ladder working as designed,
not a bug in either server or this driver.
