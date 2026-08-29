/**
 * Opt-in thread-local garbage collector (`tgc`).
 *
 * Each attached thread owns a private heap arena. Collection scans and sweeps
 * only that thread's stack, registers, TLS, roots/ranges, and blocks — it does
 * not call `thread_suspendAll`. Detached `@nogc` threads are never paused by
 * `tgc`.
 *
 * Memory comes from chunk-aligned arenas carved into size-class slots, so a
 * candidate pointer is resolved to its block by masking and indexing rather
 * than by searching. That keeps the mark phase linear in live data instead of
 * quadratic in block count.
 *
 * Cross-thread pointer sharing of GC blocks is unsupported in v1 except via
 * explicit ownership transfer that returns memory through a remote free list.
 * Prefer copy or `immutable` message passing (`std.concurrency`). Partitioned
 * shared regions are planned as Phase 2.
 *
 * Select with `--DRT-gcopt=gc:tgc`. Informal side-name: "realtime GC".
 *
 * Copyright: Copyright dlang-supplemental contributors 2026.
 * License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 */
module core.internal.gc.impl.tgc.gc;

import core.gc.gcinterface;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.internal.container.array;
import core.internal.spinlock;
import core.internal.traits : externDFunc;

import core.thread.context : StackContext;
import core.thread.threadbase : ThreadBase;

import cstdlib = core.stdc.stdlib : calloc, free, malloc, realloc;
import core.stdc.string : memcpy, memset;
static import core.memory;

extern (C) noreturn onOutOfMemoryError(void* pretend_sideffect = null, string file = __FILE__, size_t line = __LINE__) @trusted pure nothrow @nogc; /* dmd @@@BUG11461@@@ */
extern (C) void rt_finalizeFromGC(void* p, size_t size, uint attr, const(TypeInfo) typeInfo) nothrow;
extern (C) void* thread_stackTop() nothrow @nogc;
extern (C) void* thread_stackBottom() nothrow @nogc;

// Used only by the cooperative global collection; a thread-local collection
// never suspends anybody.
alias ScanAllThreadsFn = void delegate(void* pbeg, void* pend) nothrow;
extern (C) void thread_suspendAll() nothrow;
extern (C) void thread_resumeAll() nothrow;
extern (C) void thread_scanAll(scope ScanAllThreadsFn scan) nothrow;

private void thread_yield() nothrow
{
    import core.thread.osthread : Thread;

    Thread.yield();
}

private
{
    alias ScanDg = void delegate(void* pstart, void* pend) nothrow;

    // Interface to rt.tlsgc. This is extern(D) with a mangled name, so it must
    // be reached the same way core.thread.threadbase reaches it — not as
    // extern(C). Scanning TLS is mandatory: a GC pointer whose only copy lives
    // in a thread-local global is otherwise swept while still live.
    alias rt_tlsgc_scan = externDFunc!("rt.tlsgc.scan", void function(void*, scope ScanDg) nothrow);

    // Spills callee-saved registers to the stack and hands back the resulting
    // stack pointer. Without this, a pointer held only in a register (routine
    // in optimized builds) is invisible to the mark phase.
    alias callWithStackShellDg = void delegate(void* sp) nothrow;
    alias callWithStackShell = externDFunc!("core.thread.osthread.callWithStackShell",
                                            void function(scope callWithStackShellDg) nothrow);

    // rt_finalizeFromGC is nothrow but not @nogc, because a finalizer may
    // allocate. cleanupThread is @nogc by interface contract yet still has to
    // run destructors for objects alive at thread exit, so the call is made
    // through a cast.
    alias FinalizeFn = extern (C) void function(void*, size_t, uint, const(TypeInfo)) nothrow @nogc;

    void finalizeBlock(void* p, size_t size, uint attr, const(TypeInfo) ti) nothrow @nogc
    {
        (cast(FinalizeFn) &rt_finalizeFromGC)(p, size, attr, ti);
    }
}

/**
 * Head of druntime's global list of every registered stack context.
 *
 * This is the list `thread_scanAllType` walks, and it contains fiber stacks as
 * well as thread stacks — `Fiber` registers its context with
 * `ThreadBase.add(m_ctxt)` on construction. tgc needs it because scanning only
 * the running stack silently loses every suspended fiber.
 *
 * Reached through `__traits(getMember)` because the field is not public. As
 * with the rt.tlsgc handle, a druntime rename must be a hard build failure: a
 * silent fallback here means fibers' live data gets freed underneath them.
 */
private StackContext* globalStackContexts() nothrow @nogc
{
    static if (__traits(compiles, __traits(getMember, ThreadBase, "sm_cbeg")))
        return cast(StackContext*) __traits(getMember, ThreadBase, "sm_cbeg");
    else
        static assert(false,
            "tgc: cannot reach druntime's global stack-context list " ~
            "(ThreadBase.sm_cbeg). Without it, suspended fiber stacks cannot " ~
            "be scanned and the collector would free live data held by any " ~
            "fiber parked on a yield. Port this to the current druntime " ~
            "before using tgc.");
}

/**
 * druntime's lock guarding the global thread and stack-context lists.
 *
 * Taking it during a collection follows druntime's own documented lock order —
 * "the GC acquires this lock after the GC lock" — so it cannot invert. The
 * inverse (allocating while holding it) is what deadlocks, and tgc never does
 * that.
 */
private auto threadListLock() nothrow @nogc
{
    static if (__traits(compiles, __traits(getMember, ThreadBase, "slock")))
        return __traits(getMember, ThreadBase, "slock");
    else
        static assert(false,
            "tgc: cannot reach druntime's thread-list lock (ThreadBase.slock), " ~
            "needed to snapshot the stack-context list safely.");
}

/**
 * Head of this thread's active stack-context chain (`ThreadBase.m_curr`).
 *
 * The chain links the running context to the ones it is nested inside, so from
 * inside a fiber it yields that fiber and then the thread's own stack.
 */
private StackContext* currentStackContext(ThreadBase t) nothrow @nogc
{
    if (t is null)
        return null;
    static if (__traits(compiles, __traits(getMember, ThreadBase.init, "m_curr")))
        return cast(StackContext*) __traits(getMember, t, "m_curr");
    else
        static assert(false,
            "tgc: cannot reach druntime's current stack context " ~
            "(ThreadBase.m_curr), needed to identify which stacks belong to " ~
            "this thread.");
}

/**
 * Marks the conservative scanning routines as exempt from AddressSanitizer.
 *
 * A conservative collector deliberately reads memory a sanitizer considers
 * off-limits: padding and redzones between stack variables, and quarantined
 * heap. Those reads are by design, so instrumenting them produces both false
 * reports and a large slowdown — enough to make a sanitized test run
 * impractical. Exempting the scan routines is the standard treatment.
 */
version (LDC)
{
    import ldc.attributes : noSanitize;

    private enum conservativeScan = noSanitize("address");
}
else
{
    // No-op UDA on compilers without the attribute.
    private enum conservativeScan = "tgc.conservativeScan";
}

/**
 * druntime's per-thread `rt.tlsgc` handle, describing this thread's TLS ranges.
 *
 * The handle is deliberately *borrowed* rather than created here. On the
 * sections_elf_shared backend `rt.tlsgc.init` hands back a pointer to a
 * thread-local singleton, so a second init/destroy pair double-frees the
 * ranges and crashes the thread on exit. druntime creates exactly one handle
 * per thread in `ThreadBase.tlsRTdataInit` and destroys it in
 * `destroyDataStorage`; tgc only reads it.
 *
 * This reaches a private field. If a future druntime renames it, that must be
 * a hard build failure — a `static if (__traits(compiles, ...))` guard around
 * TLS scanning compiles away silently and lets the collector free live memory
 * in every real build.
 */
private void* threadTLSData(ThreadBase t) nothrow @nogc
{
    if (t is null)
        return null;
    static if (__traits(compiles, __traits(getMember, ThreadBase.init, "m_tlsrtdata")))
        return cast(void*) __traits(getMember, t, "m_tlsrtdata");
    else
        static assert(false,
            "tgc: cannot reach druntime's per-thread rt.tlsgc handle " ~
            "(ThreadBase.m_tlsrtdata). Without it TLS cannot be scanned and " ~
            "the collector would free live memory reachable only from " ~
            "thread-local globals. Port this to the current druntime before " ~
            "using tgc.");
}

// ---------------------------------------------------------------------------
// arena geometry
// ---------------------------------------------------------------------------

/// Payload alignment required of every GC allocation. `real`, SIMD vectors and
/// `align(16)` aggregates depend on it; an aligned SSE store into an 8-aligned
/// block faults on x86-64.
private enum size_t payloadAlign = 16;

/**
 * Arena granularity. Chunks are allocated aligned to their own size so that
 * `p & ~(chunkSize - 1)` yields a candidate chunk base in a couple of
 * instructions — the property that makes `markPtr` O(1).
 */
private enum size_t chunkSize = 64 * 1024;
static assert((chunkSize & (chunkSize - 1)) == 0, "chunkSize must be a power of two");
static assert(chunkSize % payloadAlign == 0);

private enum size_t chunkMask = ~(chunkSize - 1);

/// Allocations larger than this get a dedicated chunk run instead of a slot.
private enum size_t maxSmall = 32768;

/**
 * Size classes.
 *
 * The range above 8 KiB matters more than it looks. Without it, a 9000-byte
 * request fell straight through to a dedicated 64 KiB chunk run: 7.3x space
 * amplification, and the whole run was scanned and zeroed on every touch. HTTP
 * buffers live exactly there.
 */
private static immutable uint[] sizeClasses = [
    16, 32, 48, 64, 80, 96, 112, 128,
    160, 192, 224, 256, 320, 384, 448, 512,
    640, 768, 896, 1024, 1280, 1536, 1792, 2048,
    2560, 3072, 3584, 4096, 5120, 6144, 7168, 8192,
    10240, 12288, 14336, 16384, 20480, 24576, 28672, 32768,
];

/// Aim for at least this many slots per chunk, so a chunk is worth its header.
private enum size_t minSlotsPerChunk = 8;

private enum size_t numClasses = sizeClasses.length;

private enum size_t collectThresholdInit = 256 * 1024;

/**
 * Heap headroom: collect once live data has grown by this factor.
 *
 * With mark-sweep, a pause costs time proportional to the *live set*, while
 * headroom only changes how often collections happen — so more headroom is
 * better for both throughput and latency, and costs only memory. The old
 * hardcoded 2 made tgc collect 135 times on binary-trees depth 18 where the
 * conservative collector collected 7, spending 1.76 s of a 2.81 s run in the
 * collector.
 */
