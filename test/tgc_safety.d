/**
 * Reachability and safety tests for `tgc`.
 *
 * These are deliberately adversarial. The previous smoke test passed
 * identically under `--DRT-gcopt=gc:conservative`, so it could not detect
 * either a failure to select tgc or tgc freeing live memory. Every test here
 * either exercises a tgc-specific guarantee or uses a finalizer canary to
 * prove an object survived a collection.
 */
module tgc_safety;

import tgc.gcobj;
import core.memory;
import core.thread;
import core.atomic;

import core.internal.gc.impl.tgc.gc : ThreadGC;

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

/**
 * Iteration divisor for sanitized builds.
 *
 * ASan/TSan instrument every load, and a conservative collector scanning whole
 * stacks is close to their worst case — a full-size run takes long enough to
 * be useless in CI. The code paths stay identical; only the counts shrink.
 */
version (TgcSanitize)
    private enum workScale = 10;
else
    private enum workScale = 1;

/**
 * Compiler barrier forcing `p` to still be live at this point.
 *
 * This has to be a real barrier. The obvious `__gshared slot = p; slot = null;`
 * is removed outright by LLVM as a dead store at -O2, which silently turns
 * every "this must survive" assertion below into a tautology.
 */
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

    // Fallback for compilers without GCC-style inline asm: genuinely retain the
    // pointer in a global. Weaker (it tests reachability rather than stack
    // liveness) but never gives a false pass.
    pragma(inline, false)
    private void keepAlive(void* p) @nogc nothrow
    {
        keepAliveSlot = p;
    }
}

/// Overwrite dead stack slots left behind by a previous call, so a stale copy
/// of a pointer cannot keep a canary alive by accident and mask a real bug.
private void scrubStack(int depth = 64)
{
    ubyte[512] junk = 0xEE;
    if (depth > 0)
        scrubStack(depth - 1);
    keepAlive(junk.ptr);
}

private bool tgcIsActive()
{
    import core.internal.gc.proxy : gc_getProxy;

    return (cast(ThreadGC) gc_getProxy()) !is null;
}

// ---------------------------------------------------------------------------
// the active GC really is tgc
// ---------------------------------------------------------------------------

unittest
{
    assert(tgcIsActive(),
        "tgc is not the active GC — every other test in this module would be " ~
        "silently testing the default collector instead");
}

// ---------------------------------------------------------------------------
// payload alignment
// ---------------------------------------------------------------------------

unittest
{
    // D guarantees 16-byte alignment for GC allocations; `real`, SIMD vectors
    // and align(16) aggregates depend on it, and an aligned SSE store into an
    // 8-aligned block faults on x86-64.
    foreach (n; [1, 3, 8, 16, 17, 32, 64, 100, 1000, 4096])
    {
        auto p = GC.malloc(n);
        assert((cast(size_t) p & 15) == 0,
            "GC.malloc returned a payload that is not 16-byte aligned");
    }
    foreach (n; [1, 7, 33, 129])
    {
        auto a = new ubyte[n];
        assert((cast(size_t) a.ptr & 15) == 0,
            "array allocation is not 16-byte aligned");
    }
}

// ---------------------------------------------------------------------------
// reachability canaries
// ---------------------------------------------------------------------------

__gshared int tlsCanaryDead;
__gshared int gsCanaryDead;
__gshared int rootCanaryDead;
__gshared int stackCanaryDead;

class TlsCanary   { ~this() { tlsCanaryDead   = 1; } ubyte[32] pad; }
class GsCanary    { ~this() { gsCanaryDead    = 1; } ubyte[32] pad; }
class RootCanary  { ~this() { rootCanaryDead  = 1; } ubyte[32] pad; }
class StackCanary { ~this() { stackCanaryDead = 1; } ubyte[32] pad; }

/// Reachable only through thread-local storage.
TlsCanary tlsOnly;
/// Reachable only through the static data segment.
__gshared GsCanary gsOnly;

private void stashTls() { tlsOnly = new TlsCanary; }
private void stashGs()  { gsOnly = new GsCanary; }

