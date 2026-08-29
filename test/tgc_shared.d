/**
 * Cross-thread escape tests for `tgc`.
 *
 * A block that has ever been reachable from a global root may be held by
 * another thread, so a thread-local collection must never reclaim it — even
 * once it is unreachable from every root the owning thread can see. See
 * CROSS-THREAD.md for why this cannot be decided at allocation time from D's
 * type qualifiers, and has to be an escape test at collection time.
 */
module tgc_shared;

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

private void scrubStack(int depth = 48)
{
    ubyte[512] junk = 0xEE;
    if (depth > 0)
        scrubStack(depth - 1);
    keepAlive(junk.ptr);
}

// ---------------------------------------------------------------------------
// publish, share, unpublish
// ---------------------------------------------------------------------------

__gshared int escapedDtorRan;

class Escaped
{
    ~this() { escapedDtorRan = 1; }
    ubyte[64] payload;
    Child child;
}

class Child
{
    ubyte[64] payload;
}

/// The only global reference. Cleared partway through the test.
__gshared Escaped published;

private void publish()
{
    auto e = new Escaped;
    e.payload[] = 0xC7;
    // A child that is never itself published: it is reachable only *through*
    // the escaped object, and must be kept alive by the same rule.
    e.child = new Child;
    e.child.payload[] = 0x3D;
    published = e;
}

/**
 * Hide an address from the conservative collector.
 *
 * A test for "this block must survive without any local reference" cannot keep
 * the pointer in a scanned location — stack, TLS or globals are all roots, and
 * holding the address there retains the block by itself and makes the test
 * vacuous. Storing the complement keeps the bit pattern unrecognisable as a
 * pointer.
 */
private size_t hide(void* p) { return (cast(size_t) p) ^ size_t.max; }
private void* unhide(size_t v) { return cast(void*)(v ^ size_t.max); }

shared size_t hiddenEscaped;
shared size_t hiddenChild;

unittest
{
    // Escape promotion is opt-in; see CROSS-THREAD.md for why it is not the
    // default (the promoted set is sticky, so pause time grows with everything
    // ever published).
    assert(!tgcTrackEscapes(), "escape tracking should default to off");
    tgcTrackEscapes(true);
    scope (exit) tgcTrackEscapes(false);

    escapedDtorRan = 0;
    publish();
    scrubStack();

    // Promotion is sampled at collection time: a block is promoted when a
    // collection observes it reachable from a global. This collection is what
    // performs the promotion, and it is the guarantee being tested. A block
    // published and unpublished entirely between two collections is never
    // sampled and is NOT covered -- see CROSS-THREAD.md.
    GC.collect();

    // Another thread observes it, exactly as a worker would.
    auto t = new Thread({
        auto e = published;
        atomicStore(hiddenEscaped, hide(cast(void*) e));
        atomicStore(hiddenChild, hide(cast(void*) e.child));
    });
    t.start();
    t.join();

    // Drop the global. The object is now unreachable from every root this
    // thread can see, and no live reference to it exists anywhere the
    // collector scans — only the obfuscated addresses above.
    published = null;
    scrubStack();
    foreach (_; 0 .. 4)
        GC.collect();

    assert(!escapedDtorRan,
        "a block that had escaped through a global was finalized after the " ~
        "global was cleared; another thread could still hold it");

    auto p = unhide(atomicLoad(hiddenEscaped));
    auto pc = unhide(atomicLoad(hiddenChild));
    assert(GC.sizeOf(p) > 0,
        "a block that had escaped through a global was freed after the " ~
        "global was cleared");
    assert(GC.sizeOf(pc) > 0,
        "a child reachable only through an escaped block was freed; " ~
        "promotion must be transitive");

    auto e = cast(Escaped) p;
    foreach (b; e.payload)
        assert(b == 0xC7, "escaped block corrupted");
    foreach (b; e.child.payload)
        assert(b == 0x3D, "child of an escaped block corrupted");
}

