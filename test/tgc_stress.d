/**
 * Allocator stress tests for `tgc`.
 *
 * These hammer the boundaries the arena allocator actually has: size-class
 * edges, the small/large chunk transition, chunk release and reuse, remote
 * frees, and interleaved collection. Every block carries a checkable fill
 * pattern, so a slot handed out twice, released early, or resolved to the
 * wrong block shows up as corrupted data rather than as a silent survival.
 */
module tgc_stress;

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
    {
        asm @nogc nothrow { "" : : "r"(p) : "memory"; }
    }
}
else version (GNU)
{
    private void keepAlive(void* p) @nogc nothrow
    {
        asm @nogc nothrow { "" : : "r"(p) : "memory"; }
    }
}
else
{
    private __gshared void* keepAliveSlot;

    pragma(inline, false)
    private void keepAlive(void* p) @nogc nothrow
    {
        keepAliveSlot = p;
    }
}

/// Deterministic per-block fill so cross-talk between blocks is detectable.
private ubyte patternFor(size_t seed, size_t i)
{
    return cast(ubyte)((seed * 31 + i * 7 + 11) & 0xFF);
}

private void fill(ubyte[] b, size_t seed)
{
    foreach (i, ref x; b)
        x = patternFor(seed, i);
}

private void verify(const(ubyte)[] b, size_t seed, string what)
{
    foreach (i, x; b)
        assert(x == patternFor(seed, i), what);
}

// ---------------------------------------------------------------------------
// size-class boundaries and the small/large transition
// ---------------------------------------------------------------------------

unittest
{
    // maxSmall is 8192; sizes either side of it take completely different
    // paths (slot in a shared chunk vs. a dedicated chunk run).
    static immutable sizes = [
        1, 15, 16, 17, 31, 32, 33, 63, 64, 65,
        127, 128, 129, 255, 256, 257, 511, 512, 513,
        1023, 1024, 1025, 2047, 2048, 2049, 4095, 4096, 4097,
        8191, 8192, 8193, 16383, 16384, 65535, 65536, 65537, 200_000,
    ];

    ubyte[][] blocks;
    foreach (seed, sz; sizes)
    {
        auto b = new ubyte[sz];
        fill(b, seed);
        blocks ~= b;
    }

    // Every block must be 16-byte aligned and report at least its own size.
    foreach (b; blocks)
    {
        assert((cast(size_t) b.ptr & 15) == 0, "block not 16-byte aligned");
        assert(GC.sizeOf(b.ptr) >= b.length, "GC.sizeOf under-reports capacity");
        assert(GC.addrOf(b.ptr) is b.ptr, "GC.addrOf did not resolve to the base");
        // An interior pointer must resolve to the same base.
        if (b.length > 1)
            assert(GC.addrOf(b.ptr + b.length - 1) is b.ptr,
                "interior pointer resolved to the wrong block");
    }

    GC.collect();

    foreach (seed, b; blocks)
        verify(b, seed, "block corrupted across a collection");

    keepAlive(blocks.ptr);
}

// ---------------------------------------------------------------------------
// churn: allocate, drop, collect, reuse
// ---------------------------------------------------------------------------

unittest
{
    // Repeatedly fill and drop a working set so chunks are emptied, released
    // and re-created. A slot handed out while still live, or a chunk released
    // with a live slot in it, corrupts the pattern.
    enum rounds = 40 / workScale;
    enum perRound = 300;

    foreach (round; 0 .. rounds)
    {
        ubyte[][] live;
        foreach (i; 0 .. perRound)
        {
            // Mix size classes, including across the small/large boundary.
            size_t sz = [24, 100, 700, 3000, 9000][i % 5] + (i % 17);
            auto b = new ubyte[sz];
            fill(b, round * 1000 + i);
            live ~= b;
        }

        // Drop half, keep half, then collect.
        ubyte[][] kept;
        foreach (i, b; live)
            if (i % 2 == 0)
                kept ~= b;
        live = null;

        GC.collect();

        foreach (i, b; kept)
            verify(b, round * 1000 + i * 2, "surviving block corrupted by churn");

        keepAlive(kept.ptr);
    }
}

// ---------------------------------------------------------------------------
// explicit free and reuse
// ---------------------------------------------------------------------------

