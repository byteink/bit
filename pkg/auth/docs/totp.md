# Two-factor authentication with TOTP

A password alone means one leaked credential is a compromised account. You
want a second step at login - a 6-digit code from the user's phone that
changes every 30 seconds - so a stolen password is not enough on its own.
This is TOTP (RFC 6238), the algorithm behind Google Authenticator, Authy,
and every other "authenticator app" a user already has installed.

## Enrolling a user

`generateSecret()` makes a fresh, random key. Store it against the user -
alongside their password hash is fine - and show them `provisioningUri`
as a QR code, which their authenticator app scans to start generating
codes:

```bit
import { generateSecret, provisioningUri } from "auth"

fn enrollTwoFactor(userEmail: string): (string, string) {
  let secret = generateSecret()
  let uri = provisioningUri(secret, "Inkwell", userEmail)
  return (secret.base32(), uri)
}
```

`secret.base32()` is what you store - text, safe for a database column.
`uri` is an `otpauth://` URI: turn it into a QR code (any QR library takes
a plain string) and the user's app has everything it needs. Never log or
email the secret itself; the QR code is the only time it should leave your
server unencrypted.

## Verifying a code at login

Once a user has enrolled, every login needs their password AND a current
code. `verify` checks a submitted code against the stored secret, accepting
a small clock-drift window, and - this is the part a naive check misses -
refuses a code that was already used:

```bit
import { parseSecret, verify } from "auth"
import { now } from "std/time"

// Persisted alongside the user: the base32 secret from enrollment, and the
// counter `verify` last accepted (0 until their first successful code).
class TwoFactorState {
  secretBase32: string,
  lastCounter: uint,
}

// Checks `code` and returns the counter to persist as the new
// `lastCounter` - the caller must save it, or the same code (and every
// code from the same or an earlier step) verifies again.
fn checkCode(state: TwoFactorState, code: string): uint! {
  let secret = parseSecret(state.secretBase32)?
  let unixSeconds = now().ns / 1000000000
  return verify(secret, code, unixSeconds, state.lastCounter, 1)?
}
```

`skew = 1` (the last argument) accepts a code from one 30-second step
before or after the server's clock - the RFC's own recommendation, and
enough to cover a phone whose clock has drifted a little. `lastCounter`
is what makes replay impossible: `checkCode` never accepts a step at or
before it, so the exact code a user just typed - or one an attacker
captured over their shoulder - fails on a second attempt, inside or
outside the skew window. **You must persist the returned counter.** If you
verify a code and never save the result, every code in the skew window
stays valid until it naturally expires, and `checkCode` gives you no way
to notice that happened.

## Wiring it into a login flow

A full second-factor login is two requests, both routes [Getting
started](getting-started.md) already showed you how to add to an `App`: the
password step (`requireAuth([]Strategy{ PasswordStrategy(users) })`)
succeeds and marks the session "awaiting 2FA" rather than fully
authenticated - `c.session()?.set("2fa:pending", currentIdentity(c)?.id)?` -
and a second route, `POST /login/totp`, reads that pending id back, calls
`checkCode` (above) against the body's submitted code, and on success
persists the returned counter and clears `"2fa:pending"` before answering.
On failure - a bad code, or `parseSecret` failing on a corrupted stored
value - the handler answers `unauthorized()` exactly like a wrong password
does, and the session stays pending: the user can retry.

## When the phone is lost: recovery codes

An authenticator app lives on one phone. Lose it and the user is locked out
of their own account, with a second factor nobody can reproduce. The usual
answer is a short list of recovery codes, shown once at enrollment, each
good for exactly one login in place of a TOTP code.

`generateRecoveryCodes()` makes ten of them. `codes` is for the user - show
it once, then forget it. `hashes` is for your database:

```bit
import { RecoverySet, generateRecoveryCodes } from "auth"

class RecoveryState {
  hashes: []string,
}

// Called when the user finishes enrolling: the codes go on screen, the
// hashes go in the database.
fn issueRecoveryCodes(): (RecoverySet, RecoveryState)! {
  let set = generateRecoveryCodes()?
  return (set, RecoveryState{ hashes = set.hashes })
}
```

A code looks like `k3x9a-7qm2p`: two groups of five characters from an
alphabet with no `i`, `l`, `o` or `u`. That is 50 random bits from the
operating system's CSPRNG, far beyond what anyone can guess through a
login form. The shape is a typed option rather than a second function:

```bit
import { RecoveryOptions, RecoverySet, generateRecoveryCodes } from "auth"

// Eight longer codes: three groups of five is 75 bits each.
fn longerCodes(): RecoverySet! {
  return generateRecoveryCodes(RecoveryOptions{ count = 8, groups = 3, groupLen = 5 })?
}
```

