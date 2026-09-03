# vibe.d benchmark: tgc, tgc with per-request regions, and the default collector

A real web framework rather than binary-trees, because that is what this
collector is aimed at. vibe.d is fiber-per-request, so a collection has to
enumerate and scan hundreds of suspended stacks, and a request is served
entirely on the thread that accepted it, which is the shape thread-private heaps
assume — and a fiber is also what a region binds to, so the framework offers the
region API its natural unit of work.

```
dub build --build=release          # in this directory
./run.sh                           # /work, 4 threads, 30s, both collectors
./run.sh -R                        # add a third column: tgc with regions
./run.sh -d 15 -N 3 -k 100000      # shorter, 3 reps, a large live set
./run.sh -m 8                      # put tgc on a matched memory budget
```

All columns are the same binary; only `--DRT-gcopt=gc:` and `--region` differ.
Runs are interleaved rather than batched, and each figure is the best of N
repetitions, because interference on a developer machine only ever lowers
throughput and raises latency.

The two `/work` handlers do identical work through the same `renderPayload` and
the same response call. The only difference is where the per-request scratch is
allocated.

## Results

macOS/arm64, LDC 1.42.0, `-release`. 4 server threads, 128 connections, 15 s,
best of 3.

### Small live set (4,096-entry cache, ~31 MB)

| | conservative | tgc | tgc+regions |
|---|---|---|---|
| requests/sec | 41,000 | **43,410** | 38,312 |
| latency p50 | 3.01 ms | **2.80 ms** | 3.28 ms |
| latency p99 | **4.00 ms** | 4.33 ms | 4.70 ms |
| peak RSS | **31.3 MB** | **31.3 MB** | 32.6 MB |
| collections | 674 | 739 | **147** |
| total pause | 458 ms | 977 ms | **198 ms** |

### Large live set (100,000-entry cache, ~115-145 MB)

| | conservative | tgc | tgc+regions |
|---|---|---|---|
| requests/sec | 40,907 | **44,134** | 37,158 |
| latency p50 | 3.02 ms | **2.79 ms** | 3.31 ms |
| latency p99 | 7.71 ms | 8.16 ms | **6.59 ms** |
| peak RSS | **115.0 MB** | 145.6 MB | 143.1 MB |
| collections | 108 | 109 | **25** |
| total pause | 377 ms | 524 ms | **118 ms** |

## What this says

**Regions do exactly what they claim about garbage collection, and it is not
close.** Collections drop 4.4x and total pause 4.4x with a large live set, 5x
with a small one. Request garbage allocated in a region is released at the end
of the request without ever being traced, so the collector simply never sees
it — that is the whole mechanism and it works.

**Whether that is worth having depends on the live set.** With a small one it is
not: p99 is 4.70 ms against 4.00 ms and throughput is 12% down, because there was
never much tracing to remove. With a large one the tail flips — p99 6.59 ms
against 7.71 ms for the default collector and 8.16 ms for plain tgc, the only
configuration measured here where anything beats the default collector's tail.
That is the shape to expect: regions remove the cost of tracing request garbage,
which is worth removing exactly when tracing is expensive.

**Regions cost throughput, and the reason is a fixed cost per region rather than
contention.** It is 12-16% in every configuration, and it does not grow with
thread count (14% at one thread, 12% at four), which rules out the global
segment lock that `IMPROVEMENTS.md` flags as the suspect for allocation-heavy
multi-threaded workloads. Measured directly:

| | ns |
|---|---|
| open and close an empty region | 32 |
| 24 allocations inside a region | 1,637 |
| the same 24 allocations, no region | 566 |

Opening a region is free. *Allocating* in one is roughly three times the price,
because a region owns its chunks exclusively, so it builds fresh ones and hands
them back at close — a chunk creation, its metadata wipe and its release, per
region per size class. At a ~25 µs request that is around a microsecond of pure
overhead, which is the 12-16%.

That points at a concrete improvement rather than a limitation: a per-thread
cache of region chunks, so a closing region hands its chunks to the next region
on that thread instead of to the segment allocator. `bintree_region.d` already
shows regions winning outright when the work inside one is large; this benchmark
is the case where the fixed cost dominates, and it is fixable.

**Plain tgc is a small win at equal memory.** 4-8% ahead on throughput and 7-8%
on median in every configuration, roughly level on p99, and its memory depends
on how it is told to size heaps — it grows a thread's heap 4x with a 32 MB
floor, *per thread*, where the default collector sizes one pool for the process.

## Regions and vibe.d: what does not work

Wrapping the whole handler in a region — the obvious thing, and what the region
documentation's example looks like — **crashes vibe.d**, reproducibly, on about
the 34th request:

```
EXC_BAD_ACCESS  InterfaceProxy!OutputStream.__postblit
                HTTP1ServerExchange.bodyWriter
                HTTPServerResponse.doWriteJsonBody
                app.handleWorkRegion
```

vibe.d runs request handling through a `RegionListAllocator!GCAllocator` owned
by the *connection* and reused across requests on it. Allocate that inside a
region and it is region memory: freed when that request's region closes, and
used again by the next request on the same keep-alive connection. The region
documentation names this exactly — "a keep-alive connection object" — and it is
easy to walk into anyway, because the offending allocation is vibe.d's, not
yours.

So the handler here keeps the region around the *scratch work only*, writes the
response after closing it, and copies the one value that has to survive out
through `malloc` — the deep-copy-on-the-way-out discipline regions require. With
that structure it runs clean under `--region-verify`.

**`tgcRegionVerify` did not catch the broken version**, and that is worth
knowing. The verifier reports references into a region from outside, but it
deliberately excludes the region's own fiber stack, since that stack legitimately
holds region references while the region runs. The connection object is reachable
from precisely that stack — so the one reference that mattered was in the one
place the verifier does not look. It is a real blind spot, not a bug in the
handler.

## Notes on the setup

* The per-worker cache is thread-local, not `__gshared`. That is realistic for a
  per-worker cache and is also the only shape tgc supports without
  `tgcTrackEscapes`. Measuring the shared variant would be measuring escape
  tracking, which `bench/escape_probe.d` does.
* Each thread builds its own router and `HTTPServerSettings`. Sharing one would
  put a GC block allocated on the main thread into every worker's hands.
* `latency max` is printed but no conclusion here rests on it: it is a single
  worst sample and flipped between 7.7 ms and 26.9 ms for one configuration
  across repetitions. p99 is the tail figure worth reading.
* Both `total pause` figures are process-wide and do not mean the same thing —
  see the note `run.sh` prints.
