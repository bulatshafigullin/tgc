/**
 * Giving memory back, and asking for it up front.
 *
 * Chunks are carved out of large mappings, so a segment can only be unmapped
 * once every chunk in it is free — one live chunk pins the whole thing. That
 * used to mean a process held its peak until something called `GC.minimize()`,
 * which is a surprising default and the most likely thing about this collector
 * to be reported as a leak. A collection now hands back what a shrunken heap is
 * no longer using, and `GC.reserve` maps and faults in memory up front instead
 * of returning 0.
 */
module tgc_memory;

import tgc.gcobj;
import core.memory;

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

version (TgcSanitize) private enum settleRounds = 40;
else private enum settleRounds = 5;

private void settle()
{
    foreach (_; 0 .. settleRounds)
    {
        scrubStack();
        GC.collect();
    }
}

/**
 * Settle, then wait out the trim's window and settle again.
 *
 * The trim judges demand over a window of wall time — that is its hysteresis,
 * and the reason a heap oscillating between collections keeps its headroom.
 * Collections back to back all land inside the window in which the peak was
 * still standing, so a test that wants to observe a trim has to let the window
 * close first.
 */
private void settlePastTrimWindow()
{
    import core.thread : Thread;
    import core.time : msecs;

    settle();
    Thread.sleep(msecs(600));
    settle();
}

/**
 * Allocate a burst and drop it, in a frame that goes away.
 *
 * Not inlined, and the objects are deliberately allocated one after another
 * rather than scattered: what is being measured is the ordinary shape of a
 * request-scoped workload, where a burst of allocation is nearly all dead once
 * the burst is over and whole chunks fall free together. Survivors spread
 * through every chunk would pin them, and rightly so — that is fragmentation,
 * not retention, and no amount of trimming can help it.
 */
pragma(inline, false)
private void burst(size_t count)
{
    static final class Node { size_t a; Node next; }

    Node head;
    foreach (_; 0 .. count)
    {
        auto n = new Node;
        n.next = head;
        head = n;
    }
    keepAlive(cast(void*) head);
}

// ---------------------------------------------------------------------------
// a shrunken heap returns its memory without being asked
// ---------------------------------------------------------------------------

unittest
{
    immutable savedRatio = tgcTrimRatio();
    immutable savedSeg = tgcSegmentSize();
    scope (exit)
    {
        tgcTrimRatio(savedRatio);
        tgcSegmentSize(savedSeg);
    }

    // Small segments so the peak is reached with a burst that runs quickly, and
    // so the floor the trim will not go below is small enough to see past.
    tgcSegmentSize(2 * 1024 * 1024);

    // Build and drop the peak with the automatic return switched off, which is
    // the behaviour this replaces: the chunks go back to the segment allocator,
    // which keeps them mapped.
    tgcTrimRatio(0);
    settle();
    burst(400_000);
    settle();
    immutable held = tgcCommittedBytes();

    // Turn it on and collect again. Nothing else changes -- same live set, same
    // heap -- so any drop is the trim.
    tgcTrimRatio(1);
    settlePastTrimWindow();
    immutable trimmed = tgcCommittedBytes();

    assert(trimmed < held,
        "a heap that dropped its peak went on holding the memory; the " ~
        "automatic trim returned nothing");

    // And it is bounded: a program that keeps allocating gets to keep its
    // headroom rather than handing back pages it is about to fault in again.
    tgcTrimRatio(size_t.max);
    burst(50_000);
    settlePastTrimWindow();
    immutable withHeadroom = tgcCommittedBytes();
    settlePastTrimWindow();
    assert(tgcCommittedBytes() >= withHeadroom,
        "a ratio that can never be exceeded still returned memory");
}

// ---------------------------------------------------------------------------
// reserve
// ---------------------------------------------------------------------------

unittest
{
    enum size_t want = 8 * 1024 * 1024;

    immutable got = GC.reserve(want);
    assert(got >= want,
        "GC.reserve did not reserve what it was asked for");

    // Whatever it reserved is backed and resident, so it is accounted for.
    assert(tgcCommittedBytes() >= got,
        "GC.reserve reported memory the allocator does not have");

    assert(GC.reserve(0) == 0, "GC.reserve(0) reserved something");

    // The reservation is usable, not just mapped: allocating into it works and
    // the memory is sound.
    auto a = new ubyte[want / 2];
    a[0] = 1;
    a[$ - 1] = 2;
    keepAlive(a.ptr);
    assert(a[0] == 1 && a[$ - 1] == 2, "memory allocated after a reserve is bad");
}

// ---------------------------------------------------------------------------
// minimize still does more than a collection does
// ---------------------------------------------------------------------------

unittest
{
    // The trim leaves a floor of one segment behind and only runs once its
    // window has closed; `GC.minimize()` is the documented "give it back now"
    // call and honours neither. It must therefore never leave *more* committed
    // than a plain collection would.
    immutable savedSeg = tgcSegmentSize();
    scope (exit)
        tgcSegmentSize(savedSeg);
    tgcSegmentSize(2 * 1024 * 1024);

    burst(200_000);
    settlePastTrimWindow();
    immutable afterCollect = tgcCommittedBytes();
    GC.minimize();
    assert(tgcCommittedBytes() <= afterCollect,
        "GC.minimize() left more committed than a collection did");
}
