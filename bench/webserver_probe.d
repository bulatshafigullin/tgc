/**
 * The probes behind WEBSERVER.md's numbers.
 *
 * Both measure the same thing a fiber-per-connection server cares about: how
 * long one thread's collection takes, as a function of what that thread is
 * holding. Neither says anything about the other threads, which is the point --
 * they are not paused.
 *
 * The earlier figures in that document came from throwaway probes that no
 * longer exist, which is exactly the problem `bench/` was added to fix. Run:
 *
 *   dub run -q --build=release --config=bench-webserver
 *   ./bench-webserver --DRT-gcopt=gc:tgc
 */
import core.memory;
import core.thread;
import core.time;
import core.stdc.stdio;

/// 32 bytes with a vtable and monitor pointer: the size class a small
/// connection-state object lands in.
final class Obj
{
    size_t a;
}

__gshared Obj[] live;
__gshared Fiber[] parked;

double bestCollectMs(int tries = 5)
{
    GC.collect(); // settle the threshold before timing
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

/// Collection time against live set, with no fibers involved.
void liveSetSweep()
{
    printf("live objects | collect (ms)\n");
    foreach (n; [2_000, 8_000, 16_000, 64_000, 256_000])
    {
        live = new Obj[n];
        foreach (i; 0 .. n)
            live[i] = new Obj;
        printf("%12d | %.2f\n", n, bestCollectMs());
        live = null;
        GC.collect();
    }
}

/// Collection time against suspended fibers, on a constant live set, so all
/// growth comes from the fiber stacks that have to be scanned.
void fiberSweep()
{
    enum liveCount = 50_000;
    live = new Obj[liveCount];
    foreach (i; 0 .. liveCount)
        live[i] = new Obj;

    printf("suspended fibers | collect (ms)\n");
    size_t have = 0;
    foreach (want; [0, 100, 1_000, 5_000, 10_000])
    {
        while (have < want)
        {
            auto f = new Fiber({
                auto held = new Obj; // live only on the fiber's own stack
                Fiber.yield();
                held.a++;
            });
            f.call(); // runs to the yield and parks there
            parked ~= f;
            have++;
        }
        printf("%16d | %.2f\n", cast(int) want, bestCollectMs());
    }
}

void main()
{
    liveSetSweep();
    printf("\n");
    fiberSweep();
}
