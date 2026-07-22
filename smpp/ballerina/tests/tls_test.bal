// Copyright (c) 2026. TLS transport: handshake + bind + dispatch round-trip, the dev-only
// no-verify path, and the negative test that proves verification actually happens.
import ballerina/test;

// One port per test (avoids TIME_WAIT reopen flakiness); next free after 27776-27787.
const int TLS_TEST_PORT = 27788;
const int TLS_NOVERIFY_PORT = 27789;
const int TLS_NEGATIVE_PORT = 27790;
const int MTLS_TEST_PORT = 27791;
const int TLS_PEM_TEST_PORT = 27792;
const int TLS_PEM_NEGATIVE_PORT = 27793;
const int MTLS_NEGATIVE_PORT = 27794;
const int TLS_HOSTNAME_PORT = 27795;

const string CERTS = "tests/resources/certs";
const string SERVER_KEYSTORE = CERTS + "/server-keystore.p12";
const string CLIENT_TRUSTSTORE = CERTS + "/client-truststore.p12";
const string SERVER_CERT_PEM = CERTS + "/server.crt";
const string WRONG_TRUSTSTORE = CERTS + "/wrong-truststore.p12";
const string WRONG_CERT_PEM = CERTS + "/wrong.crt";
const string CLIENT_KEYSTORE = CERTS + "/client-keystore.p12";
const string SERVER_TRUSTSTORE = CERTS + "/server-truststore.p12";
const string WRONGHOST_KEYSTORE = CERTS + "/wronghost-keystore.p12";
const string WRONGHOST_TRUSTSTORE = CERTS + "/wronghost-truststore.p12";
const string CERT_PASS = "password";

Listener? tlsTestListener = ();
int tlsTestMockId = -1;

function cleanupTlsTest() returns error? {
    error? stopResult = ();
    Listener? l = tlsTestListener;
    if l is Listener {
        stopResult = l.gracefulStop();   // idempotent no-op after a failed start() too
        tlsTestListener = ();
    }
    if tlsTestMockId != -1 {
        mockSmscClose(tlsTestMockId);
        tlsTestMockId = -1;
    }
    return stopResult;
}

// (a) HAPPY PATH: full deliver_sm round-trip over TLS, connector verifying the mock's cert
//     against a committed truststore. Proves the WHOLE encrypted path works.
@test:Config {groups: ["tls"], after: cleanupTlsTest}
function testTlsBindAndDeliverRoundTrip() returns error? {
    clearRecorded();
    int mockId = check mockSmscOpenTls(TLS_TEST_PORT, SERVER_KEYSTORE, CERT_PASS);
    tlsTestMockId = mockId;

    Listener smsListener = check new ({
        host: "localhost",
        port: TLS_TEST_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        secureSocket: {
            cert: {path: CLIENT_TRUSTSTORE, password: CERT_PASS}
        }
    });
    tlsTestListener = smsListener;
    check smsListener.attach(new RecordingService());

    // Returning without error means the TLS handshake AND the SMPP bind both succeeded.
    check smsListener.'start();
    int connectionId = check mockSmscAwaitNextBind(mockId, 5000);

    // deliver_sm pushed back down the SAME TLS socket -> dispatch -> Sms -> deliver_sm_resp.
    check mockSmscSendDeliverSm(mockId, connectionId, "tls round-trip", "", 0);

    test:assertEquals(recordedCount(), 1, "the deliver_sm should have arrived over TLS");
    test:assertEquals(recordedAt(0).shortMessage, "tls round-trip");
}

