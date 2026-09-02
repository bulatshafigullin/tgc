/**
 * A vibe.d HTTP server, so the collector can be measured on the workload it was
 * designed for rather than on binary-trees.
 *
 * vibe.d is the interesting case for tgc specifically. It is fiber-per-request:
 * every connection runs in its own fiber, so a collection has to enumerate and
 * scan hundreds or thousands of suspended stacks, which is the thing
 * `WEBSERVER.md` is about. And request handling is *thread-local* by
 * construction -- a request is served entirely on the worker thread that
 * accepted it -- which is the shape tgc's thread-private heaps assume.
 *
 * Both collectors run the same binary; only `--DRT-gcopt=gc:` differs.
 *
 *   dub build --build=release
 *   ./tgc-vibe-bench --DRT-gcopt=gc:tgc --port=8080 --threads=4
 *
 * `bench/vibe/run.sh` drives it under `wrk` and reports both columns.
 *
 * Routes, in increasing order of how much garbage they make:
 *
 *   /plaintext  a fixed response. Almost no allocation; measures the framework
 *               and the harness, and says what the floor is.
 *   /json       serialise a small object, which is where a real service starts.
 *   /work       per-request garbage plus a live set: a session object is built,
 *               rendered, and kept in a per-worker LRU ring. This is the one
 *               that has anything to say about a collector, because it has both
 *               a high allocation rate and a live set to mark.
 *
 * The cache is deliberately `static` (thread-local) rather than `__gshared`.
 * That is realistic for a per-worker cache, and it is also the only shape tgc
 * supports without `tgcTrackEscapes`: a block published to a global and read
 * from another thread is the one pattern thread-private heaps cannot handle.
 * Making it shared would measure escape tracking instead, which is a different
 * question -- see `bench/escape_probe.d`.
 */
module app;

import vibe.core.core;
import vibe.core.log;
import vibe.http.server;
import vibe.http.router;
import vibe.data.json;

import core.memory : GC;
import core.stdc.stdio : printf;
import std.conv : to;
import std.format : format;
import core.time : hours;

import tgc.gcobj; // registers the tgc factory; the collector is chosen at runtime

/// A session-ish object: a few strings and an array, the sort of thing a
/// request handler builds and mostly throws away.
final class Session
{
    string id;
    string user;
    string[] tags;
    long[] recent;
    string rendered;
}

/// Per-worker LRU ring. Thread-local, so it is a live set the owning thread's
/// collection has to mark, and nothing another thread can see.
private Session[] cacheRing;
private size_t cacheNext;

// `__gshared`, not plain module-level. A module-level variable in D is
// thread-local, so as ordinary globals these were set by `main` on the main
// thread and every worker went on using the defaults -- which made `--cache`
// and `--work` silently do nothing on exactly the threads doing the work.
// Written once before any worker starts and only read afterwards.
private __gshared size_t cacheSize = 4096;
private __gshared size_t workPerRequest = 24;

/// tgc heap-sizing overrides; 0 means "leave the default alone".
private __gshared size_t growth;
private __gshared size_t minHeapMb;

void handlePlaintext(HTTPServerRequest req, HTTPServerResponse res)
{
    res.writeBody("Hello, World!", "text/plain");
}

void handleJson(HTTPServerRequest req, HTTPServerResponse res)
{
    res.writeJsonBody(["message": "Hello, World!"]);
}

/**
 * Build a session, render it, keep it in the ring, and drop whatever the ring
 * evicted.
 *
 * `workPerRequest` controls how much garbage each request makes without
 * changing the shape of the live set, so allocation rate and live set can be
 * varied independently.
 */
void handleWork(HTTPServerRequest req, HTTPServerResponse res)
{
    if (cacheRing.length != cacheSize)
    {
        cacheRing = new Session[cacheSize];
        cacheNext = 0;
    }

    auto s = new Session;
    s.id = format("%08x", cacheNext);
    s.user = "user-" ~ (cacheNext % 1000).to!string;

    s.tags.reserve(workPerRequest);
    foreach (i; 0 .. workPerRequest)
        s.tags ~= format("tag-%d-%d", cacheNext, i);

    s.recent = new long[workPerRequest];
    foreach (i; 0 .. workPerRequest)
        s.recent[i] = cast(long)(cacheNext + i);

    // The rendering is the bulk of the per-request garbage, and it is the part
    // a real handler would also do: build a string nobody keeps.
    string body_;
    body_.reserve(workPerRequest * 32);
    foreach (i, t; s.tags)
        body_ ~= format("%s=%d;", t, s.recent[i]);
    s.rendered = body_;

    cacheRing[cacheNext % cacheRing.length] = s;
    cacheNext++;

    res.writeJsonBody([
        "id": Json(s.id),
        "user": Json(s.user),
        "tags": Json(cast(long) s.tags.length),
        "rendered": Json(cast(long) s.rendered.length),
    ]);
}

/// Printed on exit by every worker, so the driver can see what the collector
/// actually did rather than inferring it from wall time.
void reportGC(string tag)
{
    auto p = GC.profileStats();
    auto s = GC.stats();
    // `tgcCommittedBytes` is non-zero only when tgc is the collector in use, so
    // it doubles as proof that `--DRT-gcopt=gc:` did what was asked rather than
    // silently falling back.
    printf("GCSTATS %.*s collections=%llu totalPauseMs=%.2f maxPauseMs=%.2f usedMB=%.1f committedMB=%.1f\n",
           cast(int) tag.length, tag.ptr,
           cast(ulong) p.numCollections,
           p.totalPauseTime.total!"usecs" / 1000.0,
           p.maxPauseTime.total!"usecs" / 1000.0,
           s.usedSize / 1048576.0,
           tgcCommittedBytes() / 1048576.0);
}

shared static this()
{
    setLogLevel(LogLevel.warn);
}

/// Port, as a plain integer. Config crossing a thread boundary has to be
/// primitives: handing a worker an `HTTPServerSettings` object built on the
/// main thread would be exactly the cross-thread sharing tgc does not support,
/// and it is avoidable -- every worker can build its own.
private __gshared ushort gPort;

/**
 * Build this thread's router and settings and start listening.
 *
 * A function pointer, because that is what `runWorkerTaskDist` takes, and one
 * router and one settings object per thread, because sharing them would put a
 * GC block allocated on one thread into another thread's hands.
 *
 * `reusePort` gives every thread its own listening socket, so the kernel
 * distributes connections and a request is accepted, served and finished on a
 * single thread. That is what makes a thread-private collector applicable at
 * all, and it is also how vibe.d is normally deployed.
 */
void startListener() nothrow
{
    try
    {
        auto router = new URLRouter;
        router.get("/plaintext", &handlePlaintext);
        router.get("/json", &handleJson);
        router.get("/work", &handleWork);

        auto settings = new HTTPServerSettings;
        settings.port = gPort;
        settings.bindAddresses = ["127.0.0.1"];
        settings.options |= HTTPServerOption.reusePort;
        listenHTTP(settings, router);

        // `runWorkerTaskDist` wants a *long-living* task, and this is why:
        // returning here ends the task, the worker thread finds nothing left to
        // run, and its event loop tears the eventcore driver down underneath
        // the listener that was just registered -- which shows up as
        // "leaking eventcore driver because there are still active handles" at
        // startup and, on the way out, a segfault. Parking the task keeps the
        // worker alive; SIGINT ends the whole process anyway.
        if (Task.getThis() != Task.init)
            while (true)
                sleep(1.hours);
    }
    catch (Exception e)
    {
        import core.stdc.stdlib : abort;
        printf("listen failed: %.*s\n", cast(int) e.msg.length, e.msg.ptr);
        abort();
    }
}

int main(string[] args)
{
    ushort port = 8080;
    uint threads = 1;

    // Parsed by hand rather than with std.getopt, because vibe's own
    // runApplication also wants the argument list and the two do not compose
    // cleanly.
    string[] rest;
    foreach (a; args)
    {
        if (a.length > 7 && a[0 .. 7] == "--port=")
            port = a[7 .. $].to!ushort;
        else if (a.length > 10 && a[0 .. 10] == "--threads=")
            threads = a[10 .. $].to!uint;
        else if (a.length > 8 && a[0 .. 8] == "--cache=")
            cacheSize = a[8 .. $].to!size_t;
        else if (a.length > 7 && a[0 .. 7] == "--work=")
            workPerRequest = a[7 .. $].to!size_t;
        else if (a.length > 9 && a[0 .. 9] == "--growth=")
            growth = a[9 .. $].to!size_t;
        else if (a.length > 11 && a[0 .. 11] == "--min-heap=")
            minHeapMb = a[11 .. $].to!size_t;
        else
            rest ~= a;
    }

    gPort = port;

    // Heap sizing is policy, not collector quality, and the two collectors do
    // not default to the same policy: tgc grows a thread's heap by 4x with a
    // 32 MB floor, *per thread*, where the default collector sizes one pool for
    // the process. Comparing them at their defaults measures that difference as
    // much as anything else, so both are exposed and `run.sh -m` uses them to
    // put the two on the same memory budget. Left alone, nothing changes.
    if (growth)
        tgcHeapGrowth(growth);
    if (minHeapMb)
        tgcMinHeap(minHeapMb * 1024 * 1024);

    if (threads > 1)
    {
        setupWorkerThreads(threads - 1);
        runWorkerTaskDist(&startListener);
    }
    startListener();

    printf("listening on 127.0.0.1:%d, %d thread(s), cache %d, work %d\n",
           cast(int) port, cast(int) threads,
           cast(int) cacheSize, cast(int) workPerRequest);

    auto ret = runApplication(&rest);
    reportGC("main");
    return ret;
}
