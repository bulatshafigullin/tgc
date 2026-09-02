# vibe.d benchmark: tgc against the default collector

A real web framework rather than binary-trees, because that is what this
collector is aimed at. vibe.d is fiber-per-request, so a collection has to
enumerate and scan hundreds of suspended stacks, and a request is served
entirely on the thread that accepted it, which is the shape thread-private heaps
assume.

```
dub build --build=release          # in this directory
./run.sh                           # /work, 4 threads, 30s, both collectors
./run.sh -d 15 -t 4 -N 3           # shorter, three repetitions
./run.sh -m 8                      # put tgc on a matched memory budget
./run.sh -r /json                  # a route that barely allocates
```

Both columns are the same binary; only `--DRT-gcopt=gc:` differs. Runs are
interleaved rather than batched, and each figure is the best of N repetitions,
because interference on a developer machine only ever lowers throughput and
raises latency.

## Results

macOS/arm64, LDC 1.42.0, `-release`. 4 server threads, 128 connections, 15 s,
`/work` (a session object built, rendered, JSON-encoded, and kept in a
4096-entry per-worker ring).

### At each collector's defaults

| | conservative | tgc | |
|---|---|---|---|
| requests/sec | 39,215 | **42,894** | +9% |
| latency p50 | 3.15 ms | **2.89 ms** | -8% |
| latency p99 | **5.12 ms** | 5.32 ms | +4% |
| peak RSS | **53.4 MB** | 77.4 MB | +45% |
| collections | 227 | 198 | |
| max pause | **2.45 ms** | 3.55 ms | |

Best of 3.

### At a matched memory budget (`-m 8`: 8 MB/thread floor, growth 2)

| | conservative | tgc | |
|---|---|---|---|
| requests/sec | 40,701 | **42,411** | +4% |
| latency p50 | 3.08 ms | **2.85 ms** | -7% |
| latency p99 | **4.87 ms** | 5.09 ms | +5% |
| peak RSS | 53.4 MB | **43.1 MB** | -19% |
| collections | 237 | 580 | |
| max pause | **1.82 ms** | 2.43 ms | |

Best of 5.

## What this says

**tgc is modestly faster and its memory is a tuning decision.** Throughput is
4-9% better and the median 7-8% better in every configuration measured. Memory
is 45% *worse* at the defaults and 19% *better* when told to use a comparable
budget — which is a statement about default heap sizing policy, not about the
collectors. tgc grows a thread's heap by 4x with a 32 MB floor, *per thread*,
where the default collector sizes one pool for the whole process; multiply the
first by four threads and the difference is entirely accounted for.

**The tail-latency win a thread-private collector promises does not appear
here, and it is worth being precise about why.** The mechanism is real: every
pause the default collector takes stops all four threads, while each of tgc's
stops one. But the pauses on this workload are ~2 ms against a ~3 ms request, so
there is very little tail for that mechanism to remove — p99 is 5 ms either way,
and the difference between stopping one thread and four is lost in it. The
advantage needs pauses that are *large* relative to request latency, which means
a large live set.

**At a large live set the comparison stops being about the collector.** With a
200,000-entry ring (`-k 200000`, a ~1.2 GB heap) pauses reach 80-190 ms and p99
reaches 50-80 ms, and tgc comes out worse. Two things are mixed together there
and neither is the stop-the-world question:

* Memory. Single-threaded, where connection distribution cannot be a factor,
  tgc holds 1,435 MB against 658 MB and its max pause is 159 ms against 138 ms
  -- 15% worse pause for 2.2x the memory, at the default growth factor.
* Distribution. At four threads the same test gives tgc a 194 ms max pause
  against 80 ms, much worse than the single-threaded gap, which points at
  `SO_REUSEPORT` handing one thread a disproportionate share of the connections.
  A thread-private collector pays for that directly: the worst thread's live set
  is what sets the worst pause, where a global collector averages it away.

So the honest summary is that on a realistic vibe.d workload tgc is a small
throughput and median win at equal or better memory, not a tail-latency win --
and that the configuration where its architecture should pay is one where other
effects arrive first.

## Notes on the setup

* The per-worker cache is thread-local, not `__gshared`. That is realistic for a
  per-worker cache and it is also the only shape tgc supports without
  `tgcTrackEscapes`: a block published to a global and read from another thread
  is the one pattern thread-private heaps cannot handle. Measuring the shared
  variant would be measuring escape tracking, which `bench/escape_probe.d` does.
* Each thread builds its own router and `HTTPServerSettings`. Sharing one would
  put a GC block allocated on the main thread into every worker's hands.
* `latency max` is printed by `run.sh` but is not used for any conclusion here:
  it is a single worst sample and it flipped between 7.7 ms and 26.9 ms for the
  same configuration across repetitions. p99 is the tail figure worth reading.
* Both `total pause` figures are process-wide, and they do not mean the same
  thing -- see the note `run.sh` prints.
