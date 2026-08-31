# tgc — status and remaining work

Findings marked **[measured]** were reproduced by building and running probes with
LDC 1.42.0 (DMD 2.112.1) on macOS/aarch64.

The original audit's findings and what was done about them are recorded in
`CHANGELOG.adoc`. This file tracks what is **still open**.

---

## Done

Memory safety: TLS scanning, register spilling, **fiber/all-context stack
scanning**, 16-byte payload alignment, one-past-the-end marking,
`disable()`/`collect()` semantics, **thread-teardown use-after-free (Phase 0 of
the cross-thread fix)**, `TypeInfo` capture for struct finalizers, `realloc`
accounting, atomics on cross-thread state, unattached-thread collection refusal,
`runFinalizers`.

Performance: chunk-arena allocator with O(1) pointer resolution, explicit mark
worklist, array API implementation, threshold decay, chunk release, root
snapshotting, pause-time instrumentation, **word-at-a-time sweeping**,
**address-indexed chunk directory**, **segment-backed chunks (huge pages)**,
size-class table, pointer-map memo.

Infrastructure: UTF-8 conversion, `.gitattributes`, CI (DMD/LDC ×
Linux/macOS/Windows + sanitizers + encoding guard), adversarial test suite,
optimized test build, **in-repo benchmarks** (`bench/run.sh`).

Measured collection time, N live 32-byte objects, macOS/arm64. The last column
is the current collector, reproducible with `bench/webserver_probe.d`; the first
two are from the original audit's probes.

| live objects | before | after the allocator | now |
|---|---|---|---|
| 2,000 | 21 ms | 0.05 ms | 0.03 ms |
| 8,000 | 176 ms | 0.09 ms | 0.06 ms |
| 16,000 | **577 ms** | 0.15 ms | **0.09 ms** |
| 64,000 | — | 0.46 ms | 0.30 ms |
| 256,000 | — | 1.83 ms | **1.15 ms** |

Quadratic → linear, then another 37% from the mark, sweep and allocator work.
Appending 100,000 elements: 100,000 reallocations → 13.

---

## Next — a plan, in the order worth doing it

Ranked by what a user would notice, not by what is most interesting. Every item
below is measurable with what is now in the repository (`bench/run.sh`,
`bench/webserver_probe.d`), which is the standard the last two passes were held
to and the reason two of their four "obvious" optimizations were reverted.

### A. Before calling it 0.2.0

1. **Return memory without being asked.** The segment allocator only gives
   memory back on `GC.minimize()`, so a server that never calls it holds its
   peak for the life of the process. That is a surprising default and the most
   likely thing to be reported as a leak. Proposal: during a collection, when a
   segment falls below some occupancy, hand back its free 2 MB spans — the
   machinery already exists, only the trigger is missing. Needs hysteresis so a
   breathing heap does not thrash, and measuring on both RSS and pause.
2. **Keep the thread-private checks in release builds, optionally.** They are
   asserts, so `-release` is back to the old silent behaviour. A
   `version(TgcEnforce)` that keeps them costs two atomic loads on a cold path
   and turns a development aid into a guarantee for anyone who wants it.
3. **`reserve()` still returns 0.** Trivial now that chunks come from segments:
   pre-map and pre-touch, so a latency-sensitive caller pays the page faults up
   front instead of inside its first request. Small, and directly useful to the
   audience this collector is for.
4. **Shutdown leak.** `ThreadGC` is `malloc`'d and never destroyed, and a heap's
   root/range snapshot buffers leak with it — LeakSanitizer reports 1056 bytes.
   Harmless, but it is why the ASan job runs with `detect_leaks=0`, and fixing
   it lets that flag come off.

### B. Performance: the mark phase, which is now all that is left

The counters say what to expect. On a matched budget tgc executes the same
instructions as the default collector and misses cache *less*, and after the
segment work it is 3.2x better on total pause — but on a pure single-threaded
mark of 256,000 live objects it is still 1.58 ms against 1.16 ms. That gap is
conservative scanning and the cache lines each marked object touches.

5. **Interleave `allocBits` and `markBits`.** `markPtr` reads one and writes the
   other for every marked object, and they are separate arrays a few hundred
   bytes apart — usually two lines. Interleaving them per 64-slot group makes it
   one. The sweep reads all three bitvectors and would go from three lines to
   two. Costs a strided loop in `clearMarks` where a `memset` is used today.
