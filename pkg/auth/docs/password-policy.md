# Check a new password

Inkwell lets anyone sign up as an author. Left alone, `hashPassword` hashes
whatever it is handed, so the first author to type `password` gets exactly that
as their only protection. A `PasswordPolicy` is the check you run when a password
is set: it says which rules the password breaks, and the app decides what to tell
the person.

The rules follow NIST SP 800-63B (revision 4), the standard most security reviews
measure a password login against. Each one has NIST's value as its default and
each one can be changed. The whole policy is opt-in: an app that never builds a
`PasswordPolicy` hashes and verifies passwords exactly as before.

## The simplest thing that works

Build one policy when the app starts, and ask it about every password someone
wants to set. `check` returns every rule the password breaks, so one answer is
enough to tell the person everything to fix.

```bit
import { PasswordPolicy, PolicyContext, Violation } from "auth"

fn refuse(found: []Violation): string {
  if (len(found) == 0) {
    return "ok"
  }
  return "that password will not do"
}

fn signUp(policy: PasswordPolicy, username: string, password: string): string {
  let found = policy.check(password, PolicyContext{ username = username })
  return refuse(found)
}

fn start(): PasswordPolicy! {
  return PasswordPolicy()?
}
```

`PasswordPolicy()` fails when you hand it options that cannot work, so a typo
shows up when the app starts and not when the first author signs up.

## Telling the author what is wrong

A `Violation` is an enum, some of its cases carry the number or word involved, so
you write the message, in the author's language, and the package never hard-codes
English into your sign-up form.

```bit
import { Violation } from "auth"

fn message(v: Violation): string {
  return match (v) {
    TooShort(min) => "Use at least ${min} characters."
    TooLong(max) => "Use at most ${max} characters."
    ContainsContext(word) => "Do not use '${word}' in your password."
    Blocklisted => "That password is on a list of common passwords."
    Repetitive => "Do not repeat the same characters."
    Sequential => "Do not use a run like 12345 or abcde."
    Breached => "That password has appeared in a data breach."
    BreachCheckFailed => "We could not check that password. Try again."
  }
}
```

Length counts code points, not bytes, so a password in Cyrillic or Chinese is not
penalised for how many bytes it takes. A password refused for being too long is
refused, never cut short.

## What the defaults are

`PasswordPolicy()` uses `PolicyOptions{}`:

| Option | Default | What it does |
| ------ | ------- | ------------ |
| `minLength` | 15 | The shortest password. NIST asks for 15 when the password is the only factor, and 8 at the very least, so a value under 8 is refused. |
| `maxLength` | 64 | The longest. NIST says to allow at least 64, so a value under 64 is refused. |
| `normalize` | on | NFKC normalization, applied when the password is set and when it is verified. |
| `context` | on | Refuses a password containing the username, the part of the email before its `@`, or one of your own words. |
| `blocklist` | none | Your own list of refused passwords. |
| `builtinBlocklist` | on | Also refuses the common passwords the package ships with. |
| `maxRun` | 4 | The longest run of one character (`aaaaa`) or of consecutive characters (`12345`, `abcde`), and a password that is one block repeated (`abcabcabc`). 0 turns these rules off. |
| `breach` | off | Asks a `BreachCheck`, see below. |

```bit
import { PasswordPolicy, PolicyOptions } from "auth"

fn relaxed(): PasswordPolicy! {
  return PasswordPolicy(
    PolicyOptions{
      minLength = 8,
      maxLength = 128,
      maxRun = 0,
      builtinBlocklist = false,
      blocklist = ["inkwell2026", "writeaway"],
    },
  )?
}
```

The built-in list is the passwords of eight characters or more among the 10,000
most common in public breach data, from the SecLists project
(`Passwords/Common-Credentials/10k-most-common.txt`). It is a floor. A password
that appears in no list can still have been stolen, which is what the breach check
is for.

## Words the password must not contain

People build passwords from their own name. Give the policy what it should look
for, as a `PolicyContext`.

```bit
import { PasswordPolicy, PolicyContext, Violation } from "auth"

fn mentionsMe(policy: PasswordPolicy): []Violation {
  let me = PolicyContext{
    username = "ada",
    email = "ada.lovelace@inkwell.example",
    words = ["inkwell", "engine"],
  }
  return policy.check("My-INKWELL-notes-are-long", me)
}
```

The comparison ignores case, so the capitals above do not hide `inkwell`. A word
shorter than three characters is ignored, because a one-letter username would
otherwise refuse every password with that letter in it.

## Hashing, and why normalization has to match

