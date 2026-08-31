# binary-trees benchmark

## Running them

```
bench/run.sh                # depth 18, best of 3, all three variants
bench/run.sh -d 16 -r 1     # quicker
bench/run.sh -b bintree     # one variant
```

Two probes sit outside the driver, because what they measure is not wall time:
`bench/webserver_probe.d` (`--config=bench-webserver`) for collection time
against live set and against suspended fibers, and `bench/trim_probe.d`
(`--config=bench-trim`) for whether a shrunken heap gives its memory back.

Each variant is a dub configuration (`bench-bintree`, `bench-mt`,
`bench-region`) that links tgc in, so the collector is chosen at runtime with
`--DRT-gcopt=gc:` and both columns of a comparison run the same binary. The
driver reports wall time (the parallel section, where the benchmark times one),
collections, total pause and max pause.

> **The Linux/x86-64 tables below predate the mark-and-sweep optimization pass**
> and describe the collector as it was before it. The pass was measured on both
> platforms afterwards, before and after, and is reported in the last two
> sections.

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


## Mark and sweep optimization pass — macOS/arm64

Measured on macOS/arm64 -- Apple M1 Pro, LDC 1.42.0, `-O2 -release`, best of 3,
before and after on the same machine in the same session. These are not
comparable to the Linux figures above, only to each other.

The starting point was the profile: on this machine `ThreadHeap.freeSlot` was
the single hottest routine in the collector, ahead of `markPtr`, at about 23% of
samples. That is not what the Linux `perf` run had said -- it put the sweep at
2.6% -- and the difference turned out to be real rather than a profiling
artifact: the same change is worth far less on x86-64. Both platforms are
reported, and the next section is the one to read for x86-64.

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

## Mark and sweep optimization pass — Linux/x86-64

Same box as the tables at the top -- AMD EPYC 9645, 8 cores with roughly one
already busy, Debian 13, LDC 1.42.0, `-O2 -release`. Before and after were run
*interleaved*, alternating the two binaries so that drift in machine load hits
both equally, best of 5. The pre-change column reproduces the published figures
above to within a few percent (binary-trees depth 18: 4.844 s here against
5.183 s there), so the two are comparable.

### At a matched 300 MB budget (`bintree_mt 18 1`)

| | collections | total pause | max pause | parallel section |
|---|---|---|---|---|
| conservative | 7 | 122.0 ms | 39.45 ms | 1.667 s |
| tgc, before | 7 | 750.5 ms | 135.68 ms | 2.570 s |
| **tgc, after** | 7 | **344.2 ms** | **59.34 ms** | **1.986 s** |

This is the number that matters: on the same live set and the same seven
collections, tgc's pause per collection went from about **6x** the default
collector's to about **2.8x**, and its worst pause from 3.4x to 1.5x.

### Everything else

| | wall | collections | total pause | max pause |
|---|---|---|---|---|
| bintree d18, conservative | 1.834 s | 7 | 130.3 ms | 33.41 ms |
| bintree d18, tgc before | 4.844 s | 64 | 2876.9 ms | 72.17 ms |
| bintree d18, tgc after | **4.267 s** | 64 | **2379.4 ms** | **65.76 ms** |
| mt d18 x4, tgc before | 1.636 s | 26 | 2145.3 ms | 134.47 ms |
| mt d18 x4, tgc after | **1.431 s** | 26 | **1005.9 ms** | **69.04 ms** |
| region d18 x4, before | 1.650 s | 5 | 99.1 ms | 51.60 ms |
| region d18 x4, after | **1.537 s** | 5 | **68.2 ms** | **35.33 ms** |

### Why the two platforms disagree by so much

At a matched budget the pause win is 21x on arm64 and 2.2x on x86-64, and the
reason is visible in `perf`: before the change the sweep was 2.8% of runtime on
x86-64 (`freeSlot`) plus part of `collectHeap`'s 5.6%, against roughly 23% of
samples on arm64. The per-object metadata stores that the bulk sweep removes are
simply much cheaper on this machine.

Where the time goes now, binary-trees depth 18 (`perf`, self time):

| | before | after |
|---|---|---|
| marking (`drainMarkStack` + `markPtr` + `lookup`) | 41.5% | 45.4% |
| allocation (`allocSlot` + `alloc`) | 12.3% | 13.0% |
| sweep (`freeSlot` + `collectHeap`) | 8.4% | below 1.5%, unlisted |
| kernel page management | 6.6% | 8.2% |

Marking grew as a *share* because everything around it got cheaper; in absolute
terms it is unchanged, which is the point of the next section.

## Segment-backed chunks — Linux/x86-64

Same box and the same interleaved method, best of 5. "before" here is the state
after the mark-and-sweep pass above, so this section measures the allocator
change alone.

The pass above left tgc at about 2.8x the default collector's cost per
collection, all of it in the mark phase. Counting *why* is what found this: at a
matched budget tgc executed the same instructions and missed cache 45% *less*,
yet spent 27% more cycles, with 6.3x the dTLB misses. `smaps_rollup` gave the
answer -- druntime maps its pool in one piece and the kernel backs 76 MB of it
with huge pages, while tgc's per-chunk `posix_memalign` heap got **zero**.

### At a matched 300 MB budget (`bintree_mt 18 1`)

