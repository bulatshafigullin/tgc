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
> **Phase 0 is done**: a dying thread's arenas are retained rather than
> finalized and freed, which closes the `join()` use-after-free. Phases 1 and 2
> (sticky promotion on global reachability, then cooperative global collection)
> remain open, and are what the rest of this item is about.

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

### 2. Dead threads' memory is never reclaimed (Phase 0's accepted cost)

Adopted arenas are retained until the process exits and their objects are never
finalized. Fine for a fixed worker pool; bad for a program that spawns many
short-lived threads, where it is an unbounded leak. Phase 2's cooperative global
collection is what makes those arenas reclaimable — until then this is a real
constraint on which programs should select tgc.

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

### 10. Sanitizers have never actually run — CI will be their first execution

The ASan and TSan jobs are wired up and target `ubuntu-latest`, but **neither
has been run successfully**, because both sanitizer runtimes are broken on the
development machine (macOS 15.5 / arm64, LDC 1.42):

* ASan deadlocks during its own startup, before `main`. A sampled stack shows
  `AsanInitInternal` → `InitializeShadowMemory` → `MemoryRangeIsAvailable` →
  `get_dyld_hdr` → recursive `malloc` → spin on ASan's init mutex.
* TSan segfaults on startup.

Both were confirmed with a `printf("hello")` control program containing none of
this project's code, so the failures are in the sanitizer runtimes, not in tgc.

Two changes were made in anticipation of the Linux runs, and both are correct
regardless: the mark routines carry `@noSanitize("address")` (conservative
scanning reads padding, redzones and quarantined memory *by design*, so those
reads are not bugs), and the test suite scales its iteration counts down under
`version(TgcSanitize)`.

Treat the first CI sanitizer run as an experiment that will probably need
tuning, not as a green check that already passed.

Local memory-safety confidence instead comes from `test/tgc_stress.d`, which
gives every block a checkable fill pattern and hammers size-class edges, the
small/large chunk transition, chunk release and reuse, explicit free, realloc
across boundaries, concurrent churn, and repeated thread creation/teardown.
Two real bugs were found and fixed by review and testing during this work:

* a use-after-free in the sweep — freeing the single slot of a large chunk
  releases the chunk, after which the loop was still reading `c.slotCount` and
  `c.freeCount` out of the freed header;
* a finalizer that allocates could be handed a slot from the chunk currently
  being swept, at an index the sweep had not yet reached, and the sweep would
  then immediately free the object it had just handed out. Fixed by allocating
  black while a collection is in flight.
