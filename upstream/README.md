# Patches this collector would like from druntime

Each of these is a change to druntime that tgc can use but does not require:
the collector detects the addition with `__traits(compiles, ...)` and falls back
to what exists today, so it is correct either way and simply does more work.
They live here so the numbers behind them travel with the request.

## `per-thread-stack-contexts.patch`

**Problem.** Finding a thread's fibers means walking `ThreadBase.sm_cbeg`, which
holds every `StackContext` in the process. The ownership test cannot be hoisted
out of `ThreadBase.slock`: release it and another thread may destroy its fiber
and unmap the stack that was about to be scanned. So a thread-local collector
walks T x F contexts to scan its own F, and every thread pays for every other
thread's fibers.

This does not affect druntime's own collector, which scans every stack anyway.
It is specific to a collector that scans only its own thread's — which is the
whole point of tgc, and would be the same for any other per-thread design.

**Change.** Two fields on `StackContext` (`owner`, `nextInThread`) and one on
`ThreadBase` (`m_cbeg`), threading each thread's contexts onto its own list
alongside the global one. Maintained in the existing `add`/`remove` under the
existing lock: a pointer store on add, a short walk on remove, both once per
context lifetime rather than once per collection. The global list is unchanged,
so nothing that walks it is affected.

**Measured** with `bench/fiber_probe.d`, LDC 1.42.0 on macOS/arm64, against a
druntime built from the 1.42.0 source with this patch applied. Every thread
holds 2,000 fibers and an identical live set, so the only thing that changes as
threads are added is how many *other* threads' fibers each collection walks
past:

| threads | fibers in process | stock | patched |
|---|---|---|---|
| 1 | 2,000 | 0.40 ms | 0.41 ms |
| 2 | 4,000 | 0.43 ms | 0.43 ms |
| 4 | 8,000 | 0.47 ms | 0.45 ms |
| 8 | 16,000 | 0.54 ms | 0.47 ms |

Best of seven collections, three runs. Growth from one thread to eight falls
from +33% to +10%, which is the result: what remains scales with thread count
for other reasons, not with other threads' fibers.

**Applying it.**

```
tar xzf ldc-<version>-src.tar.gz
patch -p1 -d ldc-<version>-src/runtime < upstream/per-thread-stack-contexts.patch
ldc-build-runtime --ninja --ldcSrcDir=$PWD/ldc-<version>-src --buildDir=$PWD/rtbuild
```

then compile against it with an `ldc2.conf` whose `post-switches` point `-I` at
`ldc-<version>-src/runtime/druntime/src` and whose `lib-dirs` point at
`rtbuild/lib`.

**One trap, recorded because it cost an afternoon.** tgc's notion of "this
thread's context" is "this heap owns the `StackContext` block", since `Fiber`
allocates it with `new` on its creating thread. That is *not* the same as being
on the thread's own list: a thread's `m_main` context is a field inside its
`ThreadBase`, which some other thread allocated. Asserting the two agreed
deadlocked the entire process — the `AssertError` propagated out with `slock`
held, and every thread trying to register itself blocked on it forever. The
ownership probe is therefore kept on both paths; the per-thread list shortens
the walk and changes nothing else.
