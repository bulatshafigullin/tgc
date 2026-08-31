# Using tgc for a threads + fibers web server

Design note. Claims marked **[measured]** come from probes run against this
repository's collector with LDC 1.42.0. Figures were re-measured after the
mark, sweep and allocator work; the reproducible ones come from
`bench/webserver_probe.d` (`dub run --config=bench-webserver`) and
`bench/run.sh`, on Linux/x86-64 unless noted.

Target architecture from the question: N worker threads (≈ CPU count), many
fibers per thread, an acceptor handing each new connection to a fiber.

---

## 0. Fiber stacks — was broken, now fixed

**Status: fixed.** This section documents what was wrong, because it explains a
cost you still pay and a limit that still applies.

`thread_stackBottom()` returns the **current** stack context's base
(`ThreadBase.topContext().bstack`). tgc scans `[sp, thread_stackBottom())`, i.e.
exactly one stack — whichever context happens to be running.

**[measured, before the fix] A suspended fiber's stack was not scanned.** A fiber allocates an
object, holds it only on its own stack, and yields; the thread then collects:

```
fiber suspended. state=0
after 2 collections: canary destructor ran? YES  <-- suspended fiber stack NOT scanned
```

**[measured, before the fix] Collecting *from inside* a fiber was worse** — it
missed the thread's own main stack *and* every other fiber:

```
collected from inside a fiber:
  object on the THREAD's main stack freed?  YES  <-- main stack not scanned
  object on ANOTHER fiber's stack freed?    YES  <-- fiber stack not scanned
```

Why this is fatal specifically for a fiber server: allocation is what triggers
collection, and in this design essentially all allocation happens inside fibers.
So the common case is "collect from inside fiber F", which scans F's stack and
nothing else. Every object held by every *other* fiber across a yield — which is
every connection waiting on I/O — is unreachable as far as the collector is
concerned, and gets freed and finalized while live.

### How it was fixed

druntime registers **every** stack context, fiber stacks included, on a global
list: `Fiber` does `m_ctxt = new StackContext; ThreadBase.add(m_ctxt);`, and
`thread_scanAllType` walks `for (StackContext* c = ThreadBase.sm_cbeg; c; c = c.next)`.

Both pieces are reachable from tgc: `core.thread.context.StackContext` is a
public struct in an importable module, and `ThreadBase.sm_cbeg` is `__gshared`
without a `private` (unlike its neighbour `pAboutToStart`, which is explicitly
private).

The fix is to scan, per collection:

* the **current** context precisely, via `callWithStackShell` — as today, this is
  the only context whose `tstack` is live and trustworthy;
* every other context on `sm_cbeg`, over its *used* range `[tstack, bstack)`.

The cost is smaller than it sounds: `tstack` is the saved stack pointer, so a
suspended fiber contributes only the few hundred bytes to few KB it is actually
using, not its whole reserved stack. Ten thousand idle fibers is on the order of
a few MB scanned, not gigabytes.

The over-approximation is that a thread also scans other threads' contexts. That
retains a little extra and races on other threads' *running* stacks, but it only
ever marks blocks in the scanning thread's own heap, so it errs toward retention.

### What it costs [measured]

Collection time with 50,000 live objects, as suspended fibers accumulate.
`bench/webserver_probe.d`, one thread, both collectors on the same binary:

| suspended fibers | tgc | default collector |
|---|---|---|
| 0 | 0.32 ms | 0.23 ms |
| 100 | 0.33 ms | 0.25 ms |
| 1,000 | 0.48 ms | 0.34 ms |
| 5,000 | 1.15 ms | 1.38 ms |
| 10,000 | **2.18 ms** | 3.77 ms |

Roughly 0.19 µs per suspended fiber, linear — and *cheaper* than the default
collector past a few thousand fibers, which is the shape a connection-per-fiber
server lives in. The difference that matters is not in the table: tgc's 2.18 ms
pauses one thread, the default collector's 3.77 ms pauses all of them.

