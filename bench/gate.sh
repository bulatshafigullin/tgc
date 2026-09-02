#!/usr/bin/env bash
#
# Regression gate. Runs in CI on every change; exits non-zero if something
# broke.
#
# This is not a benchmark run -- see bench/run.sh for that. A benchmark answers
# "how fast is it", which a shared CI runner cannot tell you. This answers "did
# something break", which it can, as long as every number it looks at is either
# exact or dimensionless:
#
#   * collection time relative to the *default* collector, measured the same way
#     on the same machine in the same minute, so the runner's speed cancels;
#   * collection time relative to itself at a quarter of the live set, so a
#     return to super-linear collection is visible without any baseline at all;
#   * facts that are simply true or false -- memory returned, reserve honoured,
#     garbage reclaimed.
#
# Every measurement is the best of several runs, not the mean. Interference on a
# shared runner only ever adds time, so the minimum is the closest thing to the
# machine's real number.
#
# Calibration, so the thresholds below can be argued with rather than guessed
# at. Measured on macOS/arm64 (M-series, quiet) and Linux/x86-64 (AMD EPYC 9645
# carrying an unrelated production load, which is the closer analogue of a CI
# runner):
#
#                          arm64   x86-64 pinned   x86-64 loaded, 5 runs
#   tgc / conservative       1.40      1.42         1.31 - 1.76
#   256k / 64k, tgc          4.05      4.07         2.40 - 5.17
#
# The historical regressions this is sized to catch were not subtle: collection
# time quadratic in the live set (577 ms at 16,000 objects), a sweep costing 21x
# what it should, an allocator faulting pages in a loop (374 ms of pause against
# 38 ms), and tgc at 6x the default collector per collection. It will not catch
# a few per cent, and nothing that runs on a shared runner will -- which is why
# changes at that scale are still measured by hand, paired and interleaved, as
# BENCHMARKS.md records.
#
# Usage:
#   bench/gate.sh                 # build, measure, check
#   RUNS=5 bench/gate.sh          # more samples per measurement
#   MAX_RATIO=3 bench/gate.sh     # override a threshold
#   bench/gate.sh -n              # skip the build
set -euo pipefail

cd "$(dirname "$0")/.."

RUNS=${RUNS:-3}

# tgc's collection time as a multiple of the default collector's, on the same
# live set. Worst observed on a loaded machine is 1.76; 2.5 leaves room for a
# noisier runner while still catching the 2.8x this project has measured in its
# own history.
MAX_RATIO=${MAX_RATIO:-2.5}

# Collection time at 256,000 live objects over the same at 64,000. Linear is 4,
# and that is what both platforms measure; quadratic would be 16. Worst observed
# on a loaded machine is 5.17.
MAX_LINEARITY=${MAX_LINEARITY:-8.0}

# What a collection may still be holding after the garbage is dropped, as a
# fraction of the peak. Conservative scanning retains some of it by design; a
# sweep that had stopped working would retain nearly all.
MAX_RETAINED=${MAX_RETAINED:-0.25}

BUILD=1
while getopts "nh" opt; do
    case "$opt" in
        n) BUILD=0 ;;
        h) sed -n '2,50p' "$0"; exit 0 ;;
        *) exit 2 ;;
    esac
done

if [[ $BUILD -eq 1 ]]; then
    echo "building bench-gate ..." >&2
    dub build -q --build=release --config=bench-gate >&2
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Runs ./bench-gate `RUNS` times with the given arguments and writes the
# smallest value seen for each key to $TMP/$1. Keys that are byte counts rather
# than timings are taken from the last run, since "smallest" is meaningless for
# them -- they are exact, and identical across runs.
measure() {
    local out=$1; shift
    : >"$TMP/raw"
    local i
    for ((i = 0; i < RUNS; i++)); do
        ./bench-gate "$@" >>"$TMP/raw"
    done
    python3 - "$TMP/raw" >"$TMP/$out" <<'PY'
import sys
best = {}
for line in open(sys.argv[1]):
    line = line.strip()
    if not line or '=' not in line:
        continue
    k, v = line.split('=', 1)
    if k.startswith('collect_ms'):
        v = float(v)
        best[k] = min(best[k], v) if k in best else v
    else:
        best[k] = v          # exact, not a measurement
for k, v in best.items():
    print(f'{k}={v}')
PY
}

