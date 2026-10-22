# Runtime ABI

The binary contract between the **compiler** (codegen) and the **runtime** (GC,
scheduler, channels). Change this document first; codegen and runtime both
implement what it says. Anything not written here is not guaranteed.

Status: v1 covers the garbage collector (`runtime/gc`, §1-8), green-thread
spawn and program entry (`runtime/root`, §9-10), channels (`runtime/chan`
+ `runtime/root`, §11), and panics (§12). The per-callsite stack-map wire
format and the multi-worker stop-the-world barrier are explicitly **not**
frozen here — §4/§5 say why and who owns them next.

Every section below names the **Bit** module that implements it. `libbitrt.a` is
built entirely from `runtime/**/*.bit`.

All layouts below are for 64-bit targets (x86-64, ARM64). Pointers and `usize`
are 8 bytes; the null reference is the all-zero bit pattern.

---

The contract continues in the topic pages below. These headings retain existing section links.

## 1. Managed object layout
See the [full section](abi/object-layout.md#1-managed-object-layout).

### Alignment
See the [full section](abi/object-layout.md#alignment).

### Initialization
See the [full section](abi/object-layout.md#initialization).

### 1.1 Aggregates and multi-value returns
See the [full section](abi/object-layout.md#11-aggregates-and-multi-value-returns).

### 1.2 Payload-carrying enums
See the [full section](abi/object-layout.md#12-payload-carrying-enums).

### 1.2.1 The value form: an eligible enum as two words
See the [full section](abi/object-layout.md#121-the-value-form-an-eligible-enum-as-two-words).

### 1.2.2 Which functions return an eligible enum in words
See the [full section](abi/object-layout.md#122-which-functions-return-an-eligible-enum-in-words).

## 2. Per-type pointer maps (`TypeInfo`)
See the [full section](abi/type-info.md#2-per-type-pointer-maps-typeinfo).

### 2.1 Method table (interface dispatch)
See the [full section](abi/type-info.md#21-method-table-interface-dispatch).

### 2.2 Type assertions
See the [full section](abi/type-info.md#22-type-assertions).

#### 2.2a `bit_rt_iface_as_enum`: the BOXED-ENUM target (#6017)
See the [full section](abi/type-info.md#22a-bit_rt_iface_as_enum-the-boxed-enum-target-6017).

#### 2.2b `bit_rt_iface_implements`: the INTERFACE target, verdict cached (#7406)
See the [full section](abi/type-info.md#22b-bit_rt_iface_implements-the-interface-target-verdict-cached-7406).

### 2.3 `string` value, and shared-backing views (`s[lo:hi]`)
See the [full section](abi/type-info.md#23-string-value-and-shared-backing-views-slohi).

## 3. Reference contract
See the [full section](abi/type-info.md#3-reference-contract).

## 4. Root scanning and stack maps
See the [full section](abi/stack-roots.md#4-root-scanning-and-stack-maps).

### 4.1 The one-table assumption, and why it had to go (RESOLVED)
See the [full section](abi/stack-roots.md#41-the-one-table-assumption-and-why-it-had-to-go-resolved).

### 4.2 Debug-info line table
See the [full section](abi/stack-roots.md#42-debug-info-line-table).

### 4.3 Module-cell roots (#6481)
See the [full section](abi/stack-roots.md#43-module-cell-roots-6481).

## 5. Safepoints and stop-the-world
See the [full section](abi/safepoints-and-gc.md#5-safepoints-and-stop-the-world).

### 5.1 The adjacency contract: what it guarantees, and what it never did
See the [full section](abi/safepoints-and-gc.md#51-the-adjacency-contract-what-it-guarantees-and-what-it-never-did).

## 6. Allocation and collection entry points
See the [full section](abi/safepoints-and-gc.md#6-allocation-and-collection-entry-points).

## 7. GC tuning (environment)
See the [full section](abi/safepoints-and-gc.md#7-gc-tuning-environment).

## 8. Collector algorithm (informative)
See the [full section](abi/collector.md#8-collector-algorithm-informative).

### 8.1 What goes back to the OS, and what does not (informative)
See the [full section](abi/collector.md#81-what-goes-back-to-the-os-and-what-does-not-informative).

### 8.2 `BIT_GC_STATS` byte fields
See the [full section](abi/collector.md#82-bit_gc_stats-byte-fields).

### 8.3 `BIT_GC_STATS` pause-time fields
See the [full section](abi/collector.md#83-bit_gc_stats-pause-time-fields).

### 8.4 The helper gang (#5837)
See the [full section](abi/collector.md#84-the-helper-gang-5837).

### 8.5 A stuck mutator names itself (#6423)
See the [full section](abi/collector.md#85-a-stuck-mutator-names-itself-6423).

## 9. Program entry, boot, and spawn (`runtime/root`)
See the [full section](abi/boot-and-spawn.md#9-program-entry-boot-and-spawn-runtimeroot).

### Process entry
See the [full section](abi/boot-and-spawn.md#process-entry).

### Boot sequence (`boot(main_fn, environ) !i32`)
See the [full section](abi/boot-and-spawn.md#boot-sequence-bootmain_fn-environ-i32).

### Preemption: the sysmon monitor and the preempt request flag
See the [full section](abi/boot-and-spawn.md#preemption-the-sysmon-monitor-and-the-preempt-request-flag).

### Spawn
See the [full section](abi/boot-and-spawn.md#spawn).

### Task-local storage slot (`docs/context-propagation.md` decision B)
See the [full section](abi/boot-and-spawn.md#task-local-storage-slot-docscontext-propagationmd-decision-b).

### 9.1 x86_64-windows: xmm6..xmm15 across a foreign-to-Bit entry (#6434)
See the [full section](abi/boot-and-spawn.md#91-x86_64-windows-xmm6xmm15-across-a-foreign-to-bit-entry-6434).

### Exported C symbols (all `bit_rt_*`, one process-wide runtime instance)
See the [full section](abi/boot-and-spawn.md#exported-c-symbols-all-bit_rt_-one-process-wide-runtime-instance).

## 10. Main entry normalization
See the [full section](abi/boot-and-spawn.md#10-main-entry-normalization).

### Where the fallible rows are realized
See the [full section](abi/boot-and-spawn.md#where-the-fallible-rows-are-realized).

### Module startup initializers (#6480)
See the [full section](abi/boot-and-spawn.md#module-startup-initializers-6480).

## 11. Channels (`runtime/chan` + `runtime/root`)
See the [full section](abi/channels-errors-and-files.md#11-channels-runtimechan--runtimeroot).

### The ABI's one channel type
See the [full section](abi/channels-errors-and-files.md#the-abis-one-channel-type).

### Select (§16.3)
See the [full section](abi/channels-errors-and-files.md#select-163).

### Root scanning integration
See the [full section](abi/channels-errors-and-files.md#root-scanning-integration).

## 12. Panics
See the [full section](abi/channels-errors-and-files.md#12-panics).

### 12.1 Backend-injected, argument-free panics
See the [full section](abi/channels-errors-and-files.md#121-backend-injected-argument-free-panics).

## 13. Fallible results — the error channel (SPEC.md §18)
See the [full section](abi/channels-errors-and-files.md#13-fallible-results--the-error-channel-specmd-18).

### The slot (`BIT_ERR_REG=0`)
See the [full section](abi/channels-errors-and-files.md#the-slot-bit_err_reg0).

## 14. Filesystem primitives
See the [full section](abi/channels-errors-and-files.md#14-filesystem-primitives).

## 15. Maps (`runtime/root`)
See the [full section](abi/collections-time-and-io.md#15-maps-runtimeroot).

### 15.1 Composite values — descriptor programs
See the [full section](abi/collections-time-and-io.md#151-composite-values--descriptor-programs).

## 16. Test selection (`bit test`)
See the [full section](abi/collections-time-and-io.md#16-test-selection-bit-test).

## 17. Math (`runtime/root`)
See the [full section](abi/collections-time-and-io.md#17-math-runtimeroot).

## 18. Time (`runtime/root` + `runtime/sched`)
See the [full section](abi/collections-time-and-io.md#18-time-runtimeroot--runtimesched).

### 18.1 Linux clocks read through the vDSO (#5959)
See the [full section](abi/collections-time-and-io.md#181-linux-clocks-read-through-the-vdso-5959).

## 19. OS (`runtime/root`)
See the [full section](abi/collections-time-and-io.md#19-os-runtimeroot).

## 20. Networking (`runtime/net` + `runtime/root`)
See the [full section](abi/collections-time-and-io.md#20-networking-runtimenet--runtimeroot).

## 21. Crypto (`runtime/rand` + `runtime/root`)
See the [full section](abi/crypto-and-concurrency.md#21-crypto-runtimerand--runtimeroot).

## 21b. Hardware crypto fast paths (`runtime/cryptohw` + `runtime/cryptohw`)
See the [full section](abi/crypto-and-concurrency.md#21b-hardware-crypto-fast-paths-runtimecryptohw--runtimecryptohw).

## 21c. ARM64 crypto hardware-capability detection (`runtime/cryptohw`)
See the [full section](abi/crypto-and-concurrency.md#21c-arm64-crypto-hardware-capability-detection-runtimecryptohw).

## 21d. ARM64 AES block cipher and key schedule (`runtime/cryptohw/armaes.bit`)
See the [full section](abi/crypto-and-concurrency.md#21d-arm64-aes-block-cipher-and-key-schedule-runtimecryptohwarmaesbit).

## 21e. ARM64 GHASH (`runtime/cryptohw/armghash.bit`)
See the [full section](abi/crypto-and-concurrency.md#21e-arm64-ghash-runtimecryptohwarmghashbit).

## 21f. ARM64 SHA-256 compression (`runtime/cryptohw/armsha256.bit`)
See the [full section](abi/crypto-and-concurrency.md#21f-arm64-sha-256-compression-runtimecryptohwarmsha256bit).

## 22. Shared mutable state audit
See the [full section](abi/crypto-and-concurrency.md#22-shared-mutable-state-audit).

## 23. Concurrency memory model — runtime guarantees (SPEC.md §13.7)
See the [full section](abi/crypto-and-concurrency.md#23-concurrency-memory-model--runtime-guarantees-specmd-137).

## 24. CPU sampling profiler (`runtime/root/darwin/prof.bit`)
See the [full section](abi/crypto-and-concurrency.md#24-cpu-sampling-profiler-runtimerootdarwinprofbit).

