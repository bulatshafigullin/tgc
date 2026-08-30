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

## What this says

The single-threaded case is tgc's worst: with one thread there is no world to
stop, so a private heap buys nothing while conservative marking still costs
more. That it loses by 2× there is expected; that its mark is 6× slower per
collection is not, and is the clearest optimization target the project has.

The multi-threaded case is what tgc exists for, and the shape is what the design
predicts: flat-to-improving where the default collector degrades superlinearly.
