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

`checkCode` above verifies a code, but nothing yet stops a user who only knows
the password from walking into the app: the half-logged-in state is yours to
build, and that is where apps ship a bypass. `auth` builds it for you. After
the password step, hold the session **pending**; a pending session has no
identity, so `currentIdentity` and `requireAuth` refuse it, and only
`completeSecondFactor` turns it into a login.

First the factor. `TotpFactor` wraps `verify` and the replay protection above;
you give it the three things only your application knows: where a user's
secret is, what the last accepted counter was, and how to store a new one. It
also needs a `LoginThrottle` and will not be built without one, because a
6-digit code has a million values and a client that may try them all will:

```bit
import { App, Ctx, MemoryCounter } from "web"
import {
  BindOptions,
  CompleteOptions,
  Identity,
  Lookup,
  LoginThrottle,
  PasswordOptions,
  PasswordStrategy,
  Secret,
  SecondFactor,
  SecondRequired,
  TotpFactor,
  TotpFactorOptions,
  bindSession,
  completeSecondFactor,
  currentIdentity,
  parseSecret,
} from "auth"
import { ctEq } from "std/crypto"

// One row of your users table, as far as two-factor goes.
class TwoFactorRow {
  secretBase32: string,
  lastCounter: uint,
}

// Stand-in for the table: user id to row.
class TwoFactorDb {
  rows: map<string, TwoFactorRow>,
}

fn inkwellFactor(db: TwoFactorDb): TotpFactor! {
  let throttle = LoginThrottle(MemoryCounter(10_000))?
  let secretFor: (string) => Option<Secret> = (userId) => {
    let (row, found) = db.rows[userId]
    if (!found) {
      return Option<Secret>.None
    }
    let secret = parseSecret(row.secretBase32) catch _ {
      return Option<Secret>.None
    }
    return Option<Secret>.Some(secret)
  }
  let last: (string) => uint! = (userId) => {
    let (row, found) = db.rows[userId]
    if (!found) {
      return 0
    }
    return row.lastCounter
  }
  // Store `counter` only if it is newer than what is stored, and say whether
  // it was. In a real database this is one `UPDATE ... WHERE counter < ?`.
  let advance: (string, uint) => bool! = (userId, counter) => {
    let (row, found) = db.rows[userId]
    if (!found || counter <= row.lastCounter) {
      return false
    }
    row.lastCounter = counter
    return true
  }
  return TotpFactor(
    secretFor,
    TotpFactorOptions{
      throttle = Option<LoginThrottle>.Some(throttle),
      lastCounter = last,
      advanceCounter = advance,
    },
  )?
}
```

`advance` has to be one atomic statement. Two requests that carry the same
code both pass `last`; exactly one of them may win `advance`, and the other is
a replay. Wrong codes are counted in the throttle under the user's id, apart
from the password login, so a flood of them locks the second step and not the
whole account.

Now the login. The password strategy is told, through `PasswordOptions.second`,
which users still owe a code: it gets the verified `Identity` and answers
`true` for one who has enrolled. For that user the strategy never starts a full
session. It binds the login **pending** itself, before it answers, and fails
with the 401 below; there is no moment when a password alone is a login, and no
line for a handler to forget:

```bit
@json class CodeForm {
  code: string,
}

fn enrolled(db: TwoFactorDb): SecondRequired {
  let f: SecondRequired = (who) => {
    let (_, found) = db.rows[who.id]
    return found
  }
  return f
}

fn mountLogin(app: App, lookup: Lookup, factor: TotpFactor, db: TwoFactorDb) {
  let passwords = PasswordStrategy(
    lookup,
    PasswordOptions{ second = Option<SecondRequired>.Some(enrolled(db)) },
  )
  let login = app.group("/login")
  login.post("/", (c) => {
    let who = passwords.authenticate(c)?
    return c.text("welcome ${who.id}")
  })
  login.post("/code", (c) => {
    let form = c.body<CodeForm>()?
    let who = completeSecondFactor(c, factor, form.code)?
    return c.text("welcome ${who.id}")
  })
  app.get("/me", (c) => c.text(currentIdentity(c)?.id))
}
```

