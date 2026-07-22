# Test-only TLS fixtures

Self-signed certificates and PKCS12 stores for `tests/tls_test.bal`. **Test-only —
never use any of this material for anything real.** Every store's password is
`password`, and the private keys are deliberately committed.

| File | Contents | Used by |
|---|---|---|
| `server-keystore.p12` | mock SMSC's cert + private key (`CN=localhost`, SAN `localhost`/`127.0.0.1`) | the mock (presents this cert) |
| `client-truststore.p12` | only the server's public cert | connector (verifies the mock) |
| `server.crt` | the server's public cert, PEM | connector's PEM `cert` path form |
| `wrong-truststore.p12` | an unrelated cert — deliberately **also** `CN=localhost`, so the negative test can only fail on chain-of-trust, never on hostname | connector (negative test) |
| `client-keystore.p12` | client cert + key (`CN=smpp-test-client`) | connector (mTLS identity) |
| `server-truststore.p12` | only the client's public cert | the mock (verifies the client, mTLS) |

Validity is 3650 days from generation (generated 2026-07-22; expires ~2036). To
regenerate on expiry: `./gen-certs.sh` (requires `keytool` from any JDK), then commit
the refreshed files.