// (a2) HAPPY PATH via a PEM CA-cert path instead of a truststore record — proves the
//      `cert: string` form of the config resolves and verifies identically.
@test:Config {groups: ["tls"], after: cleanupTlsTest}
function testTlsWithPemCertRoundTrip() returns error? {
    clearRecorded();
    int mockId = check mockSmscOpenTls(TLS_PEM_TEST_PORT, SERVER_KEYSTORE, CERT_PASS);
    tlsTestMockId = mockId;

    Listener smsListener = check new ({
        host: "localhost",
        port: TLS_PEM_TEST_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        secureSocket: {
            cert: SERVER_CERT_PEM   // PEM path, not a truststore record
        }
    });
    tlsTestListener = smsListener;
    check smsListener.attach(new RecordingService());
    check smsListener.'start();
    int connectionId = check mockSmscAwaitNextBind(mockId, 5000);
    check mockSmscSendDeliverSm(mockId, connectionId, "pem tls", "", 0);
    test:assertEquals(recordedCount(), 1, "PEM-cert TLS should deliver end-to-end");
}

// (b) DEV-ONLY NO-VERIFY PATH: connector trusts the self-signed cert WITHOUT verification.
//     Proves the clearly-labeled InsecureSocket path works.
@test:Config {groups: ["tls"], after: cleanupTlsTest}
function testTlsVerificationDisabledConnects() returns error? {
    clearRecorded();
    int mockId = check mockSmscOpenTls(TLS_NOVERIFY_PORT, SERVER_KEYSTORE, CERT_PASS);
    tlsTestMockId = mockId;

    Listener smsListener = check new ({
        host: "localhost",
        port: TLS_NOVERIFY_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        secureSocket: {
            disableSslVerification: true   // InsecureSocket: encrypt but don't verify
        }
    });
    tlsTestListener = smsListener;
    check smsListener.attach(new RecordingService());

    check smsListener.'start();                                   // succeeds despite no trust anchor
    int connectionId = check mockSmscAwaitNextBind(mockId, 5000);
    check mockSmscSendDeliverSm(mockId, connectionId, "insecure tls", "", 0);
    test:assertEquals(recordedCount(), 1, "no-verify TLS should still deliver end-to-end");
}

// (c) NEGATIVE: connector verifies against a truststore that does NOT contain the mock's
//     cert. The mock always presents its own CN=localhost leaf, so the hostname check
//     passes uniformly and chain-of-trust is the only variable. start() MUST fail. This
//     is the test that makes the security claim real: if it ever passes, "verification"
//     is a lie. (Hostname verification itself is proven by test (e) below.)
@test:Config {groups: ["tls"], after: cleanupTlsTest}
function testTlsUntrustedServerCertFailsHandshake() returns error? {
    int mockId = check mockSmscOpenTls(TLS_NEGATIVE_PORT, SERVER_KEYSTORE, CERT_PASS);
    tlsTestMockId = mockId;

    Listener smsListener = check new ({
        host: "localhost",
        port: TLS_NEGATIVE_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        secureSocket: {
            cert: {path: WRONG_TRUSTSTORE, password: CERT_PASS}   // does NOT trust the mock
        }
    });
    tlsTestListener = smsListener;
    check smsListener.attach(new RecordingService());

    error? startResult = smsListener.'start();
    test:assertTrue(startResult is error,
            "start() MUST fail the TLS handshake against an untrusted server certificate");
    if startResult is error {
        // start() wraps any bind/handshake failure with this prefix; the underlying
        // PKIX/SSLHandshake wording varies by JDK, so assert only on the stable wrapper.
        test:assertTrue(startResult.message().includes("failed to connect/bind to SMSC"),
                string `unexpected error surface: ${startResult.message()}`);
        // Discriminating check: the failure must be a TLS trust rejection, NOT an
        // incidental local keystore-load error (which would be a false green - the test
        // passing without ever proving verification happened).
        test:assertFalse(startResult.message().includes("unable to load the key store"),
                string `negative test failed for the wrong reason - keystore load error, not trust rejection: ${startResult.message()}`);
    }
    // Belt-and-suspenders: nothing ever bound on the mock side.
    int|error boundConn = mockSmscAwaitNextBind(mockId, 1500);
    test:assertTrue(boundConn is error, "no bind may complete on an aborted TLS handshake");
}

