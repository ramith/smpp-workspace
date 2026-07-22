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
    test:assertTrue(stopElapsed <= 2.0d,
            string `immediateStop took ${stopElapsed}s with a 5s handler running - it must return without draining`);

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
