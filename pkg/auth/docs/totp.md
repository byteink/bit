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

fn enrollTwoFactor(userEmail: string): (string, string)! {
  let secret = generateSecret()
  let uri = provisioningUri(secret, "Inkwell", userEmail)?
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

A code looks like `a3k9-k3x9a-7qm2p`. The first group, `a3k9`, is an
identifier that says which stored entry the code belongs to; the other two
groups are 50 random bits from the operating system's CSPRNG, far beyond
what anyone can guess through a login form. The letters come from an alphabet
with no `i`, `l`, `o` or `u`. The shape of the secret part is a typed option
rather than a second function:

```bit
import { RecoveryOptions, RecoverySet, generateRecoveryCodes } from "auth"

// Eight longer codes: three groups of five is 75 secret bits each.
fn longerCodes(): RecoverySet! {
  return generateRecoveryCodes(RecoveryOptions{ count = 8, groups = 3, groupLen = 5 })?
}
```

`count` is 1 to 32, and the secret part must carry at least 50 bits
(`groups * groupLen * 5`); anything else fails with an error before a
single code is made. Making a set costs one password hash per code, so a
batch of ten takes about as long as ten password hashes.

## Using a recovery code at login

The login form takes the code in the same box as a TOTP code. When
`checkCode` fails, try `redeemRecoveryCode`. It ignores case, spaces and
dashes, and reads `0`/`o` and `1`/`i`/`l` as the same character, so a code
retyped from a printout still works. A match returns `remaining`, the
stored list without the code that was just used - **persist it**, or the
code works again.

A recovery code is a guessable secret in a way a TOTP code never is: it does
not expire. Hand `redeemRecoveryCode` the same `LoginThrottle` your password
login uses, through `RedeemOptions`, so a client that keeps guessing is
locked out. The throttle counts these attempts under their own name for the
account, so a flood of wrong codes does not lock the password login:

```bit
import {
  LoginThrottle,
  RecoveryRedeem,
  RedeemOptions,
  redeemRecoveryCode,
} from "auth"

class RecoveryRecord {
  email: string,
  hashes: []string,
}

// Returns the record to save. Fails with one message whether the code was
// wrong, already used, or not a code at all, and with a `Throttled` (a 429
// when it escapes a route) once the account or the address has failed too
// often.
fn useRecoveryCode(
  record: RecoveryRecord,
  typed: string,
  throttle: LoginThrottle,
  ip: string,
): RecoveryRecord! {
  let opts = RedeemOptions{
    throttle = Option<LoginThrottle>.Some(throttle),
    account = record.email,
    ip = ip,
  }
  let redeemed: RecoveryRedeem = redeemRecoveryCode(record.hashes, typed, opts)?
  return RecoveryRecord{ email = record.email, hashes = redeemed.remaining }
}
```

`redeemRecoveryCode(record.hashes, typed)` with no options works and counts
nothing; then the throttling is yours to add, and without it a recovery
code is the weakest door into the account. If the user used a recovery
code, they have probably lost their phone: send them to enroll a new
authenticator (`generateSecret` again) right after.

## Regenerating

There is no "revoke" call. Run `generateRecoveryCodes()` again and store
the new `hashes` over the old list. The old codes name identifiers and
hashes you no longer keep, so all of them fail, used or not. Offer this
button after a user spends most of their set, and always when they re-enroll.

## How the codes are stored

You store `hashes`, never `codes`. Each entry is the code's identifier
followed by an Argon2id hash of its secret part - the same hash, with the same
cost, that `hashPassword` makes for a password. NIST SP 800-63B treats a code
a person types as a low-entropy secret: under 112 bits it has to be stored
with a password hash, not a fast one, because 50 bits is something a graphics
card can search through when it holds your table. Argon2id makes each guess
cost about what a password check costs, and the salt inside it is fresh for
every entry.

The identifier is what keeps redemption cheap. It is stored in the open and
is not counted in the 50 bits, because anyone holding the table knows it. It
tells `redeemRecoveryCode` which one entry to check, so a redemption runs
exactly one Argon2id hash whether you store one code or thirty-two. A
code with an identifier you do not have is checked against a fixed dummy hash
instead, so a hit, a wrong secret and an unknown identifier all take the same
time. Without the identifier, every guess would cost one hash per stored code.

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

The QR code advertises the same `digits`/`period` through the optional
last argument of `provisioningUri`, a `ProvisioningOptions`:

```bit
import { ProvisioningOptions, generateSecret, provisioningUri } from "auth"

fn eightDigitUri(userEmail: string): string! {
  let secret = generateSecret()
  return provisioningUri(
    secret,
    "Inkwell",
    userEmail,
    ProvisioningOptions{ digits = 8, period = 30 },
  )?
}
```

`ProvisioningOptions{}` is 6 digits and 30 seconds, the default. `digits`
outside 6..8 or a `period` of 0 or less is a mistake in your code, so the
call fails with an error instead of printing a URI no app can use. Most
authenticator apps ignore those fields and always assume 6 digits/30
seconds, so a non-default `Algorithm` will not work with a generic
authenticator app in practice; it exists for server-to-server TOTP, not for
a user's phone.

## Sharp edges

- **The secret never changes without re-enrollment.** `generateSecret`
  called again invalidates every authenticator app the user already set
  up - only call it once, at enrollment, or when the user explicitly resets
  their 2FA.
- **A code is exactly 6 (or your chosen `digits`) ASCII digits.** `verify`
  compares byte for byte in constant time; a submission with leading or
  trailing whitespace never matches - trim it before calling `verify`.
- **Persist `remaining` after every redemption.** `redeemRecoveryCode`
  holds no codes of its own, so a recovery code is single use only as long as
  you save the shorter list.
- **Pass a throttle to `redeemRecoveryCode`.** Each guess already costs a
  password hash, but nothing stops a client making guesses all day unless the
  throttle does.
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
