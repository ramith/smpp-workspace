// Copyright (c) 2026. immediateStop does NOT drain (Sprint 2 exit gate f).
import ballerina/test;
import ballerina/time;

const int IMMEDIATE_STOP_TEST_PORT = 27785;

Listener? immediateStopTestListener = ();
int immediateStopTestMockId = -1;

function cleanupImmediateStopTest() returns error? {
    error? stopResult = ();
    Listener? l = immediateStopTestListener;
    if l is Listener {
        stopResult = l.immediateStop();
        immediateStopTestListener = ();
    }
    if immediateStopTestMockId != -1 {
        mockSmscClose(immediateStopTestMockId);
        immediateStopTestMockId = -1;
    }
    return stopResult;
}

@test:Config {after: cleanupImmediateStopTest, groups: ["lifecycle"]}
function testImmediateStopDoesNotWaitForInFlightDispatch() returns error? {
    clearRecorded();
    clearRecordedErrors();
    resetSlowHandlerMarkers();
    int mockId = check mockSmscOpen(IMMEDIATE_STOP_TEST_PORT);
    immediateStopTestMockId = mockId;

    Listener smsListener = check new ({
        host: "localhost",
        port: IMMEDIATE_STOP_TEST_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER
    });
    immediateStopTestListener = smsListener;
    // 5s handler widens the window. Transaction timer deliberately left at jsmpp's 2s
    // default: the resp path is cut by immediateStop anyway, and the default bounds how
    // long the dangling send future lives.
    check smsListener.attach(new SlowRecordingService(5));
    check smsListener.'start();
    int conn = check mockSmscAwaitNextBind(mockId, 5000);

    future<error?> sendF = start mockSmscSendDeliverSm(mockId, conn, "slow dispatch", "", 0);
    test:assertTrue(pollUntil(isSlowHandlerStarted, 5), "handler never started within 5s");

    decimal t0 = time:monotonicNow();
    check smsListener.immediateStop();
    decimal stopElapsed = time:monotonicNow() - t0;
    immediateStopTestListener = ();

    test:assertFalse(isSlowHandlerCompleted(),
            "immediateStop waited for the in-flight handler - it must not");
    // Tightened from <=2.0 (Sprint 8.5): the old bound was vacuous - it could not
    // distinguish "returned immediately" from "burned the whole 2s submit sweep", which
    // is exactly the unrecorded wait stage-2 finding F5 caught sitting outside
    // if(graceful). Regression signatures sit at >=2s (sweep) and >=5s (drain); 1s
    // leaves docker-CI headroom while still separating them from the healthy path.
    test:assertTrue(stopElapsed <= 1.0d,
            string `immediateStop took ${stopElapsed}s with a 5s handler running - it must return without draining or sweeping`);

    // Outcome deliberately not asserted: the session closed mid-dispatch; jsmpp surfaces
    // either an IO failure or a 2s ResponseTimeoutException depending on close timing.
    error? danglingSendOutcome = wait sendF;
    if danglingSendOutcome is error {
        // expected in most interleavings; nothing to assert either way
    }

    // Teardown hygiene: let the handler finish before cleanup closes the mock, so its
    // late resp attempt can't interleave with the next test file.
    test:assertTrue(pollUntil(isSlowHandlerCompleted, 15), "handler never completed");
    test:assertEquals(recordedErrorCount(), 0,
            "user-initiated immediateStop must not fire onError or rebind");
}

const int IMMEDIATE_STOP_SUBMIT_PORT = 27826;

// The assertion whose absence let H4 ship: a submit already parked awaiting its
// submit_sm_resp when immediateStop closes the session. jsmpp has no
// fail-pending-on-close, so the submit is NOT woken - it completes at its full
// transactionTimeout - and before Sprint 8.5 it then surfaced TIMEOUT_DELIVERY_UNKNOWN,
// pointing the operator at delivery receipts that can never arrive on a stopped
// listener. Pins the honest outcome: LINK_DOWN, possiblySubmitted=true, message naming
// the connector's own close.
@test:Config {after: cleanupImmediateStopTest, groups: ["lifecycle"]}
function testImmediateStopWithParkedSubmitYieldsSelfClosedLinkDown() returns error? {
    clearCapturedCaller();
    int mockId = check mockSmscOpen(IMMEDIATE_STOP_SUBMIT_PORT);
    immediateStopTestMockId = mockId;
    Listener smsListener = check new ({
        host: "localhost",
        port: IMMEDIATE_STOP_SUBMIT_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        // Short on purpose: the parked submit completes only at this timeout, and the
        // test must not sit out the 30s default to observe it.
        transactionTimeout: 2
    });
    immediateStopTestListener = smsListener;
    check smsListener.attach(new CallerCapturingService());
    check smsListener.'start();
    int conn = check mockSmscAwaitNextBind(mockId, 5000);
    check mockSmscSendDeliverSm(mockId, conn, "capture", "", 0);
    test:assertTrue(pollUntil(isolated function() returns boolean {
        return capturedCaller() !is ();
    }, 5), "the dispatch never delivered a Caller");
    Caller caller = <Caller>capturedCaller();

    // The mock delays every submit_sm_resp beyond the submit timeout, so the submit is
    // provably parked in the response wait when the stop lands.
    mockSmscSetSubmitDelay(mockId, 10000);
    future<SubmitResult|Error> parked = start submitBlocker(caller);
    // The mock capturing the PDU proves the submit was WRITTEN - parked, not pre-send.
    _ = check mockSmscAwaitNextSubmit(mockId, conn, 5000);

    decimal t0 = time:monotonicNow();
    check smsListener.immediateStop();
    decimal stopElapsed = time:monotonicNow() - t0;
    immediateStopTestListener = ();
    // The mock's delayed handler occupies its processor thread, so our unbind_resp can
    // itself go unanswered for ~2s (the housekeeping bound) - the assertion here is
    // only that stop() is BOUNDED well under the watchdog + park times, not instant.
    test:assertTrue(stopElapsed <= 3.5d,
            string `immediateStop took ${stopElapsed}s - the close choreography must be bounded`);

    SubmitResult|Error outcome = wait parked;
    test:assertTrue(outcome is Error, "the parked submit must fail once its timeout lapses");
    Error e = <Error>outcome;
    test:assertEquals(e.detail().failureMode, LINK_DOWN,
            "a connector-closed session must NOT masquerade as an SMSC timeout (H4)");
    test:assertEquals(e.detail().possiblySubmitted, true,
            "the PDU was written before the close - a retry may duplicate");
    test:assertTrue(e.message().includes("closed the session"),
            string `the message must name the connector's own close: ${e.message()}`);
}
