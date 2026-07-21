#!/usr/bin/env bash
# Compiles the native Java glue into libs/smpp-native-0.1.0.jar.
# Requires JDK 21 (matching the Ballerina 2201.13.x java21 platform).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
JDK="${JAVA21_HOME:-/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home}"
BAL_RT="${BAL_RT:-/Library/Ballerina/distributions/ballerina-2201.13.4/bre/lib/ballerina-rt-2201.13.4.jar}"
JSMPP="$HERE/build-libs/jsmpp-3.0.2.jar"

OUT="$HERE/build/classes"
LIBS="$HERE/libs"
JAR="$LIBS/smpp-native-0.1.0.jar"

rm -rf "$OUT"
mkdir -p "$OUT" "$LIBS"

echo "==> compiling native glue with $("$JDK/bin/javac" -version 2>&1)"
"$JDK/bin/javac" \
    --release 21 \
    -cp "$BAL_RT:$JSMPP" \
    -d "$OUT" \
    $(find "$HERE/native" -name '*.java')

echo "==> packaging $JAR"
"$JDK/bin/jar" --create --file "$JAR" -C "$OUT" .
echo "==> done: $(ls -la "$JAR")"