unittest
{
    // GC.free must return the slot for reuse without disturbing neighbours.
    enum n = 500;
    void*[] ptrs;
    foreach (i; 0 .. n)
    {
        auto b = cast(ubyte*) GC.malloc(64);
        (b[0 .. 64])[] = cast(ubyte)(i & 0xFF);
        ptrs ~= b;
    }

    // Free every other one.
    foreach (i; 0 .. n)
        if (i % 2 == 0)
            GC.free(ptrs[i]);

    // The survivors must be untouched.
    foreach (i; 0 .. n)
    {
        if (i % 2 == 0)
            continue;
        auto b = cast(ubyte*) ptrs[i];
        foreach (k; 0 .. 64)
            assert(b[k] == cast(ubyte)(i & 0xFF),
                "GC.free of a neighbouring block corrupted this one");
    }

    // Reallocate into the freed slots and re-check the survivors.
    foreach (i; 0 .. n / 2)
    {
        auto b = cast(ubyte*) GC.malloc(64);
        (b[0 .. 64])[] = 0xEE;
    }
    foreach (i; 0 .. n)
    {
        if (i % 2 == 0)
            continue;
        auto b = cast(ubyte*) ptrs[i];
        foreach (k; 0 .. 64)
            assert(b[k] == cast(ubyte)(i & 0xFF),
                "a reused slot overlapped a still-live block");
    }
    keepAlive(ptrs.ptr);
}

// ---------------------------------------------------------------------------
// realloc across the size-class and small/large boundaries
// ---------------------------------------------------------------------------

unittest
{
    // Grow a block step by step across every interesting boundary, checking
    // the prefix survives each move.
    size_t sz = 8;
    auto p = cast(ubyte*) GC.malloc(sz);
    foreach (i; 0 .. sz)
        p[i] = patternFor(1, i);

    foreach (target; [16, 33, 100, 600, 2000, 5000, 8192, 8200, 20_000, 70_000, 300_000])
    {
        p = cast(ubyte*) GC.realloc(p, target, 0, null);
        assert((cast(size_t) p & 15) == 0, "realloc returned a misaligned block");
        // The original prefix must have been carried over.
        foreach (i; 0 .. sz)
            assert(p[i] == patternFor(1, i),
                "realloc lost data crossing a size-class boundary");
        // Extend the pattern into the new space.
        foreach (i; sz .. target)
            p[i] = patternFor(1, i);
        sz = target;
        GC.collect();
        foreach (i; 0 .. sz)
            assert(p[i] == patternFor(1, i), "realloc'd block damaged by a collection");
    }
    keepAlive(p);
}

// ---------------------------------------------------------------------------
// concurrent churn across private heaps
// ---------------------------------------------------------------------------

unittest
{
    // Each thread hammers its own heap while the others do the same. Private
    // heaps mean this must need no synchronisation at all; if a chunk map or
    // free list is being shared by accident, the patterns break.
    enum nThreads = 4;
    enum rounds = 15 / workScale;
    shared int failures = 0;

    auto threads = new Thread[nThreads];
    foreach (t; 0 .. nThreads)
    {
        immutable tid = t;
        threads[t] = new Thread({
            foreach (round; 0 .. (rounds < 1 ? 1 : rounds))
            {
                ubyte[][] kept;
                foreach (i; 0 .. 200)
                {
                    size_t sz = [32, 300, 1500, 9000][i % 4] + i % 13;
                    auto b = new ubyte[sz];
                    fill(b, tid * 100_000 + round * 1000 + i);
                    if (i % 3 == 0)
                        kept ~= b;
                }
                GC.collect();
                foreach (k, b; kept)
                {
                    auto seed = tid * 100_000 + round * 1000 + k * 3;
                    foreach (i, x; b)
                    {
                        if (x != patternFor(seed, i))
                        {
                            atomicOp!"+="(failures, 1);
                            break;
                        }
                    }
                }
                keepAlive(kept.ptr);
            }
        });
    }
    foreach (th; threads)
        th.start();
    foreach (th; threads)
        th.join();

    assert(atomicLoad(failures) == 0,
        "concurrent allocation across private heaps corrupted live data");
}

