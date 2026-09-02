/**
 * What another thread's fibers cost a collection that has no interest in them.
 *
 * Fiber *scanning* is already restricted to the collecting thread's own fibers:
 * a context counts as ours only if this heap owns the `StackContext` block,
 * which `Fiber` allocates with `new` on its creating thread. Enumeration is not,
 * and cannot be with the druntime that exists today. Finding those contexts
 * means walking `ThreadBase.sm_cbeg`, which holds every fiber in the process,
 * and the ownership test has to happen *inside* druntime's thread lock -- once
 * it is released another thread may destroy its fiber and unmap the stack, and
 * scanning that faults. So a collection walks T x F contexts to scan its own F.
 *
 * Every thread here holds the same number of fibers and the same live set, so
 * the only thing that changes as threads are added is how many *other* threads'
 * fibers each collection has to walk past. That isolates the cost this probe
 * exists to measure from everything else that scales with thread count.
 *
 *   dub build --build=release --config=bench-fiber
 *   ./bench-fiber --DRT-gcopt=gc:tgc
 *   ./bench-fiber --DRT-gcopt=gc:tgc --fibers=800
 */
import core.memory;
import core.thread;
import core.time;
import core.atomic;
import core.stdc.stdio;
import core.stdc.stdlib : atoi;
import tgc.gcobj;

final class Obj
{
    size_t a;
    Obj next;
}

__gshared size_t fibersPerThread = 400;
__gshared size_t livePerThread = 20_000;

shared size_t readyCount;
shared bool go;
shared bool stop;

/// Best of N, so a co-tenant on the machine cannot make the number look worse
/// than the hardware really is. Interference only ever adds time.
double bestCollectMs(int tries = 7)
{
    GC.collect();
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

/**
 * One worker: park `fibersPerThread` fibers, hold a fixed live set, then wait.
 *
 * The fibers are parked on a yield with a live object on their own stacks, so
 * they are exactly the thing a collection must not miss and must therefore
 * enumerate.
 */
void worker(double* result)
{
    auto live = new Obj[livePerThread];
    Obj head;
    foreach (i; 0 .. livePerThread)
    {
        auto o = new Obj;
        o.next = head;
        head = o;
        live[i] = o;
    }

    Fiber[] parked;
    parked.reserve(fibersPerThread);
    foreach (_; 0 .. fibersPerThread)
    {
        auto f = new Fiber({
            auto held = new Obj;   // live only on the fiber's own stack
            Fiber.yield();
            held.a++;
        });
        f.call();                  // runs to the yield and parks there
        parked ~= f;
    }

    // Everyone parks before anyone measures, so every measurement sees the
    // same total number of contexts in the process.
    atomicOp!"+="(readyCount, 1);
    while (!atomicLoad(go))
        Thread.yield();

    *result = bestCollectMs();

    // Stay alive, holding the fibers, until every thread has measured.
    atomicOp!"+="(readyCount, 1);
    while (!atomicLoad(stop))
        Thread.yield();

    if (live.length && parked.length)
        parked[0].call();          // keep both referenced to the very end
}

void main(string[] args)
{
    foreach (a; args[1 .. $])
    {
        if (a.length > 9 && a[0 .. 9] == "--fibers=")
            fibersPerThread = atoi(a.ptr + 9);
        else if (a.length > 7 && a[0 .. 7] == "--live=")
            livePerThread = atoi(a.ptr + 7);
    }

    printf("%zu fibers and %zu live objects per thread\n\n",
           fibersPerThread, livePerThread);
    printf("threads | fibers in process | collect per thread (ms)\n");

    foreach (nthreads; [1, 2, 4, 8])
    {
        atomicStore(readyCount, cast(size_t) 0);
        atomicStore(go, false);
        atomicStore(stop, false);

        auto results = new double[nthreads];
        auto threads = new Thread[nthreads];
        foreach (i; 0 .. nthreads)
        {
            auto slot = &results[i];
            threads[i] = new Thread({ worker(slot); });
            threads[i].start();
        }

        while (atomicLoad(readyCount) < cast(size_t) nthreads)
            Thread.yield();
        atomicStore(go, true);

        while (atomicLoad(readyCount) < cast(size_t) nthreads * 2)
            Thread.yield();
        atomicStore(stop, true);
        foreach (t; threads)
            t.join();

        double worst = 0;
        foreach (r; results)
            if (r > worst)
                worst = r;
        printf("%7d | %17zu | %23.2f\n",
               nthreads, fibersPerThread * nthreads, worst);
    }
}
