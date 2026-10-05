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
| `normalize` | on | NFKC normalization, applied when the password is set and recorded in the stored hash so verify repeats it. |
| `context` | on | Refuses a password containing the username, the part of the email before its `@`, or one of your own words. |
| `blocklist` | none | Your own list of refused passwords, compared exactly and without regard to case. |
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
      blocklist = ["inkwell2026", "writeaway"],
    },
  )?
}
```

The package ships no list of passwords. NIST asks for one, and the next two
sections show the two ways to give the policy one.

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

So the stored hash says which one was done. `hash` is `check` plus the hash: it
refuses a password that breaks a rule and otherwise hashes the normalized
password, and when `normalize` is on it writes `n=nfkc` after the Argon2
parameters:

```text
$argon2id$v=19$m=19456,t=2,p=1,n=nfkc$<salt>$<tag>
```

`PasswordStrategy` reads that parameter and normalizes what the author typed
exactly when it is there. It does not ask the policy, so nothing can drift: the
check is always made the way the password was set. The strategy takes no policy.

```bit
import { App, Config, MemoryStore } from "web"
import {
  Lookup,
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

fn build(users: Lookup): App {
  let app = App(Config{ secret = "change-me", sessions = MemoryStore(10_000) })
  let guarded = app.group("/login")
  guarded.use(requireAuth([]Strategy{ PasswordStrategy(users) }))
  guarded.post("/", (c) => c.text("welcome"))
  return app
}
```

`hash` fails with a `PolicyViolations` that carries the same list `check` returns.

What follows from the hash being the source of truth:

- A hash made by bare `hashPassword` has no `n=` and verifies exactly as typed,
  whatever the policy says now. That includes every hash stored before the
  parameter existed.
- Turning `normalize` on or off later changes only the passwords set from then on.
  Nobody who enrolled earlier is locked out.
- A hash with an `n=` value the package does not know never verifies.

Passwords that are plain ASCII come out of NFKC unchanged, so only a password with
a non-ASCII character depends on any of this. The extra parameter is the package's
own: another Argon2 library will not accept a string that carries it, so remove
`,n=nfkc` before handing the hash to one, and normalize the password yourself.

## Refuse passwords known from breaches

NIST SP 800-63B (section 3.1.1.2) says a verifier SHALL compare a new password
against a list of values known to be commonly used, expected or compromised:
passwords from earlier breaches, dictionary words, and words specific to the
service. A password that appears in no such list can still be one an attacker
tries first, which is why this is the one rule the length and run rules do not
replace.

The package carries no such list: a current one is millions of entries, and a
short one in the source gives a false sense of cover. You meet the requirement in
one of two ways, and an app can use both.

- **Ask Have I Been Pwned** with the opt-in check below. It holds billions of
  leaked passwords and is the closest to what NIST describes. It needs the
  network, and only the first 5 hex digits of the password's SHA-1 leave your
  server.
- **Give the policy your own list** in `blocklist`. Nothing leaves the server and
  it works offline, but the list is only as good as what you put in it: a
  downloaded breach list, your product's name, the words your authors would try.

Your own list is one option away. Read a downloaded list of leaked passwords
once when the app starts and hand its lines over:

```bit
import { PasswordPolicy, PolicyOptions } from "auth"

fn withOwnList(leaked: []string): PasswordPolicy! {
  return PasswordPolicy(PolicyOptions{ blocklist = leaked })?
}
```

The list is held in memory as a set, built when the policy is, so a check is one
lookup however long the list is. The two sections after this one cover the
Have I Been Pwned way: the `BreachCheck` type it fits, then the check itself.

## The breach check and its failure mode

A `BreachCheck` is a type with one method, `check(password): bool!`, that answers
true when the password is breached. You write it over whatever you trust, an
in-house list or a service, or you use the one the package ships, [the Have I Been
Pwned range check](#check-against-have-i-been-pwned).

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

## Check against Have I Been Pwned

Inkwell does not want to keep its own list of leaked passwords, so it asks
Have I Been Pwned, which holds billions of them. `PwnedPasswords` is a
`BreachCheck` over its Pwned Passwords range API. It never sends the password or
its hash. It hashes the password with SHA-1, sends the first 5 hex digits of that
hash, gets back every known hash that starts the same way, and looks for the other
35 digits in the answer on your own machine. See [the security
model](security.md#what-leaves-your-server-when-you-check-for-breaches) for exactly
what that exposes.

```bit
import { BreachMode, PasswordPolicy, PolicyOptions, PwnedOptions, PwnedPasswords } from "auth"

fn inkwellPolicy(): PasswordPolicy! {
  let pwned = PwnedPasswords(PwnedOptions{ userAgent = "inkwell/1.0 (ops@inkwell.example)" })?
  return PasswordPolicy(PolicyOptions{ breach = BreachMode.FailOpen(pwned) })?
}
```

`userAgent` is the one option with no default. The service requires one and asks
that it name your app and a way to reach you; `PwnedPasswords` fails when it is
empty, so the mistake shows when Inkwell starts and not on the first sign-up.
The others:

| Option | Default | What it does |
| --- | --- | --- |
| `endpoint` | `https://api.pwnedpasswords.com/range/` | Where the 5 digits are sent. See "Host the data yourself". |
| `timeout` | `5 * Second` | The whole request, in nanoseconds, at least 1 millisecond. |
| `padding` | on | Sends `Add-Padding: true`, so every answer is the same size whatever the prefix. The padding lines have a count of 0 and are never a hit. |
| `threshold` | 1 | The fewest appearances in breaches that count as breached. |
| `userAgent` | none | Required. |
| `fetch` | the network | A `RangeFetch`, for tests. |

A password is breached when its line in the answer has a count of at least
`threshold`. Raise it to let through a password seen a handful of times and still
refuse the famous ones; the default refuses any password that appears at all.

`check` fails, and does not say "not breached", when the request times out, the
service answers with anything but 200, or the body has a line that is not 35 hex
digits, a colon and a count. That is the failure `BreachMode` decides: with
`FailOpen` Inkwell lets the password through while Have I Been Pwned is down, with
`FailClosed` it refuses with `Violation.BreachCheckFailed`. Nothing in an error
message or a log line holds the password, its hash or the 35 digits.

### Host the data yourself

Some apps cannot send even 5 digits to a third party. Have I Been Pwned publishes
the whole dataset for download (the Pwned Passwords downloader fetches it as one
file per 5-digit prefix). Serve those files at `{endpoint}{PREFIX}` from a server
you run, each answering with the lines of that prefix, and point `endpoint` at it:

```bit
import { BreachMode, PasswordPolicy, PolicyOptions, PwnedOptions, PwnedPasswords } from "auth"
import { Second } from "std/time"

fn inkwellOnPremises(): PasswordPolicy! {
  let pwned = PwnedPasswords(
    PwnedOptions{
      userAgent = "inkwell/1.0",
      endpoint = "https://pwned.inkwell.internal/range/",
      timeout = 2 * Second,
      padding = false,
    },
  )?
  return PasswordPolicy(PolicyOptions{ breach = BreachMode.FailClosed(pwned) })?
}
```

A missing trailing `/` on `endpoint` is added. Turn `padding` off when your server
does not pad. A `http://` endpoint is accepted for a server on a network you
trust; over an untrusted network use `https://`, because whoever can change the
answer can make every password look clean.

### Test the sign-up without the network

`fetch` takes a `RangeFetch`, a function from `(url, headers, timeoutMs)` to the
response body of a 200, and replaces the network. A test serves a range from
memory, and can read the URL to prove that only the prefix is sent:

```bit
import { PwnedOptions, PwnedPasswords, RangeFetch } from "auth"

fn leakedPassword(): bool {
  // The SHA-1 of "password" is 5BAA61E4C9B93F3F0682250B6CF8331B7EE68FD8.
  let range: RangeFetch = (url, headers, timeoutMs) => {
    return "1E4C9B93F3F0682250B6CF8331B7EE68FD8:9545824\r\n"
  }
  let pwned = PwnedPasswords(PwnedOptions{ userAgent = "inkwell-tests", fetch = range }) catch _ {
    return false
  }
  return pwned.check("password") catch _ {
    return false
  }
}
```

A fake that returns an error stands in for a timeout or a 503.

## What the policy does not do, and why

There is no rule that demands a digit, a symbol or mixed case, and no option that
makes passwords expire. NIST SP 800-63B says verifiers should not impose
composition rules and should not force a change on a schedule unless there is
evidence of compromise. Both were common once and both backfire: people answer
"must have a symbol" with `Password1!`, and answer "change it every 90 days" with
`Password2!`. A long password checked against real lists beats either. Force a
change when you learn a password is stolen, not on a timer.

## Sharp edges

- **Turning on normalization after accounts exist.** Existing hashes keep the
  behavior they were made with, so they still verify, but they stay un-normalized
  until the author sets a new password through `hash`.
- **A shorter limit than before.** A policy checks passwords when they are set.
  It never locks out an author whose stored password would fail it today.
- **`Violation` has no text.** Every message is yours, and `check` returns
  the cases, never a sentence.

## Where to go next

[Slow down password guessing](brute-force.md) throttles the login this policy
protects, and [Getting started](getting-started.md) builds it.
