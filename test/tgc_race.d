/**
 * Concurrency stress for `tgc`.
 *
 * Stands in for a thread sanitizer, which cannot be run on every platform. The
 * point is to hammer the paths where threads actually touch shared state — the
 * heap registry, the orphan heap, the global-collection handshake and the
 * tuning flags — hard enough and for long enough that a torn read or a
 * use-after-free shows up as a crash or corrupted data.
 *
 * Every block carries a checkable fill pattern, so damage is detected rather
 * than merely survived.
 */
module tgc_race;

import tgc.gcobj;
import core.memory;
import core.thread;
import core.atomic;

version (TgcSanitize)
    private enum workScale = 10;
else
    private enum workScale = 1;

version (LDC)
{
    private void keepAlive(void* p) @nogc nothrow
    { asm @nogc nothrow { "" : : "r"(p) : "memory"; } }
}
else version (GNU)
{
    private void keepAlive(void* p) @nogc nothrow
    { asm @nogc nothrow { "" : : "r"(p) : "memory"; } }
}
else
{
    private __gshared void* keepAliveSlot;
    pragma(inline, false)
    private void keepAlive(void* p) @nogc nothrow { keepAliveSlot = p; }
}

private ubyte patternFor(size_t seed, size_t i)
{
    return cast(ubyte)((seed * 31 + i * 7 + 11) & 0xFF);
}

// ---------------------------------------------------------------------------
// querying pointers this thread does not own
// ---------------------------------------------------------------------------

unittest
{
    // GC.sizeOf / addrOf on a pointer the calling thread does not own used to
    // walk every other live thread's chunk map. Those maps are mutated by their
    // owners with no lock, and growing one frees its key and value arrays, so
    // the probe could read freed memory. Hammer that path from several threads
    // while others churn their heaps hard enough to force map growth.
    enum nQueriers = 3;
    enum nChurners = 3;
    shared bool stop = false;
    shared int failures = 0;

    // Pointers that are definitely not ours: stack, C heap, and static data.
    __gshared ubyte[64] staticBuf;
    auto threads = new Thread[nQueriers + nChurners];

    foreach (i; 0 .. nChurners)
    {
        threads[i] = new Thread({
            // Force repeated chunk-map growth and shrinkage.
            while (!atomicLoad(stop))
            {
                ubyte[][] kept;
                foreach (k; 0 .. 400)
                {
                    auto b = new ubyte[16 + (k % 64) * 8];
                    b[0] = cast(ubyte) k;
                    if (k % 7 == 0)
                        kept ~= b;
                }
                GC.collect();
                keepAlive(kept.ptr);
            }
        });
    }

    foreach (i; 0 .. nQueriers)
    {
        threads[nChurners + i] = new Thread({
            import core.stdc.stdlib : malloc, free;

            auto cptr = malloc(128);
            scope (exit) free(cptr);
            ubyte[32] stackBuf;

            while (!atomicLoad(stop))
            {
                foreach (_; 0 .. 200)
                {
                    // None of these belong to this thread's heap, so each one
                    // takes the fallback path.
                    if (GC.sizeOf(cptr) != 0)
                        atomicOp!"+="(failures, 1);
                    if (GC.addrOf(stackBuf.ptr) !is null)
                        atomicOp!"+="(failures, 1);
                    if (GC.sizeOf(staticBuf.ptr) != 0)
                        atomicOp!"+="(failures, 1);
                    // A pointer we do own, for contrast.
                    auto mine = new ubyte[64];
                    if (GC.sizeOf(mine.ptr) < 64)
                        atomicOp!"+="(failures, 1);
                    keepAlive(mine.ptr);
                }
            }
        });
    }

    foreach (t; threads) t.start();
    Thread.sleep(dur!"msecs"(300 / workScale + 30));
    atomicStore(stop, true);
    foreach (t; threads) t.join();

    assert(atomicLoad(failures) == 0,
        "querying pointers across threads produced wrong answers");
}

// ---------------------------------------------------------------------------
// thread lifecycle churn against the heap registry
// ---------------------------------------------------------------------------

