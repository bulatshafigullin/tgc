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

import core.atomic : atomicLoad, atomicOp, atomicStore, MemoryOrder;
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

/**
 * ThreadSanitizer happens-before annotations.
 *
 * druntime's `SpinLock` synchronises correctly -- a four-thread counter under
 * it comes out exact -- but TSan cannot see it, and reports every structure it
 * guards as racing. Annotating the acquire and release directly gives TSan the
 * edge it is missing, which is better than suppressing the reports: the
 * structures stay checked for races that are real.
 */
version (TgcTSan)
{
    extern (C) void __tsan_acquire(void*) nothrow @nogc;
    extern (C) void __tsan_release(void*) nothrow @nogc;
    extern (C) void __tsan_ignore_thread_begin() nothrow @nogc;
    extern (C) void __tsan_ignore_thread_end() nothrow @nogc;

    private void tsanAcquire(const(void)* p) nothrow @nogc { __tsan_acquire(cast(void*) p); }
    private void tsanRelease(const(void)* p) nothrow @nogc { __tsan_release(cast(void*) p); }
    private void tsanIgnoreBegin() nothrow @nogc { __tsan_ignore_thread_begin(); }
    private void tsanIgnoreEnd() nothrow @nogc { __tsan_ignore_thread_end(); }
}
else
{
    private void tsanAcquire(const(void)* p) nothrow @nogc {}
    private void tsanRelease(const(void)* p) nothrow @nogc {}
    private void tsanIgnoreBegin() nothrow @nogc {}
    private void tsanIgnoreEnd() nothrow @nogc {}
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
 * Resolve a block's pointer layout from its `TypeInfo`.
 *
 * Returns false when the type says the block holds no references at all, so it
 * need not be scanned. Otherwise `bitmap`/`elemWords` describe which words may
 * be pointers, or are left null/zero to mean "scan every word".
 *
 * Deliberately conservative in three places. An unknown type scans everything.
 * `rtinfoHasPointers` -- what the compiler emits when it cannot describe a
 * layout -- scans everything. And an *appendable* block whose TypeInfo is a
 * class scans everything, because that is an array of references while the
 * class's own bitmap describes an instance; using it would skip real pointers.
 */
private bool layoutOf(TypeInfo ti, uint attr, out const(size_t)* bitmap,
                      out size_t elemWords) nothrow
{
    if (ti is null || !atomicLoad(preciseScanning))
        return true; // conservative

    if ((attr & BlkAttr.APPENDABLE) && (cast(TypeInfo_Class) ti) !is null)
        return true; // array of class references

    auto ri = cast(const(size_t)*) ti.rtInfo();
    if (ri is null)
        return false; // rtinfoNoPointers
    if (ri is cast(const(size_t)*) 1)
        return true; // rtinfoHasPointers

    immutable size_t elem = ri[0];
    if (elem < (void*).sizeof)
        return true;

    bitmap = ri + 1;
    elemWords = elem / (void*).sizeof;
    return true;
}

/**
 * Marks the conservative scanning routines as exempt from the sanitizers.
 *
 * A conservative collector deliberately reads memory a sanitizer considers
 * off-limits, and it does so on both axes. For AddressSanitizer: padding and
 * redzones between stack variables, and quarantined heap. For
 * ThreadSanitizer: the scan walks whole stacks and the data segment while
 * other threads are mutating them, which is exactly what a race detector is
 * built to flag — including tgc's own `__gshared` state, which lives in the
 * scanned data segment. A torn read there is harmless: the word either
 * resolves to a block, retaining it for one extra cycle, or it does not.
 *
 * Instrumenting these produces both false reports and a large slowdown.
 * Exempting the scan routines is the standard treatment.
 */
version (LDC)
{
    import ldc.attributes : noSanitize;

    // The attribute takes one sanitizer per instance; apply both.
    private enum conservativeScanAddr = noSanitize("address");
    private enum conservativeScanThread = noSanitize("thread");
}
else
{
    // No-op UDA on compilers without the attribute.
    private enum conservativeScanAddr = "tgc.conservativeScan";
    private enum conservativeScanThread = "tgc.conservativeScan";
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
 * Arena granularity. Chunks are allocated aligned to their own size, so
 * `p >> chunkShift` yields a candidate's chunk unit in one instruction — the
 * property that makes `markPtr` O(1) — and a chunk's own header sits at its
 * base, so the unit index converts straight back to a `Chunk*`.
 */
private enum size_t chunkSize = 64 * 1024;
static assert((chunkSize & (chunkSize - 1)) == 0, "chunkSize must be a power of two");
static assert(chunkSize % payloadAlign == 0);

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
/**
 * Use `TypeInfo.rtInfo` pointer maps to skip words that cannot hold references.
 *
 * Falls back to conservative scanning whenever the layout is unknown or
 * ambiguous, so this only ever scans *less* where the compiler has said it is
 * safe to. Switchable mainly so a suspected precision bug can be ruled in or
 * out without rebuilding.
 */
private shared bool preciseScanning = true;

/// ditto
extern (C) void tgc_setPreciseScanning(bool enable) nothrow @nogc
{
    atomicStore(preciseScanning, enable);
}

/// ditto
extern (C) bool tgc_getPreciseScanning() nothrow @nogc
{
    return atomicLoad(preciseScanning);
}

/**
 * Floor on a thread's collection threshold — tgc's answer to `minPoolSize`.
 *
 * Without it a thread collects as soon as live data has grown by the growth
 * factor, which for a small live set means collecting constantly. The default
 * collector avoids that by starting with a large pool; `minPoolSize:300` is why
 * it collects 7 times on binary-trees where tgc collects 64.
 *
 * Note this is *per thread*, because tgc's heaps are. A program wanting a total
 * budget comparable to a global pool should divide by its thread count.
 */
private shared size_t minHeapSize = collectThresholdInit;

/// ditto
extern (C) void tgc_setMinHeap(size_t bytes) nothrow @nogc
{
    atomicStore(minHeapSize, bytes < collectThresholdInit ? collectThresholdInit : bytes);
}

/// ditto
extern (C) size_t tgc_getMinHeap() nothrow @nogc
{
    return atomicLoad(minHeapSize);
}

private shared size_t heapGrowthFactor = 4;

/**
 * Floor on the absolute headroom allowed between collections.
 *
 * A flat multiplier is fine while the heap is small and wasteful once it is
 * large: x4 on a 1 GB live set means not collecting until 4 GB. Headroom is
 * therefore capped, so the effective multiplier decays from the configured
 * factor toward 3 as the heap grows. BEAM does the same thing more
 * aggressively -- Fibonacci growth up to about a megaword, then 20% increments
 * -- but its per-process heaps are kilobytes, and copying tiny live sets is
 * cheap. Measured on a 67 MB live set, a +20% cap cost 296 collections against
 * 76 for this one.
 */
private enum size_t growthHeadroomFloor = 32 * 1024 * 1024;

/// Collection threshold for a heap holding `live` bytes.
private size_t thresholdFor(size_t live) nothrow @nogc
{
    immutable size_t g = atomicLoad(heapGrowthFactor);
    immutable size_t wanted = live * (g - 1);
    immutable size_t capped = growthHeadroomFloor > live * 2 ? growthHeadroomFloor : live * 2;
    immutable size_t headroom = wanted < capped ? wanted : capped;

    size_t t = live + headroom;
    immutable size_t floor = atomicLoad(minHeapSize);
    if (t < floor)
        t = floor;
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

/**
 * Size (in 16-byte steps) to size-class index.
 *
 * Every size class is a multiple of 16, so rounding a request up to 16 bytes
 * loses nothing and the map is exact. Built at compile time; the linear scan it
 * replaces ran on every allocation and showed up in the profile at 2%.
 */
private static immutable ubyte[maxSmall / payloadAlign + 1] classTable = ()
{
    ubyte[maxSmall / payloadAlign + 1] t;
    foreach (i; 0 .. t.length)
    {
        immutable size_t want = i * payloadAlign;
        foreach (k, sc; sizeClasses)
            if (want <= sc)
            {
                t[i] = cast(ubyte) k;
                break;
            }
    }
    return t;
}();

static assert(sizeClasses.length <= ubyte.max + 1, "size-class index no longer fits in a byte");

/// Maps a request size to a size-class index.
private uint classOf(size_t size) nothrow @nogc
{
    assert(size <= maxSmall, "classOf called with a large size");
    return classTable[(size + payloadAlign - 1) / payloadAlign];
}

private size_t alignUp(size_t n, size_t a) nothrow @nogc
{
    return (n + a - 1) & ~(a - 1);
}

// ---------------------------------------------------------------------------
// segment-backed chunk allocation
// ---------------------------------------------------------------------------

/*
 * Chunks come from a few large mappings rather than one allocator call each.
 *
 * The reason is address translation, and it was measured rather than guessed.
 * On binary-trees at a matched 300 MB budget, tgc executed the *same* number of
 * instructions as druntime's collector and missed cache 45% less often, yet
 * spent 27% more cycles. The counter that explained it was dTLB-load-misses:
 * 8.08 M against 1.27 M, a 6.3x gap. `/proc/pid/smaps_rollup` said why --
 * druntime maps its pool in one piece and the kernel backs 76 MB of it with
 * 2 MB pages, while tgc's `posix_memalign(64 KiB)` chunks came back from malloc
 * scattered across its arenas and got *zero* huge pages.
 *
 * So chunks are now carved out of segments: one mapping of several megabytes,
 * aligned to the huge-page size and, on Linux, marked `MADV_HUGEPAGE`. Chunks
 * stay 64 KiB-aligned inside it, so everything above this layer -- the chunk
 * directory, the run-head encoding, `markPtr` -- is unchanged.
 *
 * Memory returns to the OS a segment at a time instead of a chunk at a time.
 * That is the trade this makes, and it is the same delayed-return property that
 * sank the free-chunk cache experiment; the difference is what it buys. One
 * empty segment is kept back so a heap oscillating around a segment boundary
 * does not unmap and remap on every collection.
 */

/// Huge-page granularity: segments are aligned and sized to it.
private enum size_t hugePageSize = 2 * 1024 * 1024;

static assert(hugePageSize % chunkSize == 0);

private enum size_t defaultSegmentSize = 32 * 1024 * 1024;

private shared size_t segmentSizeBytes = defaultSegmentSize;

/// Size of the mappings chunks are carved from; rounded up to a huge page.
extern (C) void tgc_setSegmentSize(size_t bytes) nothrow @nogc
{
    immutable size_t rounded = alignUp(bytes < hugePageSize ? hugePageSize : bytes, hugePageSize);
    atomicStore(segmentSizeBytes, rounded);
}

/// ditto
extern (C) size_t tgc_getSegmentSize() nothrow @nogc
{
    return atomicLoad(segmentSizeBytes);
}

/**
 * Bytes of chunk storage currently backed by memory, allocated or not.
 *
 * Falls when a segment is unmapped, and when `GC.minimize()` hands back the
 * huge-page-aligned spans inside a segment that hold nothing.
 */
extern (C) size_t tgc_getCommittedBytes() nothrow @nogc
{
    return atomicLoad(committedBytes);
}

private struct Segment
{
    void* reserveBase;  /// what the OS is handed back; `base` may be inside it
    size_t reserveSize;
    void* base;         /// first chunk, aligned to `hugePageSize`
    size_t units;       /// chunks the segment holds
    size_t freeUnits;
    size_t* inUse;      /// one bit per unit
    size_t* dropped;    /// one bit per huge-page span handed back to the OS
    size_t decommittedUnits;
    size_t hint;        /// unit to resume the first-fit search from
    bool dedicated;     /// holds a single oversized run; released when freed

    void* unitAddr(size_t i) nothrow @nogc
    {
        return cast(void*)(cast(ubyte*) base + i * chunkSize);
    }

    bool contains(void* p) nothrow @nogc
    {
        return p >= base && p < cast(void*)(cast(ubyte*) base + units * chunkSize);
    }
}

private __gshared Segment** segTable; /// sorted by `base`, for lookup on free
private __gshared size_t segCount;
private __gshared size_t segCap;
private __gshared Segment* segMru;    /// last segment an allocation came from
private __gshared size_t segEmpty;    /// segments holding nothing
private __gshared SpinLock segLock;
private shared size_t committedBytes;

// -- platform mapping -------------------------------------------------------

version (Posix)
{
    import core.sys.posix.sys.mman : mmap, munmap, MAP_ANON, MAP_FAILED,
        MAP_PRIVATE, PROT_READ, PROT_WRITE;

    // `madvise` is not in core.sys.posix.sys.mman, and MADV_HUGEPAGE -- the
    // whole point of this allocator -- is Linux-specific, so both are declared
    // here rather than skipped.
    extern (C) int madvise(void* addr, size_t length, int advice) nothrow @nogc;

    version (linux)
    {
        private enum int MADV_HUGEPAGE = 14;
        private enum int MADV_DONTNEED = 4;
    }
    else version (Darwin)
    {
        private enum int MADV_FREE = 5;
    }
    else
    {
        private enum int MADV_DONTNEED = 4;
    }

    /**
     * Map `size` bytes aligned to `align_`, trimming the slack back to the OS.
     */
    private bool mapAligned(size_t size, size_t align_, out void* reserveBase,
                            out size_t reserveSize, out void* base) nothrow @nogc
    {
        immutable size_t over = size + align_;
        auto raw = mmap(null, over, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANON, -1, 0);
        if (raw is MAP_FAILED)
            return false;

        auto start = cast(ubyte*) raw;
        auto aligned = cast(ubyte*) alignUp(cast(size_t) start, align_);

        // Hand back the slack on both sides: a segment that keeps it would
        // leave unusable holes between segments and inflate the chunk
        // directory's span for nothing.
        immutable size_t head = aligned - start;
        if (head)
            munmap(raw, head);
        immutable size_t tail = over - head - size;
        if (tail)
            munmap(aligned + size, tail);

        reserveBase = aligned;
        reserveSize = size;
        base = aligned;

        version (linux)
            madvise(aligned, size, MADV_HUGEPAGE);

        return true;
    }

    private void unmapSegment(void* reserveBase, size_t reserveSize) nothrow @nogc
    {
        munmap(reserveBase, reserveSize);
    }

    /**
     * Hand the pages under `[p, p + size)` back to the OS, keeping the mapping.
     *
     * The memory reads as zero afterwards on Linux, and either as zero or as
     * its old contents on Darwin (`MADV_FREE` is lazy). Both are fine: a chunk
     * handed out again has its header and metadata rewritten, and payload is
     * only zeroed on request.
     */
    private void decommit(void* p, size_t size) nothrow @nogc
    {
        version (linux)
            madvise(p, size, MADV_DONTNEED);
        else version (Darwin)
            madvise(p, size, MADV_FREE);
        else
            madvise(p, size, MADV_DONTNEED);
    }

    private void recommit(void* p, size_t size) nothrow @nogc
    {
        // Nothing to do: the mapping never went away, so the next touch faults
        // a fresh page in. Re-advising huge pages is worth it on Linux, where
        // MADV_DONTNEED clears the flag for the range.
        version (linux)
            madvise(p, size, MADV_HUGEPAGE);
    }
}
else version (Windows)
{
    import core.sys.windows.winbase : VirtualAlloc, VirtualFree;
    import core.sys.windows.winnt : MEM_COMMIT, MEM_DECOMMIT, MEM_RELEASE,
        MEM_RESERVE, PAGE_READWRITE;

    /**
     * Reserve with slack and commit the aligned part.
     *
     * A reservation can only be released from its own base, so unlike the POSIX
     * path the slack stays reserved -- address space, not memory. Windows has
     * no transparent huge pages; large pages need `SeLockMemoryPrivilege`, so
     * this side gets the contiguity but not the TLB win.
     */
    private bool mapAligned(size_t size, size_t align_, out void* reserveBase,
                            out size_t reserveSize, out void* base) nothrow @nogc
    {
        immutable size_t over = size + align_;
        auto raw = VirtualAlloc(null, over, MEM_RESERVE, PAGE_READWRITE);
        if (raw is null)
            return false;

        auto aligned = cast(void*) alignUp(cast(size_t) raw, align_);
        if (VirtualAlloc(aligned, size, MEM_COMMIT, PAGE_READWRITE) is null)
        {
            VirtualFree(raw, 0, MEM_RELEASE);
            return false;
        }

        reserveBase = raw;
        reserveSize = over;
        base = aligned;
        return true;
    }

    private void unmapSegment(void* reserveBase, size_t reserveSize) nothrow @nogc
    {
        VirtualFree(reserveBase, 0, MEM_RELEASE);
    }

    private void decommit(void* p, size_t size) nothrow @nogc
    {
        VirtualFree(p, size, MEM_DECOMMIT);
    }

    private void recommit(void* p, size_t size) nothrow @nogc
    {
        // Unlike POSIX this is mandatory: a decommitted page faults on access.
        VirtualAlloc(p, size, MEM_COMMIT, PAGE_READWRITE);
    }
}
else
{
    static assert(false, "tgc: no segment mapping for this platform");
}

// -- segment table ----------------------------------------------------------

/// Index of the segment containing `p`, or `segCount`. Called under `segLock`.
private size_t segIndexOf(void* p) nothrow @nogc
{
    size_t lo = 0, hi = segCount;
    while (lo < hi)
    {
        immutable size_t mid = lo + (hi - lo) / 2;
        if (segTable[mid].base > p)
            hi = mid;
        else
            lo = mid + 1;
    }
    if (lo == 0)
        return segCount;
    return segTable[lo - 1].contains(p) ? lo - 1 : segCount;
}

private void segTableInsert(Segment* s) nothrow @nogc
{
    if (segCount == segCap)
    {
        size_t ncap = segCap ? segCap * 2 : 16;
        auto np = cast(Segment**) cstdlib.realloc(segTable, ncap * (Segment*).sizeof);
        if (!np)
            onOutOfMemoryError();
        segTable = np;
        segCap = ncap;
    }

    size_t i = segCount;
    while (i > 0 && segTable[i - 1].base > s.base)
    {
        segTable[i] = segTable[i - 1];
        i--;
    }
    segTable[i] = s;
    segCount++;
}

private void segTableRemove(size_t idx) nothrow @nogc
{
    foreach (i; idx .. segCount - 1)
        segTable[i] = segTable[i + 1];
    segCount--;
}

/// First run of `n` free units at or after `from`, or `size_t.max`.
private size_t segScan(Segment* s, size_t from, size_t n) nothrow @nogc
{
    size_t i = from;
    while (i + n <= s.units)
    {
        if (testBit(s.inUse, i))
        {
            i++;
            continue;
        }
        size_t j = 1;
        while (j < n && !testBit(s.inUse, i + j))
            j++;
        if (j == n)
            return i;
        i += j + 1; // the unit at i + j is taken; nothing before it can start a run
    }
    return size_t.max;
}

/**
 * First run of `n` free units in `s`, or `size_t.max`.
 *
 * Resumes from a hint rather than rescanning from unit zero, which matters once
 * a segment is mostly full: allocation is otherwise linear in the segment.
 */
private size_t segFindRun(Segment* s, size_t n) nothrow @nogc
{
    if (s.freeUnits < n)
        return size_t.max;

    immutable size_t at = segScan(s, s.hint, n);
    if (at != size_t.max)
        return at;
    return s.hint == 0 ? size_t.max : segScan(s, 0, n);
}

private Segment* segCreate(size_t bytes, bool dedicated) nothrow @nogc
{
    immutable size_t size = alignUp(bytes, hugePageSize);

    auto s = cast(Segment*) cstdlib.calloc(1, Segment.sizeof);
    if (!s)
        onOutOfMemoryError();

    if (!mapAligned(size, hugePageSize, s.reserveBase, s.reserveSize, s.base))
    {
        cstdlib.free(s);
        return null;
    }

    s.units = size / chunkSize;
    s.freeUnits = s.units;
    s.dedicated = dedicated;
    s.inUse = cast(size_t*) cstdlib.calloc(bitWords(s.units), size_t.sizeof);
    s.dropped = cast(size_t*) cstdlib.calloc(bitWords(s.units / unitsPerSpan + 1), size_t.sizeof);
    if (!s.inUse || !s.dropped)
    {
        cstdlib.free(s.inUse);
        cstdlib.free(s.dropped);
        unmapSegment(s.reserveBase, s.reserveSize);
        cstdlib.free(s);
        onOutOfMemoryError();
    }

    segTableInsert(s);
    segEmpty++;
    atomicOp!"+="(committedBytes, size);
    return s;
}

private void segDestroy(size_t idx) nothrow @nogc
{
    auto s = segTable[idx];
    segTableRemove(idx);
    if (segMru is s)
        segMru = null;
    segEmpty--;
    atomicOp!"-="(committedBytes, (s.units - s.decommittedUnits) * chunkSize);
    cstdlib.free(s.inUse);
    cstdlib.free(s.dropped);
    unmapSegment(s.reserveBase, s.reserveSize);
    cstdlib.free(s);
}

/// Units in one huge-page span, the granularity memory is handed back at.
private enum size_t unitsPerSpan = hugePageSize / chunkSize;

private void* segTake(Segment* s, size_t at, size_t n) nothrow @nogc
{
    // Take back anything `segDropFree` handed to the OS under these units.
    immutable size_t firstSpan = at / unitsPerSpan;
    immutable size_t lastSpan = (at + n - 1) / unitsPerSpan;
    foreach (span; firstSpan .. lastSpan + 1)
    {
        if (!testBit(s.dropped, span))
            continue;
        recommit(cast(void*)(cast(ubyte*) s.base + span * hugePageSize), hugePageSize);
        clearBit(s.dropped, span);
        s.decommittedUnits -= unitsPerSpan;
        atomicOp!"+="(committedBytes, hugePageSize);
    }

    foreach (k; 0 .. n)
        setBit(s.inUse, at + k);
    if (s.freeUnits == s.units)
        segEmpty--;
    s.freeUnits -= n;
    s.hint = at + n;
    return s.unitAddr(at);
}

// -- the interface the heap uses --------------------------------------------

private void* chunkAlloc(size_t bytes) nothrow @nogc
{
    assert(bytes % chunkSize == 0, "tgc: chunk requests are whole chunks");
    immutable size_t n = bytes / chunkSize;

    segLock.lock(); tsanAcquire(cast(const(void)*) &segLock);
    scope (exit)
    {
        tsanRelease(cast(const(void)*) &segLock);
        segLock.unlock();
    }

    // A run larger than a segment gets its own mapping, sized to it.
    if (bytes > atomicLoad(segmentSizeBytes))
    {
        auto s = segCreate(bytes, true);
        if (!s)
            return null;
        return segTake(s, 0, n);
    }

    if (segMru !is null)
    {
        immutable size_t at = segFindRun(segMru, n);
        if (at != size_t.max)
            return segTake(segMru, at, n);
    }

    foreach (i; 0 .. segCount)
    {
        auto s = segTable[i];
        if (s.dedicated || s is segMru)
            continue;
        immutable size_t at = segFindRun(s, n);
        if (at != size_t.max)
        {
            segMru = s;
            return segTake(s, at, n);
        }
    }

    auto s = segCreate(atomicLoad(segmentSizeBytes), false);
    if (!s)
        return null;
    segMru = s;
    return segTake(s, 0, n);
}

/**
 * Unmap every segment holding nothing.
 *
 * The automatic path keeps empty segments back, because unmapping memory a
 * growing heap is about to ask for again is how the page-fault cost this
 * allocator removes comes straight back. `GC.minimize()` is the documented
 * "give it back now" call, so that is where the retained set is dropped.
 */
/**
 * Hand back every huge-page span of `s` that holds no allocated chunk.
 *
 * Whole spans only. Decommitting part of one would split the huge page backing
 * it, which is the property this allocator exists to get, so a segment with a
 * live chunk every 2 MB gives nothing back -- and that is the right answer, not
 * a bug: the pages are still in use.
 */
private void segDropFree(Segment* s) nothrow @nogc
{
    for (size_t i = 0; i + unitsPerSpan <= s.units; i += unitsPerSpan)
    {
        immutable size_t span = i / unitsPerSpan;
        if (testBit(s.dropped, span))
            continue;

        bool free = true;
        foreach (k; 0 .. unitsPerSpan)
            if (testBit(s.inUse, i + k))
            {
                free = false;
                break;
            }
        if (!free)
            continue;

        decommit(cast(void*)(cast(ubyte*) s.base + span * hugePageSize), hugePageSize);
        setBit(s.dropped, span);
        s.decommittedUnits += unitsPerSpan;
        atomicOp!"-="(committedBytes, hugePageSize);
    }
}

private void segReleaseEmpty() nothrow @nogc
{
    segLock.lock(); tsanAcquire(cast(const(void)*) &segLock);
    scope (exit)
    {
        tsanRelease(cast(const(void)*) &segLock);
        segLock.unlock();
    }

    size_t i = segCount;
    while (i > 0)
    {
        i--;
        if (segTable[i].freeUnits == segTable[i].units)
            segDestroy(i);
        else
            segDropFree(segTable[i]);
    }
}

private void chunkFree(void* p, size_t bytes) nothrow @nogc
{
    immutable size_t n = bytes / chunkSize;

    segLock.lock(); tsanAcquire(cast(const(void)*) &segLock);
    scope (exit)
    {
        tsanRelease(cast(const(void)*) &segLock);
        segLock.unlock();
    }

    immutable size_t idx = segIndexOf(p);
    assert(idx < segCount, "tgc: freeing a chunk that came from no segment");
    auto s = segTable[idx];

    immutable size_t at = (cast(ubyte*) p - cast(ubyte*) s.base) / chunkSize;
    foreach (k; 0 .. n)
        clearBit(s.inUse, at + k);
    s.freeUnits += n;
    if (at < s.hint)
        s.hint = at;

    if (s.freeUnits != s.units)
        return;

    segEmpty++;
    // Empty segments are kept back rather than unmapped on the spot. A heap
    // that oscillates -- which is every heap, between collections -- would
    // otherwise unmap memory and immediately fault it back in, and re-faulting
    // is the cost this allocator exists to avoid: it took binary-trees from
    // 926,000 page faults to 112,000. Waste is bounded to a quarter of what is
    // mapped, plus one segment so that a small program still keeps one.
    if (s.dedicated || segEmpty > 2 + segCount / 2)
        segDestroy(idx);
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
    uint nextFree;   /// where to resume searching allocBits for a free slot

    uint slotSize;
    uint slotCount;
    uint freeCount;
    uint cls;        /// size-class index, or uint.max for a large run

    size_t runChunks; /// chunks spanned (large runs only; 1 for small chunks)
    size_t largeSize; /// payload capacity of the single slot in a large run
    Region* region;   /// owning region, or null when owned by the thread heap

    bool inPartial;
    /// Any slot in this chunk has been given a finalizer. Sticky, and only ever
    /// a hint: it lets the sweep take the bulk path for chunks that hold no
    /// destructors at all, which is most of them.
    bool hasFinal;

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

    void setAttrOf(size_t i, uint a) nothrow @nogc
    {
        attrs[i] = cast(ubyte)(a & keptAttrs);
        if (a & (BlkAttr.FINALIZE | BlkAttr.STRUCTFINAL))
            hasFinal = true;
    }

    /**
     * Index of the first unallocated slot at or after `from`; `slotCount` when
     * the chunk is full.
     *
     * Allocation used to pop an intrusive free list threaded through the free
     * slots themselves, which meant every free wrote into the dead object's
     * memory — cold, and the single hottest operation in the collector under
     * profiling. The allocation bitmap already records the same information
     * and is dense, so a free is now just a cleared bit and nothing touches
     * the payload.
     */
    size_t firstFree(size_t from) const nothrow @nogc
    {
        immutable size_t words = bitWords(slotCount);
        size_t w = from / bitsPerWord;
        if (w >= words)
            return slotCount;

        size_t bits = ~allocBits[w];
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
            bits = ~allocBits[w];
        }
    }

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
// chunk directory: address unit -> owning chunk, two-level and address-indexed
// ---------------------------------------------------------------------------

/// log2(chunkSize), so an address becomes a chunk-unit index by shifting.
private enum size_t chunkShift = 16;
static assert((cast(size_t) 1 << chunkShift) == chunkSize);

/// Units covered by one second-level table: 4096 x 64 KiB = 256 MB, in 16 KiB.
private enum size_t dirL2Bits = 12;
private enum size_t dirL2Count = cast(size_t) 1 << dirL2Bits;
private enum size_t dirL2Mask = dirL2Count - 1;

/**
 * Ceiling on the first-level table, which spans the lowest and highest chunk
 * addresses the heap holds.
 *
 * 2^20 entries cover 256 TB, more than the 128 TB of user address space either
 * supported platform hands out, so this is unreachable rather than a policy.
 */
private enum size_t dirL1MaxLen = cast(size_t) 1 << 20;

/**
 * Per-heap map from a chunk-sized address unit to the `Chunk` that owns it.
 *
 * Deliberately per-heap rather than global: a thread only ever marks its own
 * blocks, so the hot `markPtr` lookup needs no lock at all.
 *
 * This was an open-addressed hash table, and after `markPtr` itself it was the
 * most expensive thing in the collector. Every candidate word scanned -- most of
 * which are not pointers at all -- paid a 64-bit mixer and then a random probe
 * into a table that at a 74 MB live set is exactly L1-sized. Marking a tree
 * therefore missed cache on the *metadata* before it ever touched the object.
 *
 * Indexing by address instead of hashing it gives two things. A candidate
 * outside [loAddr, hiAddr) is rejected in two compares without touching memory
 * at all, which is the common case for stack and TLS words. And chunks adjacent
 * in memory -- what a tree walk actually touches -- land on adjacent entries, so
 * the directory streams like an array instead of thrashing like a hash.
 *
 * An entry is a `uint`, not a `Chunk*`, because a chunk's header lives at its
 * own base: for the head unit of a run the chunk pointer *is* the masked
 * address, and for every following unit it is that many units back. That halves
 * the table and removes the second dependent load a hash map needs (key, then
 * value).
 *
 * A second-level table costs 16 KiB and covers 256 MB of address space, so a
 * heap whose chunks cluster -- which is what an aligned allocator gives -- needs
 * one or two. A heap whose chunks were scattered one per 256 MB region would pay
 * 16 KiB per chunk, which is the structure's worst case and not one any
 * allocator produces.
 */
private struct ChunkDir
{
    uint** l1;      /// second-level tables for blocks [l1Base, l1Base + l1Len)
    size_t l1Base;
    size_t l1Len;

    size_t len;     /// live units, so an empty directory short-circuits
    void* loAddr;   /// lowest mapped chunk base
    void* hiAddr;   /// one past the highest mapped chunk

    /// Last second-level table used. One block covers 256 MB, so unlike a
    /// one-entry *chunk* cache (measured: 48% hits, not worth its bookkeeping)
    /// this one is hit by essentially every lookup of a heap under 256 MB.
    size_t lastBlk = size_t.max;
    uint* lastTab;

    /**
     * Second-level table holding `unit`, allocating the path to it when
     * `create` is set.
     */
    private uint* tableFor(size_t unit, bool create) nothrow @nogc
    {
        immutable size_t blk = unit >> dirL2Bits;
        if (blk == lastBlk && lastTab !is null)
            return lastTab;

        if (l1Len == 0)
        {
            if (!create)
                return null;
            l1 = cast(uint**) cstdlib.calloc(8, (uint*).sizeof);
            if (!l1)
                onOutOfMemoryError();
            l1Base = blk;
            l1Len = 8;
        }
        else if (blk < l1Base || blk - l1Base >= l1Len)
        {
            if (!create)
                return null;
            growToCover(blk);
        }

        auto slot = &l1[blk - l1Base];
        if (*slot is null)
        {
            if (!create)
                return null;
            *slot = cast(uint*) cstdlib.calloc(dirL2Count, uint.sizeof);
            if (!*slot)
                onOutOfMemoryError();
        }

        lastBlk = blk;
        lastTab = *slot;
        return *slot;
    }

    /// Widen the first-level table so it covers `blk`, keeping existing entries.
    private void growToCover(size_t blk) nothrow @nogc
    {
        size_t nbase = blk < l1Base ? blk : l1Base;
        size_t ntop = blk + 1 > l1Base + l1Len ? blk + 1 : l1Base + l1Len;
        size_t nlen = ntop - nbase;

        // Round up so a heap that grows in one direction does not realloc per
        // chunk, and keep some slack on the low side for the same reason.
        size_t slack = nlen >> 1;
        if (slack < 8)
            slack = 8;
        if (nbase < l1Base) // grew downward
            nbase = nbase > slack ? nbase - slack : 0;
        nlen = ntop + slack - nbase;

        assert(nlen <= dirL1MaxLen, "tgc: chunk directory span exceeds the address space");

        auto nl1 = cast(uint**) cstdlib.calloc(nlen, (uint*).sizeof);
        if (!nl1)
            onOutOfMemoryError();
        foreach (i; 0 .. l1Len)
            nl1[l1Base - nbase + i] = l1[i];

        cstdlib.free(l1);
        l1 = nl1;
        l1Base = nbase;
        l1Len = nlen;
        lastBlk = size_t.max; // the slot moved
        lastTab = null;
    }

    void put(void* base, Chunk* c) nothrow @nogc
    {
        immutable size_t unit = cast(size_t) base >> chunkShift;
        immutable size_t head = cast(size_t) c >> chunkShift;
        assert(unit >= head, "tgc: chunk unit precedes its run head");
        assert(unit - head < uint.max, "tgc: chunk run longer than the tag can encode");

        auto t = tableFor(unit, true);
        auto e = &t[unit & dirL2Mask];
        if (*e == 0)
            len++;
        *e = cast(uint)(unit - head + 1);

        if (loAddr is null || base < loAddr)
            loAddr = base;
        auto end = cast(void*)((unit + 1) << chunkShift);
        if (end > hiAddr)
            hiAddr = end;
    }

    /**
     * The chunk owning `p`, or null.
     *
     * Takes an interior pointer, not a chunk base: the unit index is a shift, so
     * masking first would only throw away bits this already ignores.
     */
    Chunk* get(void* p) nothrow @nogc
    {
        if (len == 0 || p < loAddr || p >= hiAddr)
            return null;

        immutable size_t unit = cast(size_t) p >> chunkShift;
        auto t = tableFor(unit, false);
        if (t is null)
            return null;
        immutable uint tag = t[unit & dirL2Mask];
        if (tag == 0)
            return null;
        return cast(Chunk*)((unit - (tag - 1)) << chunkShift);
    }

    void remove(void* base) nothrow @nogc
    {
        if (len == 0)
            return;
        immutable size_t unit = cast(size_t) base >> chunkShift;
        auto t = tableFor(unit, false);
        if (t is null)
            return;
        auto e = &t[unit & dirL2Mask];
        if (*e != 0)
        {
            *e = 0;
            len--;
        }
    }

    /// Drop every entry but keep the tables, for repeated rebuilds.
    void clearEntries() nothrow @nogc
    {
        foreach (i; 0 .. l1Len)
            if (l1[i] !is null)
                memset(l1[i], 0, dirL2Count * uint.sizeof);
        len = 0;
        loAddr = null;
        hiAddr = null;
    }

    void destroy() nothrow @nogc
    {
        foreach (i; 0 .. l1Len)
            cstdlib.free(l1[i]);
        cstdlib.free(l1);
        l1 = null;
        l1Base = l1Len = len = 0;
        loAddr = hiAddr = null;
        lastBlk = size_t.max;
        lastTab = null;
    }
}

// ---------------------------------------------------------------------------
// regions
// ---------------------------------------------------------------------------

/**
 * A request-scoped arena bound to one fiber.
 *
 * Everything allocated while the region is current comes from chunks the region
 * owns exclusively, and at `end` the whole set is released without tracing.
 * This is the BEAM model -- a process dies and its heap goes with it -- and it
 * carries BEAM's precondition: nothing outside may still point in. BEAM enforces
 * that by deep-copying every message; D cannot, so it is the caller's
 * invariant, checkable with `tgcRegionVerify`.
 *
 * Region chunks are never swept by a thread-local collection: everything in a
 * region stays live until the region ends, which is the whole point. They are
 * still *marked through*, because a region object may be the only thing keeping
 * a thread-heap object alive.
 */
private struct Region
{
    ThreadHeap* owner;
    StackContext* ctx;      /// the fiber this region is bound to
    Region* next;           /// in the owner's region list

    Chunk* chunks;
    Chunk*[numClasses] partial;
    size_t usedBytes;
    size_t reservedBytes;
}

/// Non-zero while any region exists, so the allocation fast path can skip the
/// per-allocation context lookup entirely when regions are not in use.
private shared int activeRegions;

private shared bool regionVerify;

// ---------------------------------------------------------------------------
// mark worklist
// ---------------------------------------------------------------------------

private struct MarkItem
{
    void* base;
    size_t size;
    /// Pointer bitmap from TypeInfo.rtInfo, or null to scan conservatively.
    const(size_t)* bitmap;
    /// Words per bitmap repeat. Zero means conservative.
    size_t elemWords;
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
    ChunkDir map;
    Chunk* allChunks;
    Chunk*[numClasses] partial;

    /// Regions currently open on this thread, and a one-entry cache so the
    /// allocation path resolves the running fiber's region with a pointer
    /// compare rather than a list walk.
    Region* regions;
    StackContext* cachedCtx;
    Region* cachedRegion;

    /// Set while verifying a region: markPtr records the first inbound hit.
    Region* verifyRegion;
    void* verifyHit;

    /**
     * One-entry memo for `layoutOf`.
     *
     * Resolving a block's pointer map means a virtual call into
     * `TypeInfo.rtInfo` and two cold loads, paid once per marked object. Types
     * repeat heavily inside one heap -- often there is only one hot one -- so
     * remembering the last answer removes nearly all of it. Cleared at the
     * start of every collection, so a change to `preciseScanning` between two
     * of them cannot be missed.
     */
    TypeInfo memoTi;
    bool memoAppendable;
    bool memoScan;
    const(size_t)* memoBitmap;
    size_t memoElemWords;

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
        h.collectThreshold = atomicLoad(minHeapSize);
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

    /// `layoutOf` through the memo above.
    bool layoutCached(TypeInfo ti, uint attr, out const(size_t)* bitmap,
                      out size_t elemWords) nothrow
    {
        immutable bool app = (attr & BlkAttr.APPENDABLE) != 0;
        if (ti !is null && ti is memoTi && app == memoAppendable)
        {
            bitmap = memoBitmap;
            elemWords = memoElemWords;
            return memoScan;
        }

        immutable bool scan = layoutOf(ti, attr, bitmap, elemWords);
        if (ti !is null)
        {
            memoTi = ti;
            memoAppendable = app;
            memoScan = scan;
            memoBitmap = bitmap;
            memoElemWords = elemWords;
        }
        return scan;
    }

    // -- chunk lifecycle ----------------------------------------------------

    Chunk* newSmallChunk(uint cls, Region* region) nothrow @nogc
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
        c.nextFree = 0;
        c.cls = cls;
        c.runChunks = units;
        c.region = region;

        // One wipe covers the bitvectors, the attribute bytes and the metadata.
        memset(cast(ubyte*) raw + bitsOff, 0, dataOff - bitsOff);

        // Registered in the thread's map either way, so a pointer into a
        // region block still resolves through the ordinary lookup path.
        foreach (i; 0 .. units)
            map.put(cast(void*)(cast(ubyte*) raw + i * chunkSize), c);
        linkAll(c);
        linkPartial(c);
        if (region !is null)
            region.reservedBytes += bytes;
        else
            reservedBytes += bytes;
        return c;
    }

    Chunk* newLargeChunk(size_t size, Region* region) nothrow @nogc
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
        c.region = region;
        // The request, not the whole rounded-up run. Reporting the run made a
        // 9000-byte allocation look like 65408 bytes, and every collection
        // scanned -- and every allocation zeroed -- all of it.
        c.largeSize = alignUp(size, payloadAlign);

        // Every chunk base in the run resolves back to the head, so an
        // interior pointer anywhere in a large object is one probe away.
        foreach (i; 0 .. runChunks)
            map.put(cast(void*)(cast(ubyte*) raw + i * chunkSize), c);

        linkAll(c);
        if (region !is null)
            region.reservedBytes += runChunks * chunkSize;
        else
            reservedBytes += runChunks * chunkSize;
        return c;
    }

    void releaseChunk(Chunk* c) nothrow @nogc
    {
        unlinkPartial(c);
        unlinkAll(c);
        // Read the run length before the memory goes back: the header lives in
        // the first chunk of the run.
        immutable size_t bytes = c.runChunks * chunkSize;
        auto raw = cast(ubyte*) c;
        foreach (i; 0 .. c.runChunks)
            map.remove(cast(void*)(raw + i * chunkSize));
        if (c.region !is null)
            c.region.reservedBytes -= bytes;
        else
            reservedBytes -= bytes;
        chunkFree(raw, bytes);
    }

    void linkAll(Chunk* c) nothrow @nogc
    {
        auto head = c.region !is null ? &c.region.chunks : &allChunks;
        c.prevAll = null;
        c.nextAll = *head;
        if (*head)
            (*head).prevAll = c;
        *head = c;
    }

    void unlinkAll(Chunk* c) nothrow @nogc
    {
        auto head = c.region !is null ? &c.region.chunks : &allChunks;
        if (c.prevAll)
            c.prevAll.nextAll = c.nextAll;
        else
            *head = c.nextAll;
        if (c.nextAll)
            c.nextAll.prevAll = c.prevAll;
        c.nextAll = c.prevAll = null;
    }

    void linkPartial(Chunk* c) nothrow @nogc
    {
        if (c.inPartial || c.isLarge())
            return;
        auto head = c.region !is null ? &c.region.partial[c.cls] : &partial[c.cls];
        c.prevPartial = null;
        c.nextPartial = *head;
        if (*head)
            (*head).prevPartial = c;
        *head = c;
        c.inPartial = true;
    }

    void unlinkPartial(Chunk* c) nothrow @nogc
    {
        if (!c.inPartial)
            return;
        auto head = c.region !is null ? &c.region.partial[c.cls] : &partial[c.cls];
        if (c.prevPartial)
            c.prevPartial.nextPartial = c.nextPartial;
        else
            *head = c.nextPartial;
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

        auto c = map.get(p);
        if (!c)
        {
            // A one-past-the-end pointer can land on the first byte of the
            // following chunk, which may not be ours -- but only when it is
            // exactly on a chunk boundary. Anywhere else `p` and `p - 1` are in
            // the same chunk, so retrying unconditionally (as this did) paid a
            // second probe for every candidate word that is not a pointer at
            // all, which is most of them.
            if (!acceptEnd || (cast(size_t) p & (chunkSize - 1)) != 0)
                return BlkRef.init;
            c = map.get(cast(void*)(cast(size_t) p - 1));
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
        // A small chunk run is at most 256 KB, so the offset fits in 32 bits
        // and the division is half the latency of a 64-bit one on x86-64. A
        // multiply-by-reciprocal was tried here and measured *slower* on
        // arm64; see IMPROVEMENTS.md.
        immutable uint off32 = cast(uint) off;
        immutable uint idx32 = off32 / c.slotSize;
        size_t idx = idx32;
        immutable size_t rem = off32 - idx32 * c.slotSize;

        if (idx >= c.slotCount)
        {
            if (!acceptEnd || idx != c.slotCount || rem != 0)
                return BlkRef.init;
            idx = c.slotCount - 1; // exactly one past the final slot
        }
        else if (acceptEnd && rem == 0 && idx > 0 && !c.isAllocated(idx))
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

    BlkRef allocSlot(size_t size, Region* region) nothrow @nogc
    {
        // Allocate black while a collection is in flight. A finalizer running
        // during the sweep may allocate, and it can be handed a slot from the
        // very chunk being swept — at an index the sweep has not reached yet.
        // Without the mark bit the sweep would see it allocated-and-unmarked
        // and immediately free the object that was just handed out.
        immutable bool birthMarked = collecting || finalizing;

        if (size > maxSmall)
        {
            auto c = newLargeChunk(size, region);
            c.setAllocated(0);
            if (birthMarked)
                c.setMarked(0);
            if (region !is null)
                region.usedBytes += c.largeSize;
            else
                usedBytes += c.largeSize;
            return BlkRef(c, 0);
        }

        immutable uint cls = classOf(size ? size : 1);
        auto c = region !is null ? region.partial[cls] : partial[cls];
        if (!c)
            c = newSmallChunk(cls, region);

        size_t idx = c.firstFree(c.nextFree);
        assert(idx < c.slotCount, "tgc: partial chunk has no free slot");
        c.nextFree = cast(uint)(idx + 1);
        c.freeCount--;
        if (c.freeCount == 0)
            unlinkPartial(c);

        c.setAllocated(idx);
        if (birthMarked)
            c.setMarked(idx);
        if (region !is null)
            region.usedBytes += c.slotSize;
        else
            usedBytes += c.slotSize;
        return BlkRef(c, idx);
    }

    /**
     * Release one slot.
     *
     * The slot's `SlotMeta` and attribute byte are deliberately left as they
     * are. `alloc` writes both on every slot it hands out, and nothing reads
     * either for a slot that is not allocated -- `lookup` rejects those before
     * any caller sees them. Clearing them here cost a 16-byte store and a byte
     * store on cold lines for every dead object, which on binary-trees made
     * this the most expensive routine in the collector on arm64.
     */
    void freeSlot(BlkRef b) nothrow @nogc
    {
        auto c = b.chunk;
        c.clearAllocated(b.idx);
        c.clearShared(b.idx);

        if (c.isLarge())
        {
            if (c.region !is null)
                c.region.usedBytes -= c.largeSize;
            else
                usedBytes -= c.largeSize;
            releaseChunk(c);
            return;
        }

        if (b.idx < c.nextFree)
            c.nextFree = cast(uint) b.idx;
        c.freeCount++;
        if (c.region !is null)
            c.region.usedBytes -= c.slotSize;
        else
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

    /**
     * Reclaim every dead slot in a chunk with word-at-a-time bit operations.
     *
     * Applies to a chunk that holds no finalizable slot, which is the common
     * case: with no destructor to run, reclaiming a slot is exactly clearing
     * its allocation bit, and 64 of those clear in one AND. The per-slot path
     * additionally walked the bitmap once per dead object, updated the partial
     * list per object and touched two cold metadata lines per object.
     */
    void sweepChunkBulk(Chunk* c) nothrow @nogc
    {
        import core.bitop : bsf, popcnt;

        immutable size_t words = bitWords(c.slotCount);
        size_t freed = 0;
        size_t firstDead = size_t.max;

        foreach (w; 0 .. words)
        {
            // Promoted slots are excluded, exactly as nextReclaimable does:
            // only a global collection can prove no other thread holds them.
            immutable size_t dead = c.allocBits[w] & ~c.markBits[w] & ~c.sharedBits[w];
            if (!dead)
                continue;
            c.allocBits[w] &= ~dead;
            freed += popcnt(dead);
            if (firstDead == size_t.max)
                firstDead = w * bitsPerWord + bsf(dead);
        }

        if (freed == 0)
            return;

        c.freeCount += cast(uint) freed;
        if (firstDead < c.nextFree)
            c.nextFree = cast(uint) firstDead;
        immutable size_t bytes = freed * c.slotSize;
        if (c.region !is null)
            c.region.usedBytes -= bytes;
        else
            usedBytes -= bytes;
        linkPartial(c);
    }

    // -- mark worklist ------------------------------------------------------

    void pushMark(void* base, size_t size, const(size_t)* bitmap = null,
                  size_t elemWords = 0) nothrow @nogc
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
        markStack[markLen++] = MarkItem(base, size, bitmap, elemWords);
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
    heapsLock.lock(); tsanAcquire(cast(const(void)*) &heapsLock);
    if (allHeapsLen == allHeapsCap)
    {
        size_t ncap = allHeapsCap ? allHeapsCap * 2 : 8;
        auto np = cast(ThreadHeap**) cstdlib.realloc(allHeaps.ptr, ncap * (ThreadHeap*).sizeof);
        if (!np)
        {
            tsanRelease(cast(const(void)*) &heapsLock); heapsLock.unlock();
            onOutOfMemoryError();
        }
        allHeaps = np[0 .. ncap];
        allHeapsCap = ncap;
    }
    allHeaps[allHeapsLen++] = h;
    tsanRelease(cast(const(void)*) &heapsLock); heapsLock.unlock();
}

private void unregisterHeap(ThreadHeap* h) nothrow @nogc
{
    heapsLock.lock(); tsanAcquire(cast(const(void)*) &heapsLock);
    foreach (i; 0 .. allHeapsLen)
    {
        if (allHeaps[i] is h)
        {
            allHeaps[i] = allHeaps[allHeapsLen - 1];
            allHeapsLen--;
            break;
        }
    }
    tsanRelease(cast(const(void)*) &heapsLock); heapsLock.unlock();
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

    orphanLock.lock(); tsanAcquire(cast(const(void)*) &orphanLock);

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
    tsanRelease(cast(const(void)*) &orphanLock); orphanLock.unlock();
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
private __gshared ChunkDir globalMap;
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

@conservativeScanAddr @conservativeScanThread
private void markPtrGlobal(void* p) nothrow
{
    if (!p)
        return;
    auto c = globalMap.get(p);
    if (!c)
    {
        // Only a chunk-aligned candidate can be one past the end of a block in
        // the preceding chunk; see ThreadHeap.lookup.
        if ((cast(size_t) p & (chunkSize - 1)) != 0)
            return;
        c = globalMap.get(cast(void*)(cast(size_t) p - 1));
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
        immutable uint off32 = cast(uint) off;
        immutable uint idx32 = off32 / c.slotSize;
        idx = idx32;
        immutable size_t rem = off32 - idx32 * c.slotSize;
        if (idx >= c.slotCount)
        {
            if (idx != c.slotCount || rem != 0)
                return;
            idx = c.slotCount - 1;
        }
        else if (rem == 0 && idx > 0
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

@conservativeScanAddr @conservativeScanThread
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

@conservativeScanAddr @conservativeScanThread
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
    heapsLock.lock(); tsanAcquire(cast(const(void)*) &heapsLock);
    scope (exit)
    {
        tsanRelease(cast(const(void)*) &heapsLock);
        heapsLock.unlock();
    }

    // The world is stopped for MARKING ONLY. Sweeping here would be unsafe:
    // running a finalizer with threads suspended can block on a lock one of
    // them holds, and freeing into a live thread's heap races that thread the
    // moment it resumes. druntime's own collector resumes before sweeping for
    // the same reason.
    {
        thread_suspendAll();
        scope (exit)
            thread_resumeAll();

        // Every access below is protected by the other threads being
        // suspended, which is a signal handshake ThreadSanitizer cannot model
        // as synchronisation -- it sees only unsynchronised accesses to memory
        // other threads touched. Ignoring this window is the documented way to
        // express "these are safe for a reason the tool cannot observe".
        tsanIgnoreBegin();
        scope (exit)
            tsanIgnoreEnd();

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
    // `sweepOrphanHeap` publishes the new retained total itself, atomically and
    // under `orphanLock`. Re-deriving it here was both redundant and a plain
    // store to a `shared` variable other threads read -- ThreadSanitizer caught
    // it racing `adoptOrphanChunks`.
    sweepOrphanHeap();
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
    orphanLock.lock(); tsanAcquire(cast(const(void)*) &orphanLock);
    scope (exit)
    {
        tsanRelease(cast(const(void)*) &orphanLock);
        orphanLock.unlock();
    }

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

/**
 * Open a region bound to the running fiber.
 *
 * Returns null if this fiber already has one; regions do not nest, because a
 * nested region's blocks would be freed while the outer one still ran.
 */
/**
 * Assert that nothing outside a region still points into it.
 *
 * This is the invariant a region rests on and the one D cannot check
 * statically: BEAM can free a dead process's heap because every message was
 * deep-copied on send, and nothing here copies. So the check is dynamic and
 * costs a full mark of the thread's own roots, which is why it is off unless
 * asked for. Turn it on in tests.
 *
 * Scans this thread's stacks, TLS and the global root tables, following
 * everything reachable *outside* the region, and reports the first reference
 * found into it. References from inside the region outward are fine and
 * expected; only inbound ones are a bug.
 */
private void verifyRegionUnreferenced(ThreadHeap* heap, Region* reg) nothrow
{
    // Mark from every root *except* the region's own fiber stack. That stack
    // legitimately holds references to region blocks while the region is still
    // running -- the locals in the very frame calling this. Everywhere else is
    // fair game: globals, TLS, the thread's own stack, and other fibers.
    for (auto c = heap.allChunks; c; c = c.nextAll)
        c.clearMarks();
    for (auto r = heap.regions; r; r = r.next)
        for (auto c = r.chunks; c; c = c.nextAll)
            c.clearMarks();

    heap.markLen = 0;
    heap.memoTi = null;
    heap.verifyRegion = reg;
    heap.verifyHit = null;

    auto gc = cast(ThreadGC) gc_instance;
    if (gc is null)
        return;

    auto cur = currentStackContext(ThreadBase.getThis());

    // Contexts the running one is nested inside: the thread's own stack.
    for (auto c = (cur !is null ? cur.within : null); c; c = c.within)
        gc.markStackSpan(heap, c.tstack, c.bstack);

    // Other fibers this thread owns.
    immutable size_t n = gc.snapshotOwnedContexts(heap, cur);
    foreach (i; 0 .. n)
        gc.markStackSpan(heap, heap.stackSnap[i].pbot, heap.stackSnap[i].ptop);

    gc.markTLS(heap);
    gc.markRootsAndRanges(heap);
    gc.drainMarkStack(heap);

    auto hit = heap.verifyHit;
    heap.verifyRegion = null;
    heap.verifyHit = null;

    assert(hit is null,
        "tgc: a region block is still referenced from outside the region. " ~
        "Anything that must outlive the region has to be copied out of it.");
}

extern (C) void* tgc_beginRegion() nothrow
{
    auto t = ThreadBase.getThis();
    if (t is null)
        return null;
    auto ctx = currentStackContext(t);
    if (ctx is null)
        return null;

    auto heap = currentHeap();
    for (auto r = heap.regions; r; r = r.next)
        if (r.ctx is ctx)
            return null; // already open on this fiber

    auto reg = cast(Region*) cstdlib.calloc(1, Region.sizeof);
    if (!reg)
        onOutOfMemoryError();
    reg.owner = heap;
    reg.ctx = ctx;
    reg.next = heap.regions;
    heap.regions = reg;

    heap.cachedCtx = null;   // invalidate the routing cache
    heap.cachedRegion = null;
    atomicOp!"+="(activeRegions, 1);
    return reg;
}

/**
 * Close a region, releasing everything allocated in it without tracing.
 *
 * Finalizers run first, by walking the allocation bitmap. Nothing outside the
 * region may still reference its blocks; `tgcRegionVerify` checks that in
 * test builds.
 */
extern (C) void tgc_endRegion(void* handle) nothrow
{
    auto reg = cast(Region*) handle;
    if (reg is null)
        return;

    auto heap = reg.owner;

    if (atomicLoad(regionVerify))
        verifyRegionUnreferenced(heap, reg);

    // Unlink from the heap first, so nothing routes into it while it drains.
    Region** pp = &heap.regions;
    while (*pp !is null && *pp !is reg)
        pp = &(*pp).next;
    if (*pp is reg)
        *pp = reg.next;
    heap.cachedCtx = null;
    heap.cachedRegion = null;

    heap.finalizing = true;
    auto c = reg.chunks;
    while (c)
    {
        auto next = c.nextAll;
        foreach (idx; 0 .. c.slotCount)
        {
            if (!c.isAllocated(idx))
                continue;
            immutable uint a = c.attrOf(idx);
            if (a & (BlkAttr.FINALIZE | BlkAttr.STRUCTFINAL))
                finalizeBlock(c.slotAt(idx), c.capacity(), a, c.meta[idx].ti);
        }
        immutable size_t bytes = c.runChunks * chunkSize;
        auto raw = cast(ubyte*) c;
        foreach (i; 0 .. c.runChunks)
            heap.map.remove(cast(void*)(raw + i * chunkSize));
        chunkFree(raw, bytes);
        c = next;
    }
    heap.finalizing = false;

    atomicOp!"-="(activeRegions, 1);
    cstdlib.free(reg);
}

/// Bytes a region currently holds.
extern (C) size_t tgc_regionBytes(void* handle) nothrow @nogc
{
    auto reg = cast(Region*) handle;
    return reg is null ? 0 : reg.reservedBytes;
}

extern (C) void tgc_setRegionVerify(bool enable) nothrow @nogc
{
    atomicStore(regionVerify, enable);
}

extern (C) bool tgc_getRegionVerify() nothrow @nogc
{
    return atomicLoad(regionVerify);
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
    segLock = SpinLock(SpinLock.Contention.brief);
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

/// The live collector instance, for code that runs outside a method call.
private __gshared ThreadGC gc_instance;

private GC initialize()
{
    import core.lifetime : emplace;

    auto gc = cast(ThreadGC) cstdlib.malloc(__traits(classInstanceSize, ThreadGC));
    if (!gc)
        onOutOfMemoryError();

    auto inst = emplace(gc);
    gc_instance = inst;
    return inst;
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

        // ... and then every segment those chunks came from, if it is now
        // empty. This is the only path that returns address space to the OS
        // eagerly; the allocator otherwise keeps a bounded set back.
        segReleaseEmpty();
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
        rootsLock.lock(); tsanAcquire(cast(const(void)*) &rootsLock);
        roots.insertBack(Root(p));
        tsanRelease(cast(const(void)*) &rootsLock); rootsLock.unlock();
    }

    void removeRoot(void* p) nothrow @nogc
    {
        rootsLock.lock(); tsanAcquire(cast(const(void)*) &rootsLock);
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
        tsanRelease(cast(const(void)*) &rootsLock); rootsLock.unlock();
    }

    @property RootIterator rootIter() return @nogc
    {
        return &rootsApply;
    }

    private int rootsApply(scope int delegate(ref Root) nothrow dg)
    {
        rootsLock.lock(); tsanAcquire(cast(const(void)*) &rootsLock);
        foreach (ref r; roots)
        {
            if (auto result = dg(r))
            {
                tsanRelease(cast(const(void)*) &rootsLock); rootsLock.unlock();
                return result;
            }
        }
        tsanRelease(cast(const(void)*) &rootsLock); rootsLock.unlock();
        return 0;
    }

    void addRange(void* p, size_t sz, const TypeInfo ti = null) nothrow @nogc
    {
        rootsLock.lock(); tsanAcquire(cast(const(void)*) &rootsLock);
        ranges.insertBack(Range(p, p + sz, cast() ti));
        tsanRelease(cast(const(void)*) &rootsLock); rootsLock.unlock();
    }

    void removeRange(void* p) nothrow @nogc
    {
        rootsLock.lock(); tsanAcquire(cast(const(void)*) &rootsLock);
        foreach (ref r; ranges)
        {
            if (r.pbot is p)
            {
                r = ranges.back;
                ranges.popBack();
                break;
            }
        }
        tsanRelease(cast(const(void)*) &rootsLock); rootsLock.unlock();
    }

    @property RangeIterator rangeIter() return @nogc
    {
        return &rangesApply;
    }

    private int rangesApply(scope int delegate(ref Range) nothrow dg)
    {
        rootsLock.lock(); tsanAcquire(cast(const(void)*) &rootsLock);
        foreach (ref r; ranges)
        {
            if (auto result = dg(r))
            {
                tsanRelease(cast(const(void)*) &rootsLock); rootsLock.unlock();
                return result;
            }
        }
        tsanRelease(cast(const(void)*) &rootsLock); rootsLock.unlock();
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
        // mutates its chunk directory with no lock at all -- and growing it
        // frees the old first-level table -- so probing it was a genuine
        // use-after-free, reachable from an ordinary GC.sizeOf on a pointer
        // this thread does not own. Cross-thread sharing is unsupported, so
        // there is nothing to find there anyway.
        orphanLock.lock(); tsanAcquire(cast(const(void)*) &orphanLock);
        scope (exit)
        {
            tsanRelease(cast(const(void)*) &orphanLock);
            orphanLock.unlock();
        }
        if (orphanHeap !is null)
            return orphanHeap.lookup(p, false);
        return BlkRef.init;
    }

    /**
     * The region bound to the running fiber, or null.
     *
     * Gated on `activeRegions` so a program that never opens a region pays a
     * single predictable branch. When regions are in use this costs a thread
     * lookup plus a pointer compare, because a fiber switch does not change
     * TLS -- the running `StackContext` is what identifies the fiber.
     */
    static Region* currentRegion(ThreadHeap* heap) nothrow
    {
        if (atomicLoad!(MemoryOrder.raw)(activeRegions) == 0 || heap.regions is null)
            return null;

        auto ctx = currentStackContext(ThreadBase.getThis());
        if (ctx is heap.cachedCtx)
            return heap.cachedRegion;

        Region* found;
        for (auto r = heap.regions; r; r = r.next)
            if (r.ctx is ctx)
            {
                found = r;
                break;
            }
        heap.cachedCtx = ctx;
        heap.cachedRegion = found;
        return found;
    }

    BlkRef alloc(size_t size, uint bits, bool zero, const TypeInfo ti) nothrow
    {
        auto heap = currentHeap();
        // Cheap test first; the atomic is only consulted when a collection looms.
        if (heap.usedBytes >= heap.collectThreshold && atomicLoad!(MemoryOrder.raw)(disabled) <= 0)
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

        auto b = heap.allocSlot(size, currentRegion(heap));
        b.setAttr(bits);
        auto m = b.meta();
        m.ti = cast(TypeInfo) ti;
        m.usedSize = (bits & BlkAttr.APPENDABLE) ? size : 0;

        auto p = b.payload();
        // Zero only when asked, as druntime's own collector does. Zeroing every
        // allocation cost a memset on the hot path for data the runtime
        // immediately overwrites with a type initialiser.
        if (zero)
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
        heap.memoTi = null;

        immutable bool trackEscapes = atomicLoad(escapeTracking);

        // Region chunks are seeded whole: everything in a region stays live
        // until the region ends, and a region object may be the only thing
        // keeping a thread-heap object alive, so they must be marked through.
        for (auto r = heap.regions; r; r = r.next)
            for (auto c = r.chunks; c; c = c.nextAll)
            {
                c.clearMarks();
                foreach (idx; 0 .. c.slotCount)
                {
                    if (!c.isAllocated(idx))
                        continue;
                    c.setMarked(idx);
                    immutable uint a = c.attrOf(idx);
                    if (a & BlkAttr.NO_SCAN)
                        continue;
                    const(size_t)* bmp;
                    size_t ew;
                    if (heap.layoutCached(c.meta[idx].ti, a, bmp, ew))
                        heap.pushMark(c.slotAt(idx), c.capacity(), bmp, ew);
                }
            }

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

            // A chunk with no finalizable slot is swept a word at a time; see
            // sweepChunkBulk. Otherwise nextReclaimable tests
            // allocated & ~marked & ~shared 64 slots at a time, so mostly-live
            // and mostly-free chunks are still skipped in a few instructions.
            // Promoted blocks are excluded from both: only a global collection
            // can prove no other thread still holds them.
            if (!large && !c.hasFinal)
            {
                heap.sweepChunkBulk(c);
            }
            else
            {
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

    @conservativeScanAddr @conservativeScanThread
    package void drainMarkStack(ThreadHeap* heap) nothrow
    {
        while (heap.markLen)
        {
            auto item = heap.markStack[--heap.markLen];
            if (item.elemWords)
                markRangePrecise(heap, item.base, item.size, item.bitmap, item.elemWords);
            else
                markRange(heap, item.base, cast(void*)(cast(ubyte*) item.base + item.size));
        }
    }

    /**
     * Scan a block consulting its pointer map, probing only the words the
     * compiler says can hold a reference.
     *
     * The map repeats every `elemWords`, which is what an array of the type
     * needs; for a single object the repeat simply covers the size-class slack
     * past the object, where nothing live can be stored anyway.
     */
    @conservativeScanAddr @conservativeScanThread
    void markRangePrecise(ThreadHeap* heap, void* base, size_t size,
                          const(size_t)* bitmap, size_t elemWords) nothrow
    {
        auto p = cast(void**) base;
        immutable size_t words = size / (void*).sizeof;
        size_t i = 0;
        while (i < words)
        {
            immutable size_t limit = i + elemWords <= words ? elemWords : words - i;
            foreach (k; 0 .. limit)
            {
                immutable size_t w = bitmap[k / bitsPerWord];
                if (w & (cast(size_t) 1 << (k % bitsPerWord)))
                    markPtr(heap, p[i + k]);
            }
            i += elemWords;
        }
    }

    /// Scan a stack range without caring which end is which.
    @conservativeScanAddr @conservativeScanThread
    package void markStackSpan(ThreadHeap* heap, void* a, void* b) nothrow
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
    @conservativeScanAddr @conservativeScanThread
    package void markStacks(ThreadHeap* heap, void* sp) nothrow
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
    package size_t snapshotOwnedContexts(ThreadHeap* heap, StackContext* cur) nothrow
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

    @conservativeScanAddr @conservativeScanThread
    package void markTLS(ThreadHeap* heap) nothrow
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
    @conservativeScanAddr @conservativeScanThread
    package void markRootsAndRanges(ThreadHeap* heap) nothrow
    {
        size_t nroots, nranges;

        rootsLock.lock(); tsanAcquire(cast(const(void)*) &rootsLock);
        {
            nroots = roots.length;
            nranges = ranges.length;

            if (nroots > heap.rootSnapCap)
            {
                size_t ncap = nroots + (nroots >> 1) + 8;
                auto np = cast(void**) cstdlib.realloc(heap.rootSnap, ncap * (void*).sizeof);
                if (!np)
                {
                    tsanRelease(cast(const(void)*) &rootsLock); rootsLock.unlock();
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
                    tsanRelease(cast(const(void)*) &rootsLock); rootsLock.unlock();
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
        tsanRelease(cast(const(void)*) &rootsLock); rootsLock.unlock();

        foreach (i; 0 .. nroots)
            markPtr(heap, heap.rootSnap[i]);
        foreach (i; 0 .. nranges)
            markRange(heap, heap.rangeSnap[i].pbot, heap.rangeSnap[i].ptop);
    }

    @conservativeScanAddr @conservativeScanThread
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

    @conservativeScanAddr @conservativeScanThread
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

    @conservativeScanAddr @conservativeScanThread
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
        if (heap.verifyRegion !is null && c.region is heap.verifyRegion)
        {
            // Reached a region block from outside the region: the invariant
            // the caller asserted does not hold.
            if (heap.verifyHit is null)
                heap.verifyHit = b.payload();
            return;
        }
        c.setMarked(b.idx);
        // The global closure is computed first and to completion, so anything
        // marked during that pass is reachable from a global and gets promoted.
        if (heap.markAsShared)
            c.setShared(b.idx);

        immutable uint attr = c.attrOf(b.idx);
        if (attr & BlkAttr.NO_SCAN)
            return;

        const(size_t)* bitmap;
        size_t elemWords;
        if (!heap.layoutCached(c.meta[b.idx].ti, attr, bitmap, elemWords))
            return; // the type says there is nothing to find in here
        heap.pushMark(b.payload(), b.capacity(), bitmap, elemWords);
    }
}
