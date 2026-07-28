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

# run_case <dir> <scenario> <port> <expected-log-substring>
run_case() {
    local name="$1" scenario="$2" port="$3" expect="$4"
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
    if wait_for "$expect" "$elog" 90; then
        echo "  PASS: saw \"$expect\""
    else
        echo "  FAIL: \"$expect\" not seen within 90s"
        echo "  ---- example log ----"; sed 's/^/    /' "$elog"
        FAILED=1
    fi

    stop_group "$epid"
    stop_group "$mpid"
    sleep 1
}

run_case receive-sms        steady 2775 "inbound SMS received"
run_case delivery-receipts  steady 2776 "message DELIVERED"
run_case two-way-sms        steady 2777 "OPT-OUT"
run_case resilient-listener flaky  2778 "session dropped"
run_case tls-smsc           tls    3550 "inbound message over TLS"

rm -rf "$LOGDIR"
if [ "$FAILED" -ne 0 ]; then echo "SMOKE TEST FAILED"; exit 1; fi
echo "SMOKE TEST PASSED"