An author types `café` on one keyboard as one code point and on another as `e`
plus an accent. They are the same word to the person and different bytes to the
hash, so the author cannot log in from the second keyboard. NFKC makes both
spellings one string before hashing. It only works if the password is normalized
both when it is set and when it is checked.

That is why the policy carries both sides. `hash` is `check` plus the hash: it
refuses a password that breaks a rule and otherwise hashes the normalized
password. `PasswordStrategy` takes the same policy in `PasswordOptions.policy` and
normalizes what the author types before it verifies. One `normalize` switch on one
object drives both.

```bit
import { App, Config, MemoryStore } from "web"
import {
  Lookup,
  PasswordOptions,
  PasswordPolicy,
  PasswordStrategy,
  PolicyContext,
  PolicyViolations,
  Strategy,
  requireAuth,
} from "auth"

fn createAccount(policy: PasswordPolicy, username: string, password: string): string! {
  let stored = policy.hash(password, PolicyContext{ username = username }) catch e {
    let (v, ok) = e.(PolicyViolations)
    if (ok) {
      fail newError("rejected: ${len(v.violations)} problem(s) with the password")
    }
    fail e
  }
  return stored
}

fn build(users: Lookup, policy: PasswordPolicy): App {
  let app = App(Config{ secret = "change-me", sessions = MemoryStore(10_000) })
  let login = PasswordStrategy(
    users,
    PasswordOptions{ policy = Option<PasswordPolicy>.Some(policy) },
  )
  let guarded = app.group("/login")
  guarded.use(requireAuth([]Strategy{ login }))
  guarded.post("/", (c) => c.text("welcome"))
  return app
}
```

`hash` fails with a `PolicyViolations` that carries the same list `check` returns.
`prepare` is the normalization on its own, for the rare caller that hashes
somewhere else:

```bit
import { PasswordPolicy } from "auth"

fn sameWord(policy: PasswordPolicy): bool {
  return policy.prepare("café") == policy.prepare("café")
}
```

Passwords that are plain ASCII come out of NFKC unchanged, so only a password with
a non-ASCII character depends on this. Hash it with bare `hashPassword` while the
strategy has a normalizing policy and that author cannot log in. Set every password
through the policy that verifies it.

## Is this password in a breach

NIST asks a verifier to refuse passwords known from breaches. The package ships no
such list, since one that is current is millions of entries. It asks a
`BreachCheck`: a type with one method, `check(password): bool!`, that answers true
when the password is breached. You write it over whatever you trust, an in-house
list or a service that uses the k-anonymity range API.

When the checker cannot answer, the service being down for instance, someone has
to choose between letting the password through and refusing it. That choice is
yours, and the type makes you make it: the only ways to give the policy a checker
are `BreachMode.FailOpen(checker)` and `BreachMode.FailClosed(checker)`.
Fail-open keeps sign-up working through an outage. Fail-closed keeps a breached
password out through one and reports `Violation.BreachCheckFailed`.

```bit
import { BreachCheck, BreachMode, PasswordPolicy, PolicyOptions } from "auth"

class KnownLeaks {
  leaked: []string

  check(password: string): bool! {
    for l of this.leaked {
      if (l == password) {
        return true
      }
    }
    return false
  }
}

fn strict(): PasswordPolicy! {
  let checker: BreachCheck = KnownLeaks{ leaked = ["Inkwell-2024-Summer"] }
  return PasswordPolicy(PolicyOptions{ breach = BreachMode.FailClosed(checker) })?
}

fn forgiving(checker: BreachCheck): PasswordPolicy! {
  return PasswordPolicy(PolicyOptions{ breach = BreachMode.FailOpen(checker) })?
}
```

The checker runs once per `check`, for every password, so a slow one slows every
sign-up. It is called even when another rule has already refused the password,
so the person sees every problem in one go.

## What the policy does not do, and why

There is no rule that demands a digit, a symbol or mixed case, and no option that
makes passwords expire. NIST SP 800-63B says verifiers should not impose
composition rules and should not force a change on a schedule unless there is
evidence of compromise. Both were common once and both backfire: people answer
"must have a symbol" with `Password1!`, and answer "change it every 90 days" with
`Password2!`. A long password checked against real lists beats either. Force a
change when you learn a password is stolen, not on a timer.

## Sharp edges

- **Turning on normalization after accounts exist.** A non-ASCII password hashed
  without it will not match once the strategy normalizes. Reset those authors'
  passwords or turn `normalize` off.
- **A shorter limit than before.** A policy checks passwords when they are set.
  It never locks out an author whose stored password would fail it today.
- **`Violation` has no text.** Every message is yours, and `check` returns
  the cases, never a sentence.

## Where to go next

[Slow down password guessing](brute-force.md) throttles the login this policy
protects, and [Getting started](getting-started.md) builds it.
