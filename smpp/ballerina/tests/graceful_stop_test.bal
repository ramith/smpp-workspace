// Copyright (c) 2026. gracefulStop drains in-flight SYNC dispatch (Sprint 2 exit gate e).
import ballerina/test;
import ballerina/time;

const int GRACEFUL_STOP_TEST_PORT = 27784;

Listener? gracefulStopTestListener = ();
int gracefulStopTestMockId = -1;

function cleanupGracefulStopTest() returns error? {
    error? stopResult = ();
    Listener? l = gracefulStopTestListener;
    if l is Listener {
        stopResult = l.gracefulStop();
        gracefulStopTestListener = ();
    }
    if gracefulStopTestMockId != -1 {
        mockSmscClose(gracefulStopTestMockId);
        gracefulStopTestMockId = -1;
    }
    return stopResult;
}

@test:Config {after: cleanupGracefulStopTest, groups: ["lifecycle"]}
function testGracefulStopWaitsForInFlightSyncDispatch() returns error? {
    clearRecorded();
    clearRecordedErrors();
    resetSlowHandlerMarkers();
    int mockId = check mockSmscOpen(GRACEFUL_STOP_TEST_PORT);
    gracefulStopTestMockId = mockId;

    Listener smsListener = check new ({
        host: "localhost",
        port: GRACEFUL_STOP_TEST_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        gracefulStopTimeout: 20
    });
    gracefulStopTestListener = smsListener;
    check smsListener.attach(new SlowRecordingService(3));
    check smsListener.'start();
    int conn = check mockSmscAwaitNextBind(mockId, 5000);

    // The mock's blocking send must outwait the 3s handler (jsmpp default 2s would
    // time out mid-test).
    check mockSmscSetTransactionTimer(mockId, conn, 15000);

    future<error?> sendF = start mockSmscSendDeliverSm(mockId, conn, "slow sync dispatch", "", 0);
    test:assertTrue(pollUntil(isSlowHandlerStarted, 5), "handler never started within 5s");

    decimal t0 = time:monotonicNow();
    check smsListener.gracefulStop();
    decimal stopElapsed = time:monotonicNow() - t0;
    gracefulStopTestListener = ();

    // Core assertion - ordering, not wall clock:
    test:assertTrue(isSlowHandlerCompleted(),
            "gracefulStop returned while the SYNC handler was still in flight - the drain did not wait");
    // Corroborating bounds: the handler had ~2.9s of sleep left when stop was called.
    test:assertTrue(stopElapsed >= 1.0d,
            string `stop returned in ${stopElapsed}s - too fast to have drained a 3s handler`);
    test:assertTrue(stopElapsed <= 10.0d,
            string `stop took ${stopElapsed}s - the drain did not exit once in-flight hit zero`);

    // Handler completed before the unbind, so the mock got its deliver_sm_resp.
    // (Theoretical sub-50ms race: awaitDrain covers handler completion, not jsmpp's
    // resp write. If this ever flakes in CI, downgrade to completion-only.)
    error? sendResult = wait sendF;
    test:assertTrue(sendResult is (), "the drained dispatch's resp must reach the mock");

    test:assertEquals(recordedCount(), 1);
    test:assertEquals(recordedErrorCount(), 0, "user-initiated gracefulStop must not fire onError");
    int|error noBind = mockSmscAwaitNextBind(mockId, 1500);
    test:assertTrue(noBind is error, "gracefulStop must not schedule a rebind");
}
