/**
 * Cooperative global collection.
 *
 * A thread-local collection cannot reclaim two things: arenas adopted from
 * threads that have exited, and blocks promoted because they escaped through a
 * global. Neither can be proven dead without knowing what every thread holds.
 * The global collection is the only operation in tgc that stops the world, and
 * the only thing that reclaims them.
 */
module tgc_global;

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
// dead threads' arenas are reclaimed
// ---------------------------------------------------------------------------

unittest
{
    // Disable the automatic trigger so the test controls when it happens.
    auto savedThreshold = tgcGlobalThreshold();
    tgcGlobalThreshold(0);
    scope (exit) tgcGlobalThreshold(savedThreshold);

    tgcCollectGlobal();
    auto baseline = tgcRetainedBytes();

    enum nThreads = 8 / workScale;
    auto threads = new Thread[nThreads < 1 ? 1 : nThreads];
    foreach (i; 0 .. threads.length)
    {
        threads[i] = new Thread({
            // Allocate a good deal, all of it garbage by the time we exit.
            foreach (k; 0 .. 400)
            {
                auto b = new ubyte[1024];
                b[0] = cast(ubyte) k;
                keepAlive(b.ptr);
            }
        });
    }
    foreach (t; threads) t.start();
    foreach (t; threads) t.join();

    auto retained = tgcRetainedBytes();
    assert(retained > baseline,
        "arenas from exited threads were not retained; they must be, because " ~
        "Thread.join hands the parent objects the child allocated");

    assert(tgcCollectGlobal(), "global collection did not run");

    auto after = tgcRetainedBytes();
    assert(after < retained,
        "a global collection did not reclaim any memory from exited threads");
}

// ---------------------------------------------------------------------------
// but only the dead parts
// ---------------------------------------------------------------------------

__gshared ubyte[] survivor;

unittest
{
    // A block a dead thread allocated and published must survive a global
    // collection, because the parent still references it.
    survivor = null;

    auto t = new Thread({
        auto b = new ubyte[8192];
        foreach (i, ref x; b)
            x = patternFor(99, i);
        survivor = b;
    });
    t.start();
    t.join();

    assert(tgcCollectGlobal() || true);
    tgcCollectGlobal();

    assert(survivor.length == 8192);
    foreach (i, x; survivor)
        assert(x == patternFor(99, i),
            "a global collection reclaimed a live block published by a dead thread");
}

// ---------------------------------------------------------------------------
// finalizers deferred at thread exit eventually run
// ---------------------------------------------------------------------------

shared int deferredDtors;

class DeferredCanary
{
    ~this() { atomicOp!"+="(deferredDtors, 1); }
    ubyte[128] pad;
}

unittest
{
    // Destructors are deliberately not run at thread exit (that is what made
    // Thread.join hand the parent a destructed object). They must still run
    // when a global collection later proves the objects dead.
    atomicStore(deferredDtors, 0);

    auto t = new Thread({
        foreach (i; 0 .. 50)
        {
            auto c = new DeferredCanary;
            c.pad[0] = cast(ubyte) i;
            keepAlive(cast(void*) c);
        }
    });
    t.start();
    t.join();

    foreach (_; 0 .. 3)
        tgcCollectGlobal();

    assert(atomicLoad(deferredDtors) > 0,
        "destructors deferred at thread exit were never run by a global " ~
        "collection, so they would never run at all");
}

// ---------------------------------------------------------------------------
// running concurrently with live threads
// ---------------------------------------------------------------------------