6. **Move `NO_SCAN` into a bitvector.** Marking reads a byte per object out of a
   byte-per-slot array — 21 cache lines for a 1,300-slot chunk against 3 for the
   equivalent bits.
7. **Prefetch down the mark stack.** Standard for a pointer-chasing collector,
   untried here.
8. **Re-test multiply-by-reciprocal on x86-64.** It measured *slower* on arm64
   and was reverted; the 32-bit divide that replaced it is cheap there but
   x86-64's divider is not, and that half was never measured.

Expect single-digit percentages each. Items 5 and 6 are the ones with a
mechanism behind them rather than a hope.

### C. Needs someone else

9. **Fiber enumeration is O(all fibers in the process)** (item 4b). Scanning is
   already restricted to a thread's own fibers; enumeration cannot be, because
   druntime's context list is the only authority on whether a stack is still
   mapped. Fixing it needs a `ThreadBase` field recording the owning thread on
   each `StackContext`, or a per-thread context list. Worth raising upstream
   alongside the tgc PR.
10. **Escape tracking as the default** (item 2). Now that a global collection is
    cheap, the question is whether tying local pause growth to the global
    interval is acceptable on a realistic workload. Needs measurement before it
    can be argued either way, and it is the difference between "unsupported" and
    "handled" for the publish-to-a-global pattern.
11. **Benchmarks in CI** (item 7). Nothing fails today when a change makes the
    mark phase slower. Pause per collection on a fixed live set is the most
    stable thing to gate on; a shared runner's wall clock is not.

### Not planned, and why

* **Parallel marking within a collection.** It would cut one thread's pause, but
  by stealing cores from the threads whose independence is the entire argument
  for this collector.
* **Precise or moving collection.** Both need compiler support D does not have;
  the same barrier problem that bounds `CROSS-THREAD.md`'s conclusions.
* **A second ownership model** (pinned cross-thread transfer). Considered and
  rejected — see item 1.

---

## Decided — heaps are strictly thread-private

### 1. Cross-thread ownership transfer: removed rather than made safe

> Researched in depth in [CROSS-THREAD.md](CROSS-THREAD.md). Headline: the
> problem is worse than "users must not share" — `Thread`'s closure, the
> `Thread` object and `join()`'s exception propagation all cross heaps by
> construction. D's type system cannot fix this at allocation time (the spec
> blesses `cast(shared)` on thread-local data), but collection-time escape
> detection can.
>
> **Phases 0, 1 and 2 are done**: a dying thread's arenas are retained rather
> than finalized and freed (closing the `join()` use-after-free); blocks
> observed reachable from a global root can be stickily promoted
> (`tgcTrackEscapes`, opt-in); and `tgcCollectGlobal()` reclaims adopted arenas
> and demotes promoted blocks, with a measured 0.07 ms world-stop for marking
> only.
>
> Phase 1 still ships **off by default**, because the promoted set is sticky and
> re-scanned every cycle: measured, the mark phase grew from 0.25 ms to 3.66 ms
> as the promoted set reached 212,000 blocks. Promotion is also *sampled* at
> collection time, so a block published, shared and unpublished entirely between
> two collections is never seen; closing that needs a write barrier D does not
> have.

**This is now decided.** The documented "explicit ownership transfer" path is
gone. It could not be made sound without scanning the receiving thread's stack,
which is the one thing this collector does not do, and it was the worst of the
available options: an unsafe path, documented as unsupported, left reachable and
untested.

Two of the three hazards the audit listed had already been fixed and the entry
had gone stale — worth recording, because the shape of the remaining one is
different:

* `queryBlock`'s foreign-heap fallback no longer probes other live heaps; it
  searches only the orphan heap, under `orphanLock` (item 11).
* The remote-free queue and `drainRemote` no longer exist. `free()` resolves
  only this thread's heap or the orphan heap.
* What was left was the *silence*: a foreign pointer was indistinguishable from
  a non-GC pointer, so `GC.free` on another thread's block did nothing and the
  caller never found out.

