# binary-trees benchmark

## Running them

```
bench/run.sh                # depth 18, best of 3, all three variants
bench/run.sh -d 16 -r 1     # quicker
bench/run.sh -b bintree     # one variant
```

Each variant is a dub configuration (`bench-bintree`, `bench-mt`,
`bench-region`) that links tgc in, so the collector is chosen at runtime with
`--DRT-gcopt=gc:` and both columns of a comparison run the same binary. The
driver reports wall time (the parallel section, where the benchmark times one),
collections, total pause and max pause.

> **The Linux/x86-64 tables below predate the mark-and-sweep optimization pass**
> described in the last section, and describe the collector as it was before it.
> They need re-running on that box. The optimization pass itself was measured on
> macOS/arm64, before and after, and is reported separately.

## Baseline (pre-optimization)

Measured on an unloaded Linux/x86-64 box — AMD EPYC 9645, 8 cores available,
Debian 13, LDC 1.42.0, `-O2 -release`. One binary per benchmark with tgc linked
in; the collector is chosen at runtime via `--DRT-gcopt=gc:`, so both columns
run identical code. Output is byte-identical under both collectors.

Earlier figures taken on the development Mac are not comparable and some were
taken while that machine was swapping; these supersede them.

## Single-threaded (`bintree.d`)

Best of 5. Here the default collector gets its 300 MB pool from
`minPoolSize:300` and tgc sizes from live data — the mismatch is the point of
the analysis below. `bintree_mt.d` matches the budgets instead.

| depth | conservative | tgc | |
|---|---|---|---|
| 16 | 0.432 s | 0.917 s | tgc 2.1× slower |
| 18 | 1.873 s | 5.183 s | tgc 2.8× slower |
| 20 | 10.958 s | 23.116 s | tgc 2.1× slower |

tgc loses, and the reason splits in two. At depth 18:

| | collections | total pause | max pause | heap |
|---|---|---|---|---|
| conservative | 7 | 138 ms | 36.8 ms | 300 MB |
| tgc | 64 | 2939 ms | 72.7 ms | **74 MB** |

**Sizing.** `bintree.d` sets `gcopt=minPoolSize:300`, which hands the default
collector a 300 MB heap up front; it collects 7 times. tgc sizes from live data
and runs in a quarter of the memory, so it collects 64 times. Giving tgc
comparable headroom (growth factor 18, cap removed) brings it to 10 collections
and 3.75 s in 124 MB — so roughly **1.4× of the gap is heap sizing policy**.

**Mark speed.** The remaining ~2× is not policy. At a comparable collection
count tgc still spends 1217 ms against 138 ms — about **6× more expensive per
collection on an identical live set**. That is the real gap.

Where tgc's time goes (`perf`, depth 18):

| | share |
|---|---|
| marking (`drainMarkStack` + `markPtr` + `lookup`) | 38.7% |
| allocation (`allocSlot` + `alloc`) | 16.9% |
| **kernel page management** (`clear_page_erms`, `folio_*`) | **7.8%** |
| sweep (`freeSlot`) | 2.6% |
| the benchmark itself (`Node.check` + `Node.create`) | 4.4% |

The kernel share looked like chunk churn — `releaseChunk` returning empty
64 KiB chunks each sweep, the next allocation faulting them back in. It is not.
A 16-chunk-per-thread cache, wired into region teardown as well, changed the
binary-trees figure by 0.2% and the region benchmark by nothing, despite a 65%
hit rate. Chunk allocation is not expensive at these rates; the page time comes
from faulting in the heap as it grows to its steady size, which caching cannot
avoid. The experiment was reverted — see `IMPROVEMENTS.md`.

## Multi-threaded (`bintree_mt.d`)

Both collectors are given the same **300 MB total heap budget**, so the
comparison is about the collectors rather than about how much memory each
decided to use. `minPoolSize:300` configures the default collector;
`tgcMinHeap(300 MB / workers)` is the equivalent for tgc, divided because tgc's
heaps are per thread.

Depth 18, parallel section only, best of 3.

| workers | conservative | tgc | |
|---|---|---|---|
| 1 | 1.820 s | 2.979 s | tgc 0.6× |
| 2 | 5.265 s | 2.120 s | **2.5×** |
| 4 | 11.524 s | **1.689 s** | **6.8×** |

At four workers:

| | collections | total pause | max pause |
|---|---|---|---|
| conservative | 8 | 418 ms | 88.5 ms |
| tgc | 27 | 1847 ms | 86.2 ms |

Giving tgc a comparable budget is worth a great deal: it collected **4983 times**
when sized from live data and **27 times** with the budget, and its four-worker
time improved from 2.171 s to 1.689 s. Max pause is now level with the default
collector's rather than better, which is the expected trade — a larger heap
means fewer but longer collections.

The default collector still gets *worse* as threads are added, 1.8 s to 11.5 s
between one and four workers, because every collection stops every thread. That
is the effect tgc exists to remove, and matching the memory budget does not
change it.

Numbers above 4 workers are omitted deliberately: the box has 8 cores with
roughly one already busy, so eight workers oversubscribe it and the results
measure scheduling rather than the collector.

## With fiber regions (`bintree_region.d`)

The third variant runs each job inside a fiber-scoped region, so a job's trees
are released wholesale when it finishes instead of being proved dead. That maps
the benchmark onto a server's shape: a job is a request, the only things
outliving it are the checksum (an `int`, copied out by value) and each worker's
long-lived tree, allocated deliberately *before* any region is opened.