// (c2) NEGATIVE via the PEM `cert: string` form: proves trustManagersForPemCert actually
//      REJECTS an untrusted cert (the happy-path PEM test only proves it accepts a trusted
//      one). The presented leaf is still the mock's CN=localhost cert, so trust is the
//      only variable here too.
@test:Config {groups: ["tls"], after: cleanupTlsTest}
function testTlsUntrustedServerCertViaPemFailsHandshake() returns error? {
    int mockId = check mockSmscOpenTls(TLS_PEM_NEGATIVE_PORT, SERVER_KEYSTORE, CERT_PASS);
    tlsTestMockId = mockId;

    Listener smsListener = check new ({
        host: "localhost",
        port: TLS_PEM_NEGATIVE_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        secureSocket: {
            cert: WRONG_CERT_PEM   // PEM of an unrelated cert; does NOT match the mock
        }
    });
    tlsTestListener = smsListener;
    check smsListener.attach(new RecordingService());

    error? startResult = smsListener.'start();
    test:assertTrue(startResult is error,
            "start() MUST fail against an untrusted server cert (PEM trust form)");
    if startResult is error {
        test:assertTrue(startResult.message().includes("failed to connect/bind to SMSC"),
                string `unexpected error surface: ${startResult.message()}`);
        test:assertFalse(startResult.message().includes("unable to load the key store"),
                string `PEM negative failed for the wrong reason: ${startResult.message()}`);
    }
}

// (e) HOSTNAME VERIFICATION, default ON: the mock presents a cert the connector TRUSTS
//     (chain verifies) whose CN/SAN is `not-localhost`, but the connector dials
//     `localhost` - so the ONLY thing that can fail is the hostname check. start() MUST
//     fail. This is the test that proves setEndpointIdentificationAlgorithm("HTTPS") is
//     actually in effect; without it, a trusted-but-wrong-host cert would be accepted.
@test:Config {groups: ["tls"], after: cleanupTlsTest}
function testTlsHostnameMismatchFailsWithVerifyOn() returns error? {
    int mockId = check mockSmscOpenTls(TLS_HOSTNAME_PORT, WRONGHOST_KEYSTORE, CERT_PASS);
    tlsTestMockId = mockId;

    Listener smsListener = check new ({
        host: "localhost",                          // dialed name...
        port: TLS_HOSTNAME_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        secureSocket: {
            cert: {path: WRONGHOST_TRUSTSTORE, password: CERT_PASS}   // ...trusts the CN=not-localhost cert
            // verifyHostName defaults to true
        }
    });
    tlsTestListener = smsListener;
    check smsListener.attach(new RecordingService());

    error? startResult = smsListener.'start();
    test:assertTrue(startResult is error,
            "start() MUST fail: cert is trusted but its identity (not-localhost) does not match the dialed host (localhost)");
    if startResult is error {
        test:assertTrue(startResult.message().includes("failed to connect/bind to SMSC"),
                string `unexpected error surface: ${startResult.message()}`);
        // Not a trust failure (the cert IS trusted) and not a keystore-load error.
        test:assertFalse(startResult.message().includes("unable to load the key store"),
                string `hostname test failed for the wrong reason: ${startResult.message()}`);
    }
}

// (e2) HOSTNAME VERIFICATION disabled: the same trusted-but-wrong-host cert now connects,
//      because verifyHostName:false relaxes the hostname check - while the chain is STILL
//      verified (the cert is in the truststore). Proves the knob works AND that relaxing
//      it doesn't disable chain validation.
@test:Config {groups: ["tls"], after: cleanupTlsTest}
function testTlsHostnameMismatchAllowedWithVerifyOff() returns error? {
    clearRecorded();
    int mockId = check mockSmscOpenTls(TLS_HOSTNAME_PORT, WRONGHOST_KEYSTORE, CERT_PASS);
    tlsTestMockId = mockId;

    Listener smsListener = check new ({
        host: "localhost",
        port: TLS_HOSTNAME_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        secureSocket: {
            cert: {path: WRONGHOST_TRUSTSTORE, password: CERT_PASS},
            verifyHostName: false
        }
    });
    tlsTestListener = smsListener;
    check smsListener.attach(new RecordingService());

    check smsListener.'start();   // succeeds: chain verified, hostname check relaxed
    int connectionId = check mockSmscAwaitNextBind(mockId, 5000);
    check mockSmscSendDeliverSm(mockId, connectionId, "hostname relaxed", "", 0);
    test:assertEquals(recordedCount(), 1, "verifyHostName:false should still connect and deliver");
}