That silence is what changed. Chunks now come from a global segment table
(item -3), which makes "tgc memory, but not yours" a question that can be
answered cheaply and without touching another heap's structures — two atomic
loads for the common case, a lock and a binary search only for a pointer that
really does land in the heap. The mutating entry points — `free`, `realloc`,
`setAttr`, `clrAttr`, `expandArrayUsed`, `shrinkArrayUsed` — assert on a foreign
block. Read-only queries stay silent and answer "no block", because callers ask
those speculatively and druntime itself does.

`test/tgc_shared.d` covers it, with the owning thread deliberately kept alive:
once it exits its arenas move to the orphan heap, where any thread may
legitimately answer for them.

**What remains open**, and it is smaller than the entry it replaces: the checks
are asserts, so a `-release` build is back to the old silent behaviour. That is
the right trade for a hot path, but it means the enforcement is a development
aid rather than a guarantee. A build-time switch to keep them in release would
be cheap to add if anyone wants it.

---

## Open — smaller items

### -3. Chunks came from malloc, and that cost more than the mark phase

Found by counting rather than profiling. After the sweep work, at a matched
300 MB budget, tgc executed the same instructions as the default collector and
missed cache 45% *less*, yet spent 27% more cycles. The counter that separated
them was `dTLB-load-misses`: 6.67 M against 1.05 M. `smaps_rollup` said why --
druntime maps its pool in one piece and the kernel backs 76 MB of it with huge
pages, while tgc's per-chunk `posix_memalign` heap got **zero**. The same
allocation pattern also had glibc handing chunks back to the kernel and taking
them again as the heap breathed: 926,000 page faults per run.

Chunks now come from 32 MB segments, huge-page aligned and `MADV_HUGEPAGE` on
Linux. Page faults fell to 210,000, dTLB misses to 4.16 M, and **total pause
from 374 ms to 38 ms** -- a third of the default collector's 155 ms on the same
live set. Peak RSS fell too, 606 MB to 541 MB. Full numbers in `BENCHMARKS.md`.

What this leaves open:

* **Retention is coarser than it was.** A segment is only unmapped when every
  chunk in it is free, so one live chunk pins 32 MB. `GC.minimize()` covers the
  gap by handing back each 2 MB span that holds nothing, but nothing calls that
  automatically. A server that never calls it holds its peak. Worth revisiting:
  doing the span-level drop during a collection when a segment falls below some
  occupancy, rather than only on demand.
* **The segment lock is global.** Chunk-granularity operations are rare enough
  that it has not shown up -- four workers improved 3.6x -- but a
  many-core allocation-heavy workload would be the test, and per-thread segment
  ownership is the fix if it does.
* macOS gains nothing from this (no transparent huge pages) and loses nothing
  either; it measured identical before and after. Windows gets contiguity but
  not huge pages, which need `SeLockMemoryPrivilege`.

### -2. The sweep, not the mark, was the largest cost — and it is fixed

The earlier reading of this — "marking is ~6x slower per collection than
druntime's" — was mostly wrong, and profiling on a second platform is what
showed it. On macOS/arm64 the hottest routine in the collector was
`ThreadHeap.freeSlot`, ahead of `markPtr`: reclaiming a slot cost a 16-byte
metadata store, an attribute store and two bit updates per dead object, all on
cold lines, plus a bitmap walk per object rather than per word. None of it was
needed — `alloc` rewrites both fields on every slot it hands out, and nothing
reads either for an unallocated slot.

A chunk holding no finalizable slot is now swept a word at a time. At a matched
300 MB budget on binary-trees depth 18, across the same seven collections:

| | arm64 pause | x86-64 pause |
|---|---|---|
| conservative | 31.1 ms | 122.0 ms |
| tgc, before | 435.6 ms | 750.5 ms |
| tgc, after | **20.4 ms** | **344.2 ms** |

So the *direction* held on both platforms and the magnitude did not: 21x on
arm64, 2.2x on x86-64. The `perf` numbers explain it -- before the change the
sweep was 2.8% of runtime on x86-64 plus part of `collectHeap`'s 5.6%, against
roughly 23% of samples on arm64, so the per-object metadata stores the bulk
sweep removes were simply much cheaper there. Both runs are in `BENCHMARKS.md`.

Two things this leaves:

* **On x86-64 tgc still costs about 2.8x the default collector per collection**
  on the same live set, down from about 6x. That is the remaining gap, and it is
  now the mark phase almost entirely -- see item 0.
