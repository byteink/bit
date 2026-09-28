# How Bit documentation is written

Owner ruling, 2026-09-14. The documentation on bitlang.org was judged
"nice aesthetics, the storytelling and the richness and coverage sucks",
"it does not guide you", "not easy to find things". This file is the
standard that answers that, and it is a hard rule: **a language feature or
a package is not done until its documentation meets it.**

The target is the NestJS documentation. Not its look. Its shape: a reader
opens it to learn one thing, stays inside it, and rarely needs anything
outside it.

## The one rule everything else serves

**Write for someone building something, not for someone auditing the
language.** They arrived with a task. Every page either advances that task
or tells them which page does.

A reference page answers "what does this construct mean". A guide page
answers "how do I do the thing I came here to do". We were writing only the
first kind and calling it documentation.

## Page shape

Every page, reference or guide, in this order:

1. **Open with the problem, never the definition.** Not "An interface is a
   set of method signatures." Instead: the situation where you reach for
   one, in two or three sentences, with the code that is awkward without it.
2. **The simplest thing that works, complete and runnable.** No ellipsis, no
   "assume a Foo". The reader can paste it and run it.
3. **Then build on it.** The same example grows. Each step adds one idea and
   says what it bought.
4. **Then the real use case.** What this looks like in a program someone
   would actually ship.
5. **Then the sharp edges.** What fails, what the error message says, what
   surprises people.
6. **Then when NOT to use it**, if there is a case.
7. **Then where to go next**, by name and link.

A page that is a list of features in declaration order has failed this,
however accurate it is.

## The running example: Inkwell, everywhere

One universe, fixed, not picked per page: **Inkwell**, a notes tool that
grows into a small blogging API over the course of the Book (`docs/book/`).
Drafts, articles, tags, authors - never `Circle`/`Rect`/`Foo`, never a
different domain invented for one page.

- The Book *builds* Inkwell, chapter by chapter, and is the only place a
  concept is taught with a story.
- A Language or Standard library reference page draws its small examples
  from the same domain (a `Draft`, not a `Shape`) but never re-tells the
  story - see "No duplicates" below.
- A package's docs use Inkwell too where a realistic example helps, since
  the Book itself is built on the first-party packages.

The reader should be able to read the Book top to bottom and end with a
program they built. A reference page's example is smaller - enough to show
the one construct on its own - but it still speaks Inkwell's vocabulary, so
nothing on the site ever asks the reader to hold two unrelated example
programs in their head at once.

## No duplicates: who owns what

- A concept is **taught** once, in the Book, at the moment the app needs it.
- A concept is **defined** once, on its Language or Standard library page.
- The Book links to the definition instead of repeating it ("the full rules
  are on [Errors](/language/errors)"). A reference page never tells a story
  and never re-teaches; it may link back to the Book chapter that uses it.
- A package's docs explain the package. They do not re-explain the language
  or the standard library, and they do not have their own "install Bit"
  page - they link to Get started.
- Install instructions exist ONLY on Get started
  (`docs/get-started.md`).

## Banned words

Never in public text, with no exception: **monomorphize, lowering, boxing,
IR, stage0, oracle, differential, spec section numbers (`§10.5`), ticket
numbers (`#6161`), rollout flags (internal `BIT_*` feature switches),
internal file paths of the compiler, commit hashes, private repo or host
names**. A user-facing environment variable such as `BIT_GC_STATS` is fine
where the reader actually sets it.

A term from this list that is genuinely load-bearing for the reader (say,
what a generic call specializes to) gets a one-line plain-English definition
at first use instead of the jargon word - "the compiler generates one copy
of the function per type you use it with" rather than "monomorphizes".

## Voice

- Plain words. Short sentences. Write the way you would explain it out loud
  to a colleague who is tired.
- Second person. "You get a compile error", not "a compile error is
  produced".
- Say why before what. A rule with no reason is memorised, not understood.
- **No implementation vocabulary in a learner page.** "Assigning a
  satisfying type into an interface-typed location boxes it into an
  interface value carrying its dynamic type and method table" is an ABI
  sentence in a beginner's page. Say what the reader observes; put the
  mechanism in a note at the bottom if it matters.
- **No spec citations anywhere, not even a section number at the foot of the
  page.** A parenthetical list of section numbers in the third sentence
  tells a reader this page was written for the compiler team, and a bare
  `§10.5` means nothing to them either way.
- No filler openings. Not "In this section we will explore". Start.
- No em dashes anywhere. `test-no-emdash` scans `docs/**/*.md`, every
  package README and every `pkg/<name>/docs/` tree, and it is right to.

## Coverage

- Every exported symbol in a package appears in that package's docs, used in
  at least one example, not merely listed in a signature table.
- Every package has a guide page shaped by task, not by module. "Serve JSON
  over HTTP", not "the `web` module".
- Every error a user can hit is searchable by its message text. If the
  compiler prints `E0217`, that string appears on a page that explains it.
- A question a user asks twice becomes a page.

## Code blocks

Every block compiles. `<!-- doctest: per-block -->` at the top of the file
puts each block through the test suite, and `_tests_/bit/docs.bit`
typechecks them. A documentation example that rots is worse than none,
because the reader trusts it.

Under `pkg/<name>/docs/`, `pkg/<name>/guides/` and `pkg/<name>/README.md`,
`_tests_/bit/pkgdocsgate.bit` (`./make test-package-docs`) typechecks every
block the same way, against a scratch project whose only dependency is
`pkg/<name>` itself. A page that needs another first-party package declares
it with `<!-- doctest: deps a b c -->` (space-separated package names, one
line) - naming an unknown package is a gate failure with a clear message.

A page under `docs/` or `spec/` needing a first-party package (not just
`std/*`) declares it the same way. `_tests_/bit/docs.bit` (`./make
test-docs`) resolves each name against `pkg/<name>` and gives the page's
scratch project that dependency, nothing else borrowed.

Blocks are complete unless the omission is the point. When a body is
genuinely beside the point, `// ...` marks it, and nothing else does.

## Finding things

Guides are titled by the task, so the title is what someone would search
for. "Read a file line by line" beats "Streaming I/O".

Cross-link generously in both directions. The last line of a page names the
next one. A page reached from three different tasks is linked from all
three.

## The rule for new work

A ticket that adds a language feature or a package API is not complete
until:

1. The feature appears in a guide page under this standard, not only in the
   reference table.
2. Every new exported symbol is used in a running example.
3. The running example for that section still compiles.

This is enforced by review, not yet by a gate. When a gate for it exists,
this paragraph names it.
