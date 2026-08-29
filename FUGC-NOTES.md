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

### Bitvector marks

FUGC spends under 5% of its time sweeping because its marks are bitvectors it
can scan with SIMD. tgc kept `allocated`/`marked`/`shared` inside a 24-byte
`SlotMeta` per slot, so clearing every mark meant a read-modify-write across all
of it, and the sweep touched 24 bytes to read one bit.

Those three states now live in per-chunk bitvectors and attributes in a byte
array. Clearing marks is a `memset` over n/8 bytes; the sweep tests
`allocated & ~marked & ~shared` 64 slots per word, so mostly-live and
mostly-free chunks are skipped in a few instructions.

| arena bytes per object | before | after |
|---|---|---|
| 16-byte objects | 48.50 | 41.94 |
| 32-byte objects | 64.55 | 58.00 |
| 64-byte objects | 96.67 | 90.11 |

Per-slot metadata fell from 24 bytes to 17.375. Collection *time* is unchanged
(256k live objects: 1.83 ms), which is itself informative: phase timing shows
marking dominates at roughly 90%, and sweeping was already only about 4%. The
SIMD-sweep win FUGC reports does not transfer to a collector whose bottleneck is
conservative marking — the payoff here is density, not speed.

## Not portable, and it is worth being precise about why

### Soft handshakes — this corrects an earlier claim in this document

An earlier draft listed soft handshakes as "the most valuable idea for tgc" and
sketched an implementation. That was wrong, and in tension with this document's
own conclusion about the store barrier two sections down.

A soft handshake lets each thread scan its own roots *at its own convenience*,
which means mutators keep running between one thread's scan and another's. That
is only sound because FUGC has a Dijkstra store barrier catching a mutator that
moves a reference from an unscanned location into an already-scanned one.

Without a barrier the hole is concrete. Thread A handshakes and is marked done.
A then reads orphan block `O` out of global `G` onto its stack and clears `G`.
The collector scans globals afterwards, finds nothing, and frees `O` while A is
using it. Rescanning stacks to a fixpoint does not save it either: A can drop
`O` from its stack into an already-scanned heap object.

So handshake-based marking requires the barrier, exactly as concurrent marking
does. What remains possible is a *ragged stop* — ask threads to park themselves
at their next allocation instead of signalling them — but every thread still has
to be stopped simultaneously for the mark, so it is not a soft handshake, and
threads that park early wait longer than they do under `thread_suspendAll`. For
a fibre server where many threads are blocked on I/O and never reach an
allocation, the suspend fallback would dominate and there would be no benefit at
all.

`thread_suspendAll` at a measured 0.07 ms stays.

## Also not yet done

### Parallel marking

FUGC marks in parallel across cores. tgc's *thread-local* collections are already
parallel in the sense that matters — each thread collects its own heap
independently — but the global collection is single-threaded. Low priority while
it stays at 0.07 ms.

---

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
| Soft handshakes | **not portable** — needs the same store barrier |
| Bitvector marks | **ported**; density win, not a speed win here |
| Honours `free` | same |

The one structural thing FUGC has that tgc cannot get is the store barrier, and
almost everything else that distinguishes FUGC follows from it — concurrency,
on-the-fly collection, and soft handshakes all rest on it. What did transfer was
the part that needs no barrier at all: scanning objects for what they are rather
than for the space they occupy, and keeping mark state in bitvectors.

## Sources

- [Fil's Unbelievable Garbage Collector](https://fil-c.org/fugc)
- [Safepoints and Fil-C](https://fil-c.org/safepoints)
- [Fil-C](https://fil-c.org/)
