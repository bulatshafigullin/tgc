/**
 * Binary-trees with fiber-scoped regions.
 *
 * `bintree_mt.d` shows what tgc is for: per-thread heaps that collect
 * independently. This version adds the other half of the design — each unit of
 * work runs inside a region, so its allocations are released wholesale when the
 * job finishes rather than being proved dead by a collector.
 *
 * That maps the benchmark onto the shape a server has. A job here is a request:
 * it allocates a working set, produces a small value, and everything it touched
 * dies at once. The only things that outlive a job are the checksum (an
 * integer, copied out by value) and each worker's long-lived tree, which is
 * deliberately allocated *before* any region is opened.
 *
 * Usage: bintree_region [depth] [workers] [--no-region]
 *   --no-region  run the identical workload without regions, for comparison
 *   --verify     turn on tgcRegionVerify, which asserts at every region close
 *                that nothing outside still points in
 */
import std;
import tgc.gcobj : tgcBeginRegion, tgcEndRegion, tgcRegionVerify;
import std.datetime.stopwatch : StopWatch, AutoStart;
import core.thread;
import core.atomic;
import core.memory : GC;
import core.stdc.stdio : fprintf, stderr;

extern (C) __gshared string[] rt_options = ["gcopt=minPoolSize:300"];

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

struct Job
{
    int depth;
    int iterations;
}

shared long grandTotal;
shared size_t nextJob;

__gshared Job[] jobs;
__gshared int workerCount;
__gshared bool useRegions = true;

/// One job's worth of trees. Everything it allocates is garbage on return; the
/// only thing that leaves is the checksum, which is an `int`.
long runJob(Job job)
{
    long sum = 0;
    foreach (i; 0 .. job.iterations)
        sum += Node.create(job.depth).check();
    return sum;
}

void workerBody()
{
    long sum = 0;

    // Allocated before any region is opened, so it lives on the thread heap and
    // survives every region close. Putting it inside a region would be the
    // classic mistake this design invites.
    auto myLongLived = Node.create(MIN_DEPTH + 2);

    for (;;)
    {
        immutable idx = atomicOp!"+="(nextJob, 1) - 1;
        if (idx >= jobs.length)
            break;

        if (useRegions)
        {
            auto r = tgcBeginRegion();
            scope (exit)
                tgcEndRegion(r);
            sum += runJob(jobs[idx]);   // returns a long, by value
        }
        else
            sum += runJob(jobs[idx]);
    }

    sum += myLongLived.check();
    atomicOp!"+="(grandTotal, sum);
}

void worker()
{
    // Regions bind to a fiber, so the work runs inside one. A server would have
    // a fiber per connection here.
    auto f = new Fiber(&workerBody);
    f.call();
    assert(f.state == Fiber.State.TERM);
}

void main(string[] args)
{
    int n = 18;
    workerCount = cast(int) totalCPUs;
    bool verify = false;

    foreach (a; args[1 .. $])
    {
        if (a == "--no-region")
            useRegions = false;
        else if (a == "--verify")
            verify = true;
        else if (a.length && a[0] != '-')
        {
            static int positional = 0;
            if (positional++ == 0)
                n = a.to!int;
            else
                workerCount = a.to!int;
        }
    }
    if (workerCount < 1) workerCount = 1;
    if (workerCount > 64) workerCount = 64;

    if (verify)
        tgcRegionVerify(true);

    auto maxDepth = max(MIN_DEPTH + 2, n);
    auto stretchDepth = maxDepth + 1;

    auto stretchTree = Node.create(stretchDepth);
    writeln(format("stretch tree of depth %d\t check: %d", stretchDepth, stretchTree.check()));
    stretchTree = null;

    auto longLivedTree = Node.create(maxDepth);

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

    writeln(format("%d workers\t jobs: %d\t regions: %s\t check sum: %d",
        workerCount, jobs.length, useRegions ? "yes" : "no", atomicLoad(grandTotal)));
    writeln(format("long lived tree of depth %d\t check: %d", maxDepth, longLivedTree.check()));
    writeln(format("parallel section: %.3f s", sw.peek.total!"usecs" / 1_000_000.0));

    () @trusted {
        auto ps = GC.profileStats();
        auto st = GC.stats();
        fprintf(stderr, "collections=%zu totalPause=%.1fms maxPause=%.2fms heap=%.1fMB\n",
            ps.numCollections,
            ps.totalPauseTime.total!"usecs" / 1000.0,
            ps.maxPauseTime.total!"usecs" / 1000.0,
            (st.usedSize + st.freeSize) / 1048576.0);
    }();
}
