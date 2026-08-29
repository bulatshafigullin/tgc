/**
 * Fiber tests for `tgc`.
 *
 * `thread_stackBottom()` reports only the *currently running* stack context, so
 * a collector that scans just that one sees neither suspended fibers nor — when
 * it runs inside a fiber — the thread's own stack. For a fiber-per-connection
 * server that is the common case rather than a corner case, because allocation
 * is what triggers collection and nearly all allocation happens inside fibers.
 *
 * These tests pin that behaviour down.
 */
module tgc_fiber;

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
// a suspended fiber's stack is a root
// ---------------------------------------------------------------------------

__gshared int suspendedCanaryDead;
class SuspendedCanary { ~this() { suspendedCanaryDead = 1; } ubyte[64] pad; }

unittest
{
    suspendedCanaryDead = 0;

    auto f = new Fiber({
        auto c = new SuspendedCanary;
        c.pad[0] = 0x5A;
        Fiber.yield();              // only reference now lives on the fiber stack
        assert(c.pad[0] == 0x5A, "object mutated while the fiber was suspended");
        keepAlive(cast(void*) c);
    });

    f.call();                       // run up to the yield
    scrubStack();
    GC.collect();
    GC.collect();

    assert(!suspendedCanaryDead,
        "an object held only on a suspended fiber's stack was collected");

    f.call();                       // resume and validate
    assert(f.state == Fiber.State.TERM);
}

// ---------------------------------------------------------------------------
// collecting from inside a fiber must not lose the thread, or other fibers
// ---------------------------------------------------------------------------

__gshared int mainStackDead, otherFiberDead;
class MainStackCanary  { ~this() { mainStackDead  = 1; } ubyte[64] pad; }
class OtherFiberCanary { ~this() { otherFiberDead = 1; } ubyte[64] pad; }

unittest
{
    mainStackDead = 0;
    otherFiberDead = 0;

    auto onMainStack = new MainStackCanary;
    onMainStack.pad[0] = 0x11;

    auto other = new Fiber({
        auto b = new OtherFiberCanary;
        b.pad[0] = 0x22;
        Fiber.yield();
        assert(b.pad[0] == 0x22);
        keepAlive(cast(void*) b);
    });
    other.call();                   // suspend it holding its object

    // Collect from inside a *different* fiber. This is the ordinary case for a
    // fiber server: allocation happens in fibers, and allocation is what
    // triggers collection.
    auto collector = new Fiber({
        GC.collect();
        GC.collect();
    });
    collector.call();

    assert(!mainStackDead,
        "collecting inside a fiber freed an object held on the thread's own stack");
    assert(!otherFiberDead,
        "collecting inside a fiber freed an object held by another fiber");

    assert(onMainStack.pad[0] == 0x11);
    keepAlive(cast(void*) onMainStack);
    other.call();
}

// ---------------------------------------------------------------------------
// many fibers, allocating and collecting - webserver shaped
// ---------------------------------------------------------------------------

private ubyte patternFor(size_t seed, size_t i)
{
    return cast(ubyte)((seed * 31 + i * 7 + 11) & 0xFF);
}

unittest
{
    // Fibers interleaved the way connection handlers are: each holds live
    // per-request state across several yields while others run and allocate.
    enum nFibers = 200 / workScale;
    enum rounds = 6;
    shared int failures = 0;

    auto fibers = new Fiber[nFibers];
    foreach (i; 0 .. nFibers)
    {
        immutable seed = i;
        fibers[i] = new Fiber({
            // Per-"connection" state, live across every yield below.
            auto buf = new ubyte[64 + (seed % 40) * 8];
            foreach (k, ref x; buf)
                x = patternFor(seed, k);

            foreach (r; 0 .. rounds)
            {
                Fiber.yield();
                // Allocate transient garbage, as a request handler would.
                auto tmp = new ubyte[128];
                tmp[0] = cast(ubyte) r;
                keepAlive(tmp.ptr);

                foreach (k, x; buf)
                {
                    if (x != patternFor(seed, k))
                    {
                        atomicOp!"+="(failures, 1);
                        break;
                    }
                }
            }
            keepAlive(buf.ptr);
        });
    }

    foreach (f; fibers)
        f.call();                   // start them all; each parks on a yield

    foreach (r; 0 .. rounds)
    {
        GC.collect();               // collect with every fiber suspended
        foreach (f; fibers)
            if (f.state == Fiber.State.HOLD)
                f.call();
    }

    assert(atomicLoad(failures) == 0,
        "per-fiber state was corrupted or collected across suspension");
}

// ---------------------------------------------------------------------------
// fibers on multiple threads, each thread owning its own
// ---------------------------------------------------------------------------

unittest
{
    // The shape recommended for a server on tgc: N threads, fibers pinned to
    // the thread that created them, nothing shared.
    enum nThreads = 4;
    enum perThread = 25 / workScale;
    shared int failures = 0;

    auto threads = new Thread[nThreads];
    foreach (t; 0 .. nThreads)
    {
        immutable tid = t;
        threads[t] = new Thread({
            auto fibers = new Fiber[perThread < 1 ? 1 : perThread];
            foreach (i; 0 .. fibers.length)
            {
                immutable seed = tid * 1000 + i;
                fibers[i] = new Fiber({
                    auto buf = new ubyte[256];
                    foreach (k, ref x; buf)
                        x = patternFor(seed, k);
                    Fiber.yield();
                    foreach (k, x; buf)
                    {
                        if (x != patternFor(seed, k))
                        {
                            atomicOp!"+="(failures, 1);
                            break;
                        }
                    }
                    keepAlive(buf.ptr);
                });
            }
            foreach (f; fibers)
                f.call();

            GC.collect();
            GC.collect();

            foreach (f; fibers)
                f.call();
            keepAlive(fibers.ptr);
        });
    }
    foreach (th; threads)
        th.start();
    foreach (th; threads)
        th.join();

    assert(atomicLoad(failures) == 0,
        "fiber state was lost when several threads collected concurrently");
}
