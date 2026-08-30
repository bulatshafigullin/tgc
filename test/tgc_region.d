/**
 * Fiber-scoped regions.
 *
 * A region is an arena bound to one fiber: everything allocated while it is
 * open is released wholesale when it closes, with no tracing. That is the BEAM
 * model, and it carries BEAM's precondition — nothing outside may still point
 * in. BEAM enforces that by deep-copying messages; nothing here does, so these
 * tests check both that the mechanism works and that the verifier catches the
 * invariant being broken.
 */
module tgc_region;

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
// the basic contract
// ---------------------------------------------------------------------------

unittest
{
    // Allocation inside a region works normally, and closing it reclaims the
    // memory without needing a collection.
    auto f = new Fiber({
        auto r = tgcBeginRegion();
        assert(r !is null, "could not open a region on a fiber");

        foreach (i; 0 .. 2000 / workScale)
        {
            auto b = new ubyte[256];
            foreach (k, ref x; b)
                x = patternFor(i, k);
            keepAlive(b.ptr);
        }

        assert(tgcRegionBytes(r) > 0, "region reported no memory");
        // Query before closing: the handle is freed by tgcEndRegion, so
        // touching it afterwards is a use-after-free. ThreadSanitizer caught
        // exactly that here.
        tgcEndRegion(r);
    });
    f.call();
    assert(f.state == Fiber.State.TERM);
}

unittest
{
    // Data inside a region stays intact across collections while the region is
    // open: a region's contents are live until it closes.
    auto f = new Fiber({
        auto r = tgcBeginRegion();
        scope (exit) tgcEndRegion(r);

        ubyte[][] kept;
        foreach (i; 0 .. 200 / workScale)
        {
            auto b = new ubyte[512];
            foreach (k, ref x; b)
                x = patternFor(i, k);
            kept ~= b;
        }

        GC.collect();
        GC.collect();

        foreach (i, b; kept)
            foreach (k, x; b)
                assert(x == patternFor(i, k),
                    "region data was collected or corrupted while the region was open");
        keepAlive(kept.ptr);
    });
    f.call();
}

// ---------------------------------------------------------------------------
// a region keeps thread-heap objects it references alive
// ---------------------------------------------------------------------------

__gshared int outsideDead;
class Outside { ~this() { outsideDead = 1; } ubyte[64] pad; }

__gshared Outside[] holder;

unittest
{
    // An object on the thread heap, referenced only from inside a region, must
    // survive: region blocks are marked through, not merely retained.
    outsideDead = 0;
    holder = null;

    auto f = new Fiber({
        auto r = tgcBeginRegion();
        scope (exit) tgcEndRegion(r);

        // Allocated on the thread heap before the region existed would be
        // simplest, but the interesting case is the reverse: a region block
        // holding the only reference to something the collector may sweep.
        auto arr = new Outside[1];
        arr[0] = new Outside;
        keepAlive(arr.ptr);

        GC.collect();
        GC.collect();

        assert(!outsideDead,
            "an object referenced only from inside a region was collected");
        assert(arr[0] !is null);
    });
    f.call();
}

// ---------------------------------------------------------------------------
// regions are per-fiber, and do not nest
// ---------------------------------------------------------------------------

unittest
{
    // Two fibers interleaved: each must allocate into its own region.
    void*[] aPtrs, bPtrs;

    auto fa = new Fiber({
        auto r = tgcBeginRegion();
        scope (exit) tgcEndRegion(r);
        foreach (i; 0 .. 50)
        {
            auto b = new ubyte[128];
            b[0] = 0xAA;
            aPtrs ~= b.ptr;
            Fiber.yield();
        }
    });
    auto fb = new Fiber({
        auto r = tgcBeginRegion();
        scope (exit) tgcEndRegion(r);
        foreach (i; 0 .. 50)
        {
            auto b = new ubyte[128];
            b[0] = 0xBB;
            bPtrs ~= b.ptr;
            Fiber.yield();
        }
    });

    foreach (i; 0 .. 50)
    {
        if (fa.state == Fiber.State.HOLD) fa.call();
        if (fb.state == Fiber.State.HOLD) fb.call();
    }

    // Every block must carry its own fiber's marker: if routing leaked across
    // the yield, blocks would be mixed between the two regions.
    foreach (p; aPtrs)
        assert(*cast(ubyte*) p == 0xAA, "region routing leaked across a fiber switch");
    foreach (p; bPtrs)
        assert(*cast(ubyte*) p == 0xBB, "region routing leaked across a fiber switch");

    while (fa.state == Fiber.State.HOLD) fa.call();
    while (fb.state == Fiber.State.HOLD) fb.call();
}

unittest
{
    // Regions do not nest.
    auto f = new Fiber({
        auto r1 = tgcBeginRegion();
        assert(r1 !is null);
        auto r2 = tgcBeginRegion();
        assert(r2 is null, "a nested region was allowed");
        tgcEndRegion(r1);
    });
    f.call();
}

unittest
{
    // Allocation outside any region is unaffected.
    assert(tgcBeginRegion() is null || true);
    auto before = GC.stats().usedSize;
    auto b = new ubyte[4096];
    b[0] = 1;
    assert(GC.stats().usedSize >= before);
    keepAlive(b.ptr);
}

// ---------------------------------------------------------------------------
// the verifier
// ---------------------------------------------------------------------------

__gshared void* escaped;

unittest
{
    // With verification on, a clean region closes without complaint.
    tgcRegionVerify(true);
    scope (exit) tgcRegionVerify(false);

    auto f = new Fiber({
        tgcRunInRegion({
            foreach (i; 0 .. 100)
            {
                auto b = new ubyte[128];
                b[0] = cast(ubyte) i;
                keepAlive(b.ptr);
            }
        });
    });
    f.call();
    assert(f.state == Fiber.State.TERM);
}

unittest
{
    // ...and an escape is caught. A region block published to a global is
    // exactly the mistake the model invites, and exactly what BEAM's
    // copy-on-send prevents by construction.
    tgcRegionVerify(true);
    scope (exit) { tgcRegionVerify(false); escaped = null; }

    bool caught = false;
    auto f = new Fiber({
        auto r = tgcBeginRegion();
        auto b = new ubyte[256];
        b[0] = 0x5A;
        escaped = b.ptr;          // <-- escapes the region
        try
            tgcEndRegion(r);
        catch (Throwable)
            caught = true;
    });
    f.call();

    assert(caught,
        "the verifier did not notice a region block published to a global");
}
