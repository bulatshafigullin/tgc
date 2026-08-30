/**
 * Multi-threaded binary-trees.
 *
 * The single-threaded benchmark says nothing about what tgc is for: with one
 * thread there is no world to stop, so a per-thread heap buys nothing and its
 * conservative marking simply costs more than the default collector's.
 *
 * This version gives each worker its own independent tree workload, which is
 * the shape tgc targets — every thread allocates from a private arena and
 * collects without pausing the others. Work is split by handing each thread a
 * slice of the iterations for every depth, so all threads stay busy allocating
 * for the whole run rather than finishing at wildly different times.
 *
 * Usage: bintree_mt [depth] [threads]
 *   depth   -- as in bintree.d (default 18)
 *   threads -- worker count (default: totalCPUs)
 */
import std;
import std.datetime.stopwatch : StopWatch, AutoStart;
import tgc.gcobj : tgcMinHeap;
import core.thread;
import core.atomic;
import core.memory : GC;
import core.stdc.stdio : fprintf, stderr;

extern (C) __gshared string[] rt_options = ["gcopt=minPoolSize:300"];

/**
 * Total heap budget both collectors are given, so the comparison is about the
 * collectors rather than about how much memory each decided to use.
 *
 * `minPoolSize:300` above hands the default collector a 300 MB pool. tgc
 * ignores that option and sizes from live data, which is why it collected 64
 * times on binary-trees where the default collector collected 7 -- a difference
 * in policy, not in the collector. `tgcMinHeap` is the equivalent knob, and it
 * is *per thread*, so the budget is divided by the worker count to give the
 * same total.
 */
enum size_t totalHeapBudget = 300 * 1024 * 1024;

enum MIN_DEPTH = 4;

final class Node
{
    Node left;
    Node right;

    this(Node left, Node right)
    {
        this.left = left;
        this.right = right;
    }

    int check()
    {
        auto r = 1;
        if (this.left !is null)
            r += this.left.check();
        if (this.right !is null)
            r += this.right.check();
        return r;
    }

    static Node create(int depth)
    {
        if (depth > 0)
        {
            auto d = depth - 1;
            return new Node(Node.create(d), Node.create(d));
        }
        return new Node(null, null);
    }
}

/// One depth's worth of work, split across threads.
struct Job
{
    int depth;
    int iterations;
}

// Accumulated atomically rather than into a per-worker slot: a delegate that
// captures a loop variable shares one frame with every other iteration in D, so
// indexing by a captured id is a trap.
shared long grandTotal;
shared size_t nextJob;

__gshared Job[] jobs;
__gshared int workerCount;

void worker()
{
    long sum = 0;

    // Each worker keeps its own long-lived tree, so every thread has a
    // non-trivial live set of its own to mark -- otherwise the benchmark would
    // measure allocation throughput only.
    auto myLongLived = Node.create(MIN_DEPTH + 2);

    for (;;)
    {
        immutable idx = atomicOp!"+="(nextJob, 1) - 1;
        if (idx >= jobs.length)
            break;
        auto job = jobs[idx];
        foreach (i; 0 .. job.iterations)
            sum += Node.create(job.depth).check();
    }

    sum += myLongLived.check();
    atomicOp!"+="(grandTotal, sum);
}

void main(string[] args)
{
    auto n = args.length > 1 ? args[1].to!int() : 18;
    workerCount = args.length > 2 ? args[2].to!int() : cast(int) totalCPUs;
    if (workerCount < 1)
        workerCount = 1;
    if (workerCount > 64)
        workerCount = 64;

    // Harmless under the default collector, which does not read it.
    tgcMinHeap(totalHeapBudget / workerCount);

    auto maxDepth = max(MIN_DEPTH + 2, n);
    auto stretchDepth = maxDepth + 1;

    auto stretchTree = Node.create(stretchDepth);
    writeln(format("stretch tree of depth %d\t check: %d", stretchDepth, stretchTree.check()));
    stretchTree = null;

    auto longLivedTree = Node.create(maxDepth);

    // Build the job list: for each depth, split its iterations into chunks so
    // workers can steal them one at a time and stay balanced.
    Job[] js;
    for (int depth = MIN_DEPTH; depth <= maxDepth; depth += 2)
    {
        auto iterations = 1 << (maxDepth - depth + MIN_DEPTH);
        auto chunks = workerCount * 4;
        auto per = max(1, iterations / chunks);
        auto remaining = iterations;
        while (remaining > 0)
        {
            auto take = min(per, remaining);
            js ~= Job(depth, cast(int) take);
            remaining -= take;
        }
    }
    jobs = js;

    auto sw = StopWatch(AutoStart.yes);

    auto threads = new Thread[workerCount];
    foreach (i; 0 .. workerCount)
        threads[i] = new Thread(&worker);
    foreach (t; threads)
        t.start();
    foreach (t; threads)
        t.join();

    sw.stop();

    immutable total = atomicLoad(grandTotal);

    writeln(format("%d workers\t jobs: %d\t heap budget: %d MB\t check sum: %d",
        workerCount, jobs.length, totalHeapBudget / 1048576, total));
    writeln(format("long lived tree of depth %d\t check: %d", maxDepth, longLivedTree.check()));
    writeln(format("parallel section: %.3f s", sw.peek.total!"usecs" / 1_000_000.0));

    () @trusted {
        auto ps = GC.profileStats();
        fprintf(stderr, "GC: collections=%zu totalPause=%.1f ms maxPause=%.2f ms\n",
            ps.numCollections,
            ps.totalPauseTime.total!"usecs" / 1000.0,
            ps.maxPauseTime.total!"usecs" / 1000.0);
    }();
}
