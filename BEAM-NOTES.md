# What tgc can learn from the BEAM (Erlang VM)

The BEAM is the production proof of per-heap-per-lightweight-process collection,
so it is the right thing to compare against for the fiber-as-arena idea. Notes
from the [Erlang GC documentation](https://www.erlang.org/doc/apps/erts/garbagecollection.html)
and [The BEAM Book](https://blog.stenmans.org/theBeamBook/#CH-Memory).

## What BEAM actually does

* Each process has a **private heap and stack** in one block, growing toward
  each other. A process GC never touches another process.
* The collector is **copying and generational**: a Cheney-style scan with a
  *high-water mark* separating young from old. Data below the mark is copied to
  an old heap and thereafter ignored by minor collections.
* **Process death frees the block wholesale.** No tracing, no sweep.
* **Messages are deep-copied** between process heaps on send.
* Binaries over 64 bytes live in a **shared, reference-counted binary heap**,
  with a small wrapper on the process heap and an MSO list woven through it to
  decrement refcounts after collection.
* Heaps grow along a Fibonacci-ish sequence from 233 words, then in 20%
  increments above roughly a megaword; they shrink when live data is under 25%.

## The one thing that makes it work

**Copying on send is the enforcement mechanism.** BEAM can free a dead process's
heap without looking at it because nothing outside can point into it, and
nothing can point in because every message is deep-copied and every term is
immutable.

That is the guarantee tgc does not have and cannot get from D. Which means the
fiber-as-arena idea is sound *as an architecture* and unsound *as an automatic
policy* — the difference is entirely whether escapes are prevented or merely
hoped for.

## What transfers

### Copy-out, not escape-detection

Last time I proposed catching escapes with a debug verifier. BEAM suggests a
better answer: don't detect escapes, *make the sanctioned exit copy*. A region
API should ship with an explicit `copyOut` that deep-copies a value from the
region into the owning thread's heap, and documentation that says anything
surviving the region must go through it. That is BEAM's send, by hand.

The verifier is still worth having, but as a test-time check on the discipline
rather than as the primary mechanism.

### A sanctioned home for things that must be shared

BEAM's refcounted binary heap exists because copying is the wrong answer for
large payloads. tgc has the same problem — a response body should not be copied
out of a request region — and already has most of the machinery: the orphan heap
is a thread-independent arena that no thread-local collection sweeps.

An explicit "shared block" allocation that lands there, outliving any region, is
the natural analogue and is much less work than it sounds.

### Nothing else, and it is worth being precise about why

**Generational collection does not transfer.** BEAM gets it almost free: terms
are immutable, so an old object can never point to a young one, and no write
barrier is needed. D has mutable data, so a generational tgc needs exactly the
barrier that is also missing for concurrent marking. Same wall as FUGC.

**Copying/compaction does not transfer.** It requires knowing precisely which
words are pointers. tgc is conservative by design, so it cannot move anything.

## Heap sizing — transfers, but far less aggressively than BEAM

BEAM tapers heap growth as heaps get larger. Two things came out of trying to
copy that, and both were corrections.

**First correction.** When the growth factor was introduced I claimed headroom
could not lengthen a pause, because a mark-sweep pause costs time proportional
to the *live set*. That is wrong: clearing marks and sweeping both walk the whole
heap rather than just the live part, so a bigger heap lengthens every collection.

**Second correction.** BEAM's actual numbers — Fibonacci growth, then +20% —
do not transfer, because BEAM's per-process heaps are kilobytes and copying a
tiny live set is cheap. tgc's heaps are whole threads. A +20% cap was measured
at 296 collections on a 67 MB live set where a looser cap needed 76.

Measured on binary-trees, single-threaded, on an unloaded machine:

| policy | d18 time | d18 heap | d18 max pause | d20 time | d20 heap | d20 max pause |
|---|---|---|---|---|---|---|
| flat x4 | 2.82 s | 96 MB | 47.9 ms | 9.39 s | 448 MB | 126.8 ms |
| flat x3 | 2.28 s | 32 MB | 47.5 ms | 10.11 s | 256 MB | 133.8 ms |
| cap at +20% | 2.43 s | 48 MB | 25.1 ms | 19.31 s | 128 MB | 74.0 ms |
| **cap at live x2** | **2.25 s** | 48 MB | **23.8 ms** | **10.74 s** | **128 MB** | **110.7 ms** |

The last row is the default: headroom is `live * (factor - 1)` capped at
`max(32 MiB, live * 2)`, so the effective multiplier decays from 4 toward 3 as
the heap grows. Against a flat x3 it halves the heap at depth 20 (128 MB against
256 MB) and cuts max pause, for about 6% throughput. Against flat x4 it uses a
quarter of the memory with a lower max pause.

The shape of BEAM's idea survives; its constants do not.

## Sources

- [Erlang Garbage Collector](https://www.erlang.org/doc/apps/erts/garbagecollection.html)
- [The BEAM Book — Memory](https://blog.stenmans.org/theBeamBook/#CH-Memory)
- [Erlang Memory Usage](https://www.erlang.org/doc/system/memory.html)