unittest
{
    // A GC pointer whose only copy lives in a thread-local global must survive.
    // This is the case a `static if (__traits(compiles, import rt.sections))`
    // guard used to compile away silently, freeing live memory in every real
    // build.
    stashTls();
    scrubStack();
    GC.collect();
    assert(!tlsCanaryDead, "object reachable only from TLS was collected");
    assert(tlsOnly !is null);
    tlsOnly = null;
}

unittest
{
    stashGs();
    scrubStack();
    GC.collect();
    assert(!gsCanaryDead, "object reachable only from __gshared data was collected");
    assert(gsOnly !is null);
    gsOnly = null;
}

unittest
{
    // Reachable only via GC.addRoot.
    auto c = new RootCanary;
    auto p = cast(void*) c;
    GC.addRoot(p);
    c = null;
    scrubStack();
    GC.collect();
    assert(!rootCanaryDead, "object registered with GC.addRoot was collected");
    GC.removeRoot(p);
}

unittest
{
    // Control: something held on the stack must never be collected. If this
    // fails, stack scanning itself is broken and every other result is noise.
    auto c = new StackCanary;
    GC.collect();
    assert(!stackCanaryDead, "object held in a live stack slot was collected");
    keepAlive(cast(void*) c);
}

// ---------------------------------------------------------------------------
// interior and one-past-the-end pointers
// ---------------------------------------------------------------------------

__gshared int interiorDead;
class InteriorCanary { ~this() { interiorDead = 1; } ubyte[256] pad; }

unittest
{
    // Only an interior pointer to the block remains.
    auto c = new InteriorCanary;
    auto interior = cast(void*)(cast(ubyte*) c + 128);
    c = null;
    scrubStack();
    GC.addRoot(interior);
    GC.collect();
    assert(!interiorDead, "block referenced only by an interior pointer was collected");
    GC.removeRoot(interior);
}

unittest
{
    // D slices routinely materialise `ptr + length`. Treating a
    // one-past-the-end pointer as a non-reference frees the array while live.
    auto arr = new int[64];
    auto onePastEnd = cast(void*)(arr.ptr + arr.length);
    auto base = arr.ptr;
    assert(GC.addrOf(onePastEnd - 1) is base);

    // Marking must accept it...
    GC.addRoot(onePastEnd);
    GC.collect();
    assert(GC.sizeOf(base) >= 64 * int.sizeof,
        "array referenced only one-past-the-end was collected");
    GC.removeRoot(onePastEnd);

    // ...while exact lookup must still reject it, so that a free() through a
    // one-past-the-end pointer cannot destroy an unrelated neighbour.
    assert(GC.addrOf(onePastEnd) !is base,
        "exact lookup wrongly resolved a one-past-the-end pointer to this block");
}

// ---------------------------------------------------------------------------
// reclamation actually happens
// ---------------------------------------------------------------------------

unittest
{
    scrubStack();
    GC.collect();
    auto baseline = GC.stats().usedSize;

    // Build up unreachable garbage with collection suppressed, so the peak is
    // deterministic. Without this the allocation-triggered collector reclaims
    // as we go and `peak` never rises above `baseline`.
    enum garbageCount = 2000 / workScale;
    enum garbageSize = 512;

    GC.disable();
    foreach (i; 0 .. garbageCount)
    {
        auto junk = new ubyte[garbageSize];
        junk[0] = cast(ubyte) i;
        // Escape the pointer so LLVM cannot elide the allocation outright; it
        // is still unreachable once the iteration ends.
        keepAlive(junk.ptr);
    }
    auto peak = GC.stats().usedSize;
    GC.enable();

    assert(peak > baseline + (garbageCount * garbageSize) / 2,
        "usedSize did not grow while allocating with the GC disabled");

    scrubStack();
    GC.collect();
    GC.collect();
    auto after = GC.stats().usedSize;

    // A conservative collector may retain some of it, but not nearly all.
    assert(after < baseline + (peak - baseline) / 2,
        "collection reclaimed less than half of the unreachable garbage");
}

// ---------------------------------------------------------------------------
// disable() must not suppress an explicit collect
// ---------------------------------------------------------------------------

