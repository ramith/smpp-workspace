#!/usr/bin/env bash
# Sprint 8.5 fix-wave validation soak.
#
# Runs the deterministic sever/rebind soak repeatedly in the SAME distribution the
# gradle build uses (docker, 2201.13.0 — the local `bal` may be a different patch
# release), and samples thread dumps for the two wedge signatures the Sprint 8.5
# review pinned from the vendored jsmpp source:
#
#   1. a thread parked in AbstractSession.close()'s unbounded enquireLinkSender.join()
#   2. a thread BLOCKED on monitorenter for the output-stream monitor held by a
#      stalled writer (the F1a mechanism)
#
# plus the observable outcome of either: an orphaned EnquireLinkSender still spinning
# while the session claims BOUND_TRX.
#
# It also watches for the fix wave's own new threads (smpp-close-watchdog,
# smpp-abandoned-session-closer) to confirm they appear and, crucially, do NOT
# accumulate — a watchdog that leaked per stop would be its own regression.
#
# Usage: scripts/soak-fix-wave.sh [iterations]   (default 20; each = 15 sever/rebind
# cycles, so 20 ≈ 300 cycles against a historical hit rate of ~1 in a few hundred)
set -uo pipefail
K="${1:-20}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ROOT}/build/soak-fix-wave"
mkdir -p "$OUT"
IMAGE="ballerina/ballerina:2201.13.0"

pass=0; fail=0
for i in $(seq 1 "$K"); do
    log="${OUT}/iter-${i}.log"
    cid="soak-fixwave-$$-${i}"
    docker run --rm --name "$cid" --net=host \
        -v "${ROOT}/smpp:/home/ballerina/smpp" \
        "$IMAGE" \
        bash -c "cd /home/ballerina/smpp/ballerina && bal test --tests testRepeatedSeverRebindCycles" \
        > "$log" 2>&1 &
    dockerpid=$!

    # Sample thread dumps CONTINUOUSLY until the container exits. A fixed early window
    # misses the point entirely: `bal test` spends its first ~30s compiling, so dumps
    # taken then contain no connector threads at all. Target BTestMain specifically —
    # the `bal` launcher is a separate JVM with none of the threads we care about.
    # pgrep is not in this image; jps is.
    # Dense sampling: `bal test` spends its first ~25s compiling and the sever/rebind
    # cycles themselves are short, so the live window is narrow — a 3s cadence mostly
    # misses it.
    ( sleep 18
      while docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null | grep -q true; do
          docker exec "$cid" bash -c \
            'p=$(jps -l 2>/dev/null | grep BTestMain | cut -d" " -f1); [ -n "$p" ] && jstack "$p" 2>/dev/null' \
            >> "${OUT}/iter-${i}.jstack" 2>/dev/null || true
          sleep 1
      done ) &
    samplerpid=$!

    wait $dockerpid; rc=$?
    kill $samplerpid 2>/dev/null; wait $samplerpid 2>/dev/null

    if [ $rc -eq 0 ] && grep -q "0 failing" "$log"; then
        pass=$((pass+1)); echo "iter ${i}/${K}: PASS"
    else
        fail=$((fail+1)); echo "iter ${i}/${K}: FAIL (rc=$rc) — see $log"
    fi
done

echo "=================================================="
echo "soak result: ${pass} passed, ${fail} failed of ${K} iterations (~$((K*15)) sever/rebind cycles)"
echo "--- wedge signature scan across all thread dumps ---"
cat "${OUT}"/*.jstack > "${OUT}/all.jstack" 2>/dev/null || true
count() { grep -c "$1" "${OUT}/all.jstack" 2>/dev/null | head -1 || true; }
if [ -s "${OUT}/all.jstack" ]; then
    echo "samples captured:      $(count 'Full thread dump')"
    echo "  -- wedge signatures (any nonzero warrants reading the dump) --"
    echo "close()-join parks:    $(count 'AbstractSession.close')"
    echo "blocked on monitor:    $(count 'waiting to lock')"
    echo "  -- jsmpp threads seen at all (0 = sampled outside the live window) --"
    echo "EnquireLinkSender:     $(count 'EnquireLinkSender')"
    echo "PDUReaderWorker:       $(count 'PDUReaderWorker')"
    echo "  -- fix-wave threads (presence expected; accumulation would be a regression) --"
    echo "close-watchdog:        $(count 'smpp-close-watchdog')"
    echo "abandoned-closer:      $(count 'smpp-abandoned-session-closer')"
    echo "peak EnquireLinkSenders in one dump: $(awk '/Full thread dump/{if(n>m)m=n;n=0} /EnquireLinkSender/{n++} END{if(n>m)m=n; print m+0}' "${OUT}/all.jstack")"
else
    echo "(no thread dumps captured — test outcomes above still stand)"
fi
[ $fail -eq 0 ]
