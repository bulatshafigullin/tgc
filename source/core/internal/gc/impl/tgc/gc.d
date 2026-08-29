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

import core.thread.threadbase : ThreadBase;

import cstdlib = core.stdc.stdlib : calloc, free, malloc, realloc;
import core.stdc.string : memcpy, memset;
static import core.memory;

extern (C) noreturn onOutOfMemoryError(void* pretend_sideffect = null, string file = __FILE__, size_t line = __LINE__) @trusted pure nothrow @nogc; /* dmd @@@BUG11461@@@ */
extern (C) void rt_finalizeFromGC(void* p, size_t size, uint attr, const(TypeInfo) typeInfo) nothrow;
extern (C) void* thread_stackTop() nothrow @nogc;
extern (C) void* thread_stackBottom() nothrow @nogc;

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
private enum size_t maxSmall = 8192;

private static immutable uint[] sizeClasses = [
    16, 32, 48, 64, 80, 96, 112, 128,
    160, 192, 224, 256, 320, 384, 448, 512,
    640, 768, 896, 1024, 1280, 1536, 1792, 2048,
    2560, 3072, 3584, 4096, 5120, 6144, 7168, 8192,
];

private enum size_t numClasses = sizeClasses.length;

private enum size_t collectThresholdInit = 256 * 1024;

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

private enum uint slotAllocated = 1 << 0;
private enum uint slotMarked = 1 << 1;

private struct SlotMeta
{
    TypeInfo ti;      /// type for finalization; may be null
    size_t usedSize;  /// BlkAttr.APPENDABLE used bytes (array API)
    uint attr;
    uint flags;
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

    // Remote frees pushed by other threads (ownership transfer).
    void** remotePtrs;
    size_t remoteLen;
    size_t remoteCap;
    SpinLock remoteLock;

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

    bool collecting;
    bool finalizing;

    static ThreadHeap* create() nothrow @nogc
    {
        auto h = cast(ThreadHeap*) cstdlib.calloc(1, ThreadHeap.sizeof);
        if (!h)
            onOutOfMemoryError();
        h.collectThreshold = collectThresholdInit;
        h.remoteLock = SpinLock(SpinLock.Contention.brief);
        return h;
    }

    void destroy() nothrow @nogc
    {
        // The rt.tlsgc handle is owned by druntime, not by us; destroying it
        // here would double-free the thread's TLS ranges.
        map.destroy();
        cstdlib.free(remotePtrs);
        cstdlib.free(markStack);
        cstdlib.free(rootSnap);
        cstdlib.free(rangeSnap);
        remotePtrs = null;
        markStack = null;
        rootSnap = null;
        rangeSnap = null;
    }

    // -- chunk lifecycle ----------------------------------------------------

    Chunk* newSmallChunk(uint cls) nothrow @nogc
    {
        immutable uint slotSize = sizeClasses[cls];

        auto raw = chunkAlloc(chunkSize);
        if (!raw)
            onOutOfMemoryError();
        memset(raw, 0, Chunk.sizeof);

        auto c = cast(Chunk*) raw;
        immutable size_t metaOff = alignUp(Chunk.sizeof, size_t.sizeof);

        // Fit as many (slot + metadata) pairs as the chunk allows.
        size_t count = (chunkSize - metaOff) / (slotSize + SlotMeta.sizeof);
        size_t dataOff;
        for (;;)
        {
            dataOff = alignUp(metaOff + count * SlotMeta.sizeof, payloadAlign);
            if (count == 0 || dataOff + count * slotSize <= chunkSize)
                break;
            count--;
        }
        assert(count > 0, "tgc: chunk too small for its size class");

        c.heap = &this;
        c.meta = cast(SlotMeta*)(cast(ubyte*) raw + metaOff);
        c.data = cast(void*)(cast(ubyte*) raw + dataOff);
        c.slotSize = slotSize;
        c.slotCount = cast(uint) count;
        c.freeCount = cast(uint) count;
        c.cls = cls;
        c.runChunks = 1;

        memset(c.meta, 0, count * SlotMeta.sizeof);

        // Thread the free list through the slots themselves.
        c.freeHead = null;
        foreach_reverse (i; 0 .. count)
        {
            auto slot = c.slotAt(i);
            *cast(void**) slot = c.freeHead;
            c.freeHead = slot;
        }

        map.put(raw, c);
        linkAll(c);
        linkPartial(c);
        reservedBytes += chunkSize;
        return c;
    }

