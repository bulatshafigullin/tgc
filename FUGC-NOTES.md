# What tgc can learn from FUGC

Notes from reading [Fil's Unbelievable Garbage Collector](https://fil-c.org/fugc)
and [Safepoints and Fil-C](https://fil-c.org/safepoints), and what does and does
not transfer to a conservative collector for D.

FUGC is described as *parallel concurrent on-the-fly grey-stack Dijkstra accurate
non-moving*. Four of those words are the interesting ones for us.

---

## Already applied

### Right-sizing allocations — the biggest single win in this repo so far

FUGC is *accurate*: it knows object layouts, so it scans exactly the object.
That prompted a check of what tgc actually scans, and the answer was bad.

Any request between 8 KiB and 64 KiB fell straight through to a dedicated
chunk run, and both the reported size and the scanned range were the *whole
run*:

```
request   8193 -> GC.sizeOf   65408  (8.0x)
request   9000 -> GC.sizeOf   65408  (7.3x)
request  20000 -> GC.sizeOf   65408  (3.3x)
```

Every collection scanned 65 KiB per object, and every allocation zeroed it. HTTP
buffers live exactly in that range, so this hit the intended use case squarely.

Fixed by extending the size classes to 32 KiB — with the bigger classes served
from multi-unit chunks so a chunk still holds ≥8 slots — and by recording the
*requested* size for genuinely large blocks rather than the rounded-up run:

| | before | after |
|---|---|---|
| 9000-byte request | 65408 B (7.3x) | 10240 B (1.1x) |
| 4000 × 9000 B: memory | 249.6 MB | 39.1 MB |
| 4000 × 9000 B: collect | 62.3 ms | 7.6 ms |

General collection scaling is unchanged (256k live objects: 1.85 ms).

### Black allocation during collection

FUGC step 3 turns on black allocation before marking. tgc arrived at the same
thing independently, for the same reason: a finalizer running during the sweep
can be handed a slot the sweep has not reached yet, and would otherwise free the
object it just handed out.

### Honouring `free`

FUGC notes that a program converted naively to GC can *leak* because dangling
pointers the program never reads still look live, and that honouring `free` kills
them. tgc already reclaims eagerly on `GC.free`, so this one is covered.

---

## Applicable, not yet done

### Soft handshakes instead of stop-the-world

This is the most valuable idea for tgc. FUGC never stops the world; it uses
*soft handshakes* — the collector asks each thread to do something (typically
"scan your own stack") and each thread does it at its own next safepoint,
asynchronously. The only pause any thread sees is its own callback, bounded by
its own stack height.

tgc's global collection currently calls `thread_suspendAll`. Measured at 0.07 ms
it is not a crisis, but it scales with total live data across all threads and it
contradicts the project's headline claim more than it needs to.

The port is plausible because tgc already has a natural poll site that D
otherwise lacks: **allocation**. There are no compiler-emitted pollchecks in D,
but `alloc` already tests flags on every call, and a thread that is allocating is
exactly a thread whose roots need re-scanning.

Sketch: publish a handshake epoch; each thread, at its next allocation, scans its
own stack/TLS into a shared mark set and acknowledges. The collector waits for
all acknowledgements, then sweeps the orphan heap.

The catch FUGC solves with *enter/exit*: a thread blocked in a syscall never
reaches a safepoint, so the collector runs the callback on its behalf. druntime
has no such protocol — but a blocked thread's stack is quiescent, so a practical
hybrid is: soft-handshake with a deadline, then individually suspend only the
threads that did not answer. Most threads never pause; stragglers pause alone.

### Bitvector marks and SIMD sweep

FUGC spends under 5% of its time sweeping, thanks to bitvector marks over a
`verse_heap` layout. tgc stores a `uint flags` inside a 24-byte `SlotMeta` per
slot, so sweeping touches 24 bytes per slot to read one bit, and the metadata
itself is 150% overhead on a 16-byte slot (open item 4).

Moving `allocated`/`marked`/`shared` into per-chunk bitvectors would let the
sweep skip 64 slots with one word test, and shrink `SlotMeta` to the fields that
are actually per-object (`ti`, `usedSize`, `attr`). Both problems, one change.

### Parallel marking

FUGC marks in parallel across cores. tgc's *thread-local* collections are already
parallel in the sense that matters — each thread collects its own heap
independently — but the global collection is single-threaded. Low priority while
it stays at 0.07 ms.

---

## Does not transfer, and it is worth being precise about why

### The Dijkstra store barrier — and therefore concurrent marking

FUGC is concurrent: mutators keep running during marking. That is only sound
because of the *store barrier*, which shades the target of every pointer store
so a mutator cannot hide a reachable object behind an already-marked one.

**D has no write barrier and cannot get one without compiler support.** Adding
one would mean instrumenting every pointer store in the language, which is a
compiler change, a codegen cost on all D code, and out of scope for a GC that is
meant to be selectable at runtime.

Consequences, in order of importance:

1. **tgc cannot mark concurrently with mutation.** Any global marking phase must
   stop the mutators — via `thread_suspendAll` today, or via soft handshakes
   later, but stopped either way. FUGC's on-the-fly property is not reachable.
2. **The escape-promotion hole cannot be closed.** `CROSS-THREAD.md` records that
   promotion is *sampled*: a block published to a global, picked up by another
   thread, and unpublished between two collections is never observed. A store
   barrier is exactly what would catch that publication at the moment it
   happens. Without one it stays a documented limitation.

Note what tgc gets in exchange, which FUGC does not need: because each heap is
private to one thread, a *thread-local* collection has no concurrent mutator at
all. The collecting thread is the only mutator of that heap, so no barrier is
required for the common case. That is the actual trade the design makes, and it
is worth stating that way rather than as "tgc is not concurrent".

### Grey-stack rescan-to-fixpoint

FUGC rescans stacks to a fixpoint so it can avoid a *load* barrier. It is a
consequence of being concurrent; with mutators stopped there is nothing to
rescan. Only relevant to tgc if the soft-handshake design above lands, and even
then only for the window between handshakes.

### Accurate (precise) marking

FUGC knows object layouts and scans exactly the pointers. tgc is conservative:
it scans every aligned word and treats anything that resolves to a block as a
reference. That costs false retention and scan time, but it is what allows tgc to
work with unmodified D code and an unmodified compiler.

`TypeInfo` is already recorded per block, so precise scanning of blocks with
known pointer maps is a possible future refinement (open item 8) — but it is a
refinement, not the FUGC design.

---

## Summary

| FUGC property | tgc |
|---|---|
| Accurate scanning | no — conservative; drove the right-sizing fix above |
| Non-moving | same |
| Black allocation | same, arrived at independently |
| Parallel marking | per-thread by construction; global collection is serial |
| Concurrent / on-the-fly | **not reachable** — needs a store barrier D lacks |
| Soft handshakes | **portable**, and the best remaining idea; `alloc` is the poll site |
| Bitvector SIMD sweep | **portable**, and would fix the metadata overhead too |
| Honours `free` | same |

The one structural thing FUGC has that tgc cannot get is the store barrier, and
almost everything else that distinguishes FUGC follows from it. What remains
portable — soft handshakes and bitvector sweeping — is worth doing, and neither
requires a language change.

## Sources

- [Fil's Unbelievable Garbage Collector](https://fil-c.org/fugc)
- [Safepoints and Fil-C](https://fil-c.org/safepoints)
- [Fil-C](https://fil-c.org/)
