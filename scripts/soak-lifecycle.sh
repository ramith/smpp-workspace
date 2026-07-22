#!/usr/bin/env bash
# Sprint-2 exit-gate soak: repeat the timing-sensitive lifecycle/soak tests K times
# (default 25). NOT part of CI - run manually before declaring Sprint 2's exit gate
# passed (docs/sprint-plan.md budgets 4-8h of soak explicitly).
#
# Repeats the deterministic drop/rebind soak (testRepeatedSeverRebindCycles) in its own
# fresh-JVM `bal test` invocation each iteration. This is the reliable, fast exit-gate
# soak for the lifecycle machinery.
#
# The accept-then-vanish bound-race HAMMER (testAcceptThenDropCyclesRecoverWithoutWedge)
# is deliberately NOT looped here: it is disabled in the automated suite (enable: false)
# because the accept-then-vanish path trips jsmpp's 60s default bind timeout on the
# single-threaded rebind executor, making it slow and timing-nondeterministic. Run it by
# hand when deliberately exercising that path:
#     cd smpp/ballerina && bal test --tests testAcceptThenDropCyclesRecoverWithoutWedge
#     (needs the @test:Config enable:false flipped to true first)
#
# Prereq: ./gradlew build from smpp/ has produced the native + testBridge jars.
set -euo pipefail
K="${1:-25}"
cd "$(dirname "$0")/../smpp/ballerina"

for i in $(seq 1 "$K"); do
    echo "=== soak iteration $i/$K ==="
    bal test --tests testRepeatedSeverRebindCycles || { echo "FAILED on iteration $i"; exit 1; }
done
echo "soak passed: $K iterations green"