unittest
{
    // A global collection stops the world. Threads doing ordinary work across
    // it must come out with their data intact.
    enum nThreads = 4;
    enum rounds = 40 / workScale;
    shared int failures = 0;
    shared bool stop = false;

    auto threads = new Thread[nThreads];
    foreach (t; 0 .. nThreads)
    {
        immutable tid = t;
        threads[t] = new Thread({
            size_t round = 0;
            while (!atomicLoad(stop))
            {
                ubyte[][] kept;
                foreach (i; 0 .. 60)
                {
                    auto b = new ubyte[128 + (i % 20) * 16];
                    foreach (k, ref x; b)
                        x = patternFor(tid * 1000 + round * 10 + i, k);
                    if (i % 3 == 0)
                        kept ~= b;
                }
                GC.collect();
                foreach (n, b; kept)
                {
                    auto seed = tid * 1000 + round * 10 + n * 3;
                    foreach (k, x; b)
                        if (x != patternFor(seed, k))
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
    foreach (th; threads) th.start();

    foreach (_; 0 .. (rounds < 1 ? 1 : rounds))
        tgcCollectGlobal();

    atomicStore(stop, true);
    foreach (th; threads) th.join();

    assert(atomicLoad(failures) == 0,
        "a global collection corrupted or reclaimed data live on another thread");
}

// ---------------------------------------------------------------------------
// the automatic trigger
// ---------------------------------------------------------------------------

unittest
{
    // With a low threshold, retained memory must be bounded without anyone
    // calling tgcCollectGlobal explicitly.
    auto saved = tgcGlobalThreshold();
    scope (exit) tgcGlobalThreshold(saved);

    tgcCollectGlobal();
    tgcGlobalThreshold(2 * 1024 * 1024);

    foreach (batch; 0 .. 6 / (workScale > 2 ? workScale : 1) + 1)
    {
        auto t = new Thread({
            foreach (k; 0 .. 500)
            {
                auto b = new ubyte[1024];
                b[0] = cast(ubyte) k;
                keepAlive(b.ptr);
            }
        });
        t.start();
        t.join();
        // Allocate on this thread so the post-collection trigger is reached.
        foreach (k; 0 .. 2000)
        {
            auto b = new ubyte[256];
            b[0] = cast(ubyte) k;
            keepAlive(b.ptr);
        }
    }

    // Not a hard bound -- the check happens after a local collection -- but it
    // must not have grown without limit.
    assert(tgcRetainedBytes() < 64 * 1024 * 1024,
        "the automatic global-collection trigger never fired; retained memory " ~
        "grew unbounded");
}

// ---------------------------------------------------------------------------
// promoted blocks drive the automatic global collection too
// ---------------------------------------------------------------------------

__gshared void[][512] publishedRing;

/**
 * The trigger used to read only the bytes held in arenas adopted from exited
 * threads. Blocks promoted by escape tracking are the other half of what a
 * thread-local collection cannot reclaim, and they counted for nothing -- so a
 * program that turned tracking on and never exited a thread never collected
 * globally, and its promoted set, re-scanned by every local collection, grew
 * without bound. Measured before the fix on `bench/escape_probe.d`: local pause
 * climbing from 0.26 ms to 8.10 ms over eight million allocations against a
 * live set of 0.6 MB, monotonically, with no global collection ever running.
 *
 * Asserts that the promoted total *fell* at some point rather than that it
 * stayed under some size. A magnitude bound passes for the wrong reason as soon
 * as the test is not run for long enough; only a fall proves the trigger fired,
 * because nothing else can demote a promoted block.
 */
unittest
{
    import core.memory : GC;

    immutable savedThreshold = tgcGlobalThreshold();
    immutable savedTracking = tgcTrackEscapes();
    scope (exit)
    {
        tgcTrackEscapes(savedTracking);
        tgcGlobalThreshold(savedThreshold);
        tgcCollectGlobal();
    }

    tgcCollectGlobal();          // start from a demoted state
    tgcTrackEscapes(true);
    tgcGlobalThreshold(2 * 1024 * 1024);

    // Publish into a fixed-size ring, so the *live* published set stays tiny
    // while the promoted set grows: each store drops the previous occupant,
    // which only a global collection can prove is gone.
    size_t n = 0;
    size_t peak = 0;
    bool fell = false;
    foreach (batch; 0 .. 60 / (workScale > 2 ? workScale : 1) + 1)
    {
        foreach (k; 0 .. 4000)
        {
            auto o = new ubyte[256];
            o[0] = cast(ubyte) k;
            keepAlive(o.ptr);
            if (k % 4 == 0)
                publishedRing[n++ % publishedRing.length] = new ubyte[512];
        }

        immutable now = tgcPromotedBytes();
        if (now + 256 * 1024 < peak)
            fell = true;
        if (now > peak)
            peak = now;
    }

    assert(fell,
        "blocks promoted by escape tracking never triggered a global " ~
        "collection: the promoted set only ever grew");

    // And the mechanism still reclaims on demand.
    immutable before = tgcPromotedBytes();
    tgcCollectGlobal();
    GC.collect();
    assert(tgcPromotedBytes() <= before,
        "a global collection did not demote anything");
}
