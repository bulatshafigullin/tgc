#!/usr/bin/env bash
#
# Benchmark driver.
#
# Marking is tgc's largest cost, so any change to it has to be measured on the
# same box, back to back, against the collector it is trying to catch. This
# builds the three binary-trees variants once and runs each under both
# collectors, reporting the best of N runs plus what the collector actually did
# (collections, total pause, max pause -- printed on stderr by the benchmarks).
#
# Both columns run the *same binary*; only `--DRT-gcopt=gc:` differs.
#
# Usage:
#   bench/run.sh                 # depth 18, 3 runs, all three benchmarks
#   bench/run.sh -d 16 -r 1      # quicker
#   bench/run.sh -o base.md      # also write the table to a file
#   bench/run.sh -b bintree      # one benchmark only (bintree|mt|region)
set -euo pipefail

cd "$(dirname "$0")/.."

DEPTH=18
RUNS=3
WORKERS=4
OUT=""
ONLY="all"
BUILD=1

while getopts "d:r:w:o:b:nh" opt; do
    case "$opt" in
        d) DEPTH=$OPTARG ;;
        r) RUNS=$OPTARG ;;
        w) WORKERS=$OPTARG ;;
        o) OUT=$OPTARG ;;
        b) ONLY=$OPTARG ;;
        n) BUILD=0 ;;
        h) sed -n '2,20p' "$0"; exit 0 ;;
        *) exit 2 ;;
    esac
done

CONFIGS=()
case "$ONLY" in
    all)     CONFIGS=(bench-bintree bench-mt bench-region) ;;
    bintree) CONFIGS=(bench-bintree) ;;
    mt)      CONFIGS=(bench-mt) ;;
    region)  CONFIGS=(bench-region) ;;
    *) echo "unknown benchmark: $ONLY" >&2; exit 2 ;;
esac

if [[ $BUILD -eq 1 ]]; then
    for c in "${CONFIGS[@]}"; do
        echo "building $c ..." >&2
        dub build -q --build=release --config="$c" >&2
    done
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Runs one binary `RUNS` times and echoes "<best seconds>|<collector stats line>".
#
# The multi-threaded benchmarks time their parallel section themselves and print
# it; that is the figure worth comparing, since it excludes building the
# long-lived tree single-threaded. Fall back to wall time when there is none.
best_of() {
    local bin=$1; shift
    local best="" bestgc="" i t gc
    for ((i = 0; i < RUNS; i++)); do
        local start end
        start=$(python3 -c 'import time; print(time.monotonic())')
        "$bin" "$@" >"$TMP/out" 2>"$TMP/err" || { cat "$TMP/err" >&2; exit 1; }
        end=$(python3 -c 'import time; print(time.monotonic())')
        t=$(python3 -c "print(f'{$end - $start:.3f}')")
        if grep -q '^parallel section:' "$TMP/out"; then
            t=$(sed -E -n 's/^parallel section: ([0-9.]+) s/\1/p' "$TMP/out")
        fi
        gc=$(grep 'collections=' "$TMP/err" || true)
        if [[ -z "$best" ]] || (( $(python3 -c "print(1 if $t < $best else 0)") )); then
            best=$t
            bestgc=$gc
        fi
    done
    echo "$best|$bestgc"
}

emit() {
    echo "$1"
    [[ -n "$OUT" ]] && echo "$1" >>"$OUT"
    return 0
}

[[ -n "$OUT" ]] && : >"$OUT"

emit "# tgc benchmark run"
emit ""
emit "depth $DEPTH, best of $RUNS, $(uname -srm)"
emit ""
emit "| benchmark | collector | wall | collections | total pause | max pause |"
emit "|---|---|---|---|---|---|"

row() {
    local label=$1 bin=$2 gcopt=$3; shift 3
    local r
    r=$(best_of "$bin" "--DRT-gcopt=gc:$gcopt" "$@")
    local wall=${r%%|*}
    local gc=${r#*|}
    local coll="-" tot="-" mx="-"
    if [[ -n "$gc" ]]; then
        coll=$(sed -E 's/.*collections=([0-9]+).*/\1/' <<<"$gc")
        tot=$(sed -E 's/.*totalPause=([0-9.]+) ?ms.*/\1 ms/' <<<"$gc")
        mx=$(sed -E 's/.*maxPause=([0-9.]+) ?ms.*/\1 ms/' <<<"$gc")
    fi
    emit "| $label | $gcopt | ${wall} s | $coll | $tot | $mx |"
}

for c in "${CONFIGS[@]}"; do
    case "$c" in
        bench-bintree)
            row "bintree d$DEPTH" ./bench-bintree conservative "$DEPTH"
            row "bintree d$DEPTH" ./bench-bintree tgc "$DEPTH"
            ;;
        bench-mt)
            row "mt d$DEPTH x$WORKERS" ./bench-mt conservative "$DEPTH" "$WORKERS"
            row "mt d$DEPTH x$WORKERS" ./bench-mt tgc "$DEPTH" "$WORKERS"
            ;;
        bench-region)
            row "region d$DEPTH x$WORKERS (no regions)" ./bench-region tgc "$DEPTH" "$WORKERS" --no-region
            row "region d$DEPTH x$WORKERS" ./bench-region tgc "$DEPTH" "$WORKERS"
            ;;
    esac
done