echo "measuring (best of $RUNS) ..." >&2
measure tgc          --DRT-gcopt=gc:tgc
measure conservative --DRT-gcopt=gc:conservative

# The behavioural checks run once, in their own process: they need a heap that
# the timing sweeps have not already fragmented, and they are exact, so
# repeating them proves nothing.
echo "checking behaviour ..." >&2
./bench-gate --DRT-gcopt=gc:tgc --checks >"$TMP/checks"

cat "$TMP/tgc" "$TMP/conservative" "$TMP/checks" | sed 's/^/  /' >&2

python3 - "$TMP/tgc" "$TMP/conservative" "$TMP/checks" \
         "$MAX_RATIO" "$MAX_LINEARITY" "$MAX_RETAINED" <<'PY'
import sys

def read(path):
    d = {}
    for line in open(path):
        line = line.strip()
        if '=' in line:
            k, v = line.split('=', 1)
            d[k] = v
    return d

tgc, cons, checks = (read(p) for p in sys.argv[1:4])
max_ratio, max_lin, max_retained = (float(x) for x in sys.argv[4:7])

failures, notes = [], []

# -- dimensionless: tgc against the reference implementation -----------------
for live in ('64k', '256k'):
    key = f'collect_ms_{live}'
    t, c = float(tgc[key]), float(cons[key])
    ratio = t / c if c else float('inf')
    notes.append(f'{live:>5} live: tgc {t:.3f} ms, conservative {c:.3f} ms, ratio {ratio:.2f}')
    if ratio > max_ratio:
        failures.append(
            f'collection at {live} live objects is {ratio:.2f}x the default '
            f'collector, over the {max_ratio}x ceiling')

# -- dimensionless: tgc against itself ---------------------------------------
# Four times the live set should cost about four times as much. This is the
# check that would have caught the original quadratic collector, and it needs no
# baseline and no second collector.
small, large = float(tgc['collect_ms_64k']), float(tgc['collect_ms_256k'])
lin = large / small if small else float('inf')
notes.append(f'linearity: 4x the live set costs {lin:.2f}x (linear is 4)')
if lin > max_lin:
    failures.append(
        f'4x the live set costs {lin:.2f}x, over the {max_lin}x ceiling: '
        f'collection time is no longer linear in the live set')

# -- exact: the features either work or they do not --------------------------
default_ratio = int(checks['trim_default_ratio'])
notes.append(f'trim: shipped default ratio {default_ratio}')
if default_ratio == 0:
    failures.append(
        'the automatic return of memory is disabled by default; a heap that '
        'drops its peak would hold it for the life of the process')

held = int(checks['trim_held_bytes'])
returned = int(checks['trim_returned_bytes'])
windows = int(checks['trim_windows'])
notes.append(f'trim: held {held/1048576:.0f} MB, returned {returned/1048576:.0f} MB '
             f'after {windows} window(s)')
if returned == 0:
    failures.append('a heap that dropped its peak returned nothing to the OS')

asked = int(checks['reserve_asked_bytes'])
got = int(checks['reserve_got_bytes'])
notes.append(f'reserve: asked {asked/1048576:.0f} MB, got {got/1048576:.0f} MB')
if got < asked:
    failures.append(f'GC.reserve returned {got} bytes for a {asked}-byte request')

peak = int(checks['reclaim_peak_bytes'])
left = int(checks['reclaim_left_bytes'])
frac = left / peak if peak else 1.0
notes.append(f'reclaim: {left/1048576:.1f} MB of a {peak/1048576:.1f} MB peak still held ({frac:.1%})')
if frac > max_retained:
    failures.append(
        f'{frac:.1%} of a dropped live set is still held, over the '
        f'{max_retained:.0%} ceiling')

print()
for n in notes:
    print(f'  {n}')
print()
if failures:
    print('FAIL')
    for f in failures:
        print(f'  - {f}')
    sys.exit(1)
print('PASS')
PY
