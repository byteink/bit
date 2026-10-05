# Let an author sign in with a passkey

A password can be guessed, reused on another site, or typed into a fake login
page. A passkey cannot: the browser makes a key pair for your site, keeps the
private half in the phone, laptop or security key, and only ever answers the
real origin. Inkwell's authors should be able to add one to their account and
stop typing a password. This page is the registration half, the moment the
author says "add a passkey" and your server stores the public key.

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
use everywhere else, at most 64 bytes, never an email address and never
something that changes. It is also what `Credential.userId` holds. An empty
or longer id fails with `user.id is 65 bytes, want 1 to 64`. `name` and
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
registration step. Five methods:

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
}

fn asStore(p: InkwellPasskeys): CredentialStore {
  return p
}
```

`add` must be one atomic step that fails when the id is already stored (a
`UNIQUE` index does it): two requests racing to store one credential must not
both win. `update` and `remove` fail for an id that is not stored.

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

## Where to go next

Registration binds no session: the author was already signed in. A login
with these passkeys is a separate step. See
[Two-factor authentication with TOTP](totp.md) for the pending session a
second factor uses, and [Security model](security.md) for what this package
checks for you.