unittest
{
    // Threads registering and unregistering heaps, adopting arenas on exit,
    // while other threads allocate and collect. Exercises heapsLock, orphanLock
    // and the adoption path together.
    enum waves = 12 / workScale;
    shared bool stop = false;
    shared int failures = 0;

    auto steady = new Thread[2];
    foreach (i; 0 .. 2)
    {
        immutable tid = i;
        steady[i] = new Thread({
            size_t round;
            while (!atomicLoad(stop))
            {
                ubyte[][] kept;
                foreach (k; 0 .. 100)
                {
                    auto b = new ubyte[64 + (k % 30) * 16];
                    foreach (n, ref x; b)
                        x = patternFor(tid * 7777 + round * 13 + k, n);
                    if (k % 4 == 0)
                        kept ~= b;
                }
                GC.collect();
                foreach (n, b; kept)
                {
                    auto seed = tid * 7777 + round * 13 + n * 4;
                    foreach (m, x; b)
                        if (x != patternFor(seed, m))
                        {
                            atomicOp!"+="(failures, 1);
                            break;
                        }
                }
                keepAlive(kept.ptr);
                round++;
            }
        });
    }
    foreach (t; steady) t.start();

    foreach (w; 0 .. (waves < 1 ? 1 : waves))
    {
        auto batch = new Thread[4];
        foreach (i; 0 .. 4)
            batch[i] = new Thread({
                foreach (k; 0 .. 200)
                {
                    auto b = new ubyte[128];
                    b[0] = cast(ubyte) k;
                    keepAlive(b.ptr);
                }
            });
        foreach (t; batch) t.start();
        foreach (t; batch) t.join();
    }

    atomicStore(stop, true);
    foreach (t; steady) t.join();

    assert(atomicLoad(failures) == 0,
        "thread lifecycle churn corrupted a running thread's live data");
}

// ---------------------------------------------------------------------------
// global collection against everything else
// ---------------------------------------------------------------------------

unittest
{
    // Global collections, thread creation and exit, ordinary allocation and
    // local collection, plus concurrent flips of the tuning flags, all at once.
    shared bool stop = false;
    shared int failures = 0;

    auto savedThreshold = tgcGlobalThreshold();
    scope (exit)
    {
        tgcGlobalThreshold(savedThreshold);
        tgcTrackEscapes(false);
    }

    auto workers = new Thread[3];
    foreach (i; 0 .. 3)
    {
        immutable tid = i;
        workers[i] = new Thread({
            size_t round;
            while (!atomicLoad(stop))
            {
                ubyte[][] kept;
                foreach (k; 0 .. 80)
                {
                    auto b = new ubyte[32 + (k % 40) * 24];
                    foreach (n, ref x; b)
                        x = patternFor(tid * 555 + round * 11 + k, n);
                    if (k % 5 == 0)
                        kept ~= b;
                }
                GC.collect();
                foreach (n, b; kept)
                {
                    auto seed = tid * 555 + round * 11 + n * 5;
                    foreach (m, x; b)
                        if (x != patternFor(seed, m))
                        {
                            atomicOp!"+="(failures, 1);
                            break;
                        }
                }
                keepAlive(kept.ptr);
                round++;
            }
        });
    }

    // A thread that keeps exiting, so arenas keep being adopted.
    auto churner = new Thread({
        while (!atomicLoad(stop))
        {
            auto t = new Thread({
                foreach (k; 0 .. 150)
                {
                    auto b = new ubyte[256];
                    b[0] = cast(ubyte) k;
                    keepAlive(b.ptr);
                }
            });
            t.start();
            t.join();
        }
    });

    foreach (t; workers) t.start();
    churner.start();

    foreach (i; 0 .. 30 / workScale + 3)
    {
        tgcCollectGlobal();
        // Flip the tuning flags underneath everyone.
        tgcTrackEscapes(i % 2 == 0);
        tgcGlobalThreshold(i % 3 == 0 ? 0 : 4 * 1024 * 1024);
        Thread.yield();
    }

    atomicStore(stop, true);
    foreach (t; workers) t.join();
    churner.join();

    assert(atomicLoad(failures) == 0,
        "a global collection or a concurrent flag change corrupted live data");
}
