// Copyright (c) 2026. Sprint 4: self-inflicted-drop / backpressure tests.
import ballerina/lang.runtime;
import ballerina/test;
import ballerina/time;

// One port per test (see tls_test.bal); Sprint 4 uses 27796-27799.
const int SYNC_KEEPALIVE_PORT = 27796;
const int SYNC_OVERFLOW_PORT = 27797;
const int ASYNC_BOUNDED_PORT = 27798;
const int BINDTIMEOUT_PORT = 27799;

// Ballerina interop surfaces a thrown Java exception's CLASS NAME as error.message(), so the
// mock throws a dedicated ThrottledException for an ESME_RTHROTTLED deliver_sm_resp - which
// is exactly what the connector's backpressure gate emits on overflow.
const string RTHROTTLED_MARKER = "ThrottledException";

Listener? bpListener = ();
int bpMockId = -1;

function cleanupBackpressure() returns error? {
    releaseGate(); // let any still-blocked handler finish so gracefulStop can drain
    Listener? l = bpListener;
    if l is Listener {
        error? stopResult = l.gracefulStop();
        bpListener = ();
        if bpMockId != -1 {
            mockSmscClose(bpMockId);
            bpMockId = -1;
        }
        return stopResult;
    }
    if bpMockId != -1 {
        mockSmscClose(bpMockId);
        bpMockId = -1;
    }
}

// (1) LOAD-BEARING: a slow SYNC handler occupying every dispatch slot must NOT provoke the
//     SMSC into dropping the link. The mock (as SMSC) probes enquire_link every 300ms and
//     closes the session if a probe goes unanswered within its 1.5s transaction timer. With
//     the keepalive reserve thread, enquire_link is always answered even while both slots are
//     blocked, so no drop (no onError) occurs. Without the reserve (degree == concurrency),
//     the probe would queue behind the blocked handlers and time out -> mock closes -> the
//     connector sees a self-inflicted drop. Mutation-verified against that regression.
@test:Config {groups: ["backpressure"], after: cleanupBackpressure}
function testSyncKeepaliveSurvivesSaturatedHandlers() returns error? {
    clearRecorded();
    clearRecordedErrors();
    resetGate();

    int mockId = check mockSmscOpen(SYNC_KEEPALIVE_PORT);
    bpMockId = mockId;
    Listener smsListener = check new ({
        host: "localhost",
        port: SYNC_KEEPALIVE_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        maxConcurrentDispatch: 2,
        responseMode: SYNC
    });
    bpListener = smsListener;
    check smsListener.attach(new GatedService());
    check smsListener.'start();
    int connId = check mockSmscAwaitNextBind(mockId, 5000);

    // Make the mock probe liveness aggressively and give up fast if unanswered.
    check mockSmscSetEnquireLinkTimer(mockId, connId, 300);
    check mockSmscSetTransactionTimer(mockId, connId, 1500);

    // Warm-up round-trip (gate not yet armed, so this is handled immediately). Its
    // deliver_sm_resp forces the mock's reader out of its initial 60s-timeout read and into a
    // read using the new 300ms enquire_link timer - so from here on the mock actually probes.
    check mockSmscSendDeliverSm(mockId, connId, "warmup", "", 0);
    test:assertTrue(pollUntil(isolated function() returns boolean {
        return recordedCount() == 1;
    }, 5), "warm-up deliver_sm should round-trip before saturation");

    // Now arm the gate and occupy both dispatch slots with handlers that block. Fire-and-
    // forget: these mock-side sends time out at the 1.5s transaction timer, but the connector
    // handlers stay blocked (holding their slots) until releaseGate() regardless.
    armGate();
    _ = start sendAndIgnore(mockId, connId, "occupy-1");
    _ = start sendAndIgnore(mockId, connId, "occupy-2");

    // Wait until both handlers are actually in (both slots occupied). Use the live count,
    // not the cumulative one: the warm-up handler already ran and exited, so it must not be
    // counted here - two blocked occupy-handlers hold the live count stably at 2.
    boolean saturated = pollUntil(isolated function() returns boolean {
        return gateConcurrentNow() == 2;
    }, 5);
    test:assertTrue(saturated, "both dispatch slots should be occupied by blocked handlers");

    // Hold the saturation for ~3s: ~10 enquire_link probe cycles at 300ms. If keepalive were
    // starved (no reserve thread), the mock's probe would go unanswered, it would close the
    // session at ~1.5s, and onError would fire. With the reserve, enquire_link is always
    // answered, so no self-inflicted drop occurs.
    runtime:sleep(3);
    test:assertEquals(recordedErrorCount(), 0,
            "keepalive must be answered while all dispatch slots are blocked - no self-inflicted drop");
}