unittest
{
    scrubStack();
    GC.collect();
    auto before = GC.profileStats().numCollections;

    GC.disable();
    scope (exit) GC.enable();

    GC.collect();
    auto after = GC.profileStats().numCollections;

    // GC.disable() suppresses only allocation-triggered collections; an
    // explicit GC.collect() is a direct instruction and must always run.
    assert(after > before,
        "explicit GC.collect() did nothing while the GC was disabled");
}

unittest
{
    // ...and while disabled, allocating past the threshold must NOT collect.
    scrubStack();
    GC.collect();

    GC.disable();
    auto before = GC.profileStats().numCollections;
    foreach (i; 0 .. 4000 / workScale)
    {
        auto junk = new ubyte[512]; // well past the 256 KiB threshold
        junk[0] = cast(ubyte) i;
        keepAlive(junk.ptr);
    }
    auto after = GC.profileStats().numCollections;
    GC.enable();

    assert(after == before,
        "GC.disable() did not suppress allocation-triggered collection");
}

// ---------------------------------------------------------------------------
// finalization
// ---------------------------------------------------------------------------

shared int threadExitDtorRan;

class ThreadExitCanary
{
    ~this() { atomicOp!"+="(threadExitDtorRan, 1); }
    ubyte[64] pad;
}

shared size_t threadExitBlock;

unittest
{
    // An object alive when its thread exits must NOT be finalized or freed.
    //
    // This reverses an earlier assumption. Finalizing at thread exit looks
    // right by analogy with program termination, but Thread.join() propagates
    // the child's Throwable to the parent *after* cleanup has run — so running
    // destructors and releasing arenas there hands the parent a destructed
    // object in freed memory. The arenas are adopted instead and stay valid.
    atomicStore(threadExitDtorRan, 0);
    atomicStore(threadExitBlock, cast(size_t) 0);

    auto t = new Thread({
        auto keep = new ThreadExitCanary;
        keep.pad[0] = 0x7E;
        atomicStore(threadExitBlock, cast(size_t) cast(void*) keep);
        keepAlive(cast(void*) keep);
    });
    t.start();
    t.join();

    assert(atomicLoad(threadExitDtorRan) == 0,
        "an object alive at thread exit was finalized, so Thread.join() would " ~
        "hand the parent a destructed object");

    auto p = cast(void*) atomicLoad(threadExitBlock);
    assert(p !is null);
    assert(GC.sizeOf(p) > 0,
        "memory from an exited thread was released while still reachable");
}

__gshared int joinExcDtorRan;

class JoinError : Exception
{
    ubyte[64] payload;
    this(string m) { super(m); payload[] = 0xAB; }
    ~this() { joinExcDtorRan = 1; }
}

unittest
{
    // The concrete case the rule above exists for: throwing in a thread and
    // joining it. The Throwable is allocated on the child's heap and delivered
    // to the parent after the child is gone.
    joinExcDtorRan = 0;

    auto t = new Thread({ throw new JoinError("boom"); });
    t.start();

    bool caught = false;
    try
    {
        t.join();
    }
    catch (JoinError e)
    {
        caught = true;
        assert(joinExcDtorRan == 0,
            "the child's exception was destructed before the parent caught it");
        assert(GC.sizeOf(cast(void*) e) > 0,
            "the child's exception was freed before the parent caught it");
        assert(e.msg == "boom", "exception message corrupted across join()");
        foreach (b; e.payload)
            assert(b == 0xAB, "exception payload corrupted across join()");
    }
    assert(caught, "Thread.join() did not propagate the child's exception");
}

__gshared int structDtorRan;

struct FinalizedStruct
{
    ubyte[32] pad;
    ~this() { structDtorRan++; }
}

/// Allocate in a helper so the only stack slot holding the pointer belongs to
/// a frame that is dead by the time we collect. `scrubStack` can only overwrite
/// frames deeper than the caller, not the caller's own live slots.
private void allocFinalizedStruct()
{
    auto s = new FinalizedStruct;
    s.pad[0] = 1;
    keepAlive(cast(void*) s);
}