// (d) mTLS round-trip: connector presents a client cert the mock's truststore accepts,
//     and verifies the server cert in the same handshake.
@test:Config {groups: ["tls"], after: cleanupTlsTest}
function testMutualTlsRoundTrip() returns error? {
    clearRecorded();
    int mockId = check mockSmscOpenMutualTls(MTLS_TEST_PORT, SERVER_KEYSTORE, CERT_PASS,
            SERVER_TRUSTSTORE, CERT_PASS);
    tlsTestMockId = mockId;

    Listener smsListener = check new ({
        host: "localhost",
        port: MTLS_TEST_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        secureSocket: {
            cert: {path: CLIENT_TRUSTSTORE, password: CERT_PASS},   // verify the server
            key: {path: CLIENT_KEYSTORE, password: CERT_PASS}       // present client identity
        }
    });
    tlsTestListener = smsListener;
    check smsListener.attach(new RecordingService());

    check smsListener.'start();
    int connectionId = check mockSmscAwaitNextBind(mockId, 5000);
    check mockSmscSendDeliverSm(mockId, connectionId, "mtls round-trip", "", 0);
    test:assertEquals(recordedCount(), 1, "mTLS deliver_sm should round-trip");
    test:assertEquals(recordedAt(0).shortMessage, "mtls round-trip");
}

// (d2) NEGATIVE mTLS: the mock REQUIRES a client cert (setNeedClientAuth), but the
//      connector presents none (no `key`). start() MUST fail. This is what proves the
//      server actually *demands* mutual auth - the happy-path mTLS test above passes
//      whether or not client auth is enforced, so on its own it proves nothing about
//      enforcement.
@test:Config {groups: ["tls"], after: cleanupTlsTest}
function testMutualTlsRequiresClientCert() returns error? {
    int mockId = check mockSmscOpenMutualTls(MTLS_NEGATIVE_PORT, SERVER_KEYSTORE, CERT_PASS,
            SERVER_TRUSTSTORE, CERT_PASS);
    tlsTestMockId = mockId;

    Listener smsListener = check new ({
        host: "localhost",
        port: MTLS_NEGATIVE_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        secureSocket: {
            cert: {path: CLIENT_TRUSTSTORE, password: CERT_PASS}   // verifies the server, but NO client key
        }
    });
    tlsTestListener = smsListener;
    check smsListener.attach(new RecordingService());

    error? startResult = smsListener.'start();
    test:assertTrue(startResult is error,
            "start() MUST fail: the mock requires a client cert and the connector presented none");
    if startResult is error {
        test:assertTrue(startResult.message().includes("failed to connect/bind to SMSC"),
                string `unexpected error surface: ${startResult.message()}`);
    }
}

// DISABLED pending a design decision (Sprint-3 Phase-1 review, "Finding B").
// A cert-TRUST failure discovered at REBIND time (server rotates to an untrusted cert, or
// a permanent misconfig only reached after an initial good bind) is caught in attemptRebind
// and rescheduled forever under maxRebindAttempts (default -1). Open question: should a TLS
// trust failure be TERMINAL (one final onError, no retry) rather than retried like a
// transient network drop? If terminal is chosen, this test pins it: sever a bound TLS
// session, have the mock reopen presenting an untrusted cert, and assert onError fires a
// bounded number of times and rebinding stops.
// @test:Config {enable: false, groups: ["tls"], after: cleanupTlsTest}
// function testTlsTrustFailureAtRebindIsTerminal() returns error? { }
