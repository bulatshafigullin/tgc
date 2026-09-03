#!/usr/bin/env bash
#
# Benchmark a vibe.d HTTP server under tgc and under the default collector.
#
# The same binary serves both columns; only `--DRT-gcopt=gc:` differs, so
# nothing but the collector changes between them. Each run starts a fresh
# server, warms it, measures with `wrk`, then sends SIGINT so the server prints
# what its collector actually did.
#
# What to look at, in order of how much it says about a garbage collector:
#
#   * **p99 latency.** This is the number a collector shows up in. Throughput on
#     a loopback benchmark is mostly the framework and the kernel; the tail is
#     where a pause lands on a request.
#   * **max pause.** Reported by the server itself rather than inferred.
#   * **RSS.** Both collectors are given the same workload, so this is a fair
#     comparison of what they hold, not of how they are configured.
#   * throughput, last, because it moves least and is the easiest to misread.
#
# The `/work` route is the one worth reading: `/plaintext` and `/json` allocate
# so little that they measure vibe.d and `wrk`, and they are here to show that.
#
# Usage:
#   bench/vibe/run.sh                       # /work, 4 threads, 30s
#   bench/vibe/run.sh -r /json -d 10        # a different route, shorter
#   bench/vibe/run.sh -t 1                  # single-threaded
#   bench/vibe/run.sh -c 200 -w 64          # more connections, more garbage
set -euo pipefail

cd "$(dirname "$0")"

ROUTE=/work
DURATION=30
THREADS=4
CONNS=128
WRK_THREADS=4
CACHE=4096
WORK=24
PORT=18080
BUILD=1
REPS=3
MATCH=""
REGION=0

while getopts "r:d:t:c:W:k:w:p:N:m:Rnh" opt; do
    case "$opt" in
        r) ROUTE=$OPTARG ;;
        d) DURATION=$OPTARG ;;
        t) THREADS=$OPTARG ;;
        c) CONNS=$OPTARG ;;
        W) WRK_THREADS=$OPTARG ;;
        k) CACHE=$OPTARG ;;
        w) WORK=$OPTARG ;;
        p) PORT=$OPTARG ;;
        N) REPS=$OPTARG ;;
        m) MATCH=$OPTARG ;;
        R) REGION=1 ;;
        n) BUILD=0 ;;
        h) sed -n '2,30p' "$0"; exit 0 ;;
        *) exit 2 ;;
    esac
done

command -v wrk >/dev/null || { echo "wrk is required (brew install wrk)" >&2; exit 2; }

if [[ $BUILD -eq 1 ]]; then
    echo "building ..." >&2
    dub build -q --build=release >&2
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; kill %1 2>/dev/null || true' EXIT

run_one() {
    local gc=$1 out=$2

    # `-m N` puts tgc on an N-MB-per-thread floor with a growth factor of 2,
    # which is the closest thing to the budget the default collector gives
    # itself. Without it both run at their own defaults, which is the other
    # comparison worth seeing and not the same one.
    # A plain string rather than an array: macOS ships bash 3.2, where expanding
    # an empty array under `set -u` is an error rather than nothing. These are
    # generated values with no spaces in them, so word splitting is what is
    # wanted here.
    local tuning=""
    if [[ -n "$MATCH" && "$gc" != conservative ]]; then
        tuning="--min-heap=$MATCH --growth=2"
    fi
    # The third column, `tgc-region`, is the same collector with each request's
    # scratch in a per-request region.
    local realgc=$gc
    if [[ "$gc" == tgc-region ]]; then
        realgc=tgc
        tuning="$tuning --region"
    fi

    ./tgc-vibe-bench "--DRT-gcopt=gc:$realgc" "--port=$PORT" "--threads=$THREADS" \
        "--cache=$CACHE" "--work=$WORK" $tuning >"$TMP/server.log" 2>&1 &
    local pid=$!

    # Wait for the port rather than sleeping a guessed amount.
    local i
    for ((i = 0; i < 100; i++)); do
        if python3 -c "
import socket,sys
s=socket.socket()
s.settimeout(0.2)
sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT))==0 else 1)
" 2>/dev/null; then break; fi
        sleep 0.1
    done

    # Warm-up: let the JIT-less but still cold code, the connection pool and the
    # collector's threshold settle before anything is recorded.
    wrk -t"$WRK_THREADS" -c"$CONNS" -d5s --latency "http://127.0.0.1:$PORT$ROUTE" >/dev/null 2>&1 || true

    wrk -t"$WRK_THREADS" -c"$CONNS" -d"${DURATION}s" --latency \
        "http://127.0.0.1:$PORT$ROUTE" >"$TMP/wrk.txt" 2>&1 &
    local wrkpid=$!

    # Sample RSS under load and keep the peak. One `ps` per sample and the
    # maximum taken afterwards, rather than a `python3` per sample to compare:
    # on a machine already running the server and the load generator, spawning
    # two processes twice a second is itself load, and it showed up in the
    # numbers.
    : >"$TMP/rss"
    while kill -0 $wrkpid 2>/dev/null; do
        ps -o rss= -p $pid >>"$TMP/rss" 2>/dev/null || true
        sleep 0.5
    done
    wait $wrkpid || true
    local peak
    peak=$(awk 'BEGIN{m=0} {if ($1+0 > m) m=$1+0} END{printf "%.1f", m/1024}' "$TMP/rss")

    kill -INT $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true

    {
        echo "gc=$gc"
        echo "peak_rss_mb=$peak"
        sed -E -n 's/^Requests\/sec: *([0-9.]+)/rps=\1/p' "$TMP/wrk.txt"
        sed -E -n 's/^ *50% *([0-9.]+)(us|ms|s)/p50=\1\2/p' "$TMP/wrk.txt"
        sed -E -n 's/^ *99% *([0-9.]+)(us|ms|s)/p99=\1\2/p' "$TMP/wrk.txt"
        sed -E -n 's/.*Latency *[0-9.]+(us|ms|s) *[0-9.]+(us|ms|s) *([0-9.]+)(us|ms|s).*/pmax=\3\4/p' "$TMP/wrk.txt"
        grep -h '^GCSTATS' "$TMP/server.log" | head -1 | sed 's/^GCSTATS main //' | tr ' ' '\n'
    } >"$out"
}