// ---------------------------------------------------------------------------
// many threads created and destroyed
// ---------------------------------------------------------------------------

unittest
{
    // Heap creation and teardown is the path that unregisters chunk maps and
    // frees arenas; run it repeatedly to shake out ordering mistakes.
    enum batches = 10 / workScale;
    foreach (b; 0 .. (batches < 1 ? 1 : batches))
    {
        auto threads = new Thread[4];
        foreach (i; 0 .. 4)
        {
            threads[i] = new Thread({
                ubyte[][] keep;
                foreach (k; 0 .. 100)
                {
                    auto x = new ubyte[k * 37 % 9000 + 16];
                    fill(x, k);
                    if (k % 4 == 0)
                        keep ~= x;
                }
                GC.collect();
                foreach (k, x; keep)
                    verify(x, k * 4, "data lost in a short-lived thread");
                keepAlive(keep.ptr);
            });
        }
        foreach (t; threads)
            t.start();
        foreach (t; threads)
            t.join();
    }

    // The main thread's own heap must be unaffected by all that churn.
    auto mine = new ubyte[1024];
    fill(mine, 7);
    GC.collect();
    verify(mine, 7, "main thread data damaged by other threads' teardown");
    keepAlive(mine.ptr);
}

// ---------------------------------------------------------------------------
// GC.extend must not claim an extension it did not perform
// ---------------------------------------------------------------------------

unittest
{
    // `extend(p, minsize, maxsize, ti)` asks to enlarge the block by at least
    // `minsize` *additional* bytes, and a non-zero return means it really was
    // enlarged. Reading it as "is the block already this big" made tgc claim
    // success without growing anything, after which the runtime wrote past the
    // end of the slot into its neighbour — corrupting the free-list pointer
    // threaded through free slots.
    //
    // This was found by running the binary-trees benchmark, not by this suite,
    // which is why it is here now.
    enum n = 400;
    void*[] blocks;
    foreach (i; 0 .. n)
    {
        auto p = GC.malloc(64);
        (cast(ubyte*) p)[0 .. 64] = cast(ubyte)(i & 0xFF);
        blocks ~= p;
    }

    foreach (i, p; blocks)
    {
        auto sz = GC.sizeOf(p);
        // Ask for more than the block holds.
        auto got = GC.extend(p, sz + 1, sz + 4096);
        assert(got == 0 || got >= sz + 1,
            "GC.extend returned a size that does not satisfy the request");
        if (got != 0)
        {
            // If it claims success the space must genuinely be there; writing
            // it must not disturb any neighbour.
            (cast(ubyte*) p)[0 .. got] = cast(ubyte)(i & 0xFF);
        }
    }

    // Every block must still hold its own pattern.
    foreach (i, p; blocks)
    {
        auto b = cast(ubyte*) p;
        foreach (k; 0 .. 64)
            assert(b[k] == cast(ubyte)(i & 0xFF),
                "GC.extend overran a block into its neighbour");
    }

    GC.collect();
    foreach (i, p; blocks)
    {
        auto b = cast(ubyte*) p;
        foreach (k; 0 .. 64)
            assert(b[k] == cast(ubyte)(i & 0xFF),
                "block damaged after a collection following GC.extend");
    }
    keepAlive(blocks.ptr);
}

unittest
{
    // The path that actually broke: phobos' formatting builds strings through
    // the array-append machinery, interleaved with a live linked structure.
    static class Node
    {
        Node left, right;
        this(Node l, Node r) { left = l; right = r; }
        int check() { int r = 1; if (left) r += left.check(); if (right) r += right.check(); return r; }
        static Node create(int d)
        {
            if (d > 0) return new Node(create(d - 1), create(d - 1));
            return new Node(null, null);
        }
    }

    import std.format : format;

    enum depth = 10 - (workScale > 1 ? 3 : 0);
    auto longLived = Node.create(depth);
    immutable expected = longLived.check();

    foreach (round; 0 .. 40 / workScale)
    {
        auto t = Node.create(depth);
        auto s = format("round %d check %d", round, t.check());
        assert(s.length > 0);
        assert(longLived.check() == expected,
            "a long-lived structure was corrupted while formatting strings");
    }
    keepAlive(cast(void*) longLived);
}