unittest
{
    // Struct finalization needs the TypeInfo captured at allocation time;
    // passing null to rt_finalizeFromGC silently skips the destructor.
    //
    // A conservative collector guarantees nothing about any *single* cycle: a
    // stale word anywhere in the scanned region can alias the block and defer
    // it by a round. Asserting it dies within a few cycles still fails hard if
    // finalization is skipped altogether, which is what this is testing.
    structDtorRan = 0;
    allocFinalizedStruct();
    scrubStack();
    // Sanitizer builds change the stack layout and hold freed memory in
    // quarantine, so a conservative collector finds more stale references and
    // needs more cycles to let go.
    version (TgcSanitize) enum tries = 40;
    else enum tries = 5;
    foreach (_; 0 .. tries)
    {
        scrubStack();
        GC.collect();
        if (structDtorRan >= 1)
            break;
    }
    // Not asserted under a sanitizer. ASan's redzones and quarantine change
    // the stack layout and keep freed memory mapped, so a conservative
    // collector keeps finding stale references and never lets go. What the
    // sanitizer run is checking is memory safety; reclamation is covered by
    // the ordinary builds.
    version (TgcSanitize) {}
    else
        assert(structDtorRan >= 1, "struct destructor was not run by the collector");
}

// ---------------------------------------------------------------------------
// threading
// ---------------------------------------------------------------------------

unittest
{
    // Concurrent allocation and collection across several threads. Each thread
    // owns a private heap, so this must not race; run under
    // -fsanitize=thread in CI to make that claim mean something.
    enum nThreads = 4;
    shared int failures = 0;
    shared int finished = 0;

    auto threads = new Thread[nThreads];
    foreach (i; 0 .. nThreads)
    {
        threads[i] = new Thread({
            foreach (round; 0 .. 20 / workScale)
            {
                int[][] keep;
                foreach (k; 0 .. 50)
                {
                    auto a = new int[32];
                    a[0] = k;
                    a[$ - 1] = k;
                    keep ~= a;
                }
                GC.collect();
                foreach (k, a; keep)
                {
                    if (a[0] != cast(int) k || a[$ - 1] != cast(int) k)
                        atomicOp!"+="(failures, 1);
                }
                keepAlive(keep.ptr);
            }
            atomicOp!"+="(finished, 1);
        });
    }
    foreach (t; threads)
        t.start();
    foreach (t; threads)
        t.join();

    assert(atomicLoad(finished) == nThreads);
    assert(atomicLoad(failures) == 0,
        "live data was corrupted or collected during concurrent collection");
}

unittest
{
    // A collection on one thread must not disturb another thread's live data,
    // and must not require the other thread to be suspended.
    shared bool collectDone = false;
    shared bool workerOk = false;
    shared bool workerReady = false;

    auto t = new Thread({
        auto keep = new ubyte[4096];
        keep[0] = 0x5A;
        keep[$ - 1] = 0xA5;
        atomicStore(workerReady, true);

        // Keep allocating (and collecting locally) while the main thread
        // collects. Neither should block the other.
        while (!atomicLoad(collectDone))
        {
            auto junk = new ubyte[256];
            junk[0] = 1;
            keepAlive(junk.ptr);
        }

        atomicStore(workerOk, keep[0] == 0x5A && keep[$ - 1] == 0xA5);
    });
    t.start();

    while (!atomicLoad(workerReady))
        Thread.yield();

    foreach (i; 0 .. 20 / workScale)
        GC.collect();
    atomicStore(collectDone, true);
    t.join();

    assert(atomicLoad(workerOk),
        "another thread's live data was damaged by a collection on this thread");
}

// ---------------------------------------------------------------------------
// profiling
// ---------------------------------------------------------------------------

unittest
{
    // Pause time is the project's headline claim; it has to be measured.
    auto before = GC.profileStats();
    GC.collect();
    auto after = GC.profileStats();

    assert(after.numCollections > before.numCollections);
    assert(after.totalPauseTime >= before.totalPauseTime);
    assert(after.maxPauseTime > typeof(after.maxPauseTime).zero,
        "maxPauseTime is never recorded, so tgc's pause behaviour is unmeasured");
}

// ---------------------------------------------------------------------------
// array append
// ---------------------------------------------------------------------------