private shared size_t heapGrowthFactor = 4;

/**
 * Headroom above which the growth factor tapers toward +20%.
 *
 * A flat multiplier is fine while the heap is small and ruinous once it is
 * large: x4 on a 1 GB live set means not collecting until 4 GB. BEAM solves the
 * same problem by growing its per-process heaps along a Fibonacci-ish sequence
 * up to about a megaword and then in 20% increments; this is the same shape,
 * expressed as a cap on the absolute headroom.
 */
private enum size_t growthTaperAbove = 32 * 1024 * 1024;

/// Collection threshold for a heap holding `live` bytes.
private size_t thresholdFor(size_t live) nothrow @nogc
{
    immutable size_t g = atomicLoad(heapGrowthFactor);
    immutable size_t wanted = live * (g - 1);
    immutable size_t capped = growthTaperAbove > live / 5 ? growthTaperAbove : live / 5;
    immutable size_t headroom = wanted < capped ? wanted : capped;

    size_t t = live + headroom;
    if (t < collectThresholdInit)
        t = collectThresholdInit;
    return t;
}

/// Set the heap growth factor; clamped to at least 2.
extern (C) void tgc_setHeapGrowth(size_t factor) nothrow @nogc
{
    atomicStore(heapGrowthFactor, factor < 2 ? 2 : factor);
}

/// ditto
extern (C) size_t tgc_getHeapGrowth() nothrow @nogc
{
    return atomicLoad(heapGrowthFactor);
}

/**
 * Whether to promote blocks observed reachable from a global root.
 *
 * Off by default, deliberately. Promotion closes a real hole — a block
 * published to a global, picked up by another thread, then unpublished would
 * otherwise be reclaimed while that other thread still held it — but promotion
 * is sticky, so the promoted set never shrinks and is re-scanned on every
 * subsequent collection. Measured on a workload that publishes and drops
 * 50,000 objects repeatedly, the mark phase grew from 0.25 ms to 3.66 ms as the
 * promoted set grew to 212,000 blocks, and it would keep growing.
 *
 * For a collector whose whole purpose is bounded pause time, monotonically
 * growing pauses are a worse failure than the narrow bug this fixes, so the
 * caller decides. Turn it on with `tgcTrackEscapes(true)` if the program
 * publishes GC pointers to globals for other threads to pick up and can afford
 * pauses that grow with total published allocations. A cooperative global
 * collection (Phase 2) is what would make this affordable by default.
 */
private shared bool escapeTracking = false;

/// Enable or disable escape promotion. See `escapeTracking`.
extern (C) void tgc_setTrackEscapes(bool enable) nothrow @nogc
{
    atomicStore(escapeTracking, enable);
}

/// ditto
extern (C) bool tgc_getTrackEscapes() nothrow @nogc
{
    return atomicLoad(escapeTracking);
}

/// Retained bytes at which a global collection is triggered; 0 disables it.
extern (C) void tgc_setGlobalThreshold(size_t bytes) nothrow @nogc
{
    atomicStore(globalThreshold, bytes);
}

/// ditto
extern (C) size_t tgc_getGlobalThreshold() nothrow @nogc
{
    return atomicLoad(globalThreshold);
}

/// Bytes held in arenas adopted from exited threads, reclaimable only globally.
extern (C) size_t tgc_getRetainedBytes() nothrow @nogc
{
    return atomicLoad(orphanBytes);
}

/// Maps a request size to a size-class index.
private uint classOf(size_t size) nothrow @nogc
{
    foreach (i, sc; sizeClasses)
        if (size <= sc)
            return cast(uint) i;
    assert(false, "classOf called with a large size");
}

private size_t alignUp(size_t n, size_t a) nothrow @nogc
{
    return (n + a - 1) & ~(a - 1);
}

// ---------------------------------------------------------------------------
// aligned chunk allocation
// ---------------------------------------------------------------------------

version (Posix)
{
    import core.sys.posix.stdlib : posix_memalign;

    private void* chunkAlloc(size_t bytes) nothrow @nogc
    {
        void* p;
        if (posix_memalign(&p, chunkSize, bytes) != 0)
            return null;
        return p;
    }

    private void chunkFree(void* p) nothrow @nogc
    {
        cstdlib.free(p);
    }
}
else version (Windows)
{
    extern (C) void* _aligned_malloc(size_t size, size_t alignment) nothrow @nogc;
    extern (C) void _aligned_free(void* p) nothrow @nogc;

    private void* chunkAlloc(size_t bytes) nothrow @nogc
    {
        return _aligned_malloc(bytes, chunkSize);
    }

    private void chunkFree(void* p) nothrow @nogc
    {
        _aligned_free(p);
    }
}
else
{
    static assert(false, "tgc: no aligned allocator for this platform");
}

// ---------------------------------------------------------------------------
// per-slot metadata
// ---------------------------------------------------------------------------

private enum size_t bitsPerWord = size_t.sizeof * 8;

private size_t bitWords(size_t n) nothrow @nogc
{
    return (n + bitsPerWord - 1) / bitsPerWord;
}

private bool testBit(const(size_t)* bits, size_t i) nothrow @nogc
{
    return (bits[i / bitsPerWord] & (cast(size_t) 1 << (i % bitsPerWord))) != 0;
}

private void setBit(size_t* bits, size_t i) nothrow @nogc
{
    bits[i / bitsPerWord] |= cast(size_t) 1 << (i % bitsPerWord);
}

private void clearBit(size_t* bits, size_t i) nothrow @nogc
{
    bits[i / bitsPerWord] &= ~(cast(size_t) 1 << (i % bitsPerWord));
}

/**
 * Block attributes actually persisted.
 *
 * Stored as one byte per slot rather than a `uint`. druntime's own conservative
 * collector keeps only the defined attribute bits too (as separate bitmaps),
 * so nothing that matters is lost, and it keeps `SlotMeta` down to two words.
 */
private enum uint keptAttrs =
    BlkAttr.FINALIZE | BlkAttr.NO_SCAN | BlkAttr.NO_MOVE |
    BlkAttr.APPENDABLE | BlkAttr.NO_INTERIOR | BlkAttr.STRUCTFINAL;

static assert(keptAttrs <= ubyte.max, "attribute bits no longer fit in a byte");

/*
 * `sharedBits`: the block has been reachable from a global root at least once,
 * so another thread may hold a reference to it.
 *
 * Sticky: never cleared by a thread-local collection. Consider thread A
 * allocating X, publishing it in a `shared` global, thread B reading the global
 * and keeping X only on B's stack, and A then clearing the global. X is now
 * reachable from nothing A can see, but B is still using it. Re-deciding this
 * each cycle would free X; only a permanent mark is safe. A global collection
 * can clear it, having proven no thread holds the block.
 */

/**
 * Per-slot data that genuinely varies per object.
 *
 * Allocated/marked/promoted state lives in per-chunk bitvectors instead, and
 * attributes in a byte array. That makes clearing every mark a `memset` over
 * n/8 bytes rather than a read-modify-write across every slot's metadata, lets
 * the sweep skip 64 slots per word test, and drops per-slot overhead from 24
 * bytes to 17.375.
 */
private struct SlotMeta
{
    TypeInfo ti;      /// type for finalization; may be null
    size_t usedSize;  /// BlkAttr.APPENDABLE used bytes (array API)
}

/**
 * A chunk-aligned arena.
 *
 * Small chunks are carved into `slotCount` slots of `slotSize` bytes, with a
 * `SlotMeta` array between the header and the slots. Large allocations get a
 * run of `runChunks` chunks holding a single slot; every chunk base in the run
 * maps back to the run head so interior pointers resolve in one probe.
 */
private struct Chunk
{
    ThreadHeap* heap;
    Chunk* nextAll;
    Chunk* prevAll;
    Chunk* nextPartial;
    Chunk* prevPartial;

    SlotMeta* meta;
    size_t* allocBits;  /// slot is handed out
    size_t* markBits;   /// slot was reached this cycle
    size_t* sharedBits; /// slot escaped through a global (sticky)
    ubyte* attrs;       /// BlkAttr, one byte per slot
    void* data;      /// first slot
    void* freeHead;  /// intrusive free-slot list, threaded through free slots

    uint slotSize;
    uint slotCount;
    uint freeCount;
    uint cls;        /// size-class index, or uint.max for a large run

    size_t runChunks; /// chunks spanned (large runs only; 1 for small chunks)
    size_t largeSize; /// payload capacity of the single slot in a large run

    bool inPartial;

    bool isLarge() const nothrow @nogc
    {
        return cls == uint.max;
    }

    void* slotAt(size_t idx) nothrow @nogc
    {
        return cast(void*)(cast(ubyte*) data + idx * slotSize);
    }

    size_t capacity() const nothrow @nogc
    {
        return isLarge() ? largeSize : slotSize;
    }

    bool isAllocated(size_t i) const nothrow @nogc { return testBit(allocBits, i); }
    bool isMarked(size_t i) const nothrow @nogc { return testBit(markBits, i); }
    bool isShared(size_t i) const nothrow @nogc { return testBit(sharedBits, i); }

    void setAllocated(size_t i) nothrow @nogc { setBit(allocBits, i); }
    void clearAllocated(size_t i) nothrow @nogc { clearBit(allocBits, i); }
    void setMarked(size_t i) nothrow @nogc { setBit(markBits, i); }
    void setShared(size_t i) nothrow @nogc { setBit(sharedBits, i); }
    void clearShared(size_t i) nothrow @nogc { clearBit(sharedBits, i); }

    uint attrOf(size_t i) const nothrow @nogc { return attrs[i]; }
    void setAttrOf(size_t i, uint a) nothrow @nogc { attrs[i] = cast(ubyte)(a & keptAttrs); }

    /// Like `nextReclaimable`, but ignores promotion: a global collection has
    /// already proven reachability, so the sticky bit must not veto it.
    size_t nextReclaimableIgnoringShared(size_t from) const nothrow @nogc
    {
        immutable size_t words = bitWords(slotCount);
        size_t w = from / bitsPerWord;
        if (w >= words)
            return slotCount;

        size_t bits = allocBits[w] & ~markBits[w];
        immutable size_t off = from % bitsPerWord;
        if (off)
            bits &= ~cast(size_t) 0 << off;

        for (;;)
        {
            if (bits)
            {
                import core.bitop : bsf;

                size_t idx = w * bitsPerWord + bsf(bits);
                return idx < slotCount ? idx : slotCount;
            }
            if (++w >= words)
                return slotCount;
            bits = allocBits[w] & ~markBits[w];
        }
    }