For a server holding 10k concurrent connections as fibers on one thread, budget
a bit over 2 ms per collection on that thread.

**Remaining limitation, smaller than it was.** Fiber *scanning* is now
restricted to the collecting thread's own fibers: a context counts as ours only
if this heap owns the `StackContext` block, which `Fiber` allocates with `new`
on its creating thread. What is still global is *enumeration* — finding those
contexts means walking druntime's list of every fiber in the process, and the
ownership test has to happen inside druntime's thread lock, because once it is
released another thread may destroy its fiber and unmap the stack.

Measured (before the mark and sweep work, so read the shape rather than the
absolute values) with each thread holding a constant 400 fibers, so all growth
comes from *other* threads' fibers: 0.20 ms at one thread, 0.29 ms at eight.
Real, but an order of magnitude smaller than the "4× more scanning" this section
used to describe. Removing it needs a druntime field recording the owning thread on each
`StackContext`.

---

## 1. The one architectural decision that matters most

> **Do not hand connections between threads. Give every worker thread its own
> listening socket with `SO_REUSEPORT` and let it accept its own connections.**

The proposed "master thread accepts, passes to a fiber on a worker" is the single
worst shape for tgc, because the `Connection` object is allocated on the
acceptor's heap and then used by a worker thread — the exact cross-heap reference
that is unsound (see `CROSS-THREAD.md`). The acceptor's collector does not scan
the worker's stacks, so it will eventually free a live connection.

With `SO_REUSEPORT` each worker binds the same address, the kernel load-balances
incoming connections across the listeners, and a connection is allocated,
processed and freed entirely within one thread's heap. Nothing crosses.

This is also independently the faster design — it is what nginx does with
`reuseport` — because it removes the handoff queue and the cross-core cache-line
traffic that comes with it. You are not trading performance for GC safety here;
both point the same way.

```d
// per worker thread
auto listener = new Socket(AddressFamily.INET, SocketType.STREAM);
listener.setOption(SocketOptionLevel.SOCKET, cast(SocketOption) SO_REUSEPORT, 1);
listener.bind(addr);
listener.listen(backlog);
// this thread's event loop accepts and spawns its own fibers
```

### If you genuinely need a single acceptor

Pass the **file descriptor**, not an object:

```d
// acceptor thread
int fd = acceptSocket();          // a plain int - not GC memory
workerQueue[next].push(fd);       // shared ring buffer of ints

// worker thread
int fd = queue.pop();
auto conn = new Connection(fd);   // allocated on THIS thread's heap
```

An `int` carries no GC reference, so nothing crosses heaps. The worker allocates
its own connection state. This keeps a central acceptor while staying compatible
with per-thread heaps.

What you must **not** do is `auto c = new Connection(fd); queue.push(c);` — that
is the unsound transfer.

Since the collector became strictly thread-private, that mistake is also
*detected* rather than silent: `GC.free`, `realloc`, `setAttr` and the
array-mutating calls assert when handed a block from another thread's heap. The
checks are asserts, so they are live in a debug or default build and compiled
out under `-release`. Run your integration tests without `-release` at least
once; a wrong answer that used to surface as corruption weeks later now surfaces
as an assertion at the point of the mistake.

---

## 2. Pin fibers to their thread

Never migrate a fiber between threads (do not `call()` a fiber from a thread
other than the one that created it). tgc's model is one heap per thread; a
migrated fiber's stack would hold references into the heap of the thread it came
from, recreating the cross-heap problem with none of the type system's help.

Practically: one event loop per thread, one fiber pool per thread, no work
stealing of in-flight fibers. If you want load balancing, balance *connections at
accept time* (§1), not fibers in flight.

---

## 3. Shared immutable state is fine — if it is rooted in a global

**[measured]** A block reachable only through a `__gshared` global survives
collection, because druntime registers the static data segment as a GC range and
every thread's collector scans it.

So this pattern is safe today:

