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
 * Defaults to 64 MiB. Set to 0 to disable automatic global collection, in which
 * case retained memory grows until `tgcCollectGlobal` is called explicitly.
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

version (Tgc_default)
{
    extern (C) __gshared string[] rt_options = [ "gcopt=gc:tgc" ];
}