    /// Clear every mark in one sweep over n/8 bytes.
    void clearMarks() nothrow @nogc
    {
        memset(markBits, 0, bitWords(slotCount) * size_t.sizeof);
    }

    /**
     * Index of the next slot that is allocated but neither marked nor
     * promoted, at or after `from`; `slotCount` when there is none.
     *
     * Tests 64 slots per word, so a chunk that is mostly free or mostly live
     * is skipped in a few instructions instead of one test per slot.
     */
    size_t nextReclaimable(size_t from) const nothrow @nogc
    {
        immutable size_t words = bitWords(slotCount);
        size_t w = from / bitsPerWord;
        if (w >= words)
            return slotCount;

        size_t bits = allocBits[w] & ~markBits[w] & ~sharedBits[w];
        // Mask off slots before `from` in the first word.
        immutable size_t off = from % bitsPerWord;
        if (off)
            bits &= ~cast(size_t) 0 << off;

        for (;;)
        {
            if (bits)
            {
                import core.bitop : bsf;

                size_t idx = w * bitsPerWord + bsf(bits);
                return idx < slotCount ? idx : slotCount;
            }
            if (++w >= words)
                return slotCount;
            bits = allocBits[w] & ~markBits[w] & ~sharedBits[w];
        }
    }
}

/// A resolved (chunk, slot) pair. Replaces the old per-object header.
private struct BlkRef
{
    Chunk* chunk;
    size_t idx;

    bool valid() const nothrow @nogc
    {
        return chunk !is null;
    }

    SlotMeta* meta() nothrow @nogc
    {
        return &chunk.meta[idx];
    }

    void* payload() nothrow @nogc
    {
        return chunk.slotAt(idx);
    }

    size_t capacity() nothrow @nogc
    {
        return chunk.capacity();
    }

    uint attr() nothrow @nogc { return chunk.attrOf(idx); }
    void setAttr(uint a) nothrow @nogc { chunk.setAttrOf(idx, a); }
}

// ---------------------------------------------------------------------------
// chunk map: chunk base -> owning chunk, open addressed
// ---------------------------------------------------------------------------

/**
 * Per-heap map from chunk base address to `Chunk*`.
 *
 * Deliberately per-heap rather than global: a thread only ever marks its own
 * blocks, so the hot `markPtr` lookup needs no lock at all.
 */
private struct ChunkMap
{
    void** keys;
    Chunk** vals;
    size_t cap;      /// power of two
    size_t len;      /// live entries
    size_t occupied; /// live entries + tombstones

    /// Sentinel for a deleted entry. Kept integral: a compile-time
    /// int-to-pointer cast is not portable across D compilers.
    enum size_t tombstoneBits = 1;

    static void* tombstone() nothrow @nogc
    {
        return cast(void*) tombstoneBits;
    }

    static size_t hash(void* base) nothrow @nogc
    {
        // Chunk bases are chunkSize-aligned, so the low bits carry no
        // information; fold the useful bits down with a 64-bit mixer.
        size_t x = (cast(size_t) base) / chunkSize;
        x ^= x >> 33;
        x *= 0xff51afd7ed558ccdUL;
        x ^= x >> 33;
        return x;
    }

    void grow(size_t newCap) nothrow @nogc
    {
        auto oldKeys = keys;
        auto oldVals = vals;
        auto oldCap = cap;

        auto nk = cast(void**) cstdlib.calloc(newCap, (void*).sizeof);
        auto nv = cast(Chunk**) cstdlib.calloc(newCap, (Chunk*).sizeof);
        if (!nk || !nv)
        {
            cstdlib.free(nk);
            cstdlib.free(nv);
            onOutOfMemoryError();
        }

        keys = nk;
        vals = nv;
        cap = newCap;
        len = 0;
        occupied = 0;

        foreach (i; 0 .. oldCap)
        {
            auto k = oldKeys[i];
            if (k !is null && k !is tombstone())
                put(k, oldVals[i]);
        }

        cstdlib.free(oldKeys);
        cstdlib.free(oldVals);
    }

    void put(void* base, Chunk* c) nothrow @nogc
    {
        if (cap == 0)
            grow(64);
        else if ((occupied + 1) * 4 >= cap * 3)
            grow(len * 4 < cap ? cap : cap * 2);

        size_t mask = cap - 1;
        size_t i = hash(base) & mask;
        size_t firstTomb = size_t.max;
        for (;;)
        {
            auto k = keys[i];
            if (k is null)
            {
                if (firstTomb != size_t.max)
                {
                    keys[firstTomb] = base;
                    vals[firstTomb] = c;
                    len++;
                    return; // reused a tombstone: `occupied` is unchanged
                }
                keys[i] = base;
                vals[i] = c;
                len++;
                occupied++;
                return;
            }
            if (k is tombstone())
            {
                if (firstTomb == size_t.max)
                    firstTomb = i;
            }
            else if (k is base)
            {
                vals[i] = c;
                return;
            }
            i = (i + 1) & mask;
        }
    }

    Chunk* get(void* base) nothrow @nogc
    {
        if (len == 0)
            return null;
        size_t mask = cap - 1;
        size_t i = hash(base) & mask;
        for (;;)
        {
            auto k = keys[i];
            if (k is null)
                return null;
            if (k is base)
                return vals[i];
            i = (i + 1) & mask;
        }
    }

    void remove(void* base) nothrow @nogc
    {
        if (len == 0)
            return;
        size_t mask = cap - 1;
        size_t i = hash(base) & mask;
        for (;;)
        {
            auto k = keys[i];
            if (k is null)
                return;
            if (k is base)
            {
                keys[i] = tombstone();
                vals[i] = null;
                len--;
                return;
            }
            i = (i + 1) & mask;
        }
    }

    /// Drop every entry but keep the allocation, for repeated rebuilds.
    void clearEntries() nothrow @nogc
    {
        if (keys)
            memset(keys, 0, cap * (void*).sizeof);
        if (vals)
            memset(vals, 0, cap * (Chunk*).sizeof);
        len = 0;
        occupied = 0;
    }

    void destroy() nothrow @nogc
    {
        cstdlib.free(keys);
        cstdlib.free(vals);
        keys = null;
        vals = null;
        cap = len = occupied = 0;
    }
}

// ---------------------------------------------------------------------------
// mark worklist
// ---------------------------------------------------------------------------

private struct MarkItem
{
    void* base;
    size_t size;
}

private struct RangeSnap
{
    void* pbot;
    void* ptop;
}

// ---------------------------------------------------------------------------
// per-thread heap
// ---------------------------------------------------------------------------

private struct ThreadHeap
{
    ChunkMap map;
    Chunk* allChunks;
    Chunk*[numClasses] partial;

    size_t usedBytes;      /// bytes in allocated slots
    size_t reservedBytes;  /// bytes held in chunks, allocated or not
    size_t allocatedTotal; /// bytes allocated on this thread since start
    size_t collectThreshold = collectThresholdInit;
    size_t numCollections;

    // Explicit mark worklist. The previous rescan-until-stable fixpoint walked
    // the whole heap once per pointer-graph level; a worklist scans each live
    // block exactly once.
    MarkItem* markStack;
    size_t markLen;
    size_t markCap;

    // Scratch buffers so the mark phase can snapshot the global root/range
    // tables and release rootsLock before marking, instead of making every
    // other thread spin for the whole collection.
    void** rootSnap;
    size_t rootSnapCap;
    RangeSnap* rangeSnap;
    size_t rangeSnapCap;
    RangeSnap* stackSnap;
    size_t stackSnapCap;

    bool collecting;
    bool finalizing;
    /// True while marking the closure reachable from global roots.
    bool markAsShared;
    /// Set on the single heap that adopts dead threads' arenas. Never collected.
    bool isOrphan;

    static ThreadHeap* create() nothrow @nogc
    {
        auto h = cast(ThreadHeap*) cstdlib.calloc(1, ThreadHeap.sizeof);
        if (!h)
            onOutOfMemoryError();
        h.collectThreshold = collectThresholdInit;
        return h;
    }

    void destroy() nothrow @nogc
    {
        // The rt.tlsgc handle is owned by druntime, not by us; destroying it
        // here would double-free the thread's TLS ranges.
        map.destroy();
        cstdlib.free(markStack);
        cstdlib.free(rootSnap);
        cstdlib.free(rangeSnap);
        cstdlib.free(stackSnap);
        markStack = null;
        rootSnap = null;
        rangeSnap = null;
        stackSnap = null;
    }

    // -- chunk lifecycle ----------------------------------------------------

    Chunk* newSmallChunk(uint cls) nothrow @nogc
    {
        immutable uint slotSize = sizeClasses[cls];

        // Bigger classes get a run of units, so a chunk still holds a useful
        // number of slots instead of one slot and a lot of slack.
        size_t units = (slotSize * minSlotsPerChunk + chunkSize - 1) / chunkSize;
        if (units < 1)
            units = 1;
        immutable size_t bytes = units * chunkSize;

        auto raw = chunkAlloc(bytes);
        if (!raw)
            onOutOfMemoryError();
        memset(raw, 0, Chunk.sizeof);

        auto c = cast(Chunk*) raw;
        immutable size_t bitsOff = alignUp(Chunk.sizeof, size_t.sizeof);

        // Per slot: SlotMeta, one attribute byte, and three bits of state.
        // Solve for the count that fits, then lay the regions out in order.
        size_t count = (bytes - bitsOff) * 8 / (slotSize * 8 + SlotMeta.sizeof * 8 + 8 + 3);
        size_t dataOff, metaOff, attrOff, markOff, sharedOff;
        for (;;)
        {
            immutable size_t bw = bitWords(count) * size_t.sizeof;
            markOff = bitsOff + bw;
            sharedOff = markOff + bw;
            attrOff = sharedOff + bw;
            metaOff = alignUp(attrOff + count, size_t.sizeof);
            dataOff = alignUp(metaOff + count * SlotMeta.sizeof, payloadAlign);
            if (count == 0 || dataOff + count * slotSize <= bytes)
                break;
            count--;
        }
        assert(count > 0, "tgc: chunk too small for its size class");

        c.heap = &this;
        c.allocBits = cast(size_t*)(cast(ubyte*) raw + bitsOff);
        c.markBits = cast(size_t*)(cast(ubyte*) raw + markOff);
        c.sharedBits = cast(size_t*)(cast(ubyte*) raw + sharedOff);
        c.attrs = cast(ubyte*)(cast(ubyte*) raw + attrOff);
        c.meta = cast(SlotMeta*)(cast(ubyte*) raw + metaOff);
        c.data = cast(void*)(cast(ubyte*) raw + dataOff);
        c.slotSize = slotSize;
        c.slotCount = cast(uint) count;
        c.freeCount = cast(uint) count;
        c.cls = cls;
        c.runChunks = units;

        // One wipe covers the bitvectors, the attribute bytes and the metadata.
        memset(cast(ubyte*) raw + bitsOff, 0, dataOff - bitsOff);

        // Thread the free list through the slots themselves.
        c.freeHead = null;
        foreach_reverse (i; 0 .. count)
        {
            auto slot = c.slotAt(i);
            *cast(void**) slot = c.freeHead;
            c.freeHead = slot;
        }

        foreach (i; 0 .. units)
            map.put(cast(void*)(cast(ubyte*) raw + i * chunkSize), c);
        linkAll(c);
        linkPartial(c);
        reservedBytes += bytes;
        return c;
    }

