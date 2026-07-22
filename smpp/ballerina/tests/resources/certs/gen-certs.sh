#!/bin/sh
# Test-only self-signed material for the TLS suite (tls_test.bal). Re-run to regenerate
# on expiry (validity 3650d). PKCS12, password "password" for every store (keytool
# requires keypass == storepass for PKCS12). NEVER used for anything real.
set -eu
cd "$(dirname "$0")"
PW=password

rm -f server-keystore.p12 client-truststore.p12 wrong-truststore.p12 wrong.crt \
      client-keystore.p12 server-truststore.p12 server.crt client.crt \
      wronghost-keystore.p12 wronghost-truststore.p12 wronghost.crt

# --- server identity: CN=localhost + localhost SAN so hostname verification passes
#     (the connector enables JSSE endpoint identification by default) ---
keytool -genkeypair -alias smpp-mock-server -keyalg RSA -keysize 2048 -validity 3650 \
  -dname "CN=localhost, OU=smpp-test, O=ramith, C=LK" \
  -ext "SAN=DNS:localhost,IP:127.0.0.1" \
  -keystore server-keystore.p12 -storetype PKCS12 -storepass "$PW" -keypass "$PW"
keytool -exportcert -alias smpp-mock-server -rfc \
  -keystore server-keystore.p12 -storetype PKCS12 -storepass "$PW" -file server.crt
keytool -importcert -noprompt -alias smpp-mock-server -file server.crt \
  -keystore client-truststore.p12 -storetype PKCS12 -storepass "$PW"

# --- an UNRELATED cert, also CN=localhost, so the negative test fails ONLY on trust
#     (chain-of-trust is the single variable; hostname identity is identical) ---
keytool -genkeypair -alias other -keyalg RSA -keysize 2048 -validity 3650 \
  -dname "CN=localhost, OU=other, O=other, C=LK" \
  -ext "SAN=DNS:localhost,IP:127.0.0.1" \
  -keystore other-keystore.p12 -storetype PKCS12 -storepass "$PW" -keypass "$PW"
# Kept as wrong.crt (PEM) too, for the PEM-form negative test (cert: string path).
keytool -exportcert -alias other -rfc \
  -keystore other-keystore.p12 -storetype PKCS12 -storepass "$PW" -file wrong.crt
keytool -importcert -noprompt -alias other -file wrong.crt \
  -keystore wrong-truststore.p12 -storetype PKCS12 -storepass "$PW"

# --- client identity for mTLS (CN need not be localhost; servers verify trust, not host) ---
keytool -genkeypair -alias smpp-client -keyalg RSA -keysize 2048 -validity 3650 \
  -dname "CN=smpp-test-client, OU=smpp-test, O=ramith, C=LK" \
  -keystore client-keystore.p12 -storetype PKCS12 -storepass "$PW" -keypass "$PW"
keytool -exportcert -alias smpp-client -rfc \
  -keystore client-keystore.p12 -storetype PKCS12 -storepass "$PW" -file client.crt
keytool -importcert -noprompt -alias smpp-client -file client.crt \
  -keystore server-truststore.p12 -storetype PKCS12 -storepass "$PW"

# --- a TRUSTED cert whose identity is NOT localhost, for the hostname-verification test.
#     Dialed as "localhost", so the chain verifies (client trusts it) but the hostname
#     check must fail - isolating hostname verification as the single variable. ---
keytool -genkeypair -alias wronghost -keyalg RSA -keysize 2048 -validity 3650 \
  -dname "CN=not-localhost, OU=smpp-test, O=ramith, C=LK" \
  -ext "SAN=DNS:not-localhost" \
  -keystore wronghost-keystore.p12 -storetype PKCS12 -storepass "$PW" -keypass "$PW"
keytool -exportcert -alias wronghost -rfc \
  -keystore wronghost-keystore.p12 -storetype PKCS12 -storepass "$PW" -file wronghost.crt
keytool -importcert -noprompt -alias wronghost -file wronghost.crt \
  -keystore wronghost-truststore.p12 -storetype PKCS12 -storepass "$PW"

rm -f other-keystore.p12 client.crt wronghost.crt   # intermediates (wrong.crt is kept)
echo "done."