* The `perf` share attributed to kernel page management is a *separate* problem
  and turned out to be the larger one. See item -3.

### -2b. Experiments that did not pay, this pass

* **Multiply-by-reciprocal for the slot-index division.** `idx = off / slotSize`
  is on the hottest path and `slotSize` is a runtime value, so the compiler emits
  a real divide. Replacing it with a 42-bit fixed-point reciprocal measured
  *slower* on arm64 — 595 ms of pause against 560 ms — whether the reciprocal was
  stored per chunk or looked up per size class. M1's divider is fast enough that
  the multiply chain is a longer dependency than the divide it replaces. The
  division is now done in 32 bits instead (a small chunk run is at most 256 KB,
  so the offset fits), which is free on arm64 and cheaper on x86-64, where the
  divider is slower. Whether a reciprocal would pay *there* is untested; it
  would have to be measured on that box before being believed.
* **Skipping the per-slot `TypeInfo` load while marking** (measured on arm64).
  Marking loads
  `meta[idx].ti` per object from a 16-byte-per-slot side array — the coldest
  touch on the path. Caching one type per chunk (correct only when a chunk is
  single-typed, which is common) was measured as an upper bound by hardcoding it:
  550 ms of pause to 530 ms, 3.6%. Not worth a per-chunk uniform-type invariant
  that has to stay correct through `realloc` and `setAttr`.

### -1. Regions do not nest, and a throw out of one is a trap

`tgcBeginRegion` returns null on a fiber that already has a region open, because
a nested region's blocks would be freed while the outer one still ran. That is
the safe answer but not a useful one; scoped nesting would need a stack of
regions per fiber and per-region chunk ownership, which is a bigger change than
it sounds.

The sharper hazard is an exception thrown out of a region: it is allocated
inside and caught outside, so it dangles. `tgcRunInRegion` closes the region on
the way out but cannot copy the exception, and the verifier will flag it only
if the catch site is reachable from a scanned root at close time. Documented,
not solved.

### 0. Marking is now the bottleneck, and it is conservative scanning itself

With the sweep gone from the profile, `markPtr` + `lookup` + `drainMarkStack`
are about a third of runtime on binary-trees, and nothing else in the collector
is close. Six cheap explanations have now been tested:

| tried | result |
|---|---|
| one-entry chunk cache in front of the map | 48% hit, cost more than it saved |
| 64 KiB → 1 MiB chunks, so the map stays in L1 | 6% |
| precise scanning via `rtInfo` | 4–6%, shipped |
| free-chunk cache, to cut kernel page management | 0.2% |
| multiply-by-reciprocal instead of a divide | *negative* on arm64 |
| per-chunk uniform `TypeInfo`, to skip a cold load | 3.6% upper bound, not taken |

What *did* pay was replacing the hash map with an address-indexed directory
(shipped) — a candidate outside the heap's span is now rejected in two compares
with no memory touched, and adjacent chunks land on adjacent entries.

What is left is the conservative scan itself and the cache misses inherent in
chasing pointers through a large heap. Note the counters say tgc already misses
cache *less* than druntime's collector on the same live set, so the remaining
levers are about work done, not about layout:
interleaving the per-chunk `allocBits`/`markBits`/`sharedBits` so marking touches
one line instead of two, moving `NO_SCAN` out of the byte-per-slot attribute
array into a bitvector, and prefetching down the mark stack. All three are worth
measuring; none is obviously worth its complexity yet.

### 2. Escape tracking still defaults to off

Phase 2 reclaims both adopted arenas and promoted blocks, so retention is no
longer permanent. But `tgcTrackEscapes` remains opt-in, because between global
collections the promoted set is still re-scanned on every local collection, so
pauses still grow with published allocations — just boundedly now, reset by each
global collection.

Making it the default would mean tying local pause time to the global-collection
interval, which needs measurement on a realistic workload first. Worth
revisiting.

### 3. Every thread scans every other thread's fibers

Fiber stacks are found through druntime's global `ThreadBase.sm_cbeg` list,
which records no fiber-to-thread affinity. So with 4 threads × 2,500 fibers, all
four scan all 10,000 rather than their own 2,500 — about 4× the necessary work,
at a measured ~0.32 µs per suspended fiber. Narrowing it means tgc tracking
affinity itself, which needs a hook druntime does not expose today; the
fallback is a tgc-side registry updated when a fiber is first seen running on a
thread.