// (2) Overflow beyond maxConcurrentDispatch is answered with ESME_RTHROTTLED, and quickly
//     (by a reserve thread, before the blocked handlers free up) - not silently queued or
//     timed out. Proves the gate NACKs excess rather than stalling.
@test:Config {groups: ["backpressure"], after: cleanupBackpressure}
function testSyncOverflowThrottled() returns error? {
    clearRecorded();
    clearRecordedErrors();
    resetGate();

    int mockId = check mockSmscOpen(SYNC_OVERFLOW_PORT);
    bpMockId = mockId;
    Listener smsListener = check new ({
        host: "localhost",
        port: SYNC_OVERFLOW_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        maxConcurrentDispatch: 2,
        responseMode: SYNC
    });
    bpListener = smsListener;
    check smsListener.attach(new GatedService());
    check smsListener.'start();
    int connId = check mockSmscAwaitNextBind(mockId, 5000);

    // Occupy both slots (armed so the handlers block).
    armGate();
    _ = start sendAndIgnore(mockId, connId, "occupy-1");
    _ = start sendAndIgnore(mockId, connId, "occupy-2");
    boolean saturated = pollUntil(isolated function() returns boolean {
        return gateConcurrentNow() == 2;
    }, 5);
    test:assertTrue(saturated, "both dispatch slots should be occupied before overflow");

    // A 3rd deliver_sm now overflows the gate: it must come back RTHROTTLED, fast.
    error? overflow = mockSmscSendDeliverSm(mockId, connId, "overflow", "", 0);
    test:assertTrue(overflow is error, "the overflow PDU must be rejected, not accepted");
    if overflow is error {
        test:assertTrue(overflow.message().includes(RTHROTTLED_MARKER),
                string `overflow must be ESME_RTHROTTLED, got: ${overflow.message()}`);
    }
}

// (3) ASYNC mode is now bounded by maxConcurrentDispatch too (previously unbounded). A burst
//     beyond the limit runs at most maxConcurrentDispatch handlers concurrently; the excess
//     is RTHROTTLED rather than spawning unbounded virtual threads.
@test:Config {groups: ["backpressure"], after: cleanupBackpressure}
function testAsyncBoundedConcurrency() returns error? {
    clearRecorded();
    clearRecordedErrors();
    resetGate();

    int mockId = check mockSmscOpen(ASYNC_BOUNDED_PORT);
    bpMockId = mockId;
    Listener smsListener = check new ({
        host: "localhost",
        port: ASYNC_BOUNDED_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        maxConcurrentDispatch: 2,
        responseMode: ASYNC
    });
    bpListener = smsListener;
    check smsListener.attach(new GatedService());
    check smsListener.'start();
    int connId = check mockSmscAwaitNextBind(mockId, 5000);

    // Burst of 5. In ASYNC the accepted ones are acked ROK immediately (send returns); the
    // overflow is RTHROTTLED (send errors). Handlers block in the gate, so the accepted ones
    // stay resident and we can observe peak concurrency.
    armGate();
    int throttled = 0;
    int i = 0;
    while i < 5 {
        error? r = mockSmscSendDeliverSm(mockId, connId, string `burst-${i}`, "", 0);
        if r is error {
            throttled += 1;
        }
        i += 1;
    }

    // Let the accepted handlers settle into the gate.
    _ = pollUntil(isolated function() returns boolean {
        return gateConcurrentNow() >= 2;
    }, 5);
    runtime:sleep(0.5);

    test:assertTrue(gateMaxConcurrent() <= 2,
            string `ASYNC concurrency must be bounded by maxConcurrentDispatch (2), observed peak ${gateMaxConcurrent()}`);
    test:assertEquals(gateMaxConcurrent(), 2, "both slots should be used under a 5-PDU burst");
    test:assertEquals(throttled, 3, "3 of the 5 burst PDUs should be RTHROTTLED while 2 slots are held");
}

// (4) The configurable bindTimeout bounds the bind handshake against a half-open SMSC (TCP
//     accepts, bind never answered). Without it, jsmpp's hardcoded 60s default would apply;
//     with bindTimeout: 2 the attempt must fail in a small multiple of 2s, well under 60s.
int bpBlackHoleId = -1;

function cleanupBlackHole() {
    if bpBlackHoleId != -1 {
        mockSmscCloseBlackHole(bpBlackHoleId);
        bpBlackHoleId = -1;
    }
}

@test:Config {groups: ["backpressure"], after: cleanupBlackHole}
function testBindTimeoutBoundsHalfOpenConnect() returns error? {
    bpBlackHoleId = check mockSmscOpenBlackHole(BINDTIMEOUT_PORT);
    Listener smsListener = check new ({
        host: "localhost",
        port: BINDTIMEOUT_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        bindTimeout: 2
    });
    check smsListener.attach(new RecordingService());

    decimal t0 = time:monotonicNow();
    error? startResult = smsListener.'start();
    decimal elapsed = time:monotonicNow() - t0;
    error? stopResult = smsListener.immediateStop();
    _ = stopResult is error; // half-open teardown; nothing actionable

    test:assertTrue(startResult is error, "start() must fail against a half-open SMSC that never answers the bind");
    test:assertTrue(elapsed < 20d,
            string `bind must give up near bindTimeout (2s), not jsmpp's 60s default; took ${elapsed}s`);
}

// Fires a mock-side deliver_sm and swallows the result. Used only to occupy a dispatch slot;
// the send itself will time out at the mock's transaction timer while the connector handler
// stays blocked in the gate, which is fine - the slot is what we want held.
isolated function sendAndIgnore(int mockId, int connId, string text) {
    error? sendResult = mockSmscSendDeliverSm(mockId, connId, text, "", 0);
    _ = sendResult is error; // expected to time out at the mock's transaction timer; ignored
}