`count` is 1 to 32, and a code must carry at least 50 bits
(`groups * groupLen * 5`); anything else fails with an error before a
single code is made.

## Using a recovery code at login

The login form takes the code in the same box as a TOTP code. When
`checkCode` fails, try `redeemRecoveryCode`. It ignores case, spaces and
dashes, and reads `0`/`o` and `1`/`i`/`l` as the same character, so a code
retyped from a printout still works. A match returns `remaining`, the
stored list without the code that was just used - **persist it**, or the
code works again:

```bit
import { RecoveryRedeem, redeemRecoveryCode } from "auth"

class RecoveryRecord {
  hashes: []string,
}

// Returns the record to save. Fails with one message whether the code was
// wrong, already used, or not a code at all.
fn useRecoveryCode(record: RecoveryRecord, typed: string): RecoveryRecord! {
  let redeemed: RecoveryRedeem = redeemRecoveryCode(record.hashes, typed)?
  return RecoveryRecord{ hashes = redeemed.remaining }
}
```

If the user used a recovery code, they have probably lost their phone: send
them to enroll a new authenticator (`generateSecret` again) right after.

## Regenerating

There is no "revoke" call. Run `generateRecoveryCodes()` again and store
the new `hashes` over the old list. The old codes are checked against
hashes you no longer keep, so all of them fail, used or not. Offer this
button after a user spends most of their set, and always when they re-enroll.

## How the codes are stored

You store `hashes`, never `codes`. Each entry is a random 16-byte salt
and the SHA-256 of the salt plus the code. A fast, salted hash is right
here and a password hash would not help: a password hash exists to slow
down guessing of secrets a person chose, and these are not chosen, they
are 50 random bits with nothing to build a dictionary from. The salt makes
every entry unique so a precomputed table is useless, and a code can be used
only once, so what a thief who copies the database learns is worth nothing
after the real user spends it. Comparison runs through `ctEq` over every
stored entry, so timing does not say which entry was close.

## The low-level primitive: HOTP

`totp`/`verify` are what a real enrollment uses. They are built on `hotp`,
the RFC 4226 counter-based code `totp` calls once per time step - exposed
for the rare integration that already has an explicit counter (a hardware
token's sequence number, say) rather than a clock:

```bit
import { Secret, hotp } from "auth"

fn hardwareTokenCode(secret: Secret, sequenceNumber: uint): string {
  return hotp(secret, sequenceNumber, 6)
}
```

## A non-default digit count or hash

`verify`/`totp`/`hotp` are SHA-1 at 6 digits and a 30-second period - what
every authenticator app expects, and the only combination worth using for a
real enrollment. `Algorithm` is what they are built on, for the rare case
you need something else (interoperating with a system that issued
8-digit codes, say):

```bit
import { Algorithm, sha1 } from "auth"

fn eightDigitCode(secretBase32: string, unixSeconds: int): string! {
  let secret = parseSecret(secretBase32)?
  let algo: Algorithm = sha1(8, 30)
  return algo.totp(secret, unixSeconds)
}
```

`provisioningUriWith` takes the matching `digits`/`period` for the QR
code - but most authenticator apps ignore those fields and always assume
6 digits/30 seconds, so a non-default `Algorithm` will not work with a
generic authenticator app in practice; it exists for server-to-server TOTP,
not for a user's phone.

## Sharp edges

- **The secret never changes without re-enrollment.** `generateSecret`
  called again invalidates every authenticator app the user already set
  up - only call it once, at enrollment, or when the user explicitly resets
  their 2FA.
- **A code is exactly 6 (or your chosen `digits`) ASCII digits.** `verify`
  compares byte for byte in constant time; a submission with leading or
  trailing whitespace never matches - trim it before calling `verify`.
- **Persist `remaining` after every redemption.** `redeemRecoveryCode` is
  a pure function: it holds no state, so a recovery code is single use only
  as long as you save the shorter list.
- **Clock skew is a security/usability tradeoff.** `skew = 1` (one step
  either side, 30 seconds) covers ordinary drift; a much larger skew widens
  the window an intercepted code stays valid in.

## When not to use it

TOTP needs the user to already have an authenticator app, or to install
one. For a lower-friction second factor - SMS, or a push notification -
you need a different mechanism entirely; this package does not provide
one. For a phishing-resistant factor, WebAuthn/passkeys are stronger than
TOTP (a fake login page can still relay a TOTP code to the real one in
real time) but are a larger integration this package does not cover.

Next: [Security model](security.md), for the properties this package
checks on every request.

Specification: [RFC 6238](https://www.rfc-editor.org/rfc/rfc6238) (TOTP),
[RFC 4226](https://www.rfc-editor.org/rfc/rfc4226) (HOTP).
