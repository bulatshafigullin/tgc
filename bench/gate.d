/**
 * The regression gate: what CI checks on every change.
 *
 * Nothing here is a benchmark result. A benchmark answers "how fast is it",
 * which a shared CI runner cannot tell you; this answers "did something break",
 * which it can, provided every number it looks at is either exact or
 * dimensionless. That constraint is what shapes the whole file:
 *
 * * **Best of N, not mean of N.** Interference only ever makes a collection
 *   slower, so the minimum of several is the closest thing to the machine's
 *   real number and is remarkably reproducible: six consecutive runs on the
 *   same live set gave 1.19, 1.19, 1.20, 1.19, 1.19 and 1.19 ms.
 * * **Ratios, not milliseconds.** A checked-in millisecond ceiling is a bet on
 *   the runner's speed and will fail the day the fleet changes. Both figures
 *   this reports are dimensionless: collection time against the *default*
 *   collector measured the same way on the same machine, and collection time
 *   against itself at a quarter of the live set.
 * * **Exact facts where there are any.** Whether a shrunken heap gives its
 *   memory back, whether `GC.reserve` reserves, whether a dropped live set is
 *   actually reclaimed -- none of that is a measurement, and all of it has been
 *   broken by a change at some point in this project's history.
 *
 * What it will and will not catch is worth being blunt about. Ratios on a
 * shared runner cannot resolve a few per cent, and the mark-phase work this
 * project has done turns on exactly that -- so this gate would not have caught
 * a 7% pause regression, and nothing runnable in CI would. What it catches is
 * the class of regression that has actually happened here: quadratic collection
 * time (577 ms at 16,000 live objects), a sweep costing 21x what it should, an
 * allocator faulting pages in a loop (374 ms of pause against 38 ms), and a
 * feature silently ceasing to work.
 *
 * Prints `key=value` lines and is driven by `bench/gate.sh`, which runs it
 * under both collectors and applies the thresholds.
 *
 *   dub build --build=release --config=bench-gate
 *   ./bench-gate --DRT-gcopt=gc:tgc --checks
 */
import core.memory;
import core.time;
import core.stdc.stdio;
import tgc.gcobj;

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

/// 32 bytes with a vtable and monitor pointer: the size class a small
/// connection-state object lands in, and what `webserver_probe` uses.
final class Obj
{
    size_t a;
    Obj next;
}

__gshared Obj[] live;

/**
 * Best of `tries` collections of the current heap.
 *
 * The minimum rather than the mean, because every source of error on a shared
 * runner -- a co-tenant, a migration, a frequency change -- adds time and none
 * subtracts it.
 */
double bestCollectMs(int tries = 7)
{
    GC.collect(); // settle the threshold before timing anything
    double best = double.max;
    foreach (_; 0 .. tries)
    {
        auto t0 = MonoTime.currTime;
        GC.collect();
        immutable ms = (MonoTime.currTime - t0).total!"usecs" / 1000.0;
        if (ms < best)
            best = ms;
    }
    return best;
}

/// Collection time on a live set of `n` objects, chained so the mark phase has
/// a real pointer graph to chase rather than a flat array of roots.
double sweepAt(size_t n)
{
    live = new Obj[n];
    Obj head;
    foreach (i; 0 .. n)
    {
        auto o = new Obj;
        o.next = head;
        head = o;
        live[i] = o;
    }
    keepAlive(cast(void*) head);
    immutable ms = bestCollectMs();
    live = null;
    GC.collect();
    return ms;
}

/**
 * Allocate a burst and drop it, in a frame that goes away.
 *
 * Not inlined: an unoptimized build keeps a slice's stack slot live for the
 * whole enclosing frame, so a block allocated in `main` stays conservatively
 * reachable however hard the stack below it is scrubbed.
 */
pragma(inline, false)
void burst(size_t count)
{
    Obj head;
    foreach (_; 0 .. count)
    {
        auto o = new Obj;
        o.next = head;
        head = o;
    }
    keepAlive(cast(void*) head);
}

