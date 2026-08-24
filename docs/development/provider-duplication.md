# Provider duplication inventory: linux/darwin

Input for #2551-#2554 (pull shared non-OS logic out of `runtime/{root,net,thread,park}/{linux,darwin}/`
into each module's core `.bit` file). #1710 is the epic. `docs/development.md:781`
("Runtime core and OS providers") states the rule this inventory feeds — read
that first; this file does not repeat it, it only lists what to move.

**Do not perform any of the moves from this file** — #2551-#2554 do the moves.
This file is the audit only.

## Scope

Only the `linux`/`darwin` provider pair, per #1710's mandate. `runtime/{root,thread,park}/windows/`
also exist now (#3322 epic) but are out of scope here — a third provider is a
third body to diff, and #3322's own tickets own that audit.

## Method

For each module, every file that exists as both `runtime/<mod>/linux/<f>.bit` and
`runtime/<mod>/darwin/<f>.bit` was function-extracted (a `fn` declaration,
brace-matched to its closing `}`) and compared name-for-name. A same-named
function is listed as a **pull-up candidate** below only if, after stripping
comments and blank lines, its body — signature excluded — is byte-identical on
both sides. Excluding the signature matters: an `@nosplit`-only difference
(`nsPerSec` in `park/wait.bit`) is not a real divergence and was a false
negative in an earlier pass, corrected before this file was written.

A textual search for `sys[A-Z]\w*(` / `extern fn` in a body is necessary but
not sufficient to rule a function OUT as non-OS: `rtFsAppend` and `rtFsListDir`
(root/fs.bit) both contain the text `sysOpen(`/`sysList(`, which look like
syscalls but are themselves same-named PROVIDER-LOCAL functions with different
bodies per OS — the wrapper touches the OS through exactly one indirect call
and both are still pull-up candidates. Conversely, several same-named,
same-line-count functions that differ only in an inline OS-primitive call
(`segvHandler`, `trapHandler` — Darwin's extra `mcontext_t` indirection;
`netFillSockAddr` — the `sockaddr_in` layout genuinely differs; `netAwaitReady` —
epoll needs two descriptors, kqueue needs one, and the code says so) were
checked by hand and are correctly NOT listed — see "Divergences investigated"
below.

## Risk this inventory does not resolve — measure it, do not reason about it

`scripts/provider-move-check.sh <root|net|thread|park>` (#2549, landed) is the
proof each of #2551-#2554 owes: `--emit-obj` before/after per (directory,
target), plus a line-multiset check across the whole module. It still cannot
see two things a green build also misses (`docs/development.md:781`): emitted
**diagnostic order** is normative (SPEC §14.8, checked by `selfhost-diffdiags`),
and filename order drives `optimizeModule`'s inlining depth (checked by
relocation counts, never by wall clock).

**The concrete, module-specific risk is the 800-line file cap, and it is closer
than it looks.** Current core-file sizes (`wc -l`) against each module's
candidate total below:

- `runtime/root/root.bit` is **617** lines. `boot.bit`, `io.bit`, `signal.bit`
  and `time.bit` have NO core-level sibling today — a pull-up from those four
  provider pairs has nowhere to land but `root.bit` itself, or a new core file
  of the same name. `io.bit` alone contributes 21 candidates / ~201 lines:
  617 + 201 = 818, **over the cap** if appended to `root.bit` directly. `fs.bit`
  and `os.bit` already have a core sibling (146 and 365 lines) with plenty of
  headroom for their own candidates (~103 and ~138 lines).
- `runtime/net/net.bit` is **480** lines. All four net provider files
  (netabi/sock/tcp/udp) currently land ONLY in `net.bit` — no per-file core
  split exists. Their candidates total ~425 lines: 480 + 425 = 905, **well over
  the cap**. #2552 cannot dump every candidate into `net.bit`; it needs at
  least one new core file (e.g. `runtime/net/netabi.bit`, mirroring the
  provider split) before it starts moving code, not after.
- `runtime/thread/thread.bit` (237 lines) and `runtime/park/park.bit` (156
  lines) each absorb a single one-line constant. No sizing risk either way —
  see why below.

## Divergences investigated, found correct, not filed

Every same-name pair with a differing body and no obvious syscall call was read
by hand before being excluded from the candidate list. None of these are bugs:

- `segvHandler` / `trapHandler` (root/signal.bit): Darwin's `ucontext_t` holds
  an extra `mcontext_t` indirection Linux's does not; both read the platform's
  real struct layout correctly.
- `netFillSockAddr` (net/sock.bit): Linux's `sockaddr_in` is a 16-bit
  little-endian family field at offset 0; BSD/Darwin's is an 8-bit length
  followed by an 8-bit family. The Linux file's own comment calls this out as
  "the one line...a reader copying from the Darwin twin would get wrong."