echo "route $ROUTE, ${DURATION}s, $THREADS server thread(s), $CONNS connections, work=$WORK cache=$CACHE${MATCH:+, tgc matched to ${MATCH}MB/thread}"
echo

# Interleaved, not batched: this machine drifts over the minutes a run takes,
# and alternating the two collectors cancels that where running all of one and
# then all of the other would bake it in.
for ((rep = 0; rep < REPS; rep++)); do
    echo "  rep $((rep + 1))/$REPS ..." >&2
    run_one conservative "$TMP/cons.$rep.txt"
    run_one tgc "$TMP/tgc.$rep.txt"
    [[ $REGION -eq 1 ]] && run_one tgc-region "$TMP/region.$rep.txt"
done

python3 - "$TMP" "$REPS" <<'PY'
import sys, glob

tmp, reps = sys.argv[1], int(sys.argv[2])

def read(p):
    d = {}
    for line in open(p):
        line = line.strip()
        if '=' in line:
            k, v = line.split('=', 1)
            d[k] = v
    return d

def num(v):
    """wrk prints latencies with a unit; normalise everything to a float in ms."""
    if v is None:
        return None
    v = v.strip()
    for suf, mul in (('us', 0.001), ('ms', 1.0), ('s', 1000.0)):
        if v.endswith(suf):
            try:
                return float(v[:-len(suf)]) * mul
            except ValueError:
                return None
    try:
        return float(v)
    except ValueError:
        return None

def collect(prefix):
    return [read(p) for p in sorted(glob.glob(f'{tmp}/{prefix}.*.txt'))]

def best(runs, key, higher):
    """Best across repetitions. Interference on a busy machine lowers
    throughput and raises latency, so the extreme in the good direction is the
    closest thing to what the machine can actually do."""
    vals = [num(r.get(key)) for r in runs]
    vals = [v for v in vals if v is not None]
    if not vals:
        return None
    return max(vals) if higher else min(vals)

cons_runs, tgc_runs = collect('cons'), collect('tgc')
region_runs = collect('region')

# label, key, note, higher-is-better, unit
rows = [
    ('requests/sec',   'rps',          'higher is better',           True,  ''),
    ('latency p50',    'p50',          '',                           False, 'ms'),
    ('latency p99',    'p99',          'where a collector shows up', False, 'ms'),
    ('latency max',    'pmax',         '',                           False, 'ms'),
    ('peak RSS (MB)',  'peak_rss_mb',  'lower is better',            False, 'MB'),
    ('collections',    'collections',  'process-wide',               True,  ''),
    ('total pause ms', 'totalPauseMs', 'see note below',             False, 'ms'),
    ('max pause ms',   'maxPauseMs',   'lower is better',            False, 'ms'),
]

cols = [('conservative', cons_runs), ('tgc', tgc_runs)]
if region_runs:
    cols.append(('tgc+regions', region_runs))

w = max(len(r[0]) for r in rows)
print(f'{"":<{w}} | ' + ' | '.join(f'{n:>13}' for n, _ in cols) + ' |')
print(f'{"-"*w}-|-' + '-|-'.join('-' * 13 for _ in cols) + '-|')
for label, key, note, higher, unit in rows:
    cells = []
    for _, runs in cols:
        v = best(runs, key, higher)
        cells.append('-' if v is None else f'{v:,.2f}{unit}')
    print(f'{label:<{w}} | ' + ' | '.join(f'{c:>13}' for c in cells) + f' | {note}')
print()
print(f'best of {reps} interleaved repetitions')
print('Both pause figures are process-wide totals. They do not mean the same')
print('thing: every pause the default collector took stopped *every* thread,')
print('while each of tgc\'s stopped only the one thread that took it. Equal')
print('totals therefore favour tgc by however many threads are running, which')
print('is why the latency tail is the honest number to compare.')
print()
for name, runs in cols[1:]:
    cm = best(runs, 'committedMB', True)
    if cm is not None:
        print(f'{name} committed: {cm:.1f} MB')
PY
