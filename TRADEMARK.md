# Trademark and naming policy

Bit's code is licensed under Apache-2.0 (see `LICENSE`). Its **name is not**.

Apache-2.0 grants copyright and patent rights and explicitly grants **no
trademark rights** (section 6). That separation is deliberate here, and it is
the project's actual control mechanism: the code is free to fork, the identity
is not. This is the same arrangement Rust, Kotlin and Swift use.

## The marks

**Bit**, **bitlang**, **byteink**, the `bit` command name, and the project logo
are marks of byteink.

## What you may do without asking

- Use Bit for anything, commercially or otherwise. That is what the license is
  for, and nothing here narrows it.
- Redistribute **unmodified** official releases under the name Bit — a package
  in a distro repo, a Docker image, a mirror.
- Say true things about your own work: "written in Bit", "Bit bindings for X",
  "compatible with Bit 1.2". Factual references are not our business.
- Write books, courses, blog posts and talks about Bit.
- Run a user group or conference about Bit, provided it is clear byteink does
  not run it.

## What needs a different name

- **A fork, or any modified compiler.** If you change the compiler, runtime or
  stdlib and distribute it, it is not Bit — pick your own name. You keep every
  right the license gives you over the code; you do not get the name with it.
- **A product or service whose name suggests it is official**: "Bit Pro",
  "BitCloud", "Bit Enterprise", `bitlang.<anything>` domains, or a logo derived
  from ours.
- **Anything implying endorsement**: "official Bit plugin", "certified for Bit",
  "Bit-approved".

If a reasonable person would think byteink published it, the name needs to
change. If in doubt, ask: <hello@byteink.io>.

## The registry

The Bit package registry is a byteink-operated service, not part of this
repository and not covered by the Apache-2.0 grant. Running your own registry
for your own packages is fine; presenting it as **the** Bit registry is not.

## Why this exists

A language lives or dies on whether people can trust the thing named `bit` to
behave the way the spec says. Ten incompatible forks all calling themselves Bit
would destroy that, and every user with it — Apache-2.0 cannot prevent that on
its own, and this policy is what does.

It is not here to stop anyone forking. Fork it, rename it, ship it. That path
stays open on purpose.
