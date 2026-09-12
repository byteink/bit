# Authentication

`scram-sha-256` (RFC 5802/7677) whenever the server offers it, and `md5`,
cleartext `password` and `trust` all connect - a stock server uses one of
the last three, and a driver that refuses them is a driver nobody can start
with. Each of the three warns once per pool, naming the method and the fix.

The SCRAM exchange verifies the **server's** signature before accepting
`AuthenticationOk`, and every comparison in it goes through `crypto/subtle`
(constant-time), so a forged server signature or a replayed nonce is
rejected rather than timed.

## What SCRAM here does not do

**SASLPrep (RFC 4013) is not applied to the password.** It is the identity
function for an ASCII password, which is every password this driver has
been run against; a password whose normalized form differs from its raw
form would derive a different key here than libpq derives.

**`SCRAM-SHA-256-PLUS` (channel binding) is not offered.** The client
always sends the GS2 header for "no channel binding, no authorization
identity" (`n,,`).

Both are read from the connection the same way regardless: neither weakens
a `trust`/`password`/`md5` connection, since those never run SCRAM at all.