### 4. Per-slot metadata is down to 17.375 bytes; `ti` and `usedSize` remain

Slot state moved into per-chunk bitvectors and attributes into a byte array, so
`SlotMeta` is now just `TypeInfo ti` and `size_t usedSize` — 24 bytes per slot
to 17.375, measured as 48.50 to 41.94 bytes of arena per 16-byte object.

The remaining two fields are each needed only sometimes: `ti` only for
finalizable blocks, `usedSize` only for appendable ones. Moving them to side
tables keyed by slot would take a 16-byte object's overhead down further, at the
cost of a lookup on the array-append path — which is hot, so this needs
measuring before it is worth doing.

### 4b. Fiber enumeration is still O(all fibers in the program)

Fiber *scanning* is correctly restricted to the collecting thread's own fibers:
a context counts as ours only if this heap owns the `StackContext` block, which
`Fiber` allocates with `new` on its creating thread.

Enumeration is not. Finding those contexts means walking druntime's global
`ThreadBase.sm_cbeg` list, which holds every fiber in the process, and the
ownership test has to happen *inside* druntime's thread lock — once the lock is
released, another thread may destroy its fiber and unmap the stack, and scanning
that faults. So each thread's collection walks T x F contexts rather than its
own F.

Measured with each thread holding a constant 400 fibers and an identical live
set, so all growth comes from *other* threads' fibers:

| threads | total fibers | collect/thread (2 walks) | (1 walk) |
|---|---|---|---|
| 1 | 400 | 0.20 ms | 0.21 ms |
| 2 | 800 | 0.23 ms | 0.24 ms |
| 4 | 1,600 | 0.27 ms | 0.27 ms |
| 8 | 3,200 | 0.38 ms | 0.29 ms |

Collapsing the count-then-filter double walk into one, with the cheap tests
first, took the 8-thread case from 0.38 ms to 0.29 ms. The residual growth is
inherent: the global list is the only authority on whether a fiber's stack is
still mapped.

Removing it needs druntime's help — a `ThreadBase` field recording the owning
thread on each `StackContext`, or a per-thread context list. Either would let a
thread enumerate only its own. Worth raising upstream alongside the tgc PR.

### 5. `GC.collect()` collects only the calling thread

A user calling `GC.collect()` before a latency-critical section reclaims
nothing from any other thread, and an idle or blocked thread's garbage is never
reclaimed because collection is driven purely by that thread's own allocation
threshold. Consider a cooperative "collect at your next safepoint" flag that
other threads poll in `alloc`.

### 6. `reserve()` still returns 0

Pre-committing arena chunks for a requested size would let latency-sensitive
callers pay the allocation cost up front. `extend()` now reports usable slack
but cannot grow a slot.

### 7. Benchmarks are in the repo, but not in CI

`dub build -c bench-bintree|bench-mt|bench-region` and `bench/run.sh` build the
three binary-trees variants and run each under both collectors, reporting wall
time, collections and pause distribution; `BENCHMARKS.md` records the numbers.
What is still missing is CI: nothing fails when a change makes the mark phase
slower, and a shared runner's timings are noisy enough that the threshold needs
thought. Pause *per collection* on a fixed live set is the most stable metric to
gate on.

### 8. Precise scanning is on, but is the newest and least-proven feature

Marking now consults `TypeInfo.rtInfo` and skips words that cannot be pointers,
which is worth 4-6%. It falls back to conservative for unknown types, for
`rtinfoHasPointers`, and for appendable blocks whose `TypeInfo` is a class.

It has only been exercised against LDC. druntime keeps its own precise mode
opt-in (`gc:precise`), which suggests less than full confidence in `RTInfo`
across compilers, and an under-scan here means freeing live memory rather than
a visible failure. `tgcPreciseScanning(false)` turns it off; the DMD leg of CI
is the first real cross-compiler check.

That leg has now run, and it found two *test* bugs rather than a precision one:
a region opened and discarded on the main thread, and the `keepAlive` barrier
publishing a region block to a `__gshared` slot inside a verified region. Both
reproduced only under DMD, because module order there runs the region tests
first. Precise scanning itself came through clean under DMD on Linux and
Windows, in both the debug and optimized builds.

