#!/usr/bin/env bash
# Runs INSIDE the ballerina docker container (see run-fixture-tests.sh).
set -uo pipefail

SMPP=/home/ballerina/smpp
VERSION=$(grep '^version' "$SMPP/ballerina/Ballerina.toml" | head -1 | sed 's/.*"\(.*\)"/\1/')

# Stale-plugin-jar guard (Phase-5 M2): CompilerPlugin.toml pins the jar by literal
# version (restamped only by updateTomlFiles). On a dirty tree after a version bump,
# build/libs can still hold the OLD jar - bal pack would embed it silently and every
# fixture would then validate the PREVIOUS sprint's plugin. Fail loud instead.
if ! grep -q "smpp-compiler-plugin-${VERSION}.jar" "$SMPP/ballerina/CompilerPlugin.toml"; then
    echo "CompilerPlugin.toml does not reference smpp-compiler-plugin-${VERSION}.jar - run updateTomlFiles"
    exit 72
fi
jarCount=$(ls "$SMPP"/compiler-plugin/build/libs/smpp-compiler-plugin-*.jar 2>/dev/null | wc -l)
if [ "$jarCount" -ne 1 ]; then
    echo "expected exactly one smpp-compiler-plugin jar in build/libs, found ${jarCount} - clean stale versions"
    exit 73
fi

echo "=== packing ramith/smpp:${VERSION} (with the compiler plugin) ==="
# Pack from a CONTAINER-LOCAL copy, never in place: on a Linux CI runner the gradle
# plugin's earlier `bal test` container leaves ballerina/target root-owned on the host
# mount, and `bal pack` refuses ("target does not have write permissions") - this
# failed the v1.1.0 release run while passing every macOS-docker local run, where the
# file sharing layer masks ownership. The copy preserves the ../native and
# ../compiler-plugin relative jar paths the tomls reference, and leaves the workspace
# untouched as a bonus.
PKG=/tmp/pkgroot
mkdir -p "$PKG/ballerina" "$PKG/native/build/libs" "$PKG/compiler-plugin/build/libs"
(cd "$SMPP/ballerina" && tar -c --exclude=./target .) | tar -x -C "$PKG/ballerina"
cp "$SMPP"/native/build/libs/*.jar "$PKG/native/build/libs/"
cp "$SMPP"/compiler-plugin/build/libs/smpp-compiler-plugin-*.jar "$PKG/compiler-plugin/build/libs/"
cd "$PKG/ballerina"
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

count=0
for d in "$SMPP"/compiler-plugin/tests/fixtures/*/; do
    run_fixture "$(basename "$d")"
    count=$((count + 1))
done

# A glob that matched nothing must not report success (Phase-5 L5).
if [ "$count" -lt 10 ]; then
    echo "only ${count} fixtures found - the suite is 10+; a path/glob regression is eating fixtures"
    exit 74
fi
if [ $fail -ne 0 ]; then exit 1; fi
echo "=== all ${count} fixtures passed ==="
