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

## Heap sizing — transfers, but not for the reason I assumed

BEAM tapers heap growth as heaps get larger. I assumed the benefit was memory
and that pause time was unaffected, on the grounds that a mark-sweep pause costs
time proportional to the *live set*. **That was wrong**, and measuring it is what
showed the error: clearing marks and sweeping both walk the whole heap, not just
the live part, so a bigger heap does lengthen every collection.

Measured on binary-trees depth 18, where the live set is identical in both:

| growth policy | time | heap | max pause |
|---|---|---|---|
| flat x4 | 2.82 s | 96 MB | 47.9 ms |
| tapered | 2.43 s | 48 MB | 25.1 ms |

The taper wins on all three axes. It is now the default: headroom is
`live * (factor - 1)`, capped at `max(32 MiB, live / 5)`, so small heaps get the
full multiplier and large ones converge on +20% — the same shape as BEAM's, for
a reason BEAM does not have to care about.

### A measurement caveat worth recording

Depth 20 results in this repository's history are unreliable. That configuration
reaches 448 MB with a flat multiplier, and the development machine was down to
~78 MB of free RAM with 13.8 GB of 14.3 GB swap in use, so those runs measure
paging rather than collector behaviour. Anything above roughly 100 MB of heap
needs re-measuring on a machine with headroom before it is quoted.

## Sources

- [Erlang Garbage Collector](https://www.erlang.org/doc/apps/erts/garbagecollection.html)
- [The BEAM Book — Memory](https://blog.stenmans.org/theBeamBook/#CH-Memory)
- [Erlang Memory Usage](https://www.erlang.org/doc/system/memory.html)