Note that full concurrency in FUGC's sense is *not* reachable: it depends on a
Dijkstra store barrier, and D has no write barrier without compiler support.
That is also why the sampled-promotion hole in `CROSS-THREAD.md` cannot be
closed. What tgc gets in exchange is that a thread-local collection has no
concurrent mutator at all, so it needs no barrier for the common case.

### 9. `ThreadGC` is never destroyed

The instance is `malloc`'d and `emplace`'d; `roots`/`ranges` leak at shutdown.
Harmless in practice, untidy.

### 10. Sanitizers: run, and clean

Both now run clean on Linux/x86-64 with LDC 1.42 — the first time either has
executed against this project. They still cannot run on macOS/arm64, where ASan
deadlocks in its own startup and TSan segfaults before `main`, both reproducible
with a `printf("hello")` program containing none of this code.

ThreadSanitizer went from 68 warnings to zero, and the path there is worth
recording because most of it was not bugs:

* **~20 were TSan blindness to druntime's `SpinLock`.** A four-thread counter
  guarded by it comes out exact, so the lock works; TSan just cannot see the
  edge. Annotating acquire and release with `__tsan_acquire`/`__tsan_release`
  fixed it — better than suppressing, because those structures stay checked.
* **~10 were the conservative scan itself**, which reads whole stacks and the
  data segment while other threads mutate them. The scan routines already
  carried `@noSanitize("address")`; they needed `"thread"` too. Two of them had
  silently lost the attribute in an earlier refactor.
* **~5 were the world-stopped section** of the global collection, where the
  synchronisation is a signal handshake TSan cannot model. Wrapped in
  `__tsan_ignore_thread_begin/end`.
* **29 were druntime's own** `thread_suspendHandler` failing to save `errno`.
  Suppressed, with a note that it is not tgc's to fix.

Two real defects came out of it: a use-after-free in `test/tgc_region.d` that
queried a region handle after freeing it, and — introduced while adding the
annotations — three sites where `scope (exit) tsanRelease(...); lock.unlock();`
released the lock *immediately* rather than on scope exit, because D binds only
the first statement to the guard. That one is exactly the class of bug the tool
exists for.

A later run, after the mark-and-sweep work, turned up one more real race that
had been there all along: `collectGlobal` re-derived `orphanBytes` with a plain
store to a `shared` variable, outside `orphanLock`, racing `adoptOrphanChunks`.
Fixed by deleting it -- `sweepOrphanHeap` already publishes the value atomically
under the lock. It reproduces intermittently, which is the usual shape and the
reason a sanitizer run is worth repeating rather than doing once.

AddressSanitizer reports zero errors *as CI runs it*, with
`detect_leaks=0`. With leak detection on it reports one 1056-byte direct leak,
which is a heap's root/range snapshot buffer never freed at shutdown -- item 9,
known and deliberate rather than new. Worth fixing before the flag is turned on. Two reclamation assertions are skipped
under `TgcSanitize`: ASan's redzones and quarantine change the stack layout
enough that a conservative collector never lets the objects go. Reclamation is
covered by the ordinary builds; the sanitizer run is checking safety.

### 11. One race is fixed by inspection, not by a reproducing test

`queryBlock` used to probe every other live thread's `ChunkMap` under
`heapsLock`, while those maps are mutated by their owners under no lock at all
— and `ChunkMap.grow` frees the old key and value arrays. That is a concurrent
read of freed memory, reachable from an ordinary `GC.sizeOf` on a pointer the
calling thread does not own. It is fixed: the fallback now searches only the
orphan heap, which is mutated exclusively under `orphanLock`.

It resisted every attempt to reproduce, including a build with a 200 µs delay
inserted into `ChunkMap.grow` and 400,000 concurrent cross-heap queries. That is
the expected shape: a reader of a just-freed malloc block usually gets
stale-but-plausible data rather than a fault, so the failure is a wrong answer,
not a crash. `test/tgc_race.d` exercises the path hard but does **not** detect
the original bug — verified by running it against the pre-fix commit, where it
passes 30/30.

This is exactly the class of defect a thread sanitizer finds by happens-before
analysis and stress testing does not. Treat it as the strongest argument for
getting item 10 working.