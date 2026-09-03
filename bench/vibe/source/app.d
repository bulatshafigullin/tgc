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
import core.stdc.string : memcpy;
import cstdlib = core.stdc.stdlib;
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

/// Run each request's scratch work inside a per-request region.
private __gshared bool useRegion;

/// Check the region invariant at every close. A full mark per request, so this
/// is for finding out whether the handler is sound, not for timing it.
private __gshared bool verifyRegions;

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
/**
 * The same work as `handleWork`, with the per-request scratch in a region.
 *
 * This is the BEAM shape vibe.d makes available: a request is a fiber, a region
 * binds to a fiber, and everything a request allocates and then throws away can
 * be released at the end without ever being traced. The collector never marks
 * any of it.
 *
 * The invariant is the caller's to keep, and it decides the structure here.
 * Anything that outlives the request has to be allocated *outside* the region,
 * so the cache entry -- the part that is deliberately long-lived -- is built
 * before the region opens. Only the rendering, which nothing keeps, happens
 * inside. Storing into `s` from within the region would put region memory in a
 * live object and leave a dangling pointer the moment the region closed; the
 * docs list "a cache entry populated mid-request" as exactly this mistake.
 *
 * Whether writing the *response* from inside the region is safe is not obvious
 * and is not assumed: vibe.d keeps buffers on the connection across requests,
 * and a buffer first allocated inside a region would dangle for every later
 * request on that connection. `--region-verify` turns on `tgcRegionVerify`,
 * which checks at every close that nothing outside points in, and is how that
 * question was settled rather than argued.
 */
void handleWorkRegion(HTTPServerRequest req, HTTPServerResponse res)
{
    // Outside the region: this is the part that is kept.
    auto s = newCacheEntry();
    immutable n = cacheNext - 1;

    // Inside: everything the request builds and drops. The response is written
    // *after* the region closes, and the one value that has to survive it is
    // copied out through malloc -- the deep-copy-on-the-way-out discipline
    // regions require, and the reason this handler is shaped the way it is
    // rather than simply wrapping the whole of `handleWork`.
    char* carried;
    size_t carriedLen;
    scope (exit)
        cstdlib.free(carried);

    tgcRunInRegion({
        immutable payload = renderPayload(n, s);
        carriedLen = payload.length;
        carried = cast(char*) cstdlib.malloc(carriedLen);
        if (carried is null)
            assert(false, "out of memory carrying the response out of the region");
        memcpy(carried, payload.ptr, carriedLen);
    });

    // Outside the region again. Writing from inside is what vibe.d cannot
    // survive: request handling runs through a `RegionListAllocator` owned by
    // the *connection* and reused across requests on it, so the body writer
    // built on the first request would be region memory, freed at that
    // region's close and used again by the next request on the same
    // connection. It crashes in `InterfaceProxy!OutputStream.__postblit` on
    // roughly the 34th request, and `tgcRegionVerify` does not catch it --
    // see this benchmark's README.
    res.writeBody(cast(ubyte[]) carried[0 .. carriedLen], "application/json");
}

void handleWork(HTTPServerRequest req, HTTPServerResponse res)
{
    auto s = newCacheEntry();
    immutable n = cacheNext - 1;

    immutable payload = renderPayload(n, s);
    res.writeBody(cast(ubyte[]) payload.dup, "application/json");
}

/**
 * The part of a request that is deliberately kept: a cache entry.
 *
 * Allocated outside any region in both handlers, because it outlives the
 * request. In the region handler that is not a style choice -- putting this in
 * the region would leave the cache holding freed memory the moment the region
 * closed, which is the mistake the region documentation calls out by name.
 *
 * Carrying a small persistent array as well as the two strings, so that the
 * cache is a live set worth marking rather than a few hundred bytes: with
 * `--cache 100000` it is tens of megabytes that every collection has to trace.
 */
Session newCacheEntry()
{
    if (cacheRing.length != cacheSize)
    {
        cacheRing = new Session[cacheSize];
        cacheNext = 0;
    }

    auto s = new Session;
    s.id = format("%08x", cacheNext);
    s.user = "user-" ~ (cacheNext % 1000).to!string;
    s.recent = new long[16];
    foreach (i; 0 .. s.recent.length)
        s.recent[i] = cast(long)(cacheNext + i);

    cacheRing[cacheNext % cacheRing.length] = s;
    cacheNext++;
    return s;
}

/**
 * The per-request work both handlers do, so the only thing that differs between
 * them is where it is allocated.
 *
 * Building the response as a string and writing it with `writeBody` rather than
 * handing vibe.d a `Json` object to serialise, because the region handler has
 * to write from outside its region and the two must not differ in the response
 * path as well as in the allocation strategy.
 */
string renderPayload(size_t n, Session s)
{
    string[] tags;
    tags.reserve(workPerRequest);
    foreach (i; 0 .. workPerRequest)
        tags ~= format("tag-%d-%d", n, i);

    auto recent = new long[workPerRequest];
    foreach (i; 0 .. workPerRequest)
        recent[i] = cast(long)(n + i);

    // The bulk of the per-request garbage, and the part a real handler would
    // also do: build a string nobody keeps.
    string body_;
    body_.reserve(workPerRequest * 32);
    foreach (i, t; tags)
        body_ ~= format("%s=%d;", t, recent[i]);

    return format(`{"id":"%s","user":"%s","tags":%d,"rendered":%d}`,
                  s.id, s.user, tags.length, body_.length);
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
        router.get("/work", useRegion ? &handleWorkRegion : &handleWork);

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
        else if (a == "--region")
            useRegion = true;
        else if (a == "--region-verify")
        {
            useRegion = true;
            verifyRegions = true;
        }
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
    if (verifyRegions)
        tgcRegionVerify(true);

    if (threads > 1)
    {
        setupWorkerThreads(threads - 1);
        runWorkerTaskDist(&startListener);
    }
    startListener();

    printf("listening on 127.0.0.1:%d, %d thread(s), cache %d, work %d%s%s\n",
           cast(int) port, cast(int) threads,
           cast(int) cacheSize, cast(int) workPerRequest,
           useRegion ? ", regions".ptr : "".ptr,
           verifyRegions ? " (verified)".ptr : "".ptr);

    auto ret = runApplication(&rest);
    reportGC("main");
    return ret;
}
