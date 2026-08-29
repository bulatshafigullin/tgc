/**
 * Registers the `tgc` GC factory at load time.
 * With version `Tgc_default`, selects thread-local GC via embedded rt_options.
 */
module tgc.gcobj;

import core.internal.gc.impl.tgc.gc;

/**
 * Enable escape promotion: blocks seen reachable from a global root are never
 * reclaimed by a thread-local collection.
 *
 * Off by default. It closes a cross-thread hole (a block published to a global,
 * picked up by another thread, then unpublished) but the promoted set is sticky
 * and re-scanned every cycle, so pause time grows with everything the program
 * has ever published. Enable it only if the program does that handoff and can
 * afford growing pauses. See CROSS-THREAD.md.
 */
void tgcTrackEscapes(bool enable) nothrow @nogc
{
    tgc_setTrackEscapes(enable);
}

/// ditto
bool tgcTrackEscapes() nothrow @nogc
{
    return tgc_getTrackEscapes();
}

version (Tgc_default)
{
    extern (C) __gshared string[] rt_options = [ "gcopt=gc:tgc" ];
}
