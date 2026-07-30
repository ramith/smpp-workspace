#!/usr/bin/env bash
# Lightweight end-to-end smoke test for the examples. For each one it starts the mock
# SMSC in the scenario the example expects, runs the example, and asserts it logs the
# expected line — proving the examples actually work, not just that they compile
# (that is build.sh). Used by CI.
set -uo pipefail
set -m  # monitor mode: each backgrounded job gets its own process group, so we can
        # kill a launcher and every child it spawned (bal -> JVM) in one signal.
cd "$(dirname "$0")"
ROOT="$(pwd)"
MOCK_BIN="$ROOT/mock-smsc/build/install/mock-smsc/bin/mock-smsc"
LOGDIR="$(mktemp -d)"
FAILED=0

# wait_for <pattern> <file> <seconds>
wait_for() {
    local i=0
    while [ "$i" -lt "$3" ]; do
        grep -q "$1" "$2" 2>/dev/null && return 0
        sleep 1; i=$((i + 1))
    done
    return 1
}

# wait_for_count <pattern> <min-count> <file> <seconds>
wait_for_count() {
    local i=0
    while [ "$i" -lt "$4" ]; do
        [ "$(grep -c "$1" "$3" 2>/dev/null || true)" -ge "$2" ] && return 0
        sleep 1; i=$((i + 1))
    done
    return 1
}

# stop_group <pid>: terminate a backgrounded job and its whole process group.
stop_group() {
    kill -TERM -- "-$1" 2>/dev/null
    wait "$1" 2>/dev/null
}

echo "== building mock SMSC (installDist) =="
( cd mock-smsc && ./gradlew -q --console=plain installDist ) || { echo "mock build failed"; exit 1; }
for ex in receive-sms delivery-receipts two-way-sms resilient-listener tls-smsc; do
    echo "== bal build: $ex =="
    ( cd "$ex" && bal build ) > /dev/null || { echo "$ex build failed"; exit 1; }
done

# run_case <dir> <scenario> <port> <expected-log-substring> [<pattern2> <min-count2>]
# The optional pair asserts a second pattern occurs at least N times — used where one
# occurrence of a string cannot prove the behavior under test (see resilient-listener).
run_case() {
    local name="$1" scenario="$2" port="$3" expect="$4" expect2="${5:-}" count2="${6:-1}"
    local mlog="$LOGDIR/$name.mock.log" elog="$LOGDIR/$name.example.log"
    echo "== $name (scenario=$scenario port=$port) =="

    "$MOCK_BIN" "$scenario" "$port" > "$mlog" 2>&1 &
    local mpid=$!
    if ! wait_for "listening on port" "$mlog" 40; then
        echo "  FAIL: mock did not start"; sed 's/^/    /' "$mlog"; FAILED=1
        stop_group "$mpid"; return
    fi

    # Run via `bal run` so the program uses Ballerina's bundled JDK (the executable is
    # Java 21 bytecode). The connection port is overridden with a config CLI arg.
    ( cd "$name" && exec bal run -- -Cport="$port" ) > "$elog" 2>&1 &
    local epid=$!
    if ! wait_for "$expect" "$elog" 90; then
        echo "  FAIL: \"$expect\" not seen within 90s"
        echo "  ---- example log ----"; sed 's/^/    /' "$elog"
        FAILED=1
    elif [ -n "$expect2" ] && ! wait_for_count "$expect2" "$count2" "$elog" 90; then
        echo "  FAIL: \"$expect2\" not seen >= $count2 times within 90s"
        echo "  ---- example log ----"; sed 's/^/    /' "$elog"
        FAILED=1
    else
        echo "  PASS: saw \"$expect\"${expect2:+ and ${count2}x \"$expect2\"}"
    fi

    stop_group "$epid"
    stop_group "$mpid"
    sleep 1
}

run_case receive-sms        steady 2775 "inbound SMS received"
run_case delivery-receipts  steady 2776 "message DELIVERED"
# two-way's assertion is the deepest in the suite: MO in -> keyword classified ->
# caller->submit out -> submit_sm_resp message_id -> correlated DLR back in. Seeing
# it proves the whole 1.1.0 reply path, not just the bind.
run_case two-way-sms        steady 2777 "opt-out confirmation DELIVERED"
# "session dropped" alone proves only the onError notification. The flaky mock
# pushes exactly 3 MOs per bind then hard-drops, so a 4th "inbound message" line
# can only come from a successful REBIND — assert both.
run_case resilient-listener flaky  2778 "session dropped" "inbound message" 4
run_case tls-smsc           tls    3550 "inbound message over TLS"

rm -rf "$LOGDIR"
if [ "$FAILED" -ne 0 ]; then echo "SMOKE TEST FAILED"; exit 1; fi
echo "SMOKE TEST PASSED"