| | collections | total pause | max pause | parallel section |
|---|---|---|---|---|
| conservative | 7 | 124.1 ms | 30.05 ms | 1.824 s |
| tgc, before | 7 | 374.4 ms | 70.81 ms | 2.279 s |
| **tgc, after** | 7 | **38.4 ms** | **10.33 ms** | **1.548 s** |

On the same live set and the same seven collections, tgc now spends **a third**
of the default collector's pause rather than three times it, and a third of its
worst pause. It is also faster in wall time on the single-threaded benchmark
that has been its worst case throughout.

Counters for that run:

| | before | after | conservative |
|---|---|---|---|
| cycles | 7.42 G | 5.05 G | 6.54 G |
| instructions | 20.18 G | 16.75 G | 19.80 G |
| IPC | 2.72 | 3.32 | 3.03 |
| page faults | 925,821 | **209,676** | 42,337 |
| dTLB load misses | 6.67 M | **4.16 M** | 1.05 M |
| `AnonHugePages` | 0 | ~154 MB | ~76 MB |
| peak RSS | 606 MB | **541 MB** | 314 MB |

Peak RSS falls rather than rises: the allocator reuses chunks instead of handing
them to the kernel and faulting them back in.

### Everything else

| | wall | collections | total pause | max pause |
|---|---|---|---|---|
| bintree d18, conservative | 1.983 s | 7 | 134.7 ms | 39.32 ms |
| bintree d18, tgc before | 4.516 s | 64 | 2500.4 ms | 64.44 ms |
| bintree d18, tgc after | **3.256 s** | 64 | **2038.3 ms** | 56.93 ms |
| mt d18 x4, conservative | 5.439 s | 8 | 778.4 ms | 153.58 ms |
| mt d18 x4, tgc before | 2.320 s | 27 | 1127.7 ms | 91.07 ms |
| mt d18 x4, tgc after | **0.649 s** | 27 | **124.7 ms** | **24.46 ms** |
| region d18 x4, before | 2.120 s | 5 | 78.1 ms | 40.81 ms |
| region d18 x4, after | **0.364 s** | 5 | 67.0 ms | 31.13 ms |

The region benchmark gains most because it is the one that churns chunks
hardest: every region close frees a whole set of them at once.

macOS/arm64 is unchanged in either direction -- 1.42 s and 550 ms of pause on
`bintree 18` before and after -- which is the expected answer where there are no
transparent huge pages to get.

## Returning memory — macOS/arm64

`bench/trim_probe.d` (`dub build --config=bench-trim`, then
`./bench-trim --DRT-gcopt=gc:tgc`). Two million 32-byte objects, 95% of them
dropped, then collections spaced out past the trim's window. `--ratio=0` is the
old behaviour: memory came back only from `GC.minimize()`.

Apple M-series, LDC 1.42.0, `-O2 -release`. *Footprint* is the kernel's ledger,
which is what Activity Monitor shows and what memory limits are enforced
against; RSS is reported too because it is the number people reach for first and
on macOS it is the wrong one — `MADV_FREE_REUSABLE` leaves pages resident until
the system wants them, so only munmap moves RSS.

| after the drop | committed | RSS | footprint |
|---|---|---|---|
| at peak | 128.0 MB | 111.9 MB | 110.9 MB |
| `--ratio=0`, any number of collections | 128.0 MB | 111.9 MB | 110.9 MB |
| default, 1st collection | 128.0 MB | 111.9 MB | 110.9 MB |
| default, 2nd collection | 22.0 MB | 66.2 MB | 23.2 MB |
| then `GC.minimize()` | 22.0 MB | 34.2 MB | 23.2 MB |

The first collection returning nothing is the hysteresis working: the window in
which the peak was still standing had not closed yet. `GC.minimize()` still
finds 32 MB of RSS to unmap afterwards, because it ignores the one-segment
floor the automatic path keeps.

`--scatter` keeps every twentieth object instead of the first 5%, so a survivor
sits in every chunk. Nothing is returned, and nothing should be: the chunks are
genuinely in use. That is fragmentation, not retention.

Cost, on the benchmarks above rather than on the probe — the probe's own pause
column is noise once collections are seconds apart:

| | total pause, before | after |
|---|---|---|
| `bintree 18` | 558 ms | 543 ms |
| `bintree_mt 18 4` (parallel section) | 51–60 ms | 44–47 ms |
| `bintree_region 18 4` | 18.6 ms | 18.6 ms |
| `bench-webserver`, 256k live | 1.15 ms | 1.16 ms |

Two earlier formulations of the trigger did cost time, and are recorded in
`segTrim` and `IMPROVEMENTS.md` because the failure is not obvious: judging on
what the heap holds at the end of a collection reads it at its trough and cost
7% of pause on `bintree`, and judging on the peak since the last collection cost
2.8x on `bintree_mt 18 4`, because every thread's collection resets the window.

### `GC.reserve`

| | build the 128 MB peak |
|---|---|
| no reserve | 35 ms |
| after `GC.reserve(256 MB)` | 29 ms |

The reservation itself costs 16 ms and touches all 256 MB, which is more than
this workload goes on to use. It is a latency trade, not a throughput one.

## What is left

Marking is still the top cost, and it is now most of what the collector does:
the sweep is off the profile and the allocator is no longer faulting pages in a
loop. What remains is the conservative scan itself and the cache misses
inherent in chasing pointers through a heap. See `IMPROVEMENTS.md` for the
explanations already tested and rejected -- four before these two passes, six
now.