- `netAwaitReady` (net/sock.bit): Linux's epoll needs separate fd descriptors
  for read vs. write interest (`EPOLL_CTL_MOD` replaces both the mask and the
  parked task, so co-resident readers/writers evict each other otherwise, #1910);
  kqueue keys on `(fd, filter)` and needs none of this. Documented in the code.
- `rtTimeMonoNs` / `rtTimeSleepNs` / `netClockNowNs`: call `parkMonoNs` with a
  scratch-slot argument on Linux (`clock_gettime` needs an output buffer) and
  with none on Darwin (`mach_absolute_time` needs none) — consistent with
  `parkMonoNs` itself genuinely differing per OS in `park/wait.bit`.
- `lastErr` (net/sock.bit): Linux reads a scratch word the syscall wrapper set;
  Darwin calls libSystem's `__error()` for a pointer to thread-local errno.
  Different mechanism, same contract, both correct.
- `rtHostTarget` (root/os.bit): returns a target-enum constant via inline
  per-architecture `asm{}` on Linux, a plain literal on Darwin — genuinely
  arch/OS-identifying code, not shared logic.

## Divergence found and filed separately (not folded into a pull-up ticket)

**#3460**: `osForkExecWait` and `osForkExecWaitBounded`
(`runtime/root/{linux,darwin}/os.bit`) share intent — fork, exec, block/poll on
the child's exit — but Linux's blocking `wait4`/polling loop explicitly retries
on errno 4 (EINTR), citing `#1904` in a comment; Darwin's `waitpid` equivalent
has no such retry and treats any negative return as a hard failure. Filed as
its own ticket per this file's own instruction not to bury a real behavior gap
inside a pure-move ticket — fixing it changes Darwin's observable behavior, so
it is not a candidate for #2551.

## Totals

47 root candidates, 60 net candidates, 1 thread candidate, 1 park candidate —
**109 pull-up candidates total**, spanning 12 provider file pairs across the
four modules.

## root

Providers: linux 4402 lines / 8 files, darwin 3834 lines / 7 files (`wc -l`).
**47 candidates** across 6 file pairs (boot, fs, io, os, signal, time). `linux/boottail.bit` and `darwin/bootworker.bit` have no cross-provider counterpart and were not diffed; `linux/fsrw.bit` likewise. See the `root.bit` 800-line risk above before landing `io.bit`'s candidates.

#### `boot.bit` (3 candidates)

### alignDownStack
linux `runtime/root/linux/boot.bit:333-335` (3 lines) / darwin `runtime/root/darwin/boot.bit:237-239` (3 lines) — rounds an address down to the fixed stack granule; pointer arithmetic only, no OS call.

### alignUpStack
linux `runtime/root/linux/boot.bit:319-322` (4 lines) / darwin `runtime/root/darwin/boot.bit:223-226` (4 lines) — rounds an address up to the fixed stack granule; pointer arithmetic only, no OS call.

### mapGuardedStack
linux `runtime/root/linux/boot.bit:410-459` (50 lines) / darwin `runtime/root/darwin/boot.bit:316-365` (50 lines) — guard-page placement arithmetic around a stack region; touches the OS through exactly `mapPages`/`protectPages`/`unmapPages`, all three already per-OS-abstracted in `alloc/{linux,darwin}` — the guard math itself never needs to know which OS it is on.

#### `fs.bit` (11 candidates)

### checkedPathZ
linux `runtime/root/linux/fs.bit:220-231` (12 lines) / darwin `runtime/root/darwin/fs.bit:216-227` (12 lines) — validates and NUL-terminates a path into scratch, rejecting embedded NULs / overlength; no OS call.

### checkedPathZ2
linux `runtime/root/linux/fs.bit:239-250` (12 lines) / darwin `runtime/root/darwin/fs.bit:235-246` (12 lines) — validates and NUL-terminates a path into scratch, rejecting embedded NULs / overlength; no OS call.

### cstrLen
linux `runtime/root/linux/fs.bit:337-346` (10 lines) / darwin `runtime/root/darwin/fs.bit:271-280` (10 lines) — string/byte-slice accessor over the managed string representation; no OS call.

### emptyStr
linux `runtime/root/linux/fs.bit:206-206` (1 line) / darwin `runtime/root/darwin/fs.bit:202-202` (1 line) — returns the empty-string sentinel; a constant, no OS call.

### fsScratchSlot
linux `runtime/root/linux/fs.bit:116-126` (11 lines) / darwin `runtime/root/darwin/fs.bit:128-138` (11 lines) — computes a per-worker scratch-buffer offset; arithmetic over `schedCurrentWorker`/`wkId`, no OS call.

### isDotName
linux `runtime/root/linux/fs.bit:355-363` (9 lines) / darwin `runtime/root/darwin/fs.bit:283-291` (9 lines) — checks a directory entry name against "." / ".."; string comparison, no OS call.

### rtFsAppend
linux `runtime/root/linux/fs.bit:473-479` (7 lines) / darwin `runtime/root/darwin/fs.bit:375-381` (7 lines) — opens a path for append; the body is `checkedPathZ` + a single call to `sysOpen`, a same-named provider-local primitive (different bodies in each `fs.bit`) — the wrapper touches the OS through exactly one indirect call.

### rtFsListDir
linux `runtime/root/linux/fs.bit:745-766` (22 lines) / darwin `runtime/root/darwin/fs.bit:618-639` (22 lines) — lists a directory by two-pass `sysList` (size probe, then fill); same one-indirect-call shape as `rtFsAppend` — `sysList` differs per provider, this orchestration does not.

### strData
linux `runtime/root/linux/fs.bit:204-204` (1 line) / darwin `runtime/root/darwin/fs.bit:200-200` (1 line) — string/byte-slice accessor over the managed string representation; no OS call.

### strLenOf
linux `runtime/root/linux/fs.bit:205-205` (1 line) / darwin `runtime/root/darwin/fs.bit:201-201` (1 line) — string/byte-slice accessor over the managed string representation; no OS call.

### wordsPathZ
linux `runtime/root/linux/fs.bit:538-554` (17 lines) / darwin `runtime/root/darwin/fs.bit:454-470` (17 lines) — same path-validation shape as `checkedPathZ` but takes a `[]i64` word buffer; no OS call.

#### `io.bit` (21 candidates)

### ifaceAssertWrite
linux `runtime/root/linux/io.bit:650-703` (54 lines) / darwin `runtime/root/darwin/io.bit:598-651` (54 lines) — assembles the interface-assertion-failure panic message (type names, fixed strings); no OS call.

### ioConstScratchSlot
linux `runtime/root/linux/io.bit:281-291` (11 lines) / darwin `runtime/root/darwin/io.bit:229-239` (11 lines) — computes a per-worker scratch-buffer offset; arithmetic over `schedCurrentWorker`/`wkId`, no OS call.

### ioLineAppendClamped
linux `runtime/root/linux/io.bit:396-403` (8 lines) / darwin `runtime/root/darwin/io.bit:344-351` (8 lines) — line-buffer bookkeeping (append/copy/slot-address); no OS call.

### ioLineAppendWord
linux `runtime/root/linux/io.bit:372-378` (7 lines) / darwin `runtime/root/darwin/io.bit:320-326` (7 lines) — line-buffer bookkeeping (append/copy/slot-address); no OS call.

### ioLineCopyBytes
linux `runtime/root/linux/io.bit:386-392` (7 lines) / darwin `runtime/root/darwin/io.bit:334-340` (7 lines) — line-buffer bookkeeping (append/copy/slot-address); no OS call.

### ioLineSlotAddr
linux `runtime/root/linux/io.bit:362-364` (3 lines) / darwin `runtime/root/darwin/io.bit:310-312` (3 lines) — line-buffer bookkeeping (append/copy/slot-address); no OS call.

### panicWrite
linux `runtime/root/linux/io.bit:491-505` (15 lines) / darwin `runtime/root/darwin/io.bit:439-453` (15 lines) — assembles a prefix+message+newline panic line into the line buffer and forwards it to the already-abstracted `rootWriteAll`; no direct OS call.

### rootAssert
linux `runtime/root/linux/io.bit:540-545` (6 lines) / darwin `runtime/root/darwin/io.bit:488-493` (6 lines) — panic/diagnostic message assembly and exit; formats text and calls the already-abstracted `rootWriteAll`/`rootExit`, no direct OS call itself.

### rootEprint
linux `runtime/root/linux/io.bit:554-556` (3 lines) / darwin `runtime/root/darwin/io.bit:502-504` (3 lines) — panic/diagnostic message assembly and exit; formats text and calls the already-abstracted `rootWriteAll`/`rootExit`, no direct OS call itself.

### rootGcMarkStackOverflow
linux `runtime/root/linux/io.bit:595-599` (5 lines) / darwin `runtime/root/darwin/io.bit:543-547` (5 lines) — panic/diagnostic message assembly and exit; formats text and calls the already-abstracted `rootWriteAll`/`rootExit`, no direct OS call itself.

### rootIfaceAssert
linux `runtime/root/linux/io.bit:712-718` (7 lines) / darwin `runtime/root/darwin/io.bit:660-666` (7 lines) — panic/diagnostic message assembly and exit; formats text and calls the already-abstracted `rootWriteAll`/`rootExit`, no direct OS call itself.

### rootOom
linux `runtime/root/linux/io.bit:576-580` (5 lines) / darwin `runtime/root/darwin/io.bit:524-528` (5 lines) — panic/diagnostic message assembly and exit; formats text and calls the already-abstracted `rootWriteAll`/`rootExit`, no direct OS call itself.

### rootPanic
linux `runtime/root/linux/io.bit:532-535` (4 lines) / darwin `runtime/root/darwin/io.bit:480-483` (4 lines) — panic/diagnostic message assembly and exit; formats text and calls the already-abstracted `rootWriteAll`/`rootExit`, no direct OS call itself.

### rootPanicDivZero
linux `runtime/root/linux/io.bit:607-610` (4 lines) / darwin `runtime/root/darwin/io.bit:555-558` (4 lines) — panic/diagnostic message assembly and exit; formats text and calls the already-abstracted `rootWriteAll`/`rootExit`, no direct OS call itself.

### rootPanicNilCall
linux `runtime/root/linux/io.bit:614-617` (4 lines) / darwin `runtime/root/darwin/io.bit:562-565` (4 lines) — panic/diagnostic message assembly and exit; formats text and calls the already-abstracted `rootWriteAll`/`rootExit`, no direct OS call itself.

### rootPanicNilIface
linux `runtime/root/linux/io.bit:622-625` (4 lines) / darwin `runtime/root/darwin/io.bit:570-573` (4 lines) — panic/diagnostic message assembly and exit; formats text and calls the already-abstracted `rootWriteAll`/`rootExit`, no direct OS call itself.

### rootPrint
linux `runtime/root/linux/io.bit:549-551` (3 lines) / darwin `runtime/root/darwin/io.bit:497-499` (3 lines) — panic/diagnostic message assembly and exit; formats text and calls the already-abstracted `rootWriteAll`/`rootExit`, no direct OS call itself.

### strBytesOf
linux `runtime/root/linux/io.bit:457-463` (7 lines) / darwin `runtime/root/darwin/io.bit:405-411` (7 lines) — string/byte-slice accessor over the managed string representation; no OS call.

### strSizeOf
linux `runtime/root/linux/io.bit:465-471` (7 lines) / darwin `runtime/root/darwin/io.bit:413-419` (7 lines) — string/byte-slice accessor over the managed string representation; no OS call.

### writeConst
linux `runtime/root/linux/io.bit:317-321` (5 lines) / darwin `runtime/root/darwin/io.bit:265-269` (5 lines) — writes a fixed byte sequence into the line buffer; buffer bookkeeping, no OS call.

### writeConstLine
linux `runtime/root/linux/io.bit:413-444` (32 lines) / darwin `runtime/root/darwin/io.bit:361-392` (32 lines) — writes a fixed byte sequence into the line buffer; buffer bookkeeping, no OS call.

#### `os.bit` (7 candidates)

### osFillTestIndex
linux `runtime/root/linux/os.bit:227-247` (21 lines) / darwin `runtime/root/darwin/os.bit:217-237` (21 lines) — formats a decimal test-worker index into the child-env buffer; no OS call.

### osScratchSlot
linux `runtime/root/linux/os.bit:149-159` (11 lines) / darwin `runtime/root/darwin/os.bit:69-79` (11 lines) — computes a per-worker scratch-buffer offset; arithmetic over `schedCurrentWorker`/`wkId`, no OS call.

### osWriteDecimal
linux `runtime/root/linux/os.bit:194-223` (30 lines) / darwin `runtime/root/darwin/os.bit:184-213` (30 lines) — formats an integer to decimal ASCII into scratch; no OS call.

### rtOsRun
linux `runtime/root/linux/os.bit:340-350` (11 lines) / darwin `runtime/root/darwin/os.bit:308-318` (11 lines) — argv/envp marshalling ahead of the already-abstracted fork/exec/wait primitive; orchestration only.

### rtOsRunBounded
linux `runtime/root/linux/os.bit:594-603` (10 lines) / darwin `runtime/root/darwin/os.bit:558-567` (10 lines) — argv/envp marshalling ahead of the already-abstracted fork/exec/wait primitive; orchestration only.

### rtOsRunTest
linux `runtime/root/linux/os.bit:357-385` (29 lines) / darwin `runtime/root/darwin/os.bit:324-351` (28 lines) — same argv/envp marshalling as `rtOsRun`, specialised for the per-worker test-index env var; orchestration only.

### rtOsRunTestBounded
linux `runtime/root/linux/os.bit:607-632` (26 lines) / darwin `runtime/root/darwin/os.bit:571-596` (26 lines) — same argv/envp marshalling as `rtOsRun`, specialised for the per-worker test-index env var; orchestration only.

#### `signal.bit` (4 candidates)

### classifyOverflowTrap
linux `runtime/root/linux/signal.bit:330-342` (13 lines) / darwin `runtime/root/darwin/signal.bit:395-407` (13 lines) — stack-overflow classification and message emission; operates on an already-normalized stack pointer, no OS call.

### emitFatalSignal
linux `runtime/root/linux/signal.bit:386-405` (20 lines) / darwin `runtime/root/darwin/signal.bit:454-473` (20 lines) — stack-overflow classification and message emission; operates on an already-normalized stack pointer, no OS call.

### emitMainStackOverflow
linux `runtime/root/linux/signal.bit:364-369` (6 lines) / darwin `runtime/root/darwin/signal.bit:432-437` (6 lines) — stack-overflow classification and message emission; operates on an already-normalized stack pointer, no OS call.

### emitSpawnedStackOverflow
linux `runtime/root/linux/signal.bit:372-379` (8 lines) / darwin `runtime/root/darwin/signal.bit:440-447` (8 lines) — stack-overflow classification and message emission; operates on an already-normalized stack pointer, no OS call.

#### `time.bit` (1 candidate)

### timeScratch
linux `runtime/root/linux/time.bit:79-85` (7 lines) / darwin `runtime/root/darwin/time.bit:68-74` (7 lines) — computes the per-worker scratch offset for the monotonic-clock timespec buffer; arithmetic only.

## net

Providers: linux 1951 lines / 4 files, darwin 1957 lines / 5 files (`wc -l`). Darwin's extra file, `darwin/dns.bit` (119 lines), has no Linux counterpart — Darwin resolves DNS through a different path with no shared name to diff, so it is not in this inventory.
**60 candidates** across 4 file pairs. See the `net.bit` 800-line risk above before landing any of them — a new core file per provider basename is the likely shape.

#### `netabi.bit` (29 candidates)

### copySockAddrWords
linux `runtime/net/linux/netabi.bit:445-450` (6 lines) / darwin `runtime/net/darwin/netabi.bit:434-439` (6 lines) — copies a sockaddr's raw words between buffers; no OS call.

### emptyStr
linux `runtime/net/linux/netabi.bit:140-142` (3 lines) / darwin `runtime/net/darwin/netabi.bit:129-131` (3 lines) — returns the empty-string sentinel; a constant, no OS call.

### formatQuad
linux `runtime/net/linux/netabi.bit:179-186` (8 lines) / darwin `runtime/net/darwin/netabi.bit:168-175` (8 lines) — formats a 4-byte IPv4 address as dotted decimal; no OS call.

### netAbiAccept
linux `runtime/net/linux/netabi.bit:208-210` (3 lines) / darwin `runtime/net/darwin/netabi.bit:197-199` (3 lines) — thin `bit_rt_*`-exported wrapper that forwards straight to a same-named provider primitive (`netSys*`/`netRead*`/`netWrite*`); the wrapper itself is pure forwarding, no OS call.

### netAbiDial
linux `runtime/net/linux/netabi.bit:214-219` (6 lines) / darwin `runtime/net/darwin/netabi.bit:203-208` (6 lines) — thin `bit_rt_*`-exported wrapper that forwards straight to a same-named provider primitive (`netSys*`/`netRead*`/`netWrite*`); the wrapper itself is pure forwarding, no OS call.

### netAbiDialDeadlineW
linux `runtime/net/linux/netabi.bit:277-295` (19 lines) / darwin `runtime/net/darwin/netabi.bit:265-283` (19 lines) — thin `bit_rt_*`-exported wrapper that forwards straight to a same-named provider primitive (`netSys*`/`netRead*`/`netWrite*`); the wrapper itself is pure forwarding, no OS call.

### netAbiListen
linux `runtime/net/linux/netabi.bit:194-199` (6 lines) / darwin `runtime/net/darwin/netabi.bit:183-188` (6 lines) — thin `bit_rt_*`-exported wrapper that forwards straight to a same-named provider primitive (`netSys*`/`netRead*`/`netWrite*`); the wrapper itself is pure forwarding, no OS call.

### netAbiLocalPort
linux `runtime/net/linux/netabi.bit:202-204` (3 lines) / darwin `runtime/net/darwin/netabi.bit:191-193` (3 lines) — thin `bit_rt_*`-exported wrapper that forwards straight to a same-named provider primitive (`netSys*`/`netRead*`/`netWrite*`); the wrapper itself is pure forwarding, no OS call.

### netAbiRead
linux `runtime/net/linux/netabi.bit:224-237` (14 lines) / darwin `runtime/net/darwin/netabi.bit:213-226` (14 lines) — thin `bit_rt_*`-exported wrapper that forwards straight to a same-named provider primitive (`netSys*`/`netRead*`/`netWrite*`); the wrapper itself is pure forwarding, no OS call.

### netAbiReadDeadlineW
linux `runtime/net/linux/netabi.bit:303-319` (17 lines) / darwin `runtime/net/darwin/netabi.bit:291-307` (17 lines) — thin `bit_rt_*`-exported wrapper that forwards straight to a same-named provider primitive (`netSys*`/`netRead*`/`netWrite*`); the wrapper itself is pure forwarding, no OS call.

### netAbiResolve
linux `runtime/net/linux/netabi.bit:573-607` (35 lines) / darwin `runtime/net/darwin/netabi.bit:562-596` (35 lines) — DNS-or-literal host resolution dispatcher; calls `netParseIpv4`, `readResolvConf`, `netFirstNameserver`, `netResolveHost` — all either core or already-provider-abstracted. No direct OS touch.

### netAbiShutdownSockW
linux `runtime/net/linux/netabi.bit:347-349` (3 lines) / darwin `runtime/net/darwin/netabi.bit:335-337` (3 lines) — thin `bit_rt_*`-exported wrapper that forwards straight to a same-named provider primitive (`netSys*`/`netRead*`/`netWrite*`); the wrapper itself is pure forwarding, no OS call.

### netAbiUdpBind
linux `runtime/net/linux/netabi.bit:453-458` (6 lines) / darwin `runtime/net/darwin/netabi.bit:442-447` (6 lines) — thin `bit_rt_*`-exported wrapper that forwards straight to a same-named provider primitive (`netSys*`/`netRead*`/`netWrite*`); the wrapper itself is pure forwarding, no OS call.

### netAbiUdpRecv
linux `runtime/net/linux/netabi.bit:475-500` (26 lines) / darwin `runtime/net/darwin/netabi.bit:464-489` (26 lines) — thin `bit_rt_*`-exported wrapper that forwards straight to a same-named provider primitive (`netSys*`/`netRead*`/`netWrite*`); the wrapper itself is pure forwarding, no OS call.

### netAbiUdpSend
linux `runtime/net/linux/netabi.bit:462-467` (6 lines) / darwin `runtime/net/darwin/netabi.bit:451-456` (6 lines) — thin `bit_rt_*`-exported wrapper that forwards straight to a same-named provider primitive (`netSys*`/`netRead*`/`netWrite*`); the wrapper itself is pure forwarding, no OS call.

### netAbiUdpSenderHost
linux `runtime/net/linux/netabi.bit:504-514` (11 lines) / darwin `runtime/net/darwin/netabi.bit:493-503` (11 lines) — thin `bit_rt_*`-exported wrapper that forwards straight to a same-named provider primitive (`netSys*`/`netRead*`/`netWrite*`); the wrapper itself is pure forwarding, no OS call.

### netAbiUdpSenderPort
linux `runtime/net/linux/netabi.bit:518-524` (7 lines) / darwin `runtime/net/darwin/netabi.bit:507-513` (7 lines) — thin `bit_rt_*`-exported wrapper that forwards straight to a same-named provider primitive (`netSys*`/`netRead*`/`netWrite*`); the wrapper itself is pure forwarding, no OS call.

### netAbiWrite
linux `runtime/net/linux/netabi.bit:241-243` (3 lines) / darwin `runtime/net/darwin/netabi.bit:230-232` (3 lines) — thin `bit_rt_*`-exported wrapper that forwards straight to a same-named provider primitive (`netSys*`/`netRead*`/`netWrite*`); the wrapper itself is pure forwarding, no OS call.

### netAbiWriteDeadlineW
linux `runtime/net/linux/netabi.bit:325-340` (16 lines) / darwin `runtime/net/darwin/netabi.bit:313-328` (16 lines) — thin `bit_rt_*`-exported wrapper that forwards straight to a same-named provider primitive (`netSys*`/`netRead*`/`netWrite*`); the wrapper itself is pure forwarding, no OS call.

### readResolvConf
linux `runtime/net/linux/netabi.bit:547-564` (18 lines) / darwin `runtime/net/darwin/netabi.bit:536-553` (18 lines) — reads `/etc/resolv.conf` through the already-abstracted `fsOpen`/`netReadSock`/`fsClose` trio; the loop-until-`bufCap`-or-EOF shape is the kind of retry loop the epic calls out.

### scratchWords
linux `runtime/net/linux/netabi.bit:168-170` (3 lines) / darwin `runtime/net/darwin/netabi.bit:157-159` (3 lines) — computes the per-worker scratch-word count for a DNS/resolve buffer; arithmetic over `schedMaxWorkers`, no OS call.

### strData
linux `runtime/net/linux/netabi.bit:130-132` (3 lines) / darwin `runtime/net/darwin/netabi.bit:119-121` (3 lines) — string/byte-slice accessor over the managed string representation; no OS call.

### strFromPacked
linux `runtime/net/linux/netabi.bit:153-165` (13 lines) / darwin `runtime/net/darwin/netabi.bit:142-154` (13 lines) — string/byte-slice accessor over the managed string representation; no OS call.

### strSizeOf
linux `runtime/net/linux/netabi.bit:134-136` (3 lines) / darwin `runtime/net/darwin/netabi.bit:123-125` (3 lines) — string/byte-slice accessor over the managed string representation; no OS call.

### u8At
linux `runtime/net/linux/netabi.bit:123-126` (4 lines) / darwin `runtime/net/darwin/netabi.bit:112-115` (4 lines) — raw pointer-cast accessor into a scratch buffer; no OS call.

### udpSenderAddr
linux `runtime/net/linux/netabi.bit:416-418` (3 lines) / darwin `runtime/net/darwin/netabi.bit:405-407` (3 lines) — UDP sender-address scratch-slot bookkeeping; arithmetic/byte access only, no OS call.

### udpSenderSlot
linux `runtime/net/linux/netabi.bit:431-441` (11 lines) / darwin `runtime/net/darwin/netabi.bit:420-430` (11 lines) — UDP sender-address scratch-slot bookkeeping; arithmetic/byte access only, no OS call.

### udpSenderWordAt
linux `runtime/net/linux/netabi.bit:411-413` (3 lines) / darwin `runtime/net/darwin/netabi.bit:400-402` (3 lines) — UDP sender-address scratch-slot bookkeeping; arithmetic/byte access only, no OS call.

### udpValidAt
linux `runtime/net/linux/netabi.bit:421-423` (3 lines) / darwin `runtime/net/darwin/netabi.bit:410-412` (3 lines) — UDP sender-address scratch-slot bookkeeping; arithmetic/byte access only, no OS call.

#### `sock.bit` (27 candidates)

### afInet
linux `runtime/net/linux/sock.bit:65-65` (1 line) / darwin `runtime/net/darwin/sock.bit:116-116` (1 line) — AF_INET is 2 on both platforms (POSIX-standard address family); the constant is not OS-specific even though the socket syscalls that consume it are.

### bytesAt
linux `runtime/net/linux/sock.bit:222-225` (4 lines) / darwin `runtime/net/darwin/sock.bit:278-281` (4 lines) — raw pointer-cast accessor into a scratch buffer; no OS call.

### dnsBytes
linux `runtime/net/linux/sock.bit:233-233` (1 line) / darwin `runtime/net/darwin/sock.bit:289-289` (1 line) — returns a fixed byte-count constant for a wire-format field; not OS-specific.

### eIntr
linux `runtime/net/linux/sock.bit:99-99` (1 line) / darwin `runtime/net/darwin/sock.bit:146-146` (1 line) — EINTR is 4 on both Linux and Darwin (low POSIX errno values are cross-platform); the surrounding `sock.bit` is a provider file but this one constant is not OS-specific — most sibling errno constants in the same file (eAgain, eConnReset, ...) genuinely do differ and correctly stay put.

### fGetFl
linux `runtime/net/linux/sock.bit:80-80` (1 line) / darwin `runtime/net/darwin/sock.bit:123-123` (1 line) — F_GETFL is 3 on both platforms (POSIX fcntl command).

### fSetFl
linux `runtime/net/linux/sock.bit:81-81` (1 line) / darwin `runtime/net/darwin/sock.bit:124-124` (1 line) — F_SETFL is 4 on both platforms (POSIX fcntl command).

### getU16Be
linux `runtime/net/linux/sock.bit:253-255` (3 lines) / darwin `runtime/net/darwin/sock.bit:309-311` (3 lines) — big/little-endian word packing helper; pure byte marshalling, no OS call.

### getU32Le
linux `runtime/net/linux/sock.bit:270-278` (9 lines) / darwin `runtime/net/darwin/sock.bit:321-329` (9 lines) — big/little-endian word packing helper; pure byte marshalling, no OS call.

### getU64Le
linux `runtime/net/linux/sock.bit:280-288` (9 lines) / darwin `runtime/net/darwin/sock.bit:331-339` (9 lines) — big/little-endian word packing helper; pure byte marshalling, no OS call.

### getU8
linux `runtime/net/linux/sock.bit:240-243` (4 lines) / darwin `runtime/net/darwin/sock.bit:296-299` (4 lines) — single-byte accessor; pure byte marshalling, no OS call.

### ipBytes
linux `runtime/net/linux/sock.bit:231-231` (1 line) / darwin `runtime/net/darwin/sock.bit:287-287` (1 line) — returns a fixed byte-count constant for a wire-format field; not OS-specific.

### lenBytes
linux `runtime/net/linux/sock.bit:230-230` (1 line) / darwin `runtime/net/darwin/sock.bit:286-286` (1 line) — returns a fixed byte-count constant for a wire-format field; not OS-specific.

### netSockAddrFamily
linux `runtime/net/linux/sock.bit:369-371` (3 lines) / darwin `runtime/net/darwin/sock.bit:404-406` (3 lines) — reads one field out of an already-filled sockaddr buffer at a fixed offset; no OS call.

### netSockAddrLen
linux `runtime/net/linux/sock.bit:325-327` (3 lines) / darwin `runtime/net/darwin/sock.bit:361-363` (3 lines) — reads one field out of an already-filled sockaddr buffer at a fixed offset; no OS call.

### netSockAddrOctets
linux `runtime/net/linux/sock.bit:374-380` (7 lines) / darwin `runtime/net/darwin/sock.bit:409-415` (7 lines) — reads one field out of an already-filled sockaddr buffer at a fixed offset; no OS call.

### netSockAddrPort
linux `runtime/net/linux/sock.bit:352-354` (3 lines) / darwin `runtime/net/darwin/sock.bit:386-388` (3 lines) — reads one field out of an already-filled sockaddr buffer at a fixed offset; no OS call.

### optBytes
linux `runtime/net/linux/sock.bit:229-229` (1 line) / darwin `runtime/net/darwin/sock.bit:285-285` (1 line) — returns a fixed byte-count constant for a wire-format field; not OS-specific.

### putU16Be
linux `runtime/net/linux/sock.bit:248-251` (4 lines) / darwin `runtime/net/darwin/sock.bit:304-307` (4 lines) — big/little-endian word packing helper; pure byte marshalling, no OS call.

### putU32Le
linux `runtime/net/linux/sock.bit:262-268` (7 lines) / darwin `runtime/net/darwin/sock.bit:313-319` (7 lines) — big/little-endian word packing helper; pure byte marshalling, no OS call.

### putU64Le
linux `runtime/net/linux/sock.bit:290-296` (7 lines) / darwin `runtime/net/darwin/sock.bit:341-347` (7 lines) — big/little-endian word packing helper; pure byte marshalling, no OS call.

### putU8
linux `runtime/net/linux/sock.bit:235-238` (4 lines) / darwin `runtime/net/darwin/sock.bit:291-294` (4 lines) — single-byte accessor; pure byte marshalling, no OS call.

### saBytes
linux `runtime/net/linux/sock.bit:227-227` (1 line) / darwin `runtime/net/darwin/sock.bit:283-283` (1 line) — returns a fixed byte-count constant for a wire-format field; not OS-specific.

### saBytes2
linux `runtime/net/linux/sock.bit:228-228` (1 line) / darwin `runtime/net/darwin/sock.bit:284-284` (1 line) — returns a fixed byte-count constant for a wire-format field; not OS-specific.

### sockDgram
linux `runtime/net/linux/sock.bit:67-67` (1 line) / darwin `runtime/net/darwin/sock.bit:118-118` (1 line) — SOCK_DGRAM is 2 on both platforms (POSIX-standard).

### sockScratchSlot
linux `runtime/net/linux/sock.bit:149-159` (11 lines) / darwin `runtime/net/darwin/sock.bit:238-248` (11 lines) — computes a per-worker scratch-buffer offset; arithmetic over `schedCurrentWorker`/`wkId`, no OS call.

### sockStream
linux `runtime/net/linux/sock.bit:66-66` (1 line) / darwin `runtime/net/darwin/sock.bit:117-117` (1 line) — SOCK_STREAM is 1 on both platforms (POSIX-standard).

### tvBytes
linux `runtime/net/linux/sock.bit:232-232` (1 line) / darwin `runtime/net/darwin/sock.bit:288-288` (1 line) — returns a fixed byte-count constant for a wire-format field; not OS-specific.

#### `tcp.bit` (3 candidates)

### netAwaitDeadlineTick
linux `runtime/net/linux/tcp.bit:436-448` (13 lines) / darwin `runtime/net/darwin/tcp.bit:417-429` (13 lines) — deadline-vs-now arithmetic for the polling read/write path; no OS call.

### netClampDeadline
linux `runtime/net/linux/tcp.bit:418-427` (10 lines) / darwin `runtime/net/darwin/tcp.bit:399-408` (10 lines) — deadline-vs-now arithmetic for the polling read/write path; no OS call.

### netListenTcp
linux `runtime/net/linux/tcp.bit:31-57` (27 lines) / darwin `runtime/net/darwin/tcp.bit:31-57` (27 lines) — socket/bind/listen sequencing; every OS-touching step (`netSysSocket`, `netSetReuseAddr`, `netFillSockAddr`, `netSysBind`, `netSysListen`, `netClose`, `lastErr`) is a same-named provider primitive already split per OS — the sequence itself is identical control flow.

#### `udp.bit` (1 candidate)

### netBindUdp
linux `runtime/net/linux/udp.bit:29-50` (22 lines) / darwin `runtime/net/darwin/udp.bit:15-36` (22 lines) — socket/bind sequencing for UDP, same shape as `netListenTcp`; every OS-touching step is a same-named provider primitive.

## thread

Providers: linux 1045 lines / 2 files (spawn.bit + tls.bit), darwin 269 lines / 1 file (spawn.bit only — no `tls.bit` counterpart, Darwin's thread-local setup lives elsewhere). Only `spawn.bit` exists on both sides, and only one of its three same-named functions is genuinely identical.
**1 candidate.** `threadStart`/`threadRelease` share a name but not a body (Linux: raw `clone()`, stack registration, TLS prep; Darwin: a pthread-style trampoline+claim/release) — real per-OS implementations, not a leaked duplicate; not listed.

#### `spawn.bit` (1 candidate)

### runningSentinel
linux `runtime/thread/linux/spawn.bit:53-53` (1 line) / darwin `runtime/thread/darwin/spawn.bit:46-46` (1 line) — a sentinel bit pattern used to mark a thread slot as running; a chosen constant, not OS state — the only shared name between the two `spawn.bit` files, which otherwise implement thread creation almost entirely differently (raw `clone()` vs `pthread`-style trampoline).

## park

Providers: linux 323 lines / 1 file, darwin 322 lines / 1 file — nearly identical total size, almost entirely futex (Linux) vs. `__ulock`/mach (Darwin) primitives that must differ.
**1 candidate**, a single unit-conversion constant. Every other shared name in `wait.bit` is a real OS primitive or an OS-specific numeric constant (`eTimedOut` is 110 on Linux, 60 on Darwin, and the file says why) — this is the smallest-yield module of the four, by design: it is the module closest to the syscall.

#### `wait.bit` (1 candidate)

### nsPerSec
linux `runtime/park/linux/wait.bit:63-63` (1 line) / darwin `runtime/park/darwin/wait.bit:73-73` (1 line) — 1e9, nanoseconds per second; a unit-conversion constant, not OS state — its neighbor `eTimedOut` in the same file genuinely differs (60 vs 110) and correctly stays put.