void settle(int rounds = 5)
{
    foreach (_; 0 .. rounds)
    {
        scrubStack();
        GC.collect();
    }
}

/**
 * The facts that are exact, and so need no threshold at all.
 *
 * Each of these has been broken by a change at some point, and each fails
 * silently: memory that is never returned looks like a busy program, and a
 * `reserve` that returns 0 looks like a small request.
 */
void behaviouralChecks()
{
    // A shrunken heap gives its memory back without being asked. The trim
    // judges demand over a window of wall time, so the collections have to be
    // spaced out past it or they all land inside the window in which the peak
    // was still standing.
    import core.thread : Thread;
    import core.time : msecs;

    // The shipped default, read before anything here changes it. The check
    // below forces the ratio on, so it proves the mechanism works and would say
    // nothing about a change that quietly disabled it.
    printf("trim_default_ratio=%zu\n", tgcTrimRatio());

    immutable savedRatio = tgcTrimRatio();

    // Segments are left at their default size on purpose. Turn them down to
    // 2 MB and a segment is a single huge-page span, so it is all-or-nothing
    // and `chunkFree` already handles the whole of it -- the span-level trim
    // has nothing left to do and the check silently measures zero. The
    // behaviour being checked only exists when a segment is bigger than a span,
    // which is the shipping configuration.
    tgcTrimRatio(0);
    settle();
    burst(2_000_000);
    settle();
    immutable held = tgcCommittedBytes();

    // Same live set, same heap; anything given back now is the trim.
    //
    // Waits for it rather than assuming how many windows it takes, because that
    // is a detail of the hysteresis and not the property under test. It is
    // two windows in steady state -- one evaluation to re-baseline the peak
    // once demand has fallen, the next to act on it -- and three here, because
    // switching the ratio back on spends one opening the window.
    tgcTrimRatio(savedRatio == 0 ? 2 : savedRatio);
    size_t trimmed = held;
    size_t windows = 0;
    foreach (_; 0 .. 6)
    {
        settle();
        Thread.sleep(msecs(600));
        settle();
        windows++;
        trimmed = tgcCommittedBytes();
        if (trimmed < held)
            break;
    }

    tgcTrimRatio(savedRatio);
    printf("trim_held_bytes=%zu\n", held);
    printf("trim_returned_bytes=%zu\n", held > trimmed ? held - trimmed : 0);
    printf("trim_windows=%zu\n", windows);

    // GC.reserve maps and faults in what it was asked for.
    enum size_t want = 8 * 1024 * 1024;
    printf("reserve_got_bytes=%zu\n", GC.reserve(want));
    printf("reserve_asked_bytes=%zu\n", want);

    // A dropped live set is actually reclaimed, rather than retained by a
    // collector that has stopped sweeping.
    settle();
    immutable before = GC.stats().usedSize;
    burst(200_000);
    immutable peak = GC.stats().usedSize;
    settle();
    immutable after = GC.stats().usedSize;
    printf("reclaim_peak_bytes=%zu\n", peak > before ? peak - before : 0);
    printf("reclaim_left_bytes=%zu\n", after > before ? after - before : 0);
}

void main(string[] args)
{
    bool checks = false;
    foreach (a; args[1 .. $])
        if (a == "--checks")
            checks = true;

    // In its own process, deliberately. The sweeps below leave the heap
    // fragmented across whatever segments they touched, and a segment with one
    // live chunk every 2 MB has nothing to give back -- correctly, but it makes
    // the trim check depend on what ran before it, which is exactly the kind of
    // flake a gate must not have.
    if (checks)
    {
        behaviouralChecks();
        return;
    }

    // A quarter and a whole, so the ratio between them says whether collection
    // time is still linear in the live set. It is the one number here that is
    // meaningful without a second process to compare against.
    immutable small = sweepAt(64_000);
    immutable large = sweepAt(256_000);
    printf("collect_ms_64k=%.4f\n", small);
    printf("collect_ms_256k=%.4f\n", large);
}
