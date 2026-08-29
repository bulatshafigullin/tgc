# Using tgc for a threads + fibers web server

Design note. Claims marked **[measured]** come from probes run against this
repository's collector with LDC 1.42.0 on macOS/aarch64.

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

Collection time with 50,000 live objects, as suspended fibers accumulate:

| suspended fibers | collect |
|---|---|
| 0 | 0.32 ms |
| 100 | 0.36 ms |
| 1,000 | 0.64 ms |
| 5,000 | 2.16 ms |
| 10,000 | 3.55 ms |

Roughly 0.32 µs per suspended fiber, linear. For a server holding 10k concurrent
connections as fibers, budget ~3.5 ms per collection on that thread — still only
that thread, while the others keep serving.

**Remaining limitation.** druntime's context list is global and records no
fiber-to-thread affinity, so each thread currently scans *every* thread's
fibers. With 4 threads × 2,500 fibers each, all four do the full 10,000-fiber
scan instead of their own 2,500. That is roughly 4× more scanning than
necessary; fixing it needs tgc to track affinity itself. Keep it in mind when
sizing threads: many threads each with many fibers multiplies this cost.

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

## 4. Per-request allocation: play to tgc's strength

The reason to want tgc here is tail latency: a collection pauses one thread's
fibers, not the whole process, and it scans only that thread's live set. With the
arena allocator this repository now has, a collection over 256,000 live objects
takes **1.83 ms** [measured], and scales linearly — so a worker holding ~50k live
objects pauses for a few hundred microseconds, while the other workers keep
serving. That is a genuinely good story for p99 latency, and it is the thing the
default global-STW collector cannot give you.

To keep it that way:

* Keep the per-thread live set small. Latency is proportional to live data on
  *that* thread, so bounding connections per worker directly bounds pause time.
* Reuse buffers rather than allocating per request — a thread-local free list of
  request/response buffers keeps the live set flat and the collector idle.
* Prefer `scope`/stack or explicit `malloc` arenas for short-lived per-request
  scratch. tgc's per-thread heap makes a per-request bump allocator natural, and
  anything you do not hand to the GC is not scanned.

---

## 5. Interim mitigation for fibers, if you must experiment before the fix

Root each fiber's live state somewhere tgc *does* scan — thread-local storage:

```d
Connection[size_t] active;    // TLS: scanned by this thread's collector

void handle(int fd)
{
    auto conn = new Connection(fd);
    active[conn.id] = conn;          // now reachable from TLS, not just the fiber stack
    scope(exit) active.remove(conn.id);
    ...
}
```

This keeps the connection object alive across yields regardless of fiber-stack
scanning. It does **not** protect arbitrary intermediate objects held in fiber
locals across a yield, so treat it as a workaround for a demo, not a production
strategy.

---

## 6. Honest bottom line

| | status |
|---|---|
| Per-thread heaps for a shared-nothing worker model | good fit, this is the intended shape |
| Pause behaviour vs. the default GC | genuinely better: 1.83 ms for 256k live objects, one thread only |
| Fibers | **broken today** — fiber stacks unscanned; fixable in tgc as in §0 |
| Acceptor handing objects to workers | unsound; redesign per §1 |
| Shared `immutable` config via `__gshared` | works today [measured] |
| Thread shutdown (`join` after a throw) | use-after-free, see `CROSS-THREAD.md` §2.2 |

**Recommendation.** The architecture is right for tgc if you make two changes:
accept per-thread with `SO_REUSEPORT` instead of handing connections across
threads, and pin fibers to their thread. But do not build on tgc until fiber
stack scanning (§0) and the thread-teardown use-after-free are fixed — both are
tractable and neither needs a language change.
