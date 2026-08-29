# Can D's type system make per-thread heaps sound?

Research note for `tgc`. Every claim marked **[measured]** was produced by
compiling and running a probe against this repository's collector with
LDC 1.42.0 (DMD 2.112.1) on macOS/aarch64. Probes are in the session scratchpad.

**Short answer.** D's guarantees are real and worth using, but they cannot be
*abused* into an allocation-time heap partition — the information the GC would
need is not available where it would need it, and the language spec explicitly
blesses the idiom that defeats it. What does work is escape detection at
*collection* time, using the reachability oracle the collector already computes.
That happens to be both the original design intent for `shared` and what a
druntime maintainer proposed when this project was announced.

---

## 1. What D actually guarantees, and it is more than you'd think

D is unusual: module-level variables are thread-local by default, `shared` is a
transitive type qualifier, and `immutable` is implicitly shared. This was
designed with exactly our use case in mind. Bartosz Milewski, writing while the
semantics were being settled:

> Finally, there is an unexpected bonus from this scheme for the garbage
> collector. We will be able to use a separate shared heap (which will also
> store invariant objects), and separate per-thread heaps for non-shared
> objects. Since there can't be any references going from the shared/invariant
> heap to non-shared ones, per-thread garbage collection will be easy. Only
> occasional collection of the shared heap would require the cooperation of all
> threads, and even that could be done without stopping the world.

So tgc is not fighting the language; it is trying to cash a cheque the language
wrote in 2008. Two parts of that cheque do clear:

**`std.concurrency.send` is a real compile-time gate.** [measured] It is not
advisory — these are `__traits(compiles)` results:

| sent type | accepted |
|---|---|
| `int`, `string`, `immutable(int)[]`, `shared(int)*` | yes |
| `int[]`, `Object`, `int*` | **no** |

`send` rejects any type with unshared aliasing. So the sanctioned message-passing
path genuinely cannot smuggle a thread-local reference across threads.

**`core.atomic` enforces it too.** [measured] An early probe of mine failed to
compile with:

```
static assert:  "Copying argument `void* newval` to `shared(void*) here`
                 would violate shared."
```

You cannot store an unshared indirection into a `shared` location. The type
system is doing real work at exactly the boundary we care about.

---

## 2. Three holes — and none of them are user error

The guarantee covers *user* data crossing threads. It does not cover druntime's
own machinery, which crosses threads by construction.

### 2.1 `core.thread` allocates on the parent heap and hands it to the child

[measured] For `auto t = new Thread(dg); t.start();`

```
closure ctx           = 0x9908099b0   GC.sizeOf = 16    <- parent's heap
Thread object         = 0x990810be0   GC.sizeOf = 512   <- parent's heap
child read captured   = 12345                           <- child read both
```

The delegate's closure context and the `Thread` object itself are GC blocks
owned by the *creating* thread and dereferenced by the *created* thread. No
qualifier, no cast, no user mistake — this is the `Thread` API working normally.
tgc's own test suite does it on every threading test.

### 2.2 `Thread.join()` hands the parent a destructed, freed object

This one is a live use-after-free in tgc today, reachable from ordinary code:

```d
auto t = new Thread({ throw new ChildError("boom"); });
t.start();
try t.join();
catch (ChildError e) { /* ... */ }
```

[measured]

```
caught in parent
  destructor already ran on the child's teardown? YES - object was finalized
                                                       before the parent saw it
  GC.sizeOf = 0 (0 => block no longer owned by any heap)
  msg still readable: boom
```

`join()` propagates the child's `Throwable` to the parent. The exception was
allocated on the child's private heap; `cleanupThread` finalized it and released
its arena when the child exited. The parent then catches a **destructed object
in freed memory**. It reads correctly only because nothing has reused the pages
yet.

This matters for how the project describes itself. Cross-thread sharing is
currently documented as "unsupported in v1" — but this is not user code
violating a documented restriction, it is `core.thread`'s contract. "Don't share
between threads" is not a restriction a D program can actually honour.

### 2.3 `shared` and `immutable` data still lives on the allocating thread's heap

`send`ing an `immutable(int)[]` is type-safe and sanctioned, but the array was
allocated by the sender and its block remains owned by the sender's heap. The
type system says the *data* is safe to share; it says nothing about which
collector owns the *memory*. A reply in the announcement thread made exactly
this point:

> Immutable is only useful here if that memory is in read only memory allocated
> by loader. In other words, global non-TLS memory.

---

## 3. The obvious fix — classify at allocation — does not work

The tempting design: tag `shared`/`immutable` allocations and route them to a
global heap, leaving everything else thread-private. Milewski's "separate shared
heap". Three findings, in order of increasing severity.