    Chunk* newLargeChunk(size_t size) nothrow @nogc
    {
        // A large chunk holds exactly one slot, so one word of each bitvector
        // and one attribute byte suffice.
        immutable size_t bitsOff = alignUp(Chunk.sizeof, size_t.sizeof);
        immutable size_t markOff = bitsOff + size_t.sizeof;
        immutable size_t sharedOff = markOff + size_t.sizeof;
        immutable size_t attrOff = sharedOff + size_t.sizeof;
        immutable size_t metaOff = alignUp(attrOff + 1, size_t.sizeof);
        immutable size_t dataOff = alignUp(metaOff + SlotMeta.sizeof, payloadAlign);

        size_t bytes = dataOff + size;
        if (bytes < size) // overflow
            onOutOfMemoryError();
        size_t runChunks = alignUp(bytes, chunkSize) / chunkSize;

        auto raw = chunkAlloc(runChunks * chunkSize);
        if (!raw)
            onOutOfMemoryError();
        memset(raw, 0, dataOff);

        auto c = cast(Chunk*) raw;
        c.heap = &this;
        c.allocBits = cast(size_t*)(cast(ubyte*) raw + bitsOff);
        c.markBits = cast(size_t*)(cast(ubyte*) raw + markOff);
        c.sharedBits = cast(size_t*)(cast(ubyte*) raw + sharedOff);
        c.attrs = cast(ubyte*)(cast(ubyte*) raw + attrOff);
        c.meta = cast(SlotMeta*)(cast(ubyte*) raw + metaOff);
        c.data = cast(void*)(cast(ubyte*) raw + dataOff);
        c.slotSize = 0;
        c.slotCount = 1;
        c.freeCount = 0;
        c.cls = uint.max;
        c.runChunks = runChunks;
        // The request, not the whole rounded-up run. Reporting the run made a
        // 9000-byte allocation look like 65408 bytes, and every collection
        // scanned -- and every allocation zeroed -- all of it.
        c.largeSize = alignUp(size, payloadAlign);

        // Every chunk base in the run resolves back to the head, so an
        // interior pointer anywhere in a large object is one probe away.
        foreach (i; 0 .. runChunks)
            map.put(cast(void*)(cast(ubyte*) raw + i * chunkSize), c);

        linkAll(c);
        reservedBytes += runChunks * chunkSize;
        return c;
    }

    void releaseChunk(Chunk* c) nothrow @nogc
    {
        unlinkPartial(c);
        unlinkAll(c);
        auto raw = cast(ubyte*) c;
        foreach (i; 0 .. c.runChunks)
            map.remove(cast(void*)(raw + i * chunkSize));
        reservedBytes -= c.runChunks * chunkSize;
        chunkFree(raw);
    }

    void linkAll(Chunk* c) nothrow @nogc
    {
        c.prevAll = null;
        c.nextAll = allChunks;
        if (allChunks)
            allChunks.prevAll = c;
        allChunks = c;
    }

    void unlinkAll(Chunk* c) nothrow @nogc
    {
        if (c.prevAll)
            c.prevAll.nextAll = c.nextAll;
        else
            allChunks = c.nextAll;
        if (c.nextAll)
            c.nextAll.prevAll = c.prevAll;
        c.nextAll = c.prevAll = null;
    }

    void linkPartial(Chunk* c) nothrow @nogc
    {
        if (c.inPartial || c.isLarge())
            return;
        c.prevPartial = null;
        c.nextPartial = partial[c.cls];
        if (partial[c.cls])
            partial[c.cls].prevPartial = c;
        partial[c.cls] = c;
        c.inPartial = true;
    }

    void unlinkPartial(Chunk* c) nothrow @nogc
    {
        if (!c.inPartial)
            return;
        if (c.prevPartial)
            c.prevPartial.nextPartial = c.nextPartial;
        else
            partial[c.cls] = c.nextPartial;
        if (c.nextPartial)
            c.nextPartial.prevPartial = c.prevPartial;
        c.nextPartial = c.prevPartial = null;
        c.inPartial = false;
    }

    // -- block lookup -------------------------------------------------------

    /**
     * Resolve a candidate pointer to the block containing it.
     *
     * `acceptEnd` additionally accepts a one-past-the-end pointer, which the
     * mark phase must do because D slices routinely materialise
     * `ptr + length`; exact lookups (free/query) must not, or
     * `GC.free(arr.ptr + arr.length)` would destroy an unrelated neighbour.
     */
    BlkRef lookup(void* p, bool acceptEnd) nothrow @nogc
    {
        if (!p)
            return BlkRef.init;

        auto c = map.get(cast(void*)(cast(size_t) p & chunkMask));
        if (!c)
        {
            if (!acceptEnd)
                return BlkRef.init;
            // A one-past-the-end pointer can land on the first byte of the
            // following chunk, which may not be ours.
            c = map.get(cast(void*)(((cast(size_t) p) - 1) & chunkMask));
            if (!c)
                return BlkRef.init;
        }

        if (c.isLarge())
        {
            auto base = c.data;
            auto end = cast(void*)(cast(ubyte*) base + c.largeSize);
            if (p < base)
                return BlkRef.init;
            if (acceptEnd ? (p > end) : (p >= end))
                return BlkRef.init;
            if (!c.isAllocated(0))
                return BlkRef.init;
            return BlkRef(c, 0);
        }

        if (p < c.data)
            return BlkRef.init;
        size_t off = cast(ubyte*) p - cast(ubyte*) c.data;
        size_t idx = off / c.slotSize;

        if (idx >= c.slotCount)
        {
            if (!acceptEnd || idx != c.slotCount || off % c.slotSize != 0)
                return BlkRef.init;
            idx = c.slotCount - 1; // exactly one past the final slot
        }
        else if (acceptEnd && off % c.slotSize == 0 && idx > 0 && !c.isAllocated(idx))
        {
            // Slot boundary: also consider it one-past-the-end of the
            // preceding slot before giving up.
            if (c.isAllocated(idx - 1))
                idx--;
        }

        if (!c.isAllocated(idx))
            return BlkRef.init;
        return BlkRef(c, idx);
    }

    // -- allocation ---------------------------------------------------------

    BlkRef allocSlot(size_t size) nothrow @nogc
    {
        // Allocate black while a collection is in flight. A finalizer running
        // during the sweep may allocate, and it can be handed a slot from the
        // very chunk being swept — at an index the sweep has not reached yet.
        // Without the mark bit the sweep would see it allocated-and-unmarked
        // and immediately free the object that was just handed out.
        immutable bool birthMarked = collecting || finalizing;

        if (size > maxSmall)
        {
            auto c = newLargeChunk(size);
            c.setAllocated(0);
            if (birthMarked)
                c.setMarked(0);
            usedBytes += c.largeSize;
            return BlkRef(c, 0);
        }

        immutable uint cls = classOf(size ? size : 1);
        auto c = partial[cls];
        if (!c)
            c = newSmallChunk(cls);

        auto slot = c.freeHead;
        assert(slot !is null, "tgc: partial chunk has no free slot");
        c.freeHead = *cast(void**) slot;
        c.freeCount--;
        if (c.freeCount == 0)
            unlinkPartial(c);

        size_t idx = (cast(ubyte*) slot - cast(ubyte*) c.data) / c.slotSize;
        c.setAllocated(idx);
        if (birthMarked)
            c.setMarked(idx);
        usedBytes += c.slotSize;
        return BlkRef(c, idx);
    }

    void freeSlot(BlkRef b) nothrow @nogc
    {
        auto c = b.chunk;
        c.meta[b.idx] = SlotMeta.init;
        c.clearAllocated(b.idx);
        c.clearShared(b.idx);
        c.setAttrOf(b.idx, 0);

        if (c.isLarge())
        {
            usedBytes -= c.largeSize;
            releaseChunk(c);
            return;
        }

        auto slot = c.slotAt(b.idx);
        *cast(void**) slot = c.freeHead;
        c.freeHead = slot;
        c.freeCount++;
        usedBytes -= c.slotSize;
        linkPartial(c);
    }

    void freeSlotFinalize(BlkRef b) nothrow @nogc
    {
        immutable uint attr = b.chunk.attrOf(b.idx);
        if (attr & (BlkAttr.FINALIZE | BlkAttr.STRUCTFINAL))
            finalizeBlock(b.payload(), b.capacity(), attr, b.meta().ti);
        freeSlot(b);
    }

    // -- mark worklist ------------------------------------------------------

    void pushMark(void* base, size_t size) nothrow @nogc
    {
        if (markLen == markCap)
        {
            size_t ncap = markCap ? markCap * 2 : 256;
            auto np = cast(MarkItem*) cstdlib.realloc(markStack, ncap * MarkItem.sizeof);
            if (!np)
                onOutOfMemoryError();
            markStack = np;
            markCap = ncap;
        }
        markStack[markLen++] = MarkItem(base, size);
    }
}

// TLS pointer to the calling thread's heap
private static ThreadHeap* tlsHeap;

private __gshared ThreadHeap*[] allHeaps;
private __gshared size_t allHeapsLen;
private __gshared size_t allHeapsCap;
private __gshared SpinLock heapsLock;

