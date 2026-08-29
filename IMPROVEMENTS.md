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
snapshotting, pause-time instrumentation.

Infrastructure: UTF-8 conversion, `.gitattributes`, CI (DMD/LDC ×
Linux/macOS/Windows + sanitizers + encoding guard), adversarial test suite,
optimized test build.

Measured collection time, N live 32-byte objects:

| live objects | before | after |
|---|---|---|
| 2,000 | 21 ms | 0.05 ms |
| 8,000 | 176 ms | 0.09 ms |
| 16,000 | **577 ms** | **0.15 ms** |
| 64,000 | — | 0.46 ms |
| 256,000 | — | 1.83 ms |

Quadratic → linear. Appending 100,000 elements: 100,000 reallocations → 13.

---

## Open — design decision required

### 1. Cross-thread ownership transfer is unsound, and unenforced

> Researched in depth in [CROSS-THREAD.md](CROSS-THREAD.md), which supersedes
> the options sketched below. Headline: the problem is worse than "users must
> not share" — `Thread`'s closure, the `Thread` object and `join()`'s exception
> propagation all cross heaps by construction. D's type system cannot fix this
> at allocation time (the spec blesses `cast(shared)` on thread-local data), but
> collection-time escape detection can.
>
> **Phases 0 and 1 are done**: a dying thread's arenas are retained rather than
> finalized and freed (closing the `join()` use-after-free), and blocks observed
> reachable from a global root are stickily promoted and never reclaimed by a
> thread-local sweep.
>
> **Phase 2 is done**: `tgcCollectGlobal()` reclaims adopted arenas and demotes
> promoted blocks, with a measured 0.07 ms world-stop for marking only. That
> removes the permanent-retention objection to both Phase 0 and Phase 1.
>
> Phase 1 still ships **off by default** (`tgcTrackEscapes(true)` enables it),
> because the promoted set is sticky and must be re-scanned every cycle:
> measured, the mark phase grew from 0.25 ms to 3.66 ms as the promoted set
> grew to 212,000 blocks, and it keeps growing. Unbounded pause growth is a
> worse failure than the bug it fixes for this collector's audience.
>
> Two things remain. Promotion is *sampled* at collection time, so a block
> published, shared and unpublished entirely between two collections is never
> seen and is still vulnerable; closing that needs a write barrier D does not
> have. And promoted blocks accumulate, because only a cooperative global
> collection (Phase 2) can prove no thread holds them — which is also what
> would let Phase 1 be the default.

This is the one item from the audit deliberately **not** fixed, because it is a
design decision rather than a bug fix.

The docs say transfer is the single supported cross-thread path. The
implementation cannot make it safe:

- A block handed to thread B is still owned by A's heap. A's collector scans
  only A's stack, registers, TLS and the global roots. B's stack is never
  scanned, so **A's next collection sweeps the block while B is using it.**
- `queryBlock`'s foreign-heap fallback reads other heaps' chunk maps under
  `heapsLock` only, while the owning thread mutates them under no lock at all.
- `free()` on a foreign block queues the pointer for the owner, but the owner
  may already have swept it, so `drainRemote` can double-free.

Nothing enforces the "don't share" rule and no test exercises it, so the hazard
stays invisible until it corrupts a user's heap.

**Options:**

- *Explicit pinned transfer (recommended).* Add `tgcTransfer(p)` moving the
  block out of A's heap into a global in-flight set that no collector sweeps,
  and `tgcAdopt(p)` linking it into B. Everything else stays strictly
  thread-private, and `free`/`realloc`/`query` on a foreign pointer becomes an
  assert instead of a silent race.
- *Remove the path.* Drop the remote-free queue and the foreign-heap fallback
  entirely and document tgc as strictly thread-private.

The current middle ground — an unsafe path documented as unsupported but left
reachable and untested — is the worst of the three.

---

## Open — smaller items

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

### 4. Space amplification for small objects

Each slot carries a 24-byte `SlotMeta` (`TypeInfo`, `usedSize`, `attr`,
`flags`). For a 16-byte slot that is 150% overhead.

`ti` and `usedSize` are only meaningful for finalizable and appendable blocks
respectively. Moving them into side tables keyed by slot index, and reducing
`flags`/`marked` to bitmaps, would cut per-slot metadata to ~4 bytes plus 2
bits. Worth doing before claiming competitive memory behaviour.

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

### 7. Benchmarks are not in the repo

The numbers above come from throwaway probes. A `bench/` target comparing tgc
against `conservative` on pause distribution, N-thread scaling and allocation
throughput belongs in the repository, ideally tracked in CI so a regression in
the mark phase is visible.

### 8. Conservative-only marking

`TypeInfo` is now recorded per block but unused for scanning. Precise scanning
of blocks with known pointer maps would cut both false retention and mark time.

### 9. `ThreadGC` is never destroyed

The instance is `malloc`'d and `emplace`'d; `roots`/`ranges` leak at shutdown.
Harmless in practice, untidy.

### 10. Sanitizers still have not run — CI remains their first execution

Both runtimes are broken for D on the development machine (macOS 15.5 / arm64,
LDC 1.42). ASan deadlocks inside its own startup; TSan segfaults before `main`.
Both were confirmed against controls containing none of this project's code:

* a `printf("hello")` D program fails identically under each;
* the same program **in C**, built with clang, runs fine under both;
* even `-betterC` (no druntime at all) segfaults under TSan.

So the fault is in LDC's sanitizer support on this platform, not in tgc or in
druntime. The CI jobs target `ubuntu-latest` and will be the first real
execution.

Two concrete things were fixed while trying:

* **The CI sanitizer job could never have worked.** It passed `--dflags=...`
  to `dub test`, which dub rejects outright (`Unknown command line flags`). The
  flags now live in `unittest-tsan` / `unittest-asan` build types in `dub.sdl`,
  both verified to compile and link against the real sanitizer runtimes.
* **The audit a sanitizer would have done was done by hand**, which found a real
  data race — see below.

Expect the first CI sanitizer run to need tuning rather than to be green.

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