# Let an author sign in with a passkey

A password can be guessed, reused on another site, or typed into a fake login
page. A passkey cannot: the browser makes a key pair for your site, keeps the
private half in the phone, laptop or security key, and only ever answers the
real origin. Inkwell's authors should be able to add one to their account and
stop typing a password. This page has both halves: registration, the moment the
author says "add a passkey" and your server stores the public key, and sign-in,
the moment the author comes back and proves they hold it.

Registration is two requests. The first asks the server for options, the
browser makes the key pair, and the second sends the result back to be
verified and stored.

## The relying party and the store

Your server is the "relying party". It has an identity, the domain the keys
are bound to, and a list of the exact origins a browser may call it from. It
also needs somewhere to keep each passkey's public key.
`MemoryCredentialStore` is the in-process store for development and tests:

```bit
import {
  MemoryCredentialStore,
  RelyingParty,
  WebAuthn,
  WebAuthnOptions,
} from "auth"

fn inkwellPasskeys(): WebAuthn! {
  let rp = RelyingParty{
    id = "inkwell.example",
    name = "Inkwell",
    origins = ["https://inkwell.example"],
  }
  return WebAuthn(rp, MemoryCredentialStore(), WebAuthnOptions{})?
}
```

`id` is the registrable domain: the host of every origin, or a parent domain
of it. With `id = "inkwell.example"` a passkey made on
`https://app.inkwell.example` also works on `https://inkwell.example`. Each
entry of `origins` is exactly what the browser sends: `https://host`, with
`:port` when it is not 443. `topOrigins` (empty by default) lists the pages
allowed to embed yours in an iframe.

`WebAuthn(...)` checks all of this when it is built and fails with an error,
so a mistake stops the app at startup instead of failing every registration:

- `RelyingParty.id 'inkwell.example' is not the host of origin 'https://other.example' or a parent domain of it`
- `origin 'http://inkwell.example' must be https://host[:port] (http only for localhost)`
- `RelyingParty.id 'com' is a single label; use your registrable domain, for example example.com`
- `algorithm -36 cannot be verified - use -7 ES256, -35 ES384, -8 EdDSA, -37 PS256 or -257 RS256`
- `algorithms is empty`

For local development use `id = "localhost"` and
`origins = ["http://localhost:3000"]`. Plain `http` is accepted for
`localhost` and nowhere else.

## Step one: the options

`beginRegistration` takes the signed-in author as a `UserEntity` and returns
the options JSON the browser needs. It also keeps a fresh 32-byte random
challenge in the session, good for 5 minutes and for one attempt:

```bit
import { App, unauthorized } from "web"
import { UserEntity, WebAuthn, currentIdentity } from "auth"
import { jsonEncode } from "std/json"

fn passkeyRoutes(app: App, wa: WebAuthn) {
  app.post("/passkeys/options", (c) => {
    let me = currentIdentity(c) catch _ {
      fail unauthorized()
    }
    let user = UserEntity{ id = me.id, name = me.id, displayName = "Inkwell author" }
    let options = wa.beginRegistration(c, user)?
    return c.text(jsonEncode(options)).header("Content-Type", "application/json")
  })
}
```

`user.id` is your own stable identifier for the author: the same value you
use everywhere else. It is what `Credential.userId` holds and what the store
looks passkeys up by, and it is never sent to the browser (see "The user
handle" below). An empty id fails with `user.id is empty`. `name` and
`displayName` are only what the browser shows when the author picks an
account.

Whatever passkeys the author already has are listed in `excludeCredentials`,
so the browser refuses to register the same device twice.

## Step two: the browser

The browser turns the options into a key pair. This is the whole client side
(a packaged client helper is a separate page):

```js
const options = await (await fetch("/passkeys/options", { method: "POST" })).json()
const credential = await navigator.credentials.create({
  publicKey: PublicKeyCredential.parseCreationOptionsFromJSON(options),
})
await fetch("/passkeys/register", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify(credential.toJSON()),
})
```

## Step three: verify and store

`finishRegistration` takes what `credential.toJSON()` produced and returns the
stored `Credential`:

```bit
import { App } from "web"
import { WebAuthn } from "auth"

fn registerRoute(app: App, wa: WebAuthn) {
  app.post("/passkeys/register", (c) => {
    let _ = wa.finishRegistration(c, c.bodyJson()?)?
    return c.status(201)
  })
}
```

Before anything is stored the server checks, in this order:

1. A registration was started in this session, and its challenge has not
   expired. The challenge is spent right here, on every attempt, so a
   response can never be tried twice.
2. The `clientDataJSON` says `webauthn.create`, carries the challenge you
   issued (compared in constant time) and an origin from your list.
3. The authenticator data was made for your `RelyingParty.id` (the `rpIdHash`),
   the user was present, and, when you require it, verified with a PIN or
   biometric.
4. The key's algorithm is one you offered, the credential id matches the one
   the browser reported, and no credential with that id exists yet.
5. The attestation format is `none`.

A failure is an error whose message names the check, for example
`clientData origin 'https://evil.example' is not an allowed origin`,
`authenticatorData does not have the UP flag (user presence)`,
`a credential with this id is already registered` or
`no registration is in progress for this session`. Show the author a generic
"could not add the passkey" and log the message.

Attestation `none` means you do not ask which authenticator model made the
key, which is what almost every site wants. A response in another format
(`packed`, `fido-u2f`, `tpm`) fails with
`attestation format 'packed' is not supported yet, only 'none'`.

## The user handle

A passkey keeps a "user handle" next to the key, and the authenticator can
hand it back to any page that asks. So the handle must say nothing about the
author: your user id may be an email address or a counter somebody could
guess. The store gives each author a handle of 64 random bytes the first time
they register a passkey, and `beginRegistration` sends that as `user.id` in
the options. Your own id never leaves the server.

The handle is kept only when the registration succeeds, and every later
registration for the same author sends the same one. Signing in goes the other
way: the authenticator answers with the handle, and the store says which
author it belongs to. `CredentialStore.handleFor(userId)` and
`userForHandle(handle)` do those two lookups:

```bit
import { CredentialStore } from "auth"

fn handleRoundTrip(store: CredentialStore, userId: string): string! {
  let handle = store.handleFor(userId)?
  if (!isSome(handle)) {
    return "${userId} has no passkey yet"
  }
  let back = store.userForHandle(unwrap(handle))?
  return "${len(unwrap(handle))}-byte handle belongs to ${unwrap(back)}"
}
```

`handleFor` and `userForHandle` answer `Option.None` for a user or a handle
the store does not know. A handle is not a secret (the browser holds it), so
`userForHandle` is a plain lookup by key, not a constant-time scan; a database
store keeps a `UNIQUE` index on it. Compare two handles you already hold with
`ctEq`, never `==`.

## What is stored

`finishRegistration` gives back the `Credential` it handed to the store:

```bit
import { Credential } from "auth"

fn describe(c: Credential): string {
  let kind = "device-bound"
  if (c.backupState) {
    kind = "synced"
  }
  return "${c.name} (${kind}, algorithm ${c.alg}, used ${c.signCount} times, added ${c.createdAt}, ${len(c.id)}-byte id, ${len(c.aaguid)}-byte model, ${len(c.publicKey)}-byte key, transports ${len(c.transports)}, user ${c.userId}, eligible ${c.backupEligible})"
}
```

`publicKey` is the COSE key exactly as the authenticator sent it; keep the
bytes as they are. `backupEligible` and `backupState` say whether the
passkey can be, and currently is, synced to the author's other devices.
`name` is empty until you let the author label the passkey, then you save it
with `update`.

## Your own store

`CredentialStore` is an interface, so a database table is a store with no
registration step. Eight methods, the five for credentials and three for the
user handle:

```bit
import { Credential, CredentialStore } from "auth"
import { ctEq } from "std/crypto"

class InkwellPasskeys {
  rows: []Credential

  export add(c: Credential): ()! {
    for r of this.rows {
      if (ctEq(r.id, c.id)) {
        fail newError("passkeys: duplicate id")
      }
    }
    this.rows = append(this.rows, c)
  }

  export byId(id: []byte): Option<Credential>! {
    for r of this.rows {
      if (ctEq(r.id, id)) {
        return Option<Credential>.Some(r)
      }
    }
    return Option<Credential>.None
  }

  export forUser(userId: string): []Credential! {
    let mine = []Credential(0)
    for r of this.rows {
      if (r.userId == userId) {
        mine = append(mine, r)
      }
    }
    return mine
  }

  export update(c: Credential): ()! {
    return
  }

  export remove(id: []byte): ()! {
    return
  }

  export handleFor(userId: string): Option<[]byte>! {
    return Option<[]byte>.None
  }

  export userForHandle(handle: []byte): Option<string>! {
    return Option<string>.None
  }

  export bindHandle(userId: string, handle: []byte): []byte! {
    return handle
  }
}

fn asStore(p: InkwellPasskeys): CredentialStore {
  return p
}
```

`add` must be one atomic step that fails when the id is already stored (a
`UNIQUE` index does it): two requests racing to store one credential must not
both win. `update` and `remove` fail for an id that is not stored.

`bindHandle(userId, handle)` is the same kind of step for the handle: it
stores `handle` when the user has none and answers the handle the user now
has, so two first registrations racing leave one handle, not two (the
`UNIQUE` index on the user id and on the handle does it). It fails for a handle
that is empty, over 64 bytes, or already bound to another user. The class
above is a stub; yours keeps the pairs.

## Policy

Everything else is a field of `WebAuthnOptions`, each a typed value:

```bit
import {
  Attachment,
  AttestationConveyance,
  ResidentKey,
  UserVerification,
  WebAuthnOptions,
} from "auth"

fn strictPolicy(): WebAuthnOptions {
  return WebAuthnOptions{
    algorithms = [-7, -8, -257],
    userVerification = UserVerification.Required,
    residentKey = ResidentKey.Required,
    attachment = Attachment.Platform,
    attestation = AttestationConveyance.None,
    timeoutMs = 120000,
  }
}
```

- `algorithms`: COSE numbers in order of preference. The default is
  `[-7, -8, -257]`: ES256, EdDSA, RS256. `-35` (ES384) and `-37` (PS256) are
  also accepted.
- `userVerification`: `Preferred` by default. `Required` rejects a response
  whose user-verified flag is clear.
- `residentKey`: `Required` makes a discoverable passkey, one the browser can
  offer without asking for a username first.
- `attachment`: `Platform` for the device's own authenticator, `CrossPlatform`
  for a security key, `Any` (the default) for either.
- `attestation`: the conveyance preference, `None` by default.
- `timeoutMs`: the hint the browser shows its dialog for, 5 minutes by
  default. The server-side challenge lives 5 minutes whatever this says.

## Signing in

Registration binds no session: the author was already signed in. Signing in is
a `WebAuthnStrategy`, a first-factor strategy like `PasswordStrategy`, over the
same `WebAuthn` and store. You give it `resolve(userId)`, the function that turns
the id a credential was registered under into the `Identity` to log in (and
fails for an author you have since disabled):

```bit
import {
  CloneAction,
  Identity,
  PasskeyLoginOptions,
  UserVerification,
  WebAuthn,
  WebAuthnStrategy,
} from "auth"
import { Json } from "std/json"

fn inkwellSignIn(wa: WebAuthn): WebAuthnStrategy! {
  let resolve: (string) => Identity! = (userId) => {
    return Identity{ id = userId, claims = Json.JsonNull }
  }
  let opts = PasskeyLoginOptions{
    userVerification = UserVerification.Preferred,
    onCloneSuspected = CloneAction.Reject,
  }
  return WebAuthnStrategy(wa, resolve, opts)?
}
```

Like registration, sign-in is two requests. `beginLogin` returns the options
for `navigator.credentials.get()` and keeps a fresh 32-byte challenge in the
session, good for 5 minutes and one attempt. Pass the author's id and the
options list their passkeys in `allowCredentials`; pass `None` and the list is
empty, the browser offers whichever passkey it holds for your site (a
"discoverable" login, and what the browser's autofill suggestion uses):

```bit
import { App } from "web"
import { WebAuthnStrategy } from "auth"
import { jsonEncode } from "std/json"

fn signInRoutes(app: App, passkeys: WebAuthnStrategy) {
  app.post("/signin/options", (c) => {
    let options = passkeys.beginLogin(c, Option<string>.None)?
    return c.text(jsonEncode(options)).header("Content-Type", "application/json")
  })
  app.post("/signin", (c) => {
    let me = passkeys.authenticate(c)?
    return c.text(me.id)
  })
  app.post("/signin/for/:name", (c) => {
    let options = passkeys.beginLogin(c, Option<string>.Some(c.param("name")))?
    return c.text(jsonEncode(options)).header("Content-Type", "application/json")
  })
}
```

A user id nobody has, or one with no passkeys, gets the same five members as a
real one with a single made-up credential id (the same on every request), so the
options never say whether an account exists.

The browser side:

```js
const options = await (await fetch("/signin/options", { method: "POST" })).json()
const assertion = await navigator.credentials.get({
  publicKey: PublicKeyCredential.parseRequestOptionsFromJSON(options),
})
await fetch("/signin", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify(assertion.toJSON()),
})
```

`authenticate` spends the challenge first, on every attempt, then checks in this
order: the credential exists and belongs to the author the options were for;
the `userHandle`, when the authenticator sent one, is that author's (a
discoverable login must send one); the `clientDataJSON` says `webauthn.get`,
carries your challenge and an origin from your list; the `rpIdHash`; the user was
present (and verified, when `userVerification` is `Required`); the backup
eligibility is what it was at registration; and the signature over the
authenticator data and the hash of the client data verifies under the stored key.

Then the signature counter. An authenticator that counts raises it on every
sign-in, so a count that did not rise means two copies of the key are in use.
When either the stored or the reported count is not zero, the reported one must
be greater. Synced passkeys always report 0 and are accepted. A suspected
clone is refused with `CloneAction.Reject` (the default) and let through with
`Allow`; both tell `onEvent` "login.clone". The stored counter never goes down.

Every refusal, whichever check made it, is the same 401 `unauthorized()`, so a
client learns nothing about which part was wrong. `onEvent` hears every
outcome as an `AuthEvent` ("login.success", "login.failure", "login.locked",
"login.clone"). A verified login stores the new counter and backup
state, regenerates the session id and binds the session, and an app that owes a
second factor sets `second` exactly as it does on `PasswordOptions`. The
audit hook and the throttle work the same way they do there:

```bit
import {
  AuthEventHook,
  LoginThrottle,
  PasskeyLoginOptions,
  SecondRequired,
} from "auth"

fn auditedSignIn(
  throttle: LoginThrottle,
  needsCode: SecondRequired,
  log: AuthEventHook,
): PasskeyLoginOptions {
  return PasskeyLoginOptions{
    throttle = Option<LoginThrottle>.Some(throttle),
    onEvent = log,
    second = Option<SecondRequired>.Some(needsCode),
  }
}
```

Attempts are counted under `passkey:` and the credential id the client named,
so guessing at one credential does not lock another.

## Where to go next

See [Two-factor authentication with TOTP](totp.md) for the pending session a
second factor uses, and [Security model](security.md) for what this package
checks for you.