    Chunk* newLargeChunk(size_t size) nothrow @nogc
    {
        immutable size_t metaOff = alignUp(Chunk.sizeof, size_t.sizeof);
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
        c.meta = cast(SlotMeta*)(cast(ubyte*) raw + metaOff);
        c.data = cast(void*)(cast(ubyte*) raw + dataOff);
        c.slotSize = 0;
        c.slotCount = 1;
        c.freeCount = 0;
        c.cls = uint.max;
        c.runChunks = runChunks;
        c.largeSize = runChunks * chunkSize - dataOff;

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
            if (!(c.meta[0].flags & slotAllocated))
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
        else if (acceptEnd && off % c.slotSize == 0 && idx > 0
                 && !(c.meta[idx].flags & slotAllocated))
        {
            // Slot boundary: also consider it one-past-the-end of the
            // preceding slot before giving up.
            if (c.meta[idx - 1].flags & slotAllocated)
                idx--;
        }

        if (!(c.meta[idx].flags & slotAllocated))
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
        immutable uint birthFlags =
            slotAllocated | ((collecting || finalizing) ? slotMarked : 0);

        if (size > maxSmall)
        {
            auto c = newLargeChunk(size);
            c.meta[0].flags = birthFlags;
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
        c.meta[idx].flags = birthFlags;
        usedBytes += c.slotSize;
        return BlkRef(c, idx);
    }

    void freeSlot(BlkRef b) nothrow @nogc
    {
        auto c = b.chunk;
        c.meta[b.idx] = SlotMeta.init;

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
        auto m = b.meta();
        if (m.attr & (BlkAttr.FINALIZE | BlkAttr.STRUCTFINAL))
            finalizeBlock(b.payload(), b.capacity(), m.attr, m.ti);
        freeSlot(b);
    }

    // -- remote free queue --------------------------------------------------

    void pushRemote(void* p) nothrow @nogc
    {
        remoteLock.lock();
        if (remoteLen == remoteCap)
        {
            size_t ncap = remoteCap ? remoteCap * 2 : 16;
            auto np = cast(void**) cstdlib.realloc(remotePtrs, ncap * (void*).sizeof);
            if (!np)
            {
                remoteLock.unlock();
                onOutOfMemoryError();
            }
            remotePtrs = np;
            remoteCap = ncap;
        }
        remotePtrs[remoteLen++] = p;
        remoteLock.unlock();
    }

    void drainRemote() nothrow @nogc
    {
        remoteLock.lock();
        size_t n = remoteLen;
        void** ptrs = remotePtrs;
        remoteLen = 0;
        remoteLock.unlock();

        foreach (i; 0 .. n)
        {
            auto p = ptrs[i];
            if (!p)
                continue;
            auto b = lookup(p, false);
            if (b.valid())
                freeSlot(b);
        }
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

    void minimize() nothrow
    {
        auto heap = currentHeap();
        heap.drainRemote();

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
        return b.valid() ? b.meta().attr : 0;
    }

    uint setAttr(void* p, uint mask) nothrow
    {
        auto b = queryBlock(p);
        if (!b.valid())
            return 0;
        b.meta().attr |= mask;
        return b.meta().attr;
    }

    uint clrAttr(void* p, uint mask) nothrow
    {
        auto b = queryBlock(p);
        if (!b.valid())
            return 0;
        b.meta().attr &= ~mask;
        return b.meta().attr;
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
            auto nb = alloc(size, bits ? bits : m.attr, false, ti ? ti : m.ti);
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
                m.attr = bits;
            if (ti)
                m.ti = cast(TypeInfo) ti;
            return p;
        }

        auto nb = alloc(size, bits ? bits : m.attr, false, ti ? ti : m.ti);
        memcpy(nb.payload(), p, b.capacity());
        heap.freeSlot(b);
        return nb.payload();
    }

    size_t extend(void* p, size_t minsize, size_t maxsize, const TypeInfo ti) nothrow
    {
        auto b = queryBlock(p);
        if (!b.valid())
            return 0;
        // A slot cannot grow, but it may already be large enough: size classes
        // and chunk rounding routinely leave usable slack.
        auto cap = b.capacity();
        return cap >= minsize ? cap : 0;
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
        auto local = tlsHeap;
        if (owner is local || local is null)
        {
            owner.freeSlot(b);
            return;
        }
        // Cross-thread free: queue for owning thread (ownership transfer).
        owner.pushRemote(p);
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
        info.attr = b.meta().attr;
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
                auto m = &c.meta[idx];
                if (!(m.flags & slotAllocated))
                    continue;
                if (!(m.attr & (BlkAttr.FINALIZE | BlkAttr.STRUCTFINAL)))
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
        auto m = b.meta();
        if (!(m.attr & BlkAttr.APPENDABLE))
            return null;
        return b.payload()[0 .. m.usedSize];
    }

    bool expandArrayUsed(void[] slice, size_t newUsed, bool atomic = false) nothrow @safe
    {
        return (() @trusted {
            auto b = queryBlock(slice.ptr);
            if (!b.valid())
                return false;
            auto m = b.meta();
            if (!(m.attr & BlkAttr.APPENDABLE))
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
            if (!(m.attr & BlkAttr.APPENDABLE))
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
        if (!(m.attr & BlkAttr.APPENDABLE))
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

        h.drainRemote();

        // Objects still alive at thread exit must have their destructors run,
        // exactly as they would at program termination.
        h.finalizing = true;
        auto c = h.allChunks;
        while (c)
        {
            auto next = c.nextAll;
            foreach (idx; 0 .. c.slotCount)
            {
                auto m = &c.meta[idx];
                if (!(m.flags & slotAllocated))
                    continue;
                if (m.attr & (BlkAttr.FINALIZE | BlkAttr.STRUCTFINAL))
                    finalizeBlock(c.slotAt(idx), c.capacity(), m.attr, m.ti);
            }
            chunkFree(c);
            c = next;
        }
        h.finalizing = false;
        h.allChunks = null;

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
        // Slow path: search registered heaps (for free/query of foreign ptrs)
        heapsLock.lock();
        foreach (i; 0 .. allHeapsLen)
        {
            if (allHeaps[i] is tlsHeap)
                continue;
            auto b = allHeaps[i].lookup(p, false);
            if (b.valid())
            {
                heapsLock.unlock();
                return b;
            }
        }
        heapsLock.unlock();
        return BlkRef.init;
    }

    BlkRef alloc(size_t size, uint bits, bool zero, const TypeInfo ti) nothrow
    {
        auto heap = currentHeap();
        heap.drainRemote();

        if (atomicLoad(disabled) <= 0 && heap.usedBytes >= heap.collectThreshold)
            collectHeap(heap, Trigger.automatic);

        auto b = heap.allocSlot(size);
        auto m = b.meta();
        m.attr = bits;
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

        auto started = MonoTime.currTime;

        heap.collecting = true;
        heap.drainRemote();

        // Clear marks
        for (auto c = heap.allChunks; c; c = c.nextAll)
            foreach (idx; 0 .. c.slotCount)
                c.meta[idx].flags &= ~slotMarked;

        heap.markLen = 0;

        // Mark from this thread's stack and callee-saved registers. The shell
        // spills the registers so they land in the scanned range; no other
        // thread is suspended.
        callWithStackShell((void* sp) nothrow { markStack(heap, sp); });

        // Mark from this thread's TLS.
        markTLS(heap);

        // Mark from global roots/ranges.
        markRootsAndRanges(heap);

        // Transitive closure over the worklist. Each live block is scanned
        // exactly once, rather than the whole heap once per graph level.
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

            foreach (idx; 0 .. count)
            {
                auto m = &c.meta[idx];
                if ((m.flags & slotAllocated) && !(m.flags & slotMarked))
                {
                    heap.freeSlotFinalize(BlkRef(c, idx));
                    if (large)
                    {
                        released = true;
                        break;
                    }
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
        heap.collectThreshold = heap.usedBytes * 2;
        if (heap.collectThreshold < collectThresholdInit)
            heap.collectThreshold = collectThresholdInit;

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

    @conservativeScan
    void markStack(ThreadHeap* heap, void* sp) nothrow
    {
        auto bottom = thread_stackBottom();
        if (!sp || !bottom)
            return;
        void* lo = sp;
        void* hi = bottom;
        if (lo > hi)
        {
            auto tmp = lo;
            lo = hi;
            hi = tmp;
        }
        markRange(heap, lo, hi);
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
        auto m = b.meta();
        if (m.flags & slotMarked)
            return;
        m.flags |= slotMarked;
        if (!(m.attr & BlkAttr.NO_SCAN))
            heap.pushMark(b.payload(), b.capacity());
    }
}
