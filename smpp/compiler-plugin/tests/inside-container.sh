#!/usr/bin/env bash
# Runs INSIDE the ballerina docker container (see run-fixture-tests.sh).
set -uo pipefail

SMPP=/home/ballerina/smpp
VERSION=$(grep '^version' "$SMPP/ballerina/Ballerina.toml" | head -1 | sed 's/.*"\(.*\)"/\1/')
echo "=== packing ramith/smpp:${VERSION} (with the compiler plugin) ==="
cd "$SMPP/ballerina"
# target/ may hold root-owned docker build output with a stale bala; pack somewhere else
# is not an option (bal pack writes target/bala), so clear just that subtree.
rm -rf target/bala
bal pack || { echo "bal pack failed"; exit 70; }
bal push --repository=local || { echo "bal push --repository=local failed"; exit 71; }

fail=0
run_fixture() {
    local name="$1"
    local src="$SMPP/compiler-plugin/tests/fixtures/$name"
    local work="/tmp/fixtures/$name"
    mkdir -p "$work"
    cp -r "$src/." "$work/"
    sed -i "s/@smpp.version@/${VERSION}/" "$work/Ballerina.toml"
    local out
    out=$(cd "$work" && bal build 2>&1)
    local rc=$?

    local expected_file="$src/expected.txt"
    # Only SMPP_1xx lines are expected codes; anything else (e.g. the SMPP_112_ONLY
    # warning-fixture directive) is a directive, not a code.
    local expected
    expected=$(grep -E '^SMPP_1[0-9]{2}$' "$expected_file" 2>/dev/null || true)

    local ok=1
    if [ -z "$expected" ]; then
        # Valid fixture: must build clean with zero SMPP_ diagnostics.
        if [ $rc -ne 0 ]; then ok=0; fi
        if echo "$out" | grep -q "SMPP_1"; then ok=0; fi
    else
        # Every expected code must appear.
        while IFS= read -r code; do
            if ! echo "$out" | grep -q "$code"; then
                echo "  MISSING: $code"
                ok=0
            fi
        done <<< "$expected"
        # No UNEXPECTED SMPP codes may appear (spec parity cuts both ways).
        local seen
        seen=$(echo "$out" | grep -o "SMPP_1[0-9][0-9]" | sort -u)
        while IFS= read -r code; do
            [ -z "$code" ] && continue
            if ! grep -q "$code" "$expected_file"; then
                echo "  UNEXPECTED: $code"
                ok=0
            fi
        done <<< "$seen"
        # ERROR-severity fixtures must fail the build; warning-only must succeed.
        if grep -q "SMPP_112_ONLY" "$expected_file"; then
            if [ $rc -ne 0 ]; then echo "  warning-only fixture must still BUILD"; ok=0; fi
        else
            if [ $rc -eq 0 ]; then echo "  error fixture unexpectedly built clean"; ok=0; fi
        fi
    fi

    if [ $ok -eq 1 ]; then
        echo "fixture $name: PASS"
    else
        echo "fixture $name: FAIL"
        echo "----- bal build output -----"
        echo "$out" | tail -30
        echo "----------------------------"
        fail=1
    fi
}

for d in "$SMPP"/compiler-plugin/tests/fixtures/*/; do
    run_fixture "$(basename "$d")"
done

if [ $fail -ne 0 ]; then exit 1; fi
echo "=== all fixtures passed ==="