```d
immutable(Config) config;                 // built once, before workers start
__gshared immutable(Config) gConfig;      // rooted in the data segment
```

Routing tables, templates, TLS certificates, static assets — load them on the
main thread before spawning workers and publish them through a `__gshared`
`immutable` global. Every worker may read them; the main thread's collector keeps
them alive via the data-segment root.

Caveat: the owning thread must outlive the readers. In a server the main thread
normally does. Do not build shared config on a worker that later exits.

---

## 3a. Leave escape tracking off

`tgcTrackEscapes(true)` makes tgc retain anything it has seen reachable from a
global, which closes a cross-thread hole. Do not enable it in a server: the
retained set is re-scanned on every collection and never shrinks, so pause time
grows for the life of the process — the opposite of what you are here for.

The architecture in §1 and §2 is what makes it unnecessary. Nothing crosses
threads, so there is nothing to promote.

## 3b. Global collection: rare, short, and worth tuning

Threads that exit leave their arenas behind, because `Thread.join()` may still
hand the parent objects they allocated. A global collection reclaims them; it is
the one operation that stops the world, and it stops it for marking only —
measured at 0.07 ms to reclaim 2 MB of arenas from eight exited threads.

For a server this mostly does not matter, because a worker pool is created once
and its threads live for the process lifetime, so almost nothing is ever
adopted. If you *do* churn threads, tune `tgcGlobalThreshold` — lower means more
frequent, shorter stops; `0` disables the automatic trigger entirely so you can
call `tgcCollectGlobal()` yourself at a quiet moment.

## 3c. Per-request regions

`tgcBeginRegion` / `tgcEndRegion` give a request its own arena: everything the
handler allocates is released when the region closes, without tracing. This is
the single biggest lever in this document.

Measured with `bench/run.sh -b region`, four workers, the same workload with and
without regions — a job stands in for a request, and the only thing outliving it
is an `int` copied out:

| | collections | total pause | max pause | parallel section |
|---|---|---|---|---|
| without regions | 4,987 | 866.6 ms | 32.1 ms | 0.561 s |
| **with regions** | **5** | **56.8 ms** | 27.9 ms | **0.358 s** |

Same 25 MB heap either way. Request-scoped memory never enters the mark phase at
all, so the only collections left are the ones that handle genuinely long-lived
data.

```d
void handleRequest(int fd)
{
    auto r = tgcBeginRegion();
    scope (exit) tgcEndRegion(r);
    // parse, route, render, send
}   // everything above is released here, untraced
}
```

The catch is the one BEAM avoids by copying every message: **anything that must
outlive the request has to be copied out**. Session state, a keep-alive
connection object, a log buffer flushed later, a cache entry populated
mid-request — each is a dangling pointer if it stays in the region. An exception
thrown out of the handler is the same problem, since it is allocated inside and
caught outside.

Turn on `tgcRegionVerify(true)` in your test builds. It checks at every close
that nothing outside still points in, which is the difference between an arena
you can trust and one that corrupts memory the first time a handler caches
something.

## 4. Per-request allocation: play to tgc's strength

The reason to want tgc here is tail latency: a collection pauses one thread's
fibers, not the whole process, and it scans only that thread's live set.
`bench/webserver_probe.d`, one thread, no fibers:

| live objects | collect |
|---|---|
| 2,000 | 0.04 ms |
| 16,000 | 0.12 ms |
| 64,000 | 0.40 ms |
| 256,000 | **1.58 ms** |

Linear, so a worker holding ~50k live objects pauses for roughly a third of a
millisecond while the other workers keep serving. That is the thing the default
global-STW collector cannot give you, and the gap widens with worker count: at
four workers on binary-trees the default collector spends 778 ms of pause
against tgc's 125 ms, and its worst pause is 154 ms against 24 ms.

To keep it that way:

* Keep the per-thread live set small. Latency is proportional to live data on
  *that* thread, so bounding connections per worker directly bounds pause time.