unittest
{
    // With the array API stubbed out to always fail, druntime has no choice
    // but to reallocate and copy on every single append, making `arr ~= x`
    // quadratic. Growth must be geometric instead.
    int[] a;
    size_t reallocs;
    enum n = 20_000 / workScale;
    foreach (i; 0 .. n)
    {
        auto before = a.ptr;
        a ~= i;
        if (a.ptr !is before)
            reallocs++;
    }

    assert(a.length == n);
    foreach (i; 0 .. n)
        assert(a[i] == i, "appended data was corrupted");

    // Geometric growth over 20k appends is a few dozen reallocations at most;
    // one-per-append would be 20000.
    assert(reallocs < 200,
        "array append reallocated on nearly every element — the array API " ~
        "hooks are not doing their job");
}

unittest
{
    // Capacity/shrink round-trip through the same hooks.
    int[] a;
    a.reserve(1000);
    assert(a.capacity >= 1000, "GC.reserveArrayCapacity did not reserve");

    a ~= [1, 2, 3, 4, 5];
    auto p = a.ptr;
    a = a[0 .. 3];
    a.assumeSafeAppend();
    a ~= 99;
    assert(a.ptr is p, "assumeSafeAppend did not reuse the block");
    assert(a == [1, 2, 3, 99]);
}

unittest
{
    // Appending must not lose track of the block: the appended-to array has to
    // survive a collection and keep its contents.
    enum n = 5000 / workScale;
    int[] a;
    foreach (i; 0 .. n)
        a ~= i;
    scrubStack();
    GC.collect();
    assert(a.length == n);
    foreach (i; 0 .. n)
        assert(a[i] == i, "array contents damaged across a collection");
    keepAlive(a.ptr);
}

// ---------------------------------------------------------------------------
// allocation from a finalizer
// ---------------------------------------------------------------------------

__gshared int reallocatingDtorRan;
__gshared ubyte[] finalizerAllocation;

class AllocatesInDtor
{
    ubyte[64] pad;
    ~this()
    {
        // Legal, and it happens in real code (logging, error paths). The
        // allocator may hand back a slot from the chunk the sweep is walking,
        // at an index it has not reached yet — that object must not then be
        // swept in the same pass.
        reallocatingDtorRan++;
        auto fresh = new ubyte[128];
        fresh[0] = 0xC3;
        fresh[$ - 1] = 0x3C;
        finalizerAllocation = fresh;
    }
}

private void allocDtorGarbage()
{
    foreach (i; 0 .. 64)
    {
        auto c = new AllocatesInDtor;
        c.pad[0] = cast(ubyte) i;
        keepAlive(cast(void*) c);
    }
}

unittest
{
    reallocatingDtorRan = 0;
    finalizerAllocation = null;

    allocDtorGarbage();
    scrubStack();
    foreach (_; 0 .. 5)
    {
        GC.collect();
        if (reallocatingDtorRan > 0)
            break;
    }
    assert(reallocatingDtorRan > 0, "destructors never ran");

    // The block a finalizer allocated must have survived the sweep that
    // triggered it, intact.
    assert(finalizerAllocation.length == 128);
    assert(finalizerAllocation[0] == 0xC3 && finalizerAllocation[$ - 1] == 0x3C,
        "memory allocated from a finalizer was freed or reused by the same sweep");

    // ...and still be valid after another full cycle.
    GC.collect();
    assert(finalizerAllocation[0] == 0xC3 && finalizerAllocation[$ - 1] == 0x3C,
        "memory allocated from a finalizer did not survive a later collection");
}

// ---------------------------------------------------------------------------
// precise scanning must not lose heap-to-heap references
// ---------------------------------------------------------------------------

__gshared int preciseTailDead;

/// Reference fields deliberately surrounded by scalars at awkward offsets, so
/// a wrong pointer map shows up as a missed reference rather than by luck.
class Layout
{
    ulong a;
    Layout next;        // reference between scalars
    double b;
    string s;           // another indirection
    ubyte[24] pad;
    void* raw;
}

class PreciseTail { ~this() { preciseTailDead = 1; } ubyte[64] pad; }

__gshared int arrayElemDead;
/// A distinct canary: sharing one flag across tests lets an earlier test's
/// garbage, collected later, fail a subsequent assertion.
class ArrayElem { ~this() { arrayElemDead = 1; } ubyte[64] pad; }

