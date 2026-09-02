/**
 * Registers the `tgc` GC factory at load time.
 * With version `Tgc_default`, selects thread-local GC via embedded rt_options.
 */
module tgc.gcobj;

import core.internal.gc.impl.tgc.gc;

/**
 * Enable escape promotion: blocks seen reachable from a global root are never
 * reclaimed by a thread-local collection.
 *
 * Off by default. It closes a cross-thread hole (a block published to a global,
 * picked up by another thread, then unpublished) but the promoted set is sticky
 * and re-scanned every cycle, so pause time grows with everything the program
 * has ever published. Enable it only if the program does that handoff and can
 * afford growing pauses. See CROSS-THREAD.md.
 */
void tgcTrackEscapes(bool enable) nothrow @nogc
{
    tgc_setTrackEscapes(enable);
}

/// ditto
bool tgcTrackEscapes() nothrow @nogc
{
    return tgc_getTrackEscapes();
}

/**
 * Run a cooperative global collection now.
 *
 * This is the one tgc operation that stops the world, and the only way to
 * reclaim memory a thread-local collection cannot prove dead: arenas adopted
 * from exited threads, and blocks promoted by `tgcTrackEscapes`. It is
 * otherwise triggered automatically once retained bytes pass
 * `tgcGlobalThreshold`.
 *
 * Detached `@nogc` threads are not paused: only threads registered with the
 * runtime are suspended.
 *
 * Returns: false if a global collection was already in progress.
 */
bool tgcCollectGlobal()
{
    import core.internal.gc.proxy : gc_getProxy;

    if (auto g = cast(ThreadGC) gc_getProxy())
        return g.collectGlobalNow();
    return false;
}

/**
 * Retained bytes at which a global collection triggers automatically.
 *
 * Defaults to 64 MiB, and is compared against `tgcRetainedBytes` and
 * `tgcPromotedBytes` *together*: arenas adopted from exited threads and blocks
 * promoted by escape tracking are both reclaimable only globally. It used to
 * count the arenas alone, which meant a program that turned escape tracking on
 * and never exited a thread never collected globally at all, and its promoted
 * set -- re-scanned by every local collection -- grew without bound.
 *
 * Set to 0 to disable automatic global collection, in which case retained
 * memory grows until `tgcCollectGlobal` is called explicitly.
 */
void tgcGlobalThreshold(size_t bytes) nothrow @nogc
{
    tgc_setGlobalThreshold(bytes);
}

/// ditto
size_t tgcGlobalThreshold() nothrow @nogc
{
    return tgc_getGlobalThreshold();
}

/**
 * Bytes held in arenas adopted from threads that have exited.
 *
 * A thread-local collection cannot prove these dead, so they accumulate until a
 * global collection runs. Use this to decide when to call `tgcCollectGlobal`,
 * or to check that the automatic threshold is doing its job.
 */
size_t tgcRetainedBytes() nothrow @nogc
{
    return tgc_getRetainedBytes();
}

/**
 * Bytes in blocks promoted by `tgcTrackEscapes`, across every live heap.
 *
 * The other half of what only a global collection can reclaim. A thread-local
 * collection cannot demote a promoted block -- only a global one can prove no
 * other thread still holds it -- so this grows with everything the program
 * publishes, and falls back to the live published set when a global collection
 * runs. Automatic global collection triggers on this and `tgcRetainedBytes`
 * together, so a program that publishes but never exits a thread is covered.
 *
 * Meaningful only while escape tracking is on; with it off nothing is promoted
 * and the figure holds at whatever the last collection saw.
 */
size_t tgcPromotedBytes() nothrow @nogc
{
    return tgc_getPromotedBytes();
}

/**
 * Collect once a thread's live data has grown by this factor. Default 4.
 *
 * A mark-sweep pause costs time proportional to the live set, not to the heap,
 * so extra headroom reduces how *often* collections happen without making any
 * one of them longer. Raise it to trade memory for both throughput and fewer
 * pauses; lower it (minimum 2) to keep the heap tight.
 */
void tgcHeapGrowth(size_t factor) nothrow @nogc
{
    tgc_setHeapGrowth(factor);
}

/// ditto
size_t tgcHeapGrowth() nothrow @nogc
{
    return tgc_getHeapGrowth();
}

/**
 * Use `TypeInfo` pointer maps to skip words that cannot hold references.
 *
 * On by default. Scanning falls back to conservative whenever the layout is
 * unknown or ambiguous, so this only ever scans less where the compiler has
 * said that is safe. Turn it off to rule a suspected precision bug in or out.
 */
void tgcPreciseScanning(bool enable) nothrow @nogc
{
    tgc_setPreciseScanning(enable);
}

/// ditto
bool tgcPreciseScanning() nothrow @nogc
{
    return tgc_getPreciseScanning();
}

/**
 * A request-scoped arena bound to the running fiber.
 *
 * Everything allocated while the region is open comes from chunks it owns
 * exclusively, and closing it releases the lot without tracing — the BEAM
 * model, where a process dies and its heap goes with it.
 *
 * It carries BEAM's precondition too. BEAM can free a dead process's heap
 * because every message was deep-copied on send, so nothing outside can point
 * in. D has no such enforcement, so **anything that must outlive the region has
 * to be copied out of it**, and that is your invariant to keep. Session state,
 * a keep-alive connection object, a log buffer flushed later, a cache entry
 * populated mid-request — each is a dangling pointer if it stays in the region.
 *
 * Enable `tgcRegionVerify` in tests: it checks the invariant dynamically at
 * every close, at the cost of a full mark, and is off by default for that
 * reason.
 *
 * Regions do not nest. Opening one on a fiber that already has one returns
 * null and changes nothing.
 *
 * ---
 * void handleRequest(int fd)
 * {
 *     auto r = tgcBeginRegion();
 *     scope (exit) tgcEndRegion(r);
 *     // ... parse, route, render, send ...
 * }   // every allocation above is released here, untraced
 * ---
 */