* Reuse buffers rather than allocating per request — a thread-local free list of
  request/response buffers keeps the live set flat and the collector idle.
* Prefer `scope`/stack or explicit `malloc` arenas for short-lived per-request
  scratch. tgc's per-thread heap makes a per-request bump allocator natural, and
  anything you do not hand to the GC is not scanned.

### 4a. Size the heap, or you will collect constantly

tgc sizes each thread's heap from its own live data, which for a small live set
means collecting very often. `tgcMinHeap(bytes)` is the floor, and it is **per
thread** — the equivalent of the default collector's `minPoolSize`, divided by
your worker count.

It is worth more than it looks. On binary-trees at four workers, sizing from
live data cost 4,983 collections; the same run with a matched budget took 27.
Give each worker a floor that comfortably exceeds its steady-state live set:

```d
tgcMinHeap(totalHeapBudget / workerCount);   // before starting the workers
```

Pause time is proportional to *live* data, not to the heap, so headroom costs
memory and buys both throughput and latency.

---

## 5. Memory: segments, huge pages, and when memory goes back

This section replaces an interim workaround for unscanned fiber stacks, which is
no longer needed — §0 shipped.

Chunks are carved from large mappings rather than allocated one at a time, which
on Linux lets the kernel back the heap with huge pages. That is worth an order
of magnitude: on binary-trees at a matched budget it took page faults from
926,000 to 210,000 and total pause from 374 ms to 38 ms. Nothing is required of
you to get it.

What *is* required of you is deciding when memory goes back. Freed chunks stay
in their segment, and empty segments are kept — bounded to a quarter of what is
mapped, plus one — because unmapping memory a growing heap is about to ask for
again is the page fault this design exists to avoid. Nothing returns it
automatically.

For a server that means: after a traffic spike drains, the peak stays mapped
until you ask.

```d
// on an idle tick, or after a burst subsides
GC.minimize();   // unmaps empty segments, and hands back every 2 MB span
                 // inside a segment that holds nothing
```

`tgcCommittedBytes()` reports what is currently backed by memory, so a health
endpoint can watch it. `tgcSegmentSize(bytes)` tunes the granularity: larger
segments mean fewer mappings and less churn, smaller ones return memory at a
finer grain. The default is 32 MB.

One caveat worth knowing before you tune it down: a segment is only unmapped
when *every* chunk in it is free, so one long-lived object can pin one. The 2 MB
span-level release inside `GC.minimize()` is what covers that case.

---

## 6. Honest bottom line

| | status |
|---|---|
| Per-thread heaps for a shared-nothing worker model | good fit, this is the intended shape |
| Pause behaviour vs. the default GC | better, and the gap widens with workers: at four, 125 ms of pause against 778 ms, worst pause 24 ms against 154 ms |
| Fibers | **works** — every registered stack context is scanned, and only this thread's (§0) |
| Acceptor handing objects to workers | unsound; redesign per §1. Now asserts in a non-release build instead of failing silently |
| Shared `immutable` config via `__gshared` | works [measured] |
| Thread shutdown (`join` after a throw) | fixed: a dying thread's arenas are retained, and reclaimed by a global collection |
| Per-request regions | the biggest lever here: 4,987 collections to 5, 867 ms of pause to 57 ms (§3c) |
| Returning memory to the OS | your call, via `GC.minimize()` (§5) |

**Recommendation.** The architecture is right for tgc if you make two changes:
accept per-thread with `SO_REUSEPORT` instead of handing connections across
threads, and pin fibers to their thread. The two blockers this document used to
end on — unscanned fiber stacks and the thread-teardown use-after-free — are
both fixed, so the honest advice is now: build on it, with regions for
per-request memory, a `tgcMinHeap` floor per worker, and your integration tests
running without `-release` so the thread-private checks are live.

What is still true and worth planning around: marking is conservative and is now
the collector's dominant cost, so per-thread live set is the number that governs
your pause time; and nothing returns memory to the OS unless you call
`GC.minimize()`.