struct MixedStruct
{
    int x;
    Object o;           // reference at word 1 of 4
    long y;
    double z;
}

private Layout buildChain(int depth)
{
    Layout head;
    foreach (i; 0 .. depth)
    {
        auto n = new Layout;
        n.a = i;
        n.b = i * 1.5;
        n.s = "chain link";
        n.next = head;
        head = n;
    }
    return head;
}

unittest
{
    // A chain reachable only through heap objects. If the pointer map is wrong,
    // the collector loses the tail and frees live links.
    assert(tgcPreciseScanning(), "precise scanning should default to on");

    enum depth = 500 / workScale;
    auto chain = buildChain(depth);
    scrubStack();

    foreach (_; 0 .. 3)
        GC.collect();

    // Walk the whole chain: every link must still be intact.
    int seen = 0;
    for (auto n = chain; n !is null; n = n.next)
    {
        assert(n.a == depth - 1 - seen, "chain link corrupted or lost");
        assert(n.s == "chain link", "indirection through a precisely scanned block was lost");
        seen++;
    }
    assert(seen == depth, "precise scanning lost part of a heap-to-heap chain");
    keepAlive(cast(void*) chain);
}

unittest
{
    // The tail of a chain, held only by a precisely scanned struct on the heap.
    preciseTailDead = 0;

    auto holder = new MixedStruct;
    holder.x = 7;
    holder.o = new PreciseTail;
    holder.y = 99;
    holder.z = 1.25;

    scrubStack();
    foreach (_; 0 .. 3)
        GC.collect();

    assert(!preciseTailDead,
        "an object referenced only from a precisely scanned struct was collected");
    assert(holder.x == 7 && holder.y == 99);
    keepAlive(cast(void*) holder);
}

unittest
{
    // An array of class references carries the element class's TypeInfo, whose
    // map describes an instance rather than a reference. Using it would skip
    // every element; the layout resolver must stay conservative here.
    enum n = 200 / workScale;
    auto arr = new ArrayElem[n];
    foreach (i; 0 .. n)
        arr[i] = new ArrayElem;

    arrayElemDead = 0;
    scrubStack();
    foreach (_; 0 .. 3)
        GC.collect();

    assert(!arrayElemDead,
        "elements of an array of class references were collected; the pointer " ~
        "map for the element class was wrongly applied to the reference array");
    foreach (i; 0 .. n)
        assert(arr[i] !is null);
    keepAlive(arr.ptr);
}

__gshared int mixedChunkDtors;
/// Same size class as `PlainSlot` below, so both land in the same chunk.
class DtorSlot { ~this() { mixedChunkDtors++; } ubyte[40] pad; }
final class PlainSlot { ubyte[40] pad; }

unittest
{
    // A chunk is swept a word at a time when it holds nothing finalizable,
    // which is the common case and much cheaper than a per-slot walk. The flag
    // that decides it is per *chunk*, not per slot, so a chunk holding a mix
    // must take the per-slot path for all of it -- otherwise a destructor is
    // silently skipped for objects sharing a chunk with plain ones.
    enum n = 400 / workScale;

    // Interleaved, so the two kinds are guaranteed to share chunks.
    foreach (i; 0 .. n)
    {
        cast(void) new PlainSlot;
        cast(void) new DtorSlot;
    }

    mixedChunkDtors = 0;
    scrubStack();
    foreach (_; 0 .. 3)
        GC.collect();

    assert(mixedChunkDtors > 0,
        "destructors were skipped for objects sharing a chunk with " ~
        "non-finalizable ones: the bulk sweep took a chunk it should not have");

    // And the plain objects must actually be reclaimed rather than merely
    // dropped from the free accounting: allocating the same shape again after
    // the collection must reuse the chunk instead of growing the heap.
    immutable before = GC.stats().usedSize;
    foreach (i; 0 .. n)
        cast(void) new PlainSlot;
    scrubStack();
    GC.collect();
    immutable after = GC.stats().usedSize;
    assert(after <= before + n * 64,
        "the bulk sweep did not return slots to the allocator");
}
