#!/usr/bin/env bash
# Builds every example against the published ramith/smpp connector, plus the mock
# SMSC harness. Used by CI and handy locally to confirm the examples still compile.
set -euo pipefail
cd "$(dirname "$0")"

echo "=== building mock SMSC harness ==="
( cd mock-smsc && ./gradlew --console=plain compileJava )

for ex in receive-sms delivery-receipts two-way-sms resilient-listener tls-smsc; do
    echo "=== bal build: $ex ==="
    ( cd "$ex" && bal build )
done

echo "=== all examples built ==="