void* tgcBeginRegion()
{
    return tgc_beginRegion();
}

/// ditto
void tgcEndRegion(void* region)
{
    tgc_endRegion(region);
}

/// Bytes a region currently holds.
size_t tgcRegionBytes(void* region) nothrow @nogc
{
    return tgc_regionBytes(region);
}

/**
 * Run `body` inside a region, closing it afterwards even if `body` throws.
 *
 * A throw is the case most likely to break the invariant: the exception is
 * allocated inside the region and caught outside it. Copy anything you need out
 * of it before it propagates.
 */
void tgcRunInRegion(scope void delegate() body)
{
    auto r = tgcBeginRegion();
    scope (exit)
        tgcEndRegion(r);
    body();
}

/**
 * Check at every region close that nothing outside still points into it.
 *
 * Costs a full mark of the thread's roots per close, so it is off by default.
 * Turn it on in test builds: it converts "I believe nothing escapes" into
 * something your suite verifies.
 */
void tgcRegionVerify(bool enable) nothrow @nogc
{
    tgc_setRegionVerify(enable);
}

/// ditto
bool tgcRegionVerify() nothrow @nogc
{
    return tgc_getRegionVerify();
}

/**
 * Floor on a thread's collection threshold — the analogue of the default
 * collector's `minPoolSize`.
 *
 * A thread collects once its live data has grown by `tgcHeapGrowth`, which for
 * a small live set means collecting very often. Raising the floor trades memory
 * for far fewer collections, exactly as `--DRT-gcopt=minPoolSize` does for the
 * default collector.
 *
 * This is **per thread**, because tgc's heaps are. To match a global pool of
 * N bytes across T threads, pass N / T.
 */
void tgcMinHeap(size_t bytes) nothrow @nogc
{
    tgc_setMinHeap(bytes);
}

/// ditto
size_t tgcMinHeap() nothrow @nogc
{
    return tgc_getMinHeap();
}

version (Tgc_default)
{
    extern (C) __gshared string[] rt_options = [ "gcopt=gc:tgc" ];
}

/**
 * Size of the mappings chunks are carved from, rounded up to 2 MB.
 *
 * Chunks do not come from `malloc`; they are carved out of a few large
 * mappings, which on Linux the kernel can back with huge pages. Measured on
 * binary-trees at a 300 MB budget, that took page faults from 926,000 to
 * 187,000 and total pause from 406 ms to 41 ms. Larger segments mean fewer,
 * bigger mappings and less churn when a heap oscillates; smaller ones return
 * memory to the OS at a finer grain. The default is 32 MB.
 *
 * Address space, not memory: an untouched part of a segment costs nothing.
 */
void tgcSegmentSize(size_t bytes) nothrow @nogc
{
    tgc_setSegmentSize(bytes);
}

/// ditto
size_t tgcSegmentSize() nothrow @nogc
{
    return tgc_getSegmentSize();
}

/**
 * Bytes of chunk storage currently backed by memory, allocated or not.
 *
 * Memory is kept back rather than returned on the spot, because handing back
 * pages a growing heap is about to ask for again is exactly the fault this
 * allocator exists to avoid. Three things return it: a collection, once this
 * figure exceeds recent peak demand by `tgcTrimRatio`; a segment falling
 * entirely empty; and `GC.minimize()`, which hands back every 2 MB span holding
 * nothing, whatever the ratio says.
 */
size_t tgcCommittedBytes() nothrow @nogc
{
    return tgc_getCommittedBytes();
}

/**
 * Headroom a collection leaves committed, as a multiple of recent peak demand.
 * Default 2; 0 never returns memory automatically.
 *
 * A segment is only unmapped once every chunk in it is free, so without this a
 * single live chunk pins 32 MB and a process holds its peak until it calls
 * `GC.minimize()`. A collection compares committed bytes against the most
 * chunk memory the program held at any point in the last half-second and, above
 * this factor, hands back the 2 MB spans that hold nothing.
 *
 * *Peak* rather than what the heap holds when the collection ends, because that
 * moment is its trough -- the sweep has just run. Comparing against the trough
 * makes the test true on every collection of an ordinary oscillating heap, and
 * the memory handed back is faulted straight in again; measured, that cost 7%
 * of pause time on a heap that was not shrinking at all. Against the peak, a
 * breathing heap keeps its headroom and only a program whose demand has
 * actually fallen hands anything back.
 *
 * Memory comes back about a second after demand falls, not immediately: one
 * collection past the window re-baselines the peak now that the program has
 * stopped asking for memory, and the next one acts on it. That is the cost of
 * the hysteresis, and it is why a burst followed by silence returns its memory
 * on the second collection rather than the first.
 *
 * Raise the factor to favour throughput, lower it to favour resident size;
 * whatever the setting, at least one segment is always kept.
 */
void tgcTrimRatio(size_t factor) nothrow @nogc
{
    tgc_setTrimRatio(factor);
}

/// ditto
size_t tgcTrimRatio() nothrow @nogc
{
    return tgc_getTrimRatio();
}