private void registerHeap(ThreadHeap* h) nothrow @nogc
{
    heapsLock.lock();
    if (allHeapsLen == allHeapsCap)
    {
        size_t ncap = allHeapsCap ? allHeapsCap * 2 : 8;
        auto np = cast(ThreadHeap**) cstdlib.realloc(allHeaps.ptr, ncap * (ThreadHeap*).sizeof);
        if (!np)
        {
            heapsLock.unlock();
            onOutOfMemoryError();
        }
        allHeaps = np[0 .. ncap];
        allHeapsCap = ncap;
    }
    allHeaps[allHeapsLen++] = h;
    heapsLock.unlock();
}

private void unregisterHeap(ThreadHeap* h) nothrow @nogc
{
    heapsLock.lock();
    foreach (i; 0 .. allHeapsLen)
    {
        if (allHeaps[i] is h)
        {
            allHeaps[i] = allHeaps[allHeapsLen - 1];
            allHeapsLen--;
            break;
        }
    }
    heapsLock.unlock();
}

/**
 * Heap that adopts the arenas of threads that have exited.
 *
 * A dying thread's memory cannot simply be finalized and released. `Thread.join`
 * propagates the child's `Throwable` to the parent *after* the child's cleanup
 * has run, so releasing here hands the parent a destructed object in freed
 * memory — reachable from ordinary code, no cast or unsafe construct involved.
 * The same applies to anything else the child published before exiting.
 *
 * Phase 0 of the fix (see CROSS-THREAD.md): keep the memory. Chunks move to
 * this heap, which no thread owns and no collection ever sweeps, so the blocks
 * stay valid and unfinalized. The cost is that a dead thread's memory is not
 * reclaimed until the process exits; a cooperative global collection (Phase 2)
 * is what makes it reclaimable.
 */
private __gshared ThreadHeap* orphanHeap;
private __gshared SpinLock orphanLock;

/// Bytes held in arenas adopted from exited threads. Drives the global-collection trigger.
private shared size_t orphanBytes;

private void adoptOrphanChunks(ThreadHeap* dying) nothrow @nogc
{
    if (dying.allChunks is null)
        return;

    orphanLock.lock();

    if (orphanHeap is null)
    {
        orphanHeap = ThreadHeap.create();
        orphanHeap.isOrphan = true;
        registerHeap(orphanHeap);
    }

    auto c = dying.allChunks;
    while (c)
    {
        auto next = c.nextAll;
        auto raw = cast(ubyte*) c;

        foreach (i; 0 .. c.runChunks)
            dying.map.remove(cast(void*)(raw + i * chunkSize));
        dying.unlinkPartial(c);
        dying.unlinkAll(c);

        c.heap = orphanHeap;
        // Never hand orphaned slots back out: the adopting heap is not owned by
        // any thread, so nothing would ever scan a new allocation's roots.
        c.inPartial = false;
        c.nextPartial = null;
        c.prevPartial = null;

        orphanHeap.linkAll(c);
        foreach (i; 0 .. c.runChunks)
            orphanHeap.map.put(cast(void*)(raw + i * chunkSize), c);

        orphanHeap.reservedBytes += c.runChunks * chunkSize;
        atomicOp!"+="(orphanBytes, c.runChunks * chunkSize);
        orphanHeap.usedBytes += c.isLarge()
            ? c.largeSize
            : (c.slotCount - c.freeCount) * c.slotSize;

        c = next;
    }

    dying.allChunks = null;
    orphanLock.unlock();
}

// ---------------------------------------------------------------------------
// cooperative global collection
// ---------------------------------------------------------------------------

/*
 * A thread-local collection can never reclaim two things: arenas adopted from
 * exited threads, and blocks promoted because they escaped through a global.
 * Neither can be proven dead without knowing what every thread holds, so both
 * accumulate for the life of the process.
 *
 * The global collection is the answer, and it is the one operation in tgc that
 * does stop the world. That is the deal Milewski's original sketch of the
 * scheme described -- per-thread heaps collect independently, and "only
 * occasional collection of the shared heap would require the cooperation of all
 * threads". It is rare and triggered by retained bytes, not by allocation rate.
 *
 * Detached @nogc threads are still never paused: thread_suspendAll only
 * suspends threads registered with the runtime.
 */

// Touched only by the thread that won the globalPending CAS, so no further
// synchronisation is needed on these.
private __gshared ChunkMap globalMap;
private __gshared MarkItem* globalMarkStack;
private __gshared size_t globalMarkLen;
private __gshared size_t globalMarkCap;

private shared bool globalPending;
private shared int activeLocalCollections;

/// Retained bytes at which a global collection is triggered. 0 disables it.
private shared size_t globalThreshold = 64 * 1024 * 1024;

private void pushGlobalMark(void* base, size_t size) nothrow @nogc
{
    if (globalMarkLen == globalMarkCap)
    {
        size_t ncap = globalMarkCap ? globalMarkCap * 2 : 1024;
        auto np = cast(MarkItem*) cstdlib.realloc(globalMarkStack, ncap * MarkItem.sizeof);
        if (!np)
            onOutOfMemoryError();
        globalMarkStack = np;
        globalMarkCap = ncap;
    }
    globalMarkStack[globalMarkLen++] = MarkItem(base, size);
}

@conservativeScan
private void markPtrGlobal(void* p) nothrow
{
    if (!p)
        return;
    auto c = globalMap.get(cast(void*)(cast(size_t) p & chunkMask));
    if (!c)
    {
        c = globalMap.get(cast(void*)(((cast(size_t) p) - 1) & chunkMask));
        if (!c)
            return;
    }

    size_t idx;
    if (c.isLarge())
    {
        auto base = c.data;
        auto end = cast(void*)(cast(ubyte*) base + c.largeSize);
        if (p < base || p > end)
            return;
        idx = 0;
    }
    else
    {
        if (p < c.data)
            return;
        size_t off = cast(ubyte*) p - cast(ubyte*) c.data;
        idx = off / c.slotSize;
        if (idx >= c.slotCount)
        {
            if (idx != c.slotCount || off % c.slotSize != 0)
                return;
            idx = c.slotCount - 1;
        }
        else if (off % c.slotSize == 0 && idx > 0
                 && !c.isAllocated(idx) && c.isAllocated(idx - 1))
        {
            idx--;
        }
    }

    if (!c.isAllocated(idx) || c.isMarked(idx))
        return;
    c.setMarked(idx);
    if (!(c.attrOf(idx) & BlkAttr.NO_SCAN))
        pushGlobalMark(c.slotAt(idx), c.capacity());
}

@conservativeScan
private void markRangeGlobal(void* pbot, void* ptop) nothrow
{
    if (!pbot || !ptop || pbot >= ptop)
        return;
    auto addr = (cast(size_t) pbot + (void*).sizeof - 1) & ~((void*).sizeof - 1);
    auto p = cast(void**) addr;
    auto e = cast(void**) ptop;
    for (; p + 1 <= e; ++p)
        markPtrGlobal(*p);
}

@conservativeScan
private void drainGlobalMark() nothrow
{
    while (globalMarkLen)
    {
        auto item = globalMarkStack[--globalMarkLen];
        markRangeGlobal(item.base, cast(void*)(cast(ubyte*) item.base + item.size));
    }
}

/**
 * Reclaim everything a thread-local collection cannot: adopted arenas and
 * promoted blocks.
 *
 * Returns false if another global collection is already running, in which case
 * this one is simply skipped.
 */
private bool collectGlobal(ThreadGC gc) nothrow
{
    import core.atomic : cas;

    // A collection already running on this thread has its own entry in
    // activeLocalCollections, so proceeding here would wait for ourselves. This
    // happens for real: a finalizer running during the sweep may allocate,
    // which re-enters alloc and reaches the trigger below.
    if (tlsHeap !is null && (tlsHeap.collecting || tlsHeap.finalizing))
        return false;
    if (ThreadBase.getThis() is null)
        return false;

    // One at a time.
    if (!cas(&globalPending, false, true))
        return false;
    scope (exit)
        atomicStore(globalPending, false);

    // Wait for in-flight thread-local collections to finish. A local collection
    // owns its heap's mark bits, so suspending one mid-mark and then rewriting
    // those bits here would corrupt both.
    while (atomicLoad(activeLocalCollections) != 0)
        thread_yield();

    // Taken before suspending, so no thread can be suspended midway through
    // mutating the heap registry. Never the other way round.
    heapsLock.lock();
    scope (exit)
        heapsLock.unlock();

    // The world is stopped for MARKING ONLY. Sweeping here would be unsafe:
    // running a finalizer with threads suspended can block on a lock one of
    // them holds, and freeing into a live thread's heap races that thread the
    // moment it resumes. druntime's own collector resumes before sweeping for
    // the same reason.
    {
        thread_suspendAll();
        scope (exit)
            thread_resumeAll();

        // Index every chunk of every heap, including the orphan heap, so a
        // candidate pointer costs one probe instead of one per heap.
        globalMap.clearEntries();
        globalMarkLen = 0;
        foreach (i; 0 .. allHeapsLen)
        {
            auto h = allHeaps[i];
            for (auto c = h.allChunks; c; c = c.nextAll)
            {
                auto raw = cast(ubyte*) c;
                foreach (k; 0 .. c.runChunks)
                    globalMap.put(cast(void*)(raw + k * chunkSize), c);
                c.clearMarks();
            }
        }

        // Every thread's stack, fibers, saved registers and TLS. This is the
        // traversal the stop-the-world collector performs, and it is only
        // valid with the world stopped.
        thread_scanAll((void* pbeg, void* pend) nothrow { markRangeGlobal(pbeg, pend); });
        drainGlobalMark();

        gc.markGlobalRootsAndRanges();
        drainGlobalMark();

        // Demote promoted blocks the global mark proved unreachable. Only flag
        // manipulation happens here -- no allocation, no finalizers, no frees
        // -- so it is safe with the world stopped. Their owning threads then
        // reclaim them on their own next local collection, on their own
        // thread, running their finalizers normally.
        foreach (i; 0 .. allHeapsLen)
        {
            auto h = allHeaps[i];
            if (h.isOrphan)
                continue;
            for (auto c = h.allChunks; c; c = c.nextAll)
                for (size_t idx = c.nextReclaimableIgnoringShared(0); idx < c.slotCount;
                     idx = c.nextReclaimableIgnoringShared(idx + 1))
                    c.clearShared(idx);
        }
    }

    // World resumed. The orphan heap is owned by no thread, so it can be swept
    // now, with finalizers running normally. Its mark bits are untouched by
    // anyone else in the meantime.
    sweepOrphanHeap();

    orphanBytes = orphanHeap is null ? 0 : orphanHeap.reservedBytes;
    return true;
}

