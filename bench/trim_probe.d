/**
 * Does a shrunken heap give its memory back?
 *
 * A segment is only unmapped when every chunk in it is free, so one live chunk
 * used to pin 32 MB and a process held its peak until something called
 * `GC.minimize()`. This measures the automatic path that replaced that: build a
 * large live set, drop nearly all of it, collect, and watch both what the
 * collector says it has committed and what the OS says the process costs. The
 * collections are spaced out because the trim judges demand over a window of
 * wall time -- back to back they would all land inside the window in which the
 * peak was still standing, and measure nothing.
 *
 * Run twice, once with the trim disabled, to see the difference:
 *
 *   dub run -q --build=release --config=bench-trim
 *   ./bench-trim --DRT-gcopt=gc:tgc
 *   ./bench-trim --DRT-gcopt=gc:tgc --ratio=0     # the old behaviour
 *   ./bench-trim --DRT-gcopt=gc:tgc --reserve     # GC.reserve, page faults up front
 *   ./bench-trim --DRT-gcopt=gc:tgc --scatter     # survivors in every chunk
 */
import core.memory;
import core.time;
import core.thread : Thread;
import core.stdc.stdio;
import core.stdc.stdlib : atoi;
import tgc.gcobj;

/// 32 bytes with a vtable and monitor pointer, as in webserver_probe.
final class Obj
{
    size_t a;
}

__gshared Obj[] live;

/// Resident set in bytes, straight from `ps`, so the same code works on Linux
/// and macOS and reports what an operator watching the process would see.
version (Posix)
{
    size_t rssBytes()
    {
        import core.sys.posix.unistd : getpid;

        char[64] cmd;
        snprintf(cmd.ptr, cmd.length, "ps -o rss= -p %d", getpid());
        auto f = popen(cmd.ptr, "r");
        if (f is null)
            return 0;
        char[64] buf = '\0';
        auto got = fgets(buf.ptr, cast(int) buf.length, f);
        pclose(f);
        if (got is null)
            return 0;
        return cast(size_t) atoi(buf.ptr) * 1024; // ps reports KiB
    }

    extern (C) FILE* popen(const(char)*, const(char)*) nothrow @nogc;
    extern (C) int pclose(FILE*) nothrow @nogc;
}
else
{
    /// No `ps` to ask; the collector's own committed figure is the one to read.
    size_t rssBytes() { return 0; }
}

version (OSX)
    version = Darwin;

version (Darwin)
{
    /*
     * `ps rss` is the wrong number on macOS and it took a probe to find out.
     * MADV_FREE_REUSABLE -- what libmalloc uses to give memory back, and what
     * the collector uses here -- leaves pages resident until the system wants
     * them, so RSS does not move at all. The kernel's *footprint* ledger does,
     * immediately, and that is the figure Activity Monitor shows, the one
     * memory limits are enforced against, and the one jetsam kills on.
     *
     * Measured on a 256 MB mapping: touch it, and resident and footprint are
     * both 257 MB; MADV_FREE_REUSABLE takes footprint to 1 MB and leaves
     * resident at 257 MB; plain MADV_FREE moves neither. Only `munmap` moves
     * resident.
     *
     * Truncated at `phys_footprint`, which is `TASK_VM_INFO_REV1_COUNT`: the
     * kernel fills as much of the struct as the count asks for, and everything
     * after it was added later.
     */
    private struct TaskVmInfo
    {
        ulong virtualSize;
        int regionCount;
        int pageSize;
        ulong residentSize;
        ulong residentSizePeak;
        ulong[14] counters; // device .. compressed_lifetime
        ulong physFootprint;
    }

    extern extern (C) __gshared uint mach_task_self_;
    extern (C) int task_info(uint, int, void*, uint*) nothrow @nogc;

    size_t footprintBytes()
    {
        TaskVmInfo info;
        uint count = TaskVmInfo.sizeof / uint.sizeof;
        if (task_info(mach_task_self_, 22 /* TASK_VM_INFO */, &info, &count) != 0)
            return 0;
        return cast(size_t) info.physFootprint;
    }
}
else
{
    size_t footprintBytes() { return rssBytes(); }
}

void report(const(char)* what)
{
    printf("%-28s committed %6.1f MB   rss %6.1f MB   footprint %6.1f MB\n", what,
           tgcCommittedBytes() / 1048576.0, rssBytes() / 1048576.0,
           footprintBytes() / 1048576.0);
}

/// Time one collection, so the trim's cost inside the pause is visible.
double collectMs()
{
    auto t0 = MonoTime.currTime;
    GC.collect();
    return (MonoTime.currTime - t0).total!"usecs" / 1000.0;
}

void main(string[] args)
{
    bool doReserve = false;
    bool scatter = false;
    foreach (a; args[1 .. $])
    {
        if (a.length > 8 && a[0 .. 8] == "--ratio=")
            tgcTrimRatio(atoi(a.ptr + 8)); // argv strings are zero-terminated
        else if (a == "--reserve")
            doReserve = true;
        else if (a == "--scatter")
            scatter = true;
    }

    printf("trim ratio %zu, survivors %s\n\n", tgcTrimRatio(),
           scatter ? "scattered".ptr : "clustered".ptr);

    if (doReserve)
    {
        auto t0 = MonoTime.currTime;
        immutable got = GC.reserve(256 * 1024 * 1024);
        immutable ms = (MonoTime.currTime - t0).total!"usecs" / 1000.0;
        printf("GC.reserve(256 MB) -> %.1f MB in %.1f ms\n", got / 1048576.0, ms);
        report("after reserve");
        printf("\n");
    }

    // Peak: ~2 million 32-byte objects, spread over many segments.
    enum peak = 2_000_000;
    auto tPeak = MonoTime.currTime;
    live = new Obj[peak];
    foreach (i; 0 .. peak)
        live[i] = new Obj;
    printf("build peak: %.0f ms\n", (MonoTime.currTime - tPeak).total!"usecs" / 1000.0);
    report("at peak");

    // Drop 95% of it, which is the shape a request-scoped workload has: a
    // burst of allocation, nearly all of it dead once the burst is over.
    //
    // `--scatter` keeps every twentieth object instead, so the survivors are
    // spread across every chunk. Nothing can be handed back in that case and
    // nothing should be -- the chunks really are still in use -- and it is
    // worth being able to see the difference rather than assuming it.
    foreach (i; 0 .. peak)
        if (scatter ? (i % 20 != 0) : (i >= peak / 20))
            live[i] = null;

    // The trim judges demand over a window of wall time, so the collections
    // are spaced out: back to back they would all fall inside the window in
    // which the peak was still standing, and measure nothing.
    printf("\ncollection | pause (ms) | committed (MB) | rss (MB) | footprint (MB)\n");
    foreach (n; 0 .. 4)
    {
        Thread.sleep(msecs(600));
        immutable ms = collectMs();
        printf("%10d | %10.2f | %14.1f | %8.1f | %14.1f\n", n + 1, ms,
               tgcCommittedBytes() / 1048576.0, rssBytes() / 1048576.0,
               footprintBytes() / 1048576.0);
    }

    // What the explicit call still buys on top, if anything.
    GC.minimize();
    printf("\n");
    report("after GC.minimize()");

    // Growing back: the cost of having given the memory away.
    auto t0 = MonoTime.currTime;
    foreach (i; 0 .. peak)
        if (live[i] is null)
            live[i] = new Obj;
    printf("regrow to peak: %.0f ms\n",
           (MonoTime.currTime - t0).total!"usecs" / 1000.0);
    report("back at peak");
}
