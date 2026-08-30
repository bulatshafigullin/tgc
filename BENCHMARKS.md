# binary-trees benchmark

Measured on an unloaded Linux/x86-64 box — AMD EPYC 9645, 8 cores available,
Debian 13, LDC 1.42.0, `-O2 -release`. One binary per benchmark with tgc linked
in; the collector is chosen at runtime via `--DRT-gcopt=gc:`, so both columns
run identical code. Output is byte-identical under both collectors.

Earlier figures taken on the development Mac are not comparable and some were
taken while that machine was swapping; these supersede them.

## Single-threaded (`bintree.d`)

Best of 5.

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

The kernel share is a finding in its own right: `releaseChunk` returns empty
64 KiB chunks to the allocator during every sweep, and the next allocation
faults them back in and has them zeroed. A small cache of free chunks would
remove most of it — a bounded change worth doing before anything harder.

## Multi-threaded (`bintree_mt.d`)

Depth 18, parallel section only, best of 3.

| workers | conservative | tgc | |
|---|---|---|---|
| 1 | 1.693 s | 3.139 s | tgc 0.5× |
| 2 | 5.960 s | 2.087 s | **2.9×** |
| 4 | 15.158 s | 1.324 s | **11.4×** |
| 8 | 10.259 s | 3.148 s | 3.3× |

The default collector gets *worse* as threads are added — 1.7 s to 15.2 s from
one worker to four — because every collection stops every thread. tgc improves
with each worker up to 4.

Treat the 8-worker row with suspicion: the box has 8 cores with roughly one
already busy, so eight workers oversubscribe it, and the conservative figure
moving *down* from 4 to 8 workers is a sign the run is scheduling-bound rather
than measuring the collector.

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
