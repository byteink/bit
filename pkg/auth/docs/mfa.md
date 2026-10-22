# Confirm an author before a sensitive change

An Inkwell author leaves a signed-in browser unattended. Someone who finds
that browser can read the same drafts, but changing the account's email
address should require a recent proof from the author. Keeping the browser
busy must not keep that proof fresh forever.

`requireFresh` checks the age of the last verified login or reauthentication.
Start with the password login from [Getting started](getting-started.md),
then put the check on the sensitive route:

```bit
import { App } from "web"
import { currentIdentity, requireFresh } from "auth"

fn protectExport(app: App, exportNotes: (string) => string!): () {
  let exports = app.group("/account/export")
  exports.use(requireFresh(300))
  exports.get("/", (c) => {
    let author = currentIdentity(c)?
    return c.text(exportNotes(author.id)?)
  })
}
```

The route accepts a proof no older than 300 seconds, including the exact
boundary. This is Inkwell's chosen window, not a default session timeout.
`requireFresh` also checks that a full identity exists. An anonymous or
pending session cannot pass by carrying a recent timestamp.

## Ask for the author's authenticator code

A fresh password login can satisfy the first guard. For an email-address
change, Inkwell asks specifically for the author's enrolled authenticator.
Pass the same `TotpFactor` to `requireFresh` and to the route that confirms
the submitted code. The factor uses the enrolled secrets and atomic replay
counter from [Two-factor authentication with TOTP](totp.md):

```bit
import { Config, Ctx, MemoryStore } from "web"
import {
  Identity,
  LoginThrottle,
  PasswordStrategy,
  Secret,
  SecondFactor,
  Strategy,
  TotpFactor,
  TotpFactorOptions,
  completeSecondFactor,
  reauthenticate,
  requireAuth,
} from "auth"

class InkwellSession {
  export name(): string {
    return "session"
  }

  export authenticate(c: Ctx): Identity! {
    return currentIdentity(c)?
  }
}

@json class ConfirmationCode {
  code: string,
}

@json class NewEmail {
  email: string,
}

fn inkwellAccount(
  sessionSecret: string,
  passwords: PasswordStrategy,
  secretFor: (string) => Option<Secret>,
  lastCounter: (string) => uint!,
  advanceCounter: (string, uint) => bool!,
  throttle: LoginThrottle,
  changeEmail: (string, string) => ()!,
  exportNotes: (string) => string!,
): App! {
  let factor = TotpFactor(
    secretFor,
    TotpFactorOptions{
      throttle = Option<LoginThrottle>.Some(throttle),
      lastCounter = lastCounter,
      advanceCounter = advanceCounter,
    },
  )?
  let app = App(Config{ secret = sessionSecret, sessions = MemoryStore(10_000) })
  app.post("/login", (c) => {
    let author = passwords.authenticate(c)?
    return c.text(author.id)
  })
  app.post("/login/code", (c) => {
    let form = c.body<ConfirmationCode>()?
    return c.text(completeSecondFactor(c, factor, form.code)?.id)
  })
  app.post("/reauthenticate", (c) => {
    let form = c.body<ConfirmationCode>()?
    reauthenticate(c, factor, form.code)?
    return c.text("confirmed")
  })

  let account = app.group("/account")
  account.use(requireAuth([]Strategy{ InkwellSession{} }))
  account.use(requireFresh(300, Option<SecondFactor>.Some(factor)))
  account.post("/email", (c) => {
    let author = currentIdentity(c)?
    let form = c.body<NewEmail>()?
    changeEmail(author.id, form.email)?
    return c.text("email updated")
  })
  protectExport(app, exportNotes)
  app.freeze()?
  return app
}
```

The password strategy and store callbacks are the application's existing
login and user storage. `changeEmail` validates and persists the requested
address; `exportNotes` produces the author's existing export. The example's `MemoryStore` is bounded to one process; a deployment
with several processes supplies its shared `SessionStore` instead.

`advanceCounter` must be an atomic compare-and-set: accept the counter only
if it exceeds the stored one. `TotpFactor` checks the required throttle before
verifying and refuses a reused code. Use it for both the login-code and
confirmation routes so the same TOTP cannot be spent on both.

A completed second factor already records that factor's fresh proof. A fresh
password-only login records a proof without a second-factor name, so it passes
`requireFresh(300)` but not the factor-specific email guard.

## Continue after confirmation

An old or unsuitable proof answers 401 with a machine-readable detail:

```text
{"status":401,"error":"Unauthorized","detail":"reauthentication_required"}
```

Show the authenticator-code prompt, post `{"code":"123456"}` to
`/reauthenticate` with the existing session cookie, then retry `/account/email`.
The code above keeps the current identity and session id. Only the proof time
and the name of the successfully verified factor change. This differs from
finishing a pending login: `completeSecondFactor` still rotates its session id
when it promotes that identity.

`requireFresh` never reads a code from the request, verifies a factor, or
updates the proof time. An ordinary `requireAuth` pass using `InkwellSession`
preserves that time too. A custom strategy calls `bindSession` only after it
has verified new credentials, not while reading an existing session.

## Refusals and boundaries

- A wrong code answers 401 and leaves the old proof unchanged. A verifier or
  session-store failure propagates as an error; it does not authorize the
  sensitive action. Applications should show a retryable service error without
  exposing the storage failure's internal message. A save error after a store
  has committed is ambiguous: the verified proof may already be persisted.
  The current request still fails; the guard cannot undo an unknown commit.
- A pending login must finish `/login/code` first. `reauthenticate` cannot
  promote it or substitute for a required second login factor.
- Factor-specific checks use the most recently verified factor's nonempty
  `name()`. Give different factors different names. A later password login
  clears the earlier second-factor assurance.
- Missing, malformed or future proof times are refused, as are negative age
  limits. Keep server clocks synchronized; the guard does not treat clock
  rollback as a new authentication event.
- A custom `SecondFactor` passed to `reauthenticate` must throttle itself.
  This function has no `CompleteOptions` throttle argument; using an
  unthrottled emailed-code verifier here would permit unrestricted guesses.

This guard does not set absolute or idle session lifetimes. Those remain the
session store's policy. [NIST's session guidance](https://pages.nist.gov/800-63-4/sp800-63b/session/)
distinguishes an authentication event from continuing to present a session
secret. [OWASP's sensitive-feature guidance](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html#require-re-authentication-for-sensitive-features)
explains when an application should ask again. Choose the action's proof age
and required factor for the application's assurance needs.

For initial enrollment and pending-login completion, continue with
[Two-factor authentication with TOTP](totp.md). For ending compromised
sessions, see [Sign an author out of every device](logout-everywhere.md).
