/**
 * What escape tracking costs, and whether it could be the default.
 *
 * `tgcTrackEscapes` closes the one hole thread-private heaps have: a block
 * published to a global, picked up by another thread, then unpublished, is
 * unreachable from anything its owning thread can see while another thread is
 * still using it. Tracking promotes any block seen reachable from a global root
 * and never reclaims it locally, which is sound. It ships off, because the
 * promoted set is sticky and every local collection re-scans it, so pause time
 * grows with everything the program has ever published.
 *
 * A cooperative global collection demotes promoted blocks it proves
 * unreachable, which is what was supposed to bound that growth. The question
 * this probe exists to answer is whether it actually does, on a workload shaped
 * like the pattern escape tracking is for: publish to a global, hand off,
 * unpublish.
 *
 *   dub build --build=release --config=bench-escape
 *   ./bench-escape --DRT-gcopt=gc:tgc            # tracking off, the default
 *   ./bench-escape --DRT-gcopt=gc:tgc --track    # tracking on
 *   ./bench-escape --DRT-gcopt=gc:tgc --track --global=8   # ... with an 8 MB
 *                                                          # global threshold
 */
import core.memory;
import core.time;
import core.stdc.stdio;
import core.stdc.stdlib : atoi;
import tgc.gcobj;

version (LDC)
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

/// A published item: 64 bytes with a couple of references, so promotion has
/// something to trace through rather than a flat leaf.
final class Item
{
    size_t id;
    Item link;
    ubyte[32] payload;
}

/**
 * The global other threads would read from.
 *
 * A fixed-size ring, so the program's *live* published set is bounded and
 * constant: publishing entry N overwrites entry N - ringSize, which is exactly
 * the publish-then-unpublish pattern. Anything promoted beyond what the ring
 * holds is retention the collector has not managed to give back.
 */
enum size_t ringSize = 2_000;
__gshared Item[ringSize] published;

/// Local, unpublished work, so a collection has an ordinary live set too.
__gshared Item[] localLive;

double collectMs()
{
    auto t0 = MonoTime.currTime;
    GC.collect();
    return (MonoTime.currTime - t0).total!"usecs" / 1000.0;
}

/// One round of work: allocate, publish a slice of it, drop the rest.
__gshared bool noPublish;

void round(size_t n, size_t base)
{
    foreach (i; 0 .. n)
    {
        auto it = new Item;
        it.id = base + i;
        // Every tenth item is published, overwriting whatever occupied that
        // slot before -- which is what makes the live published set bounded.
        if (i % 10 == 0 && !noPublish)
        {
            auto slot = (base + i) / 10 % ringSize;
            // A freshly allocated child, *not* the slot's previous occupant:
            // chaining to that would make the ring a set of ever-growing lists
            // and the live set unbounded, which would swamp the thing being
            // measured with an artefact of the probe.
            it.link = new Item;
            published[slot] = it;
        }
        else if (i % 97 == 0)
        {
            localLive[(base + i) / 97 % localLive.length] = it;
        }
    }
}

void main(string[] args)
{
    bool track = false;
    size_t globalMb = 0;
    size_t rounds = 10;
    bool explicitGlobal = false;
    foreach (a; args[1 .. $])
    {
        if (a == "--track")
            track = true;
        else if (a == "--nopublish")
            noPublish = true;   // isolates what tracking costs a program that publishes nothing
        else if (a.length > 9 && a[0 .. 9] == "--rounds=")
            rounds = atoi(a.ptr + 9);
        else if (a.length > 9 && a[0 .. 9] == "--global=")
        {
            globalMb = atoi(a.ptr + 9);
            explicitGlobal = true;
        }
    }

    localLive = new Item[5_000];
    tgcTrackEscapes(track);
    if (explicitGlobal)
        tgcGlobalThreshold(globalMb * 1024 * 1024);

    printf("escape tracking %s, global threshold %zu MB, ring %zu items\n\n",
           tgcTrackEscapes() ? "ON ".ptr : "OFF".ptr,
           tgcGlobalThreshold() / 1048576, ringSize);
    printf("round | allocated | collections | mean pause (ms) | promoted (MB) | heap used (MB)\n");

    // Deliberately *not* calling GC.collect() per round. Forcing collections
    // keeps the heap tidy while bypassing the automatic path entirely -- and
    // the automatic path is where the global-collection trigger lives, so a
    // probe that forces collections measures a program that would never fire
    // the thing being measured. Let the collector decide, and read what it did
    // out of profileStats.
    enum size_t perRound = 200_000;
    size_t base = 0;
    auto prev = GC.profileStats();
    foreach (r; 0 .. rounds)
    {
        round(perRound, base);
        base += perRound;
        keepAlive(cast(void*) published[0]);

        auto now = GC.profileStats();
        immutable size_t n = now.numCollections - prev.numCollections;
        immutable double totalMs =
            (now.totalPauseTime - prev.totalPauseTime).total!"usecs" / 1000.0;
        prev = now;

        if (r % 5 == 0 || r + 1 == rounds)
            printf("%5zu | %9zu | %11zu | %15.2f | %13.1f | %14.1f\n",
                   cast(size_t)(r + 1), base, n, n ? totalMs / n : 0.0,
                   tgcPromotedBytes() / 1048576.0,
                   GC.stats().usedSize / 1048576.0);
    }

    // What an explicit global collection recovers, for comparison with what the
    // automatic trigger managed on its own.
    auto t0 = MonoTime.currTime;
    immutable ran = tgcCollectGlobal();
    immutable globalMs = (MonoTime.currTime - t0).total!"usecs" / 1000.0;
    printf("\ntgcCollectGlobal(): ran=%d, world stopped %.2f ms\n", ran ? 1 : 0, globalMs);
    printf("local pause after it: %.2f ms   heap used %.1f MB\n",
           collectMs(), GC.stats().usedSize / 1048576.0);
}