// ---------------------------------------------------------------------------
// promotion must not swallow ordinary garbage
// ---------------------------------------------------------------------------

unittest
{
    // Escape analysis is only useful if it stays narrow: data that never
    // touches a global must still be reclaimed normally, or every program
    // leaks.
    scrubStack();
    GC.collect();
    GC.collect();
    auto baseline = GC.stats().usedSize;

    enum n = 3000 / workScale;
    GC.disable();
    foreach (i; 0 .. n)
    {
        auto junk = new ubyte[512];
        junk[0] = cast(ubyte) i;
        keepAlive(junk.ptr);
    }
    auto peak = GC.stats().usedSize;
    GC.enable();

    assert(peak > baseline + (n * 512) / 2, "allocation did not grow the heap");

    scrubStack();
    GC.collect();
    GC.collect();
    auto after = GC.stats().usedSize;

    assert(after < baseline + (peak - baseline) / 2,
        "purely thread-local garbage was retained; promotion is over-eager");
}

// ---------------------------------------------------------------------------
// a worker publishing into a global its parent later reads
// ---------------------------------------------------------------------------

__gshared ubyte[] workerResult;

unittest
{
    // The natural shape of a worker handing a result back: the block is
    // allocated on the worker's heap and published through a global. It must
    // survive both the worker's own collections and its exit.
    workerResult = null;

    auto t = new Thread({
        auto buf = new ubyte[4096];
        foreach (i, ref b; buf)
            b = cast(ubyte)(i & 0xFF);
        workerResult = buf;
        // Collect on the worker *after* publishing.
        GC.collect();
        GC.collect();
    });
    t.start();
    t.join();

    assert(workerResult.length == 4096);
    foreach (i, b; workerResult)
        assert(b == cast(ubyte)(i & 0xFF),
            "a result published by a worker was corrupted or reclaimed");

    // And it survives the parent collecting too.
    GC.collect();
    GC.collect();
    foreach (i, b; workerResult)
        assert(b == cast(ubyte)(i & 0xFF),
            "a worker's published result was reclaimed by the parent");
}

// ---------------------------------------------------------------------------
// the default: escape tracking off
// ---------------------------------------------------------------------------

__gshared int unpromotedDtorRan;
class Unpromoted { ~this() { unpromotedDtorRan = 1; } ubyte[64] pad; }
__gshared Unpromoted publishedUnpromoted;

private void publishUnpromoted()
{
    publishedUnpromoted = new Unpromoted;
}

unittest
{
    // With tracking off, a block that stops being globally reachable is
    // reclaimed normally. This is the documented default, and the reason it is
    // the default: no permanent growth in the scanned set.
    assert(!tgcTrackEscapes());

    unpromotedDtorRan = 0;
    publishUnpromoted();
    scrubStack();
    GC.collect();

    publishedUnpromoted = null;
    scrubStack();
    foreach (_; 0 .. 5)
    {
        GC.collect();
        if (unpromotedDtorRan)
            break;
    }

    assert(unpromotedDtorRan,
        "with escape tracking off, an unpublished block should be reclaimed " ~
        "like any other garbage");
}

unittest
{
    // Turning tracking on must not disturb ordinary thread-local reclamation.
    tgcTrackEscapes(true);
    scope (exit) tgcTrackEscapes(false);

    scrubStack();
    GC.collect();
    GC.collect();
    auto baseline = GC.stats().usedSize;

    enum n = 2000 / workScale;
    GC.disable();
    foreach (i; 0 .. n)
    {
        auto junk = new ubyte[512];
        junk[0] = cast(ubyte) i;
        keepAlive(junk.ptr);
    }
    auto peak = GC.stats().usedSize;
    GC.enable();

    scrubStack();
    GC.collect();
    GC.collect();
    auto after = GC.stats().usedSize;

    assert(after < baseline + (peak - baseline) / 2,
        "escape tracking retained purely thread-local garbage");
}