`--verify` turns on `tgcRegionVerify`, which asserts at every close that nothing
outside still points in. The benchmark passes it, so the invariant is checked
rather than assumed.

Depth 18, parallel section, best of 3. Same binary; `--no-region` runs the
identical workload without regions.

| workers | conservative | tgc | tgc + regions |
|---|---|---|---|
| 1 | 2.107 s | 3.643 s | 2.877 s |
| 2 | 5.356 s | 2.335 s | 2.200 s |
| 4 | 9.293 s | 2.171 s | **2.002 s** |

The timing gain from regions is modest — 8% at four workers — because at that
point the workload is allocation-bound rather than collection-bound. What
regions change is the collector's involvement, and that is not modest:

| 4 workers | collections | total pause | max pause | heap |
|---|---|---|---|---|
| conservative | 8 | 572 ms | 118.5 ms | 300 MB |
| tgc | 4983 | 3164 ms | 76.2 ms | 25 MB |
| **tgc + regions** | **5** | **89.6 ms** | **50.3 ms** | 25 MB |

Regions take tgc from 4983 collections to 5, and total pause from 3164 ms to
90 ms — a 35× reduction — in the same 25 MB, which is a twelfth of what the
default collector uses. The lowest max pause of the three is tgc with regions,
at 50 ms against the default collector's 118 ms.

That is the combination the design is aiming at: request-scoped memory never
enters the mark phase at all, so the only collections left are the ones that
handle genuinely long-lived data.

## What this says

The single-threaded case is tgc's worst: with one thread there is no world to
stop, so a private heap buys nothing while conservative marking still costs
more. That it loses by 2× there is expected; that its mark is 6× slower per
collection is not, and is the clearest optimization target the project has.

The multi-threaded case is what tgc exists for, and the shape is what the design
predicts: flat-to-improving where the default collector degrades superlinearly.

Regions are what make the collector nearly disappear from the request path. They
do not fix the mark speed — they avoid needing it. Both are worth having: the
6× per-collection gap still governs whatever long-lived data a real program
keeps, which regions by definition cannot cover.


## Mark and sweep optimization pass

Measured on macOS/arm64 -- Apple M1 Pro, LDC 1.42.0, `-O2 -release`, best of 3,
before and after on the same machine in the same session. These are not
comparable to the Linux figures above, only to each other.

The starting point was the profile: on this machine `ThreadHeap.freeSlot` was
the single hottest routine in the collector, ahead of `markPtr`. That was not
what the Linux `perf` run had said (it put the sweep at 2.6%), and it is the
reason the changes below are weighted the way they are. **The x86-64 half of
this is therefore unverified**: the sweep may simply be cheaper there, in which
case the win will be smaller.

### At a matched 300 MB budget (`bintree_mt 18 1`)

The comparison the collector should be judged on: same heap budget, same live
set, same collection count, one thread.

| | collections | total pause | max pause | parallel section |
|---|---|---|---|---|
| conservative | 7 | 31.1 ms | 6.77 ms | 1.205 s |
| tgc, before | 7 | 435.6 ms | 74.03 ms | 1.330 s |
| **tgc, after** | 7 | **20.4 ms** | **4.07 ms** | **0.823 s** |

Total pause fell 21x, and per collection tgc is now *below* the default
collector on the same live set rather than 14x above it. The earlier conclusion
-- "about 6x more expensive per collection" -- was mostly the sweep, not the
mark.

### Four workers (`bintree_mt 18 4`)

| | collections | total pause | max pause | parallel section |
|---|---|---|---|---|
| conservative | 8 | 110.0 ms | 23.61 ms | 3.498 s |
| tgc, before | 25 | 478.6 ms | 21.12 ms | 0.354 s |
| **tgc, after** | 25 | **66.6 ms** | **4.93 ms** | **0.252 s** |

### Sized from live data (`bintree 18`)

tgc's worst case, kept for continuity with the tables above: one thread, no
world to stop, and a quarter of the memory, so it collects 64 times against
seven.

| | collections | total pause | max pause | wall |
|---|---|---|---|---|
| conservative (300 MB pool) | 7 | 30.7 ms | 6.69 ms | 1.303 s |
| tgc, before (74 MB) | 64 | 1060.2 ms | 27.69 ms | 1.945 s |
| **tgc, after (74 MB)** | 64 | **551.1 ms** | **15.11 ms** | **1.425 s** |

tgc is now 1.09x the default collector on the benchmark that suits it least,
down from 1.48x.

### With regions (`bintree_region 18 4`)

| | collections | total pause | max pause | parallel section |
|---|---|---|---|---|
| no regions, before | 4985 | 929.3 ms | 16.43 ms | 0.447 s |
| no regions, after | 4985 | 372.3 ms | 8.04 ms | 0.300 s |
| regions, before | 5 | 28.6 ms | 17.01 ms | 0.268 s |
| **regions, after** | 5 | **18.3 ms** | **8.15 ms** | **0.254 s** |

Regions still take the collector nearly out of the request path; what changed is
that the path they avoid is now much cheaper too, so the gap between "with" and
"without" narrowed from 32x of total pause to 20x.

### What is left

Marking is now unambiguously the top cost -- `markPtr`, `lookup` and
`drainMarkStack` together are about a third of runtime on binary-trees, against
a sweep that has all but vanished from the profile. What remains there is the
conservative scan itself and the cache misses inherent in chasing pointers
through a heap, not the data structure around it. See `IMPROVEMENTS.md` for the
four explanations already tested and rejected, now six.