**(a) The qualifier does not currently reach the GC.** [measured] Instrumenting
`alloc` to print the incoming `TypeInfo`:

| expression | TypeInfo the GC receives |
|---|---|
| `new int[4]` | `TypeInfo_i` |
| `new immutable(int)[4]` | `TypeInfo_i` |
| `new shared(int)[4]` | `TypeInfo_i` |
| `new const(int)[4]` | `TypeInfo_i` |
| `new Plain` / `new immutable Plain` / `new shared Plain` | `TypeInfo_Class` |

Every qualifier is stripped. The GC cannot tell them apart today.

**(b) It could be forwarded, cheaply.** The allocation hooks are templates on the
*qualified* type — `T _d_newclassT(T)()`, `T* _d_newitemT(T)()` — and inside
them `is(T == shared)` and `is(T == immutable)` both work [measured]. `typeid`
can represent it too: `typeid(shared C)` is a `TypeInfo_Shared`,
`typeid(immutable C)` a `TypeInfo_Invariant` [measured]. The qualifier is
discarded only at the `GC.malloc(size, attr, typeid(T))` call. Adding a
`BlkAttr.SHARED` bit would be a few lines in `core/lifetime.d`.

Worth knowing, but it does not save the design, because:

**(c) The spec blesses allocating unshared and casting.** From
`dlang.org/spec/const3.html`, as the *recommended* way to create shared data:

```d
@trusted shared(C) create()
{
    auto c = new C;        // allocated UNSHARED -> thread-local heap
    // work with c without it escaping
    return cast(shared)c;  // OK -- now legitimately shared
}
```

and the same pattern for immutable — `cast(immutable)s.dup`, `.idup`. The object
is born thread-local and *becomes* shared later. Casts are compile-time; there is
no runtime hook to intercept. So allocation-site classification is provably
incomplete no matter how much qualifier information we forward.

A smaller wrinkle points the same way: [measured] `immutable(int)[]` and
`shared(int)[]` both yield a plain `TypeInfo_Array`, because the qualifier is on
the *elements* while the slice head is mutable.

**Conclusion for this section:** we can *use* D's guarantees — `send`'s gate is
genuinely sound — but we cannot abuse the type system into an allocation-time
partition. Not "hard"; unsound by construction.

---

## 4. What does work: escape detection at collection time

The collector already computes a sound reachability oracle every cycle. Use that
instead of the type.

The load-bearing observation: **every sanctioned cross-thread path bottoms out in
the static data segment**, which every thread's collector already scans as a
registered range [measured — a block reachable only transitively through a
`__gshared` global survives repeated collections].

| cross-thread path | reachable from |
|---|---|
| `Thread` object | druntime's global thread list (`sm_tbeg`) → data segment |
| closure context | `Thread.m_dg` → global thread list |
| `join()` Throwable | `Thread.m_unhandled` → global thread list |
| `shared` / `__gshared` globals | data segment directly |
| `std.concurrency` mailboxes | registered globals |

So the rule is:

> **A block reached from a global range is potentially shared. Promote it, and
> never let a thread-local sweep free a promoted block.**

All three druntime holes in §2 are covered automatically, without a single
language change.

**Promotion must be sticky.** Consider: thread A allocates X, publishes it in a
`shared` global G; thread B reads G and keeps X only on B's stack; A sets
`G = null`. X is now reachable from no global and from no root A can see. If
promotion were re-evaluated per cycle, A would reclaim X while B holds it. Once
promoted, always promoted — only a cooperative global collection may free it.

**Promotion is sampled, and that leaves a residual hole.** This corrects a claim
made earlier in this note. A block is promoted when *a collection observes it*
reachable from a global. If a block is published, grabbed by another thread, and
unpublished entirely between two collections, no collection ever sees it global
and it is never promoted — so the original use-after-free remains possible in
that window. Closing it completely needs a write barrier on stores of GC
pointers into globals, which D does not have and which would cost far more than
this collector saves.

What the sampled rule does cover:

* **The druntime holes of §2.** A `Thread` object, its closure and a propagated
  `Throwable` all hang off the global thread list for their entire lifetime, not
  for a window, so any collection during that lifetime promotes them. (§2.2 is
  additionally covered outright by Phase 0, which stops releasing a dead
  thread's arenas at all.)
* **Long-lived published state** — configuration, registries, caches, service
  singletons. These are global across many collections.

What it does not cover is a short-lived publish/unpublish handshake used to move
ownership between threads. Programs doing that should pass a value or an `fd`
rather than a GC pointer (see `WEBSERVER.md` §1), or wait for Phase 2.

This is what a druntime maintainer proposed in the announcement thread:

> Have a thread local scanner and heap. Once the stack, TLS, and heap reachable
> from those two isn't reached anymore you move that block to the global heap.
> The global scanner then looks at all blocks of memory in program […] Nice and
> thread safe. But will take longer to collect I expect.

That variant is more conservative than the one above — it promotes *everything*
a thread-local pass cannot prove dead, rather than only what is globally
reachable. It is strictly sound and simpler to argue; it also promotes far more,
so the global collector does more work. The globally-reachable variant keeps the
common case (data that never escapes) fully thread-local, at the cost of needing
the escape argument above to be airtight.

Either way the outcome matches Milewski's original sketch: per-thread heaps for
unshared data, a shared heap needing occasional cooperative collection. The
correction is only *when* classification happens — at collection, not at
allocation.

---

## 5. Recommended phasing

**Phase 0 — stop the bleeding (small, sound, no design commitment). DONE.**
A dying thread's arenas are no longer finalized and released; they are adopted
by a heap that no collection sweeps, so §2.2's objects stay valid. Verified: the
child's exception now arrives at the parent undestructed with
`GC.sizeOf` non-zero, and there is a regression test for it.

Cost, accepted deliberately: a dead thread's memory is not reclaimed until the
process exits, and its objects are never finalized. That is fine for a fixed
worker pool and bad for a program that spawns many short-lived threads. Phase 2
is what makes it reclaimable.

**Phase 1 — sticky promotion on global reachability. DONE, but opt-in.**
A per-slot `slotShared` bit, never cleared. Marking runs in two passes: first the
closure reachable from global roots, tagging everything it reaches as promoted;
then this thread's stack, registers and TLS. Already-promoted blocks are re-seeded
as roots each cycle, because a promoted block may be unreachable from anything
the owning thread can see while another thread still holds it — without that,
its children (which may never have been global themselves) would be swept out
from under that thread. The sweep frees only slots that are neither marked nor
promoted.

Enable with `tgcTrackEscapes(true)`; **off by default**, and the measurement is
why. Because promotion is sticky the promoted set never shrinks, and it must be
re-seeded as roots on every subsequent collection. On a workload that publishes
and drops 50,000 objects repeatedly, the mark phase grew as the promoted set
grew:

| promoted blocks | mark phase |
|---|---|
| 43,000 | 0.25 ms |
| 100,000 | 0.46 ms |
| 152,000 | 1.64 ms |
| 212,000 | 3.66 ms |

and it would keep growing for the life of the process. For a collector whose
entire value is bounded pause time, pauses that grow with everything the program
has ever published is a worse failure than the narrow bug promotion fixes — so
the caller chooses. With it off there is no measurable cost (collection times
are unchanged within run-to-run variance).

Turn it on if the program hands GC pointers to other threads through globals and
can afford that growth. Phase 2 is what would make it cheap enough to default
on, because a global collection can finally reclaim promoted blocks.

Also subject to the sampling limitation above: promotion only sees blocks that
are globally reachable *at the moment some collection runs*.

**Phase 2 — cooperative global collection.**
Rare, triggered by shared-heap growth. Needs every thread to publish its roots;
can use a handshake at allocation safepoints rather than `thread_suspendAll`, so
detached `@nogc` threads still never get paused — which is the project's actual
selling point, and it survives intact.

**Phase 3 (optional, upstream) — `BlkAttr.SHARED` as a hint.**
Forward `is(T == shared) || is(T == immutable)` from `_d_newclassT`/`_d_newitemT`
so obviously-shared allocations start in the shared heap and skip promotion.
Useful as a fast path; must never be the sole authority, per §3(c). This is a
natural companion PR to dlang/dmd#23514.

**What to drop:** the current remote-free queue and the foreign-heap fallback in
`queryBlock`. Under this design a foreign pointer is either promoted-shared
(handled by the global collector) or a bug; neither wants a cross-heap free
path.

---

## 6. Honest summary for the README

The present "cross-thread sharing is unsupported in v1" wording implies a
restriction users can comply with. They cannot: `Thread`, its closure, and
`join()`'s exception propagation all cross heaps by construction, and §2.2 is a
use-after-free in ordinary code. Until Phase 0 lands, the accurate statement is
that tgc is sound only for single-threaded programs, or for threads that never
throw and are never joined.

---

## Sources

- [Sharing in D — Bartosz Milewski](https://bartoszmilewski.com/2008/07/30/sharing-in-d/)
- [Type Qualifiers (`shared`, casting rules) — D Language Spec](https://dlang.org/spec/const3.html)
- [Opt-in thread-local GC (tgc) — D forum announcement thread](https://forum.dlang.org/thread/eyivmktfvmdlvhbyyphd@forum.dlang.org)
- [Automatic Memory Management — D Language Spec](https://dlang.org/spec/garbage.html)