Read it from the top. For a user who has not enrolled, `second` says no and
`passwords.authenticate(c)` is the full login it always was. For one who has,
it verifies the password and binds `BindOptions{ second = true }` directly, so
the session holds the user's id under a pending key and nothing under the
identity key, then fails instead of returning the `Identity`: `/login` answers
401 and `/me` is refused, as is every route behind `requireAuth` or
`currentIdentity`, with a body that says why:

```text
{"status":401,"error":"Unauthorized","detail":"second_factor_required"}
```

A front end switches on `detail` to show the code field instead of the sign-in
form. `completeSecondFactor` asks the factor whether the code is right. A
correct code regenerates the session id, so the id the browser held during the
half login is dead, and moves the identity to a full login. A wrong one fails
with a plain 401 and leaves the session pending, so the user can type again,
until the throttle answers 429 or the pending state runs out. That takes
`pendingTtl` seconds from the password step, 300 unless you say otherwise:

If `second` itself fails (the enrollment table is down), the login is refused:
the strategy cannot tell whether a code is owed, and the answer is never a
yes. The same option is on every strategy that can sign a user in: `PasswordOptions`,
`MagicLinkOptions`, `OAuth2Options` and `OidcOptions` (which covers Google,
Microsoft and Apple) each take a `second` and behave this way.

When you bind a half login yourself, for a flow of your own, `bindSession` with
`BindOptions{ second = true }` is the call, and `pendingTtl` sets how long it
waits:

```bit
fn quickPending(c: Ctx, who: Identity): ()! {
  bindSession(c, who, BindOptions{ second = true, pendingTtl = 120 })?
}
```

The countdown starts at the password, not at the last wrong code, so retries
do not extend it. A user who walks away is signed out of the half login after
that, not left one code short of an account for the session's full day. A
session that is not pending, or whose pending state ran out, gets the same plain
401 from `completeSecondFactor`: nothing says which, so a stranger learns nothing.

Handlers must pass the error on. `currentIdentity(c)?` keeps the code in the
401. The `catch _ { fail unauthorized() }` pattern from [Getting
started](getting-started.md) throws it away and the front end sees a plain
sign-in prompt where it should see a code prompt.

## A second factor of your own

TOTP is one `SecondFactor`. Anything with a name and a `verify` that answers
`true` for a right proof and `false` for a wrong one is another: a code sent by
e-mail, a hardware key. Such a factor does not throttle itself, so hand
`completeSecondFactor` the throttle through `CompleteOptions`:

```bit
// A code your app mailed to the user and remembers.
class EmailedCode {
  sent: map<string, string>

  export name(): string {
    return "email"
  }

  export verify(c: Ctx, userId: string, input: string): bool! {
    let (want, found) = this.sent[userId]
    if (!found) {
      return false
    }
    return ctEq([]byte(want), []byte(input))
  }
}

fn emailFactor(sent: map<string, string>): SecondFactor {
  return EmailedCode{ sent = sent }
}

fn completeWithEmail(
  c: Ctx,
  factor: SecondFactor,
  throttle: LoginThrottle,
  input: string,
): Identity! {
  let opts = CompleteOptions{ throttle = Option<LoginThrottle>.Some(throttle) }
  return completeSecondFactor(c, factor, input, opts)?
}
```

Leave `throttle` empty for a `TotpFactor`, which already counts its attempts;
passing it too counts each failure twice at the address. A failed `verify`
call, as opposed to a `false`, refuses the login: the factor could not decide,
and the answer is never a yes.

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
- **Set `second` on every first-factor strategy you mount.** A strategy
  without it makes a login on the password, link or provider alone; the option
  is what keeps a user who owes a code from ever holding a full session.
- **Hold a half login of your own with `bindSession(..., second = true)`,
  never with a session key of your own.** Every reader of the identity looks at
  one key; a second one is a route that forgot to look.
- **Mount a password `Strategy` on the login route only.** A strategy that
  authenticates on any route it guards would turn a password into a full login
  there (for a user with no second factor), so mount it where you mean one.
- **Make `advanceCounter` atomic.** A read followed by a write lets two
  requests with the same code both succeed.
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