/**
 * Reclaim dead blocks in arenas adopted from exited threads.
 *
 * Runs after the world has resumed, using the mark bits the global collection
 * computed. Nothing else touches the orphan heap: no thread owns it, a second
 * global collection is excluded by `globalPending`, and adoption takes
 * `orphanLock`.
 */
private void sweepOrphanHeap() nothrow
{
    orphanLock.lock();
    scope (exit)
        orphanLock.unlock();

    auto h = orphanHeap;
    if (h is null)
        return;

    h.finalizing = true;
    auto c = h.allChunks;
    while (c)
    {
        auto nextChunk = c.nextAll;
        immutable bool large = c.isLarge();
        immutable uint count = c.slotCount;
        bool released = false;

        for (size_t idx = c.nextReclaimableIgnoringShared(0); idx < count;
             idx = c.nextReclaimableIgnoringShared(idx + 1))
        {
            h.freeSlotFinalize(BlkRef(c, idx));
            if (large)
            {
                released = true;
                break;
            }
        }

        if (!released && !large && c.freeCount == c.slotCount)
            h.releaseChunk(c);
        c = nextChunk;
    }
    h.finalizing = false;

    atomicStore(orphanBytes, h.reservedBytes);
}

private ThreadHeap* currentHeap() nothrow @nogc
{
    if (tlsHeap)
        return tlsHeap;
    tlsHeap = ThreadHeap.create();
    registerHeap(tlsHeap);
    auto t = ThreadBase.getThis();
    if (t !is null)
        t.tlsGCData() = tlsHeap;
    return tlsHeap;
}

// register GC in C constructor
private pragma(crt_constructor) void gc_tgc_ctor()
{
    heapsLock = SpinLock(SpinLock.Contention.brief);
    orphanLock = SpinLock(SpinLock.Contention.brief);
    _d_register_tgc_gc();
}

extern (C) void _d_register_tgc_gc()
{
    import core.gc.registry;

    registerGCFactory("tgc", &initialize, &threadInitHook);
}

private void threadInitHook(ThreadBase base) nothrow @nogc
{
    // Called before the thread is fully registered; ensure a heap exists.
    base.tlsGCData() = currentHeap();
}

private GC initialize()
{
    import core.lifetime : emplace;

    auto gc = cast(ThreadGC) cstdlib.malloc(__traits(classInstanceSize, ThreadGC));
    if (!gc)
        onOutOfMemoryError();

    return emplace(gc);
}

/**
 * Thread-local GC implementation.
 *
 * Also known informally as a "realtime GC" because collection does not
 * globally stop-the-world; the name registered with the runtime is `tgc`.
 */
class ThreadGC : GC
{
    Array!Root roots;
    Array!Range ranges;
    SpinLock rootsLock;

    // Touched by every attached thread, so all must be atomic. `disabled` is a
    // nesting counter to match core.memory.GC.disable/enable semantics.
    shared int disabled;
    shared size_t profileCollections;
    shared ulong profilePauseTotalNs;
    shared ulong profilePauseMaxNs;

    this()
    {
        rootsLock = SpinLock(SpinLock.Contention.brief);
        // Ensure the initializing thread has a heap.
        cast(void) currentHeap();
    }

    ~this()
    {
    }

    void enable()
    {
        atomicOp!"-="(disabled, 1);
    }

    void disable()
    {
        atomicOp!"+="(disabled, 1);
    }

    void collect() nothrow
    {
        // An explicit GC.collect() must run even while disabled; disable()
        // suppresses only allocation-triggered collections.
        collectHeap(currentHeap(), Trigger.explicit);
    }

    /// Run a cooperative global collection now. Returns false if one was
    /// already in progress.
    bool collectGlobalNow() nothrow
    {
        return collectGlobal(this);
    }

    void minimize() nothrow
    {
        auto heap = currentHeap();

        // Hand back every chunk that holds no live slot.
        auto c = heap.allChunks;
        while (c)
        {
            auto next = c.nextAll;
            if (!c.isLarge() && c.freeCount == c.slotCount)
                heap.releaseChunk(c);
            c = next;
        }
    }

    uint getAttr(void* p) nothrow
    {
        auto b = queryBlock(p);
        return b.valid() ? b.attr() : 0;
    }

    uint setAttr(void* p, uint mask) nothrow
    {
        auto b = queryBlock(p);
        if (!b.valid())
            return 0;
        b.setAttr(b.attr() | mask);
        return b.attr();
    }

    uint clrAttr(void* p, uint mask) nothrow
    {
        auto b = queryBlock(p);
        if (!b.valid())
            return 0;
        b.setAttr(b.attr() & ~mask);
        return b.attr();
    }

    void* malloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        return alloc(size, bits, false, ti).payload();
    }

    BlkInfo qalloc(size_t size, uint bits, const scope TypeInfo ti) nothrow
    {
        auto b = alloc(size, bits, false, cast(const TypeInfo) ti);
        BlkInfo retval;
        retval.base = b.payload();
        retval.size = b.capacity();
        retval.attr = bits;
        return retval;
    }

    void* calloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        return alloc(size, bits, true, ti).payload();
    }

    void* realloc(void* p, size_t size, uint bits, const TypeInfo ti) nothrow
    {
        if (!p)
            return alloc(size, bits, false, ti).payload();
        if (!size)
        {
            free(p);
            return null;
        }

        auto b = queryBlock(p);
        if (!b.valid())
        {
            // Unknown pointer — allocate fresh
            return alloc(size, bits, false, ti).payload();
        }

        auto m = b.meta();
        auto heap = b.chunk.heap;

        if (heap !is currentHeap())
        {
            // Cannot realloc a foreign block in place; copy into the local heap.
            auto nb = alloc(size, bits ? bits : b.attr(), false, ti ? ti : m.ti);
            auto n = size < b.capacity() ? size : b.capacity();
            memcpy(nb.payload(), p, n);
            free(p);
            return nb.payload();
        }

        if (size <= b.capacity())
        {
            // Capacity is the slot size, so a shrink is a no-op. Rewriting a
            // stored size here would desynchronise heap.usedBytes.
            if (bits)
                b.setAttr(bits);
            if (ti)
                m.ti = cast(TypeInfo) ti;
            return p;
        }

        auto nb = alloc(size, bits ? bits : b.attr(), false, ti ? ti : m.ti);
        memcpy(nb.payload(), p, b.capacity());
        heap.freeSlot(b);
        return nb.payload();
    }

    size_t extend(void* p, size_t minsize, size_t maxsize, const TypeInfo ti) nothrow
    {
        // `minsize` is how many *additional* bytes the caller needs, and a
        // non-zero return means the block really was enlarged. A slot has a
        // fixed size and cannot grow, so the only correct answer is 0.
        //
        // Returning the capacity when it merely looked big enough told the
        // runtime an extension had succeeded, and it then wrote past the end of
        // the slot into its neighbour -- corrupting the free-list pointer
        // threaded through free slots. In-place growth for arrays goes through
        // expandArrayUsed, which checks against the real capacity.
        return 0;
    }

    size_t reserve(size_t size) nothrow
    {
        return 0;
    }

    void free(void* p) nothrow @nogc
    {
        if (!p)
            return;
        auto b = queryBlock(p);
        if (!b.valid())
            return;
        auto owner = b.chunk.heap;
        if (owner.isOrphan)
            return; // adopted from a dead thread; only a global collection frees it
        // queryBlock only ever resolves blocks in this thread's heap or the
        // orphan heap, so the owner is always this thread here.
        owner.freeSlot(b);
    }

    void* addrOf(void* p) nothrow @nogc
    {
        auto b = queryBlock(p);
        return b.valid() ? b.payload() : null;
    }

    size_t sizeOf(void* p) nothrow @nogc
    {
        auto b = queryBlock(p);
        return b.valid() ? b.capacity() : 0;
    }

    BlkInfo query(void* p) nothrow
    {
        auto b = queryBlock(p);
        if (!b.valid())
            return BlkInfo.init;
        BlkInfo info;
        info.base = b.payload();
        info.size = b.capacity();
        info.attr = b.attr();
        return info;
    }

    core.memory.GC.Stats stats() @trusted nothrow
    {
        core.memory.GC.Stats s;
        auto h = currentHeap();
        s.usedSize = h.usedBytes;
        s.freeSize = h.reservedBytes >= h.usedBytes ? h.reservedBytes - h.usedBytes : 0;
        s.allocatedInCurrentThread = h.allocatedTotal;
        return s;
    }

    core.memory.GC.ProfileStats profileStats() @trusted nothrow
    {
        import core.time : dur;

        core.memory.GC.ProfileStats s;
        s.numCollections = atomicLoad(profileCollections);
        s.totalPauseTime = dur!"nsecs"(cast(long) atomicLoad(profilePauseTotalNs));
        s.maxPauseTime = dur!"nsecs"(cast(long) atomicLoad(profilePauseMaxNs));
        // A tgc collection is entirely a pause on its own thread; there is no
        // concurrent phase, so mark time and pause time coincide.
        s.totalCollectionTime = s.totalPauseTime;
        return s;
    }

    void addRoot(void* p) nothrow @nogc
    {
        rootsLock.lock();
        roots.insertBack(Root(p));
        rootsLock.unlock();
    }

    void removeRoot(void* p) nothrow @nogc
    {
        rootsLock.lock();
        foreach (ref r; roots)
        {
            if (r is p)
            {
                r = roots.back;
                roots.popBack();
                break;
            }
        }
        // Removing a root that was never added is harmless; the previous
        // assert(false) here halted the process in release builds.
        rootsLock.unlock();
    }

    @property RootIterator rootIter() return @nogc
    {
        return &rootsApply;
    }

    private int rootsApply(scope int delegate(ref Root) nothrow dg)
    {
        rootsLock.lock();
        foreach (ref r; roots)
        {
            if (auto result = dg(r))
            {
                rootsLock.unlock();
                return result;
            }
        }
        rootsLock.unlock();
        return 0;
    }

    void addRange(void* p, size_t sz, const TypeInfo ti = null) nothrow @nogc
    {
        rootsLock.lock();
        ranges.insertBack(Range(p, p + sz, cast() ti));
        rootsLock.unlock();
    }

    void removeRange(void* p) nothrow @nogc
    {
        rootsLock.lock();
        foreach (ref r; ranges)
        {
            if (r.pbot is p)
            {
                r = ranges.back;
                ranges.popBack();
                break;
            }
        }
        rootsLock.unlock();
    }

    @property RangeIterator rangeIter() return @nogc
    {
        return &rangesApply;
    }

    private int rangesApply(scope int delegate(ref Range) nothrow dg)
    {
        rootsLock.lock();
        foreach (ref r; ranges)
        {
            if (auto result = dg(r))
            {
                rootsLock.unlock();
                return result;
            }
        }
        rootsLock.unlock();
        return 0;
    }

    void runFinalizers(const scope void[] segment) nothrow
    {
        auto heap = tlsHeap;
        if (!heap)
            return;

        // Finalize blocks whose code lives in the segment being unloaded, so
        // destructors do not dangle into freed code.
        heap.finalizing = true;
        auto c = heap.allChunks;
        while (c)
        {
            auto nextChunk = c.nextAll;
            // As in the sweep: releasing a large chunk invalidates `c`.
            immutable bool large = c.isLarge();
            immutable uint count = c.slotCount;

            foreach (idx; 0 .. count)
            {
                if (!c.isAllocated(idx))
                    continue;
                if (!(c.attrOf(idx) & (BlkAttr.FINALIZE | BlkAttr.STRUCTFINAL)))
                    continue;
                // The vtable pointer of a class instance points into the
                // module's code/data; if it falls inside the segment, the
                // finalizer is about to disappear.
                auto p = c.slotAt(idx);
                auto vtbl = *cast(void**) p;
                if (inSegment(segment, vtbl))
                {
                    heap.freeSlotFinalize(BlkRef(c, idx));
                    if (large)
                        break;
                }
            }
            c = nextChunk;
        }
        heap.finalizing = false;
    }

    bool inFinalizer() nothrow
    {
        auto h = tlsHeap;
        return h !is null && h.finalizing;
    }

    ulong allocatedInCurrentThread() nothrow
    {
        return currentHeap().allocatedTotal;
    }

    // -- array API ----------------------------------------------------------
    //
    // Every one of these used to return a failure constant, which forced the
    // runtime to reallocate and copy on *every* `arr ~= x`, making idiomatic
    // append O(n^2). Because heaps are thread-private, the `atomic` flag needs
    // no special handling: no other thread may touch these blocks.

    void[] getArrayUsed(void* ptr, bool atomic = false) nothrow
    {
        auto b = queryBlock(ptr);
        if (!b.valid())
            return null;
        if (!(b.attr() & BlkAttr.APPENDABLE))
            return null;
        return b.payload()[0 .. b.meta().usedSize];
    }

    bool expandArrayUsed(void[] slice, size_t newUsed, bool atomic = false) nothrow @safe
    {
        return (() @trusted {
            auto b = queryBlock(slice.ptr);
            if (!b.valid())
                return false;
            auto m = b.meta();
            if (!(b.attr() & BlkAttr.APPENDABLE))
                return false;

            size_t offset = cast(ubyte*) slice.ptr - cast(ubyte*) b.payload();
            // The slice must currently end exactly at the used size, otherwise
            // expanding would silently claim someone else's data.
            if (offset + slice.length != m.usedSize)
                return false;
            if (offset + newUsed > b.capacity())
                return false;

            m.usedSize = offset + newUsed;
            return true;
        })();
    }

    size_t reserveArrayCapacity(void[] slice, size_t request, bool atomic = false) nothrow @safe
    {
        return (() @trusted {
            auto b = queryBlock(slice.ptr);
            if (!b.valid())
                return cast(size_t) 0;
            auto m = b.meta();
            if (!(b.attr() & BlkAttr.APPENDABLE))
                return cast(size_t) 0;

            size_t offset = cast(ubyte*) slice.ptr - cast(ubyte*) b.payload();
            if (offset + slice.length != m.usedSize)
                return cast(size_t) 0;

            size_t available = b.capacity() - offset;
            // A slot cannot grow, but it is usually already larger than asked
            // for: size classes and chunk rounding leave real slack.
            return request <= available ? available : size_t(0);
        })();
    }

    bool shrinkArrayUsed(void[] slice, size_t existingUsed, bool atomic = false) nothrow
    {
        auto b = queryBlock(slice.ptr);
        if (!b.valid())
            return false;
        auto m = b.meta();
        if (!(b.attr() & BlkAttr.APPENDABLE))
            return false;

        size_t offset = cast(ubyte*) slice.ptr - cast(ubyte*) b.payload();
        if (offset + existingUsed != m.usedSize)
            return false;
        if (slice.length > existingUsed)
            return false;

        m.usedSize = offset + slice.length;
        return true;
    }

    void initThread(ThreadBase t) nothrow @nogc
    {
        t.tlsGCData() = currentHeap();
    }

    void cleanupThread(ThreadBase t) nothrow @nogc
    {
        auto h = cast(ThreadHeap*) t.tlsGCData();
        if (!h)
            return;

        // Unregister first: once the heap is off the registry no other thread
        // can walk it through queryBlock's foreign-heap fallback while it is
        // being torn down.
        unregisterHeap(h);

        // Do NOT finalize or release the thread's blocks here. Thread.join()
        // hands the child's Throwable to the parent after this point, so doing
        // either is a use-after-free in ordinary code. Move the arenas to the
        // orphan heap, where they stay valid and unswept.
        adoptOrphanChunks(h);

        if (tlsHeap is h)
            tlsHeap = null;
        t.tlsGCData() = null;
        h.destroy();
        cstdlib.free(h);
    }

