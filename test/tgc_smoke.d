/**
 * Smoke test for tgc when selected via rt_options in gcobj (Tgc_default) or
 * `--DRT-gcopt=gc:tgc`. Import gcobj so the factory is registered.
 */
module tgc_smoke;

import tgc.gcobj;
import core.memory;
import core.thread;
import core.atomic;

shared size_t otherThreadAllocs;
shared bool otherDone;
shared bool collectDone;

void worker()
{
    foreach (i; 0 .. 100)
    {
        auto p = new int[64];
        p[0] = cast(int) i;
        atomicOp!"+="(otherThreadAllocs, 1);
    }
    auto keep = new ubyte[1024];
    keep[0] = 42;

    while (!atomicLoad(collectDone))
        Thread.yield();

    assert(keep[0] == 42);
    atomicStore(otherDone, true);
}

unittest
{
    auto before = GC.profileStats().numCollections;

    int[] local;
    foreach (i; 0 .. 50)
        local ~= cast(int) i;
    assert(local.length == 50);

    auto t = new Thread(&worker);
    t.start();

    while (atomicLoad(otherThreadAllocs) < 50)
        Thread.yield();

    GC.collect();
    atomicStore(collectDone, true);

    t.join();
    assert(atomicLoad(otherDone));

    auto after = GC.profileStats().numCollections;
    assert(after >= before);

    foreach (i; 0 .. 200)
    {
        auto junk = new ubyte[4096];
        junk[0] = cast(ubyte) i;
    }
    GC.collect();

    assert(local[0] == 0 && local[$ - 1] == 49);
}
