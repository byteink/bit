# Naming policy

**This is a project policy, not a trademark claim.** byteink holds no trademark
registration for Bit, bitlang or byteink, and nothing here asserts one.

It exists because Apache-2.0 (see `LICENSE`) grants copyright and patent rights
and explicitly grants **no** trademark rights (section 6). That leaves an
obvious question unanswered - you can fork the code, but what do you call the
result? - and this file answers it. Rust, Kotlin and Swift publish the same kind
of policy.

## Fine, no need to ask

- Use Bit for anything, commercially or otherwise. That is what the license is
  for, and nothing here narrows it.
- Redistribute **unmodified** official releases as Bit - a package in a distro
  repo, a Docker image, a mirror.
- Say true things about your own work: "written in Bit", "Bit bindings for X",
  "compatible with Bit 1.2". Factual references are not our business.
- Write books, courses, blog posts and talks about Bit.
- Run a user group or conference about Bit, as long as it is clear byteink does
  not run it.

## Give it a different name

- **A fork, or any modified compiler.** Change the compiler, runtime or stdlib
  and ship it, and it is not Bit any more - name it something else. The license
  still gives you every right over the code; this is about the name only.
- **Anything shaped to look official**: "Bit Pro", "Bit Enterprise", "official
  Bit plugin", "certified for Bit", `bitlang.<anything>` domains.

The test is simple: if a reasonable person would think byteink published it, the
name is wrong. Unsure? <hello@byteink.io>.

## Why

A language lives or dies on whether people can trust the thing named `bit` to
behave the way the spec says. Ten incompatible forks all calling themselves Bit
would destroy that, and every user with it.

None of this is here to stop anyone forking. Fork it, rename it, ship it. That
path stays open on purpose.