private:

    enum Trigger
    {
        automatic, /// driven by the allocation threshold; honours disable()
        explicit,  /// user called GC.collect(); always runs
    }

    static bool inSegment(const scope void[] segment, void* p) nothrow @nogc
    {
        return p >= segment.ptr && p < segment.ptr + segment.length;
    }

    BlkRef queryBlock(void* p) nothrow @nogc
    {
        if (!p)
            return BlkRef.init;
        // Fast path: local heap, one hash probe.
        if (tlsHeap)
        {
            auto b = tlsHeap.lookup(p, false);
            if (b.valid())
                return b;
        }
        // Arenas adopted from exited threads. Safe to probe because no thread
        // owns the orphan heap: it is mutated only under orphanLock.
        //
        // Another *live* thread's heap is deliberately not searched. Its owner
        // mutates its chunk map with no lock at all -- and ChunkMap.grow frees
        // the old key and value arrays -- so probing it from here was a genuine
        // use-after-free, reachable from an ordinary GC.sizeOf on a pointer
        // this thread does not own. Cross-thread sharing is unsupported, so
        // there is nothing to find there anyway.
        orphanLock.lock();
        scope (exit)
            orphanLock.unlock();
        if (orphanHeap !is null)
            return orphanHeap.lookup(p, false);
        return BlkRef.init;
    }

    BlkRef alloc(size_t size, uint bits, bool zero, const TypeInfo ti) nothrow
    {
        auto heap = currentHeap();
        if (atomicLoad(disabled) <= 0 && heap.usedBytes >= heap.collectThreshold)
        {
            collectHeap(heap, Trigger.automatic);

            // Retained memory -- adopted arenas, and promoted blocks when
            // escape tracking is on -- can only be reclaimed globally. Check
            // after a local collection rather than on every allocation, so the
            // cost is amortised and the world stops rarely.
            auto threshold = atomicLoad(globalThreshold);
            if (threshold != 0 && atomicLoad(orphanBytes) >= threshold
                && !heap.collecting && !heap.finalizing)
                collectGlobal(this);
        }

        auto b = heap.allocSlot(size);
        b.setAttr(bits);
        auto m = b.meta();
        m.ti = cast(TypeInfo) ti;
        m.usedSize = (bits & BlkAttr.APPENDABLE) ? size : 0;

        auto p = b.payload();
        // Always zero: slots are recycled, so stale bytes would otherwise be
        // handed back as uninitialised data, and any stale pointer left in
        // them would be treated as a live reference by the conservative mark
        // phase and retain dead blocks indefinitely.
        memset(p, 0, b.capacity());

        heap.allocatedTotal += size;
        assert((cast(size_t) p & (payloadAlign - 1)) == 0,
               "tgc: GC payload must be 16-byte aligned");
        return b;
    }

    void collectHeap(ThreadHeap* heap, Trigger trigger) nothrow
    {
        import core.time : MonoTime;

        if (!heap || heap.collecting)
            return;
        if (trigger == Trigger.automatic && atomicLoad(disabled) > 0)
            return;
        // Without an attached thread there is no reliable stack bound, and
        // guessing one either misses live frames or reads unmapped memory.
        // Refuse to collect rather than free something still in use.
        if (ThreadBase.getThis() is null)
            return;

        // Publish that a local collection is in flight so a global collection
        // waits for it rather than suspending this thread mid-mark.
        atomicOp!"+="(activeLocalCollections, 1);
        if (atomicLoad(globalPending))
        {
            atomicOp!"-="(activeLocalCollections, 1);
            return;
        }
        scope (exit)
            atomicOp!"-="(activeLocalCollections, 1);

        auto started = MonoTime.currTime;

        heap.collecting = true;

        heap.markLen = 0;

        immutable bool trackEscapes = atomicLoad(escapeTracking);

        // Clear this cycle's marks. With escape tracking on, also re-seed every
        // already-promoted block as a root: a promoted block may be unreachable
        // from anything this thread can see while another thread still holds
        // it, so it must be scanned, or its children -- which may never have
        // been global themselves -- would be swept out from under that thread.
        for (auto c = heap.allChunks; c; c = c.nextAll)
        {
            // One memset over n/8 bytes, rather than a read-modify-write on
            // every slot's metadata.
            c.clearMarks();
            if (!trackEscapes)
                continue;
            foreach (idx; 0 .. c.slotCount)
            {
                if (!c.isAllocated(idx) || !c.isShared(idx))
                    continue;
                c.setMarked(idx);
                if (!(c.attrOf(idx) & BlkAttr.NO_SCAN))
                    heap.pushMark(c.slotAt(idx), c.capacity());
            }
        }

        if (trackEscapes)
        {
            // Compute the closure reachable from global roots first and to
            // completion, so everything it reaches can be tagged as escaped.
            heap.markAsShared = true;
            markRootsAndRanges(heap);
            drainMarkStack(heap);
            heap.markAsShared = false;
        }

        // This thread's own roots: stack and callee-saved registers (the shell
        // spills them into the scanned range), then TLS. No other thread is
        // suspended.
        callWithStackShell((void* sp) nothrow { markStacks(heap, sp); });
        markTLS(heap);
        if (!trackEscapes)
            markRootsAndRanges(heap);
        drainMarkStack(heap);

        // Sweep unmarked
        heap.finalizing = true;
        auto c = heap.allChunks;
        while (c)
        {
            auto nextChunk = c.nextAll;
            // Freeing the single slot of a large chunk releases the chunk, so
            // nothing may be read back out of `c` afterwards.
            immutable bool large = c.isLarge();
            immutable uint count = c.slotCount;
            bool released = false;

            // nextReclaimable tests allocated & ~marked & ~shared 64 slots at
            // a time, so mostly-live and mostly-free chunks are skipped in a
            // few instructions. Promoted blocks are excluded: only a global
            // collection can prove no other thread still holds them.
            for (size_t idx = c.nextReclaimable(0); idx < count;
                 idx = c.nextReclaimable(idx + 1))
            {
                heap.freeSlotFinalize(BlkRef(c, idx));
                if (large)
                {
                    released = true;
                    break;
                }
            }

            // Hand a fully empty chunk back rather than letting a transient
            // peak pin its arena forever.
            if (!released && !large && c.freeCount == c.slotCount)
                heap.releaseChunk(c);
            c = nextChunk;
        }
        heap.finalizing = false;

        // Recompute the trigger from what actually survived. The previous
        // scheme only ever raised the threshold, so a program that spiked once
        // and then settled would never collect again.
        heap.collectThreshold = thresholdFor(heap.usedBytes);

        heap.numCollections++;
        heap.collecting = false;

        auto elapsed = cast(ulong)(MonoTime.currTime - started).total!"nsecs";
        atomicOp!"+="(profileCollections, 1);
        atomicOp!"+="(profilePauseTotalNs, elapsed);
        // Racy max, but only ever under-reports a concurrent larger sample.
        if (elapsed > atomicLoad(profilePauseMaxNs))
            atomicStore(profilePauseMaxNs, elapsed);
    }

    @conservativeScan
    void drainMarkStack(ThreadHeap* heap) nothrow
    {
        while (heap.markLen)
        {
            auto item = heap.markStack[--heap.markLen];
            markRange(heap, item.base, cast(void*)(cast(ubyte*) item.base + item.size));
        }
    }

    /// Scan a stack range without caring which end is which.
    @conservativeScan
    void markStackSpan(ThreadHeap* heap, void* a, void* b) nothrow
    {
        if (!a || !b || a is b)
            return;
        if (a < b)
            markRange(heap, a, b);
        else
            markRange(heap, b, a);
    }

    /**
     * Scan every stack belonging to this thread.
     *
     * Scanning only the running stack is not enough once fibers exist:
     * `thread_stackBottom()` reports the *current* `StackContext`, so a
     * collection triggered inside a fiber would scan that fiber and nothing
     * else — not the thread's own stack, and not any other fiber parked on a
     * yield. In a fiber-per-connection server almost every allocation happens
     * inside a fiber, so that is the common case, and every suspended fiber's
     * live data would be freed underneath it.
     *
     * Only *this thread's* contexts are scanned. Walking druntime's global
     * context list wholesale is both wasteful (a thread has no business
     * marking through another thread's stack, since it can only mark blocks in
     * its own heap) and unsafe: another thread may destroy a fiber and unmap
     * its stack while we are reading it, which faults.
     *
     * Ownership is established two ways. The active chain from `m_curr` gives
     * the running context and everything it is nested inside, which is how the
     * thread's own stack is reached from inside a fiber. Suspended fibers are
     * not in any chain, but `Fiber` allocates its `StackContext` with `new` on
     * the creating thread's heap, so a context whose block this heap owns is a
     * fiber this thread created.
     */
    @conservativeScan
    void markStacks(ThreadHeap* heap, void* sp) nothrow
    {
        auto t = ThreadBase.getThis();
        auto cur = currentStackContext(t);

        // The running context is the only one whose saved `tstack` is stale, so
        // scan it precisely from the stack pointer the register-spill shell
        // handed us.
        markStackSpan(heap, sp, cur !is null ? cur.bstack : thread_stackBottom());

        // Contexts the running one is nested inside: from within a fiber this
        // is the thread's own stack.
        for (auto c = (cur !is null ? cur.within : null); c; c = c.within)
            markStackSpan(heap, c.tstack, c.bstack);

        // Fibers this thread created that are currently suspended.
        size_t n = snapshotOwnedContexts(heap, cur);
        foreach (i; 0 .. n)
            markStackSpan(heap, heap.stackSnap[i].pbot, heap.stackSnap[i].ptop);
    }

    /**
     * Copy the used span of every suspended fiber this thread owns into the
     * heap's scratch buffer, under druntime's thread lock.
     *
     * Taking `slock` follows druntime's documented lock order (the GC lock is
     * acquired before it, never after), so it cannot invert. Holding it only
     * for the snapshot keeps a collection from blocking fiber creation for the
     * whole mark.
     */
    size_t snapshotOwnedContexts(ThreadHeap* heap, StackContext* cur) nothrow
    {
        auto lock = threadListLock();
        lock.lock_nothrow();

        // One walk, growing the buffer as we go. The previous version walked
        // the list twice — once to count, once to filter — which doubled the
        // work done while holding druntime's thread lock.
        //
        // The ownership test has to stay inside the lock. Only once a context
        // is known to belong to this thread is it safe to use its stack bounds
        // later: any other thread's fiber may be destroyed and its stack
        // unmapped the moment the lock is released, and scanning that faults.
        size_t n = 0;
        for (auto c = globalStackContexts(); c; c = c.next)
        {
            // A fiber that has not started, or has finished, has
            // tstack == bstack and contributes nothing. Cheapest test first.
            if (!c.tstack || !c.bstack || c.tstack is c.bstack)
                continue;

            // Ours only if this heap owns the StackContext block itself —
            // `Fiber` allocates it with `new` on its creating thread.
            if (!heap.lookup(cast(void*) c, false).valid())
                continue;

            // Already covered by the active chain scanned by the caller.
            bool inChain = false;
            for (auto k = cur; k; k = k.within)
                if (k is c)
                {
                    inChain = true;
                    break;
                }
            if (inChain)
                continue;

            if (n == heap.stackSnapCap)
            {
                size_t ncap = heap.stackSnapCap ? heap.stackSnapCap * 2 : 64;
                auto np = cast(RangeSnap*) cstdlib.realloc(heap.stackSnap, ncap * RangeSnap.sizeof);
                if (!np)
                {
                    lock.unlock_nothrow();
                    onOutOfMemoryError();
                }
                heap.stackSnap = np;
                heap.stackSnapCap = ncap;
            }
            heap.stackSnap[n++] = RangeSnap(c.tstack, c.bstack);
        }

        lock.unlock_nothrow();
        return n;
    }

    @conservativeScan
    void markTLS(ThreadHeap* heap) nothrow
    {
        // Read fresh each collection: the handle is installed during thread
        // registration, which happens after the pre-registration thread init
        // hook that may have created this heap.
        auto data = threadTLSData(ThreadBase.getThis());
        if (data is null)
            return;
        rt_tlsgc_scan(data, (void* pbeg, void* pend) nothrow {
            markRange(heap, pbeg, pend);
        });
    }

    /**
     * Snapshot the shared root/range tables, then mark outside the lock.
     *
     * Marking under `rootsLock` would make every other thread calling
     * addRoot/addRange spin for the whole collection — a global pause in all
     * but name, which is the one thing tgc exists to avoid.
     */
    void markRootsAndRanges(ThreadHeap* heap) nothrow
    {
        size_t nroots, nranges;

        rootsLock.lock();
        {
            nroots = roots.length;
            nranges = ranges.length;

            if (nroots > heap.rootSnapCap)
            {
                size_t ncap = nroots + (nroots >> 1) + 8;
                auto np = cast(void**) cstdlib.realloc(heap.rootSnap, ncap * (void*).sizeof);
                if (!np)
                {
                    rootsLock.unlock();
                    onOutOfMemoryError();
                }
                heap.rootSnap = np;
                heap.rootSnapCap = ncap;
            }
            if (nranges > heap.rangeSnapCap)
            {
                size_t ncap = nranges + (nranges >> 1) + 8;
                auto np = cast(RangeSnap*) cstdlib.realloc(heap.rangeSnap, ncap * RangeSnap.sizeof);
                if (!np)
                {
                    rootsLock.unlock();
                    onOutOfMemoryError();
                }
                heap.rangeSnap = np;
                heap.rangeSnapCap = ncap;
            }

            foreach (i; 0 .. nroots)
                heap.rootSnap[i] = roots[i].proot;
            foreach (i; 0 .. nranges)
                heap.rangeSnap[i] = RangeSnap(ranges[i].pbot, ranges[i].ptop);
        }
        rootsLock.unlock();

        foreach (i; 0 .. nroots)
            markPtr(heap, heap.rootSnap[i]);
        foreach (i; 0 .. nranges)
            markRange(heap, heap.rangeSnap[i].pbot, heap.rangeSnap[i].ptop);
    }

    @conservativeScan
    /// Mark the shared root tables into the global collection's mark set.
    package void markGlobalRootsAndRanges() nothrow
    {
        // The world is stopped, so rootsLock must not be taken: the thread
        // holding it may be suspended.
        foreach (i; 0 .. roots.length)
            markPtrGlobal(roots[i].proot);
        foreach (i; 0 .. ranges.length)
            markRangeGlobal(ranges[i].pbot, ranges[i].ptop);
    }

    void markRange(ThreadHeap* heap, void* pbot, void* ptop) nothrow
    {
        if (!pbot || !ptop || pbot >= ptop)
            return;
        auto p = cast(void**) pbot;
        auto e = cast(void**) ptop;
        // Align
        auto addr = cast(size_t) p;
        addr = (addr + (void*).sizeof - 1) & ~((void*).sizeof - 1);
        p = cast(void**) addr;
        for (; p + 1 <= e; ++p)
            markPtr(heap, *p);
    }

    @conservativeScan
    void markPtr(ThreadHeap* heap, void* p) nothrow
    {
        if (!p)
            return;
        auto b = heap.lookup(p, true);
        if (!b.valid())
            return;
        auto c = b.chunk;
        if (c.isMarked(b.idx))
            return;
        c.setMarked(b.idx);
        // The global closure is computed first and to completion, so anything
        // marked during that pass is reachable from a global and gets promoted.
        if (heap.markAsShared)
            c.setShared(b.idx);
        if (!(c.attrOf(b.idx) & BlkAttr.NO_SCAN))
            heap.pushMark(b.payload(), b.capacity());
    }
}
