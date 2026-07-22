// Copyright (c) 2026. ASYNC ResponseMode: the ack precedes (and never reflects) the handler.
import ballerina/lang.runtime;
import ballerina/test;

const int ASYNC_TEST_PORT = 27779;

isolated boolean asyncHandlerCompleted = false;

isolated function markAsyncHandlerCompleted() {
    lock {
        asyncHandlerCompleted = true;
    }
}

isolated function isAsyncHandlerCompleted() returns boolean {
    lock {
        return asyncHandlerCompleted;
    }
}

isolated function resetAsyncHandlerCompleted() {
    lock {
        asyncHandlerCompleted = false;
    }
}

# Sleeps well past any loopback round-trip before recording/completing - the ordering
# marker for proving the SMSC ack arrived while the handler was still running. A
# correctness assertion on ordering, not a wall-clock threshold: no tight-sleep tuning
# knob to go flaky under CI load.
service class AsyncSlowService {
    *Service;

    remote function onDeliverSm(Sms sms) returns error? {
        runtime:sleep(3);
        recordSms(sms);
        markAsyncHandlerCompleted();
    }
}

# Fails after marking completion - for proving an ASYNC handler failure is never
# reflected back to the SMSC (the positive ack was already sent).
service class AsyncFailingService {
    *Service;

    remote function onDeliverSm(Sms sms) returns error? {
        markAsyncHandlerCompleted();
        return error("simulated async handler failure");
    }
}

Listener? asyncTestListener = ();
int asyncTestMockId = -1;

function cleanupAsyncTest() returns error? {
    // Capture the stop outcome but ALWAYS close the mock and reset state - an early
    // `check` return here would leak the mock's port into the next test as a
    // misleading BindException (the exact failure mode Sprint 0's review reproduced).
    error? stopResult = ();
    Listener? l = asyncTestListener;
    if l is Listener {
        stopResult = l.gracefulStop();
        asyncTestListener = ();
    }
    if asyncTestMockId != -1 {
        mockSmscClose(asyncTestMockId);
        asyncTestMockId = -1;
    }
    return stopResult;
}

@test:Config {after: cleanupAsyncTest}
function testAsyncAcksBeforeHandlerCompletes() returns error? {
    clearRecorded();
    resetAsyncHandlerCompleted();
    int mockId = check mockSmscOpen(ASYNC_TEST_PORT);
    asyncTestMockId = mockId;

    Listener smsListener = check new ({
        host: "localhost",
        port: ASYNC_TEST_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        responseMode: ASYNC
    });
    asyncTestListener = smsListener;
    check smsListener.attach(new AsyncSlowService());
    check smsListener.'start();
    int connectionId = check mockSmscAwaitNextBind(mockId, 5000);

    // ASYNC: this returns as soon as the connector acks - long before the handler's
    // 3-second sleep can have finished.
    check mockSmscSendDeliverSm(mockId, connectionId, "async ordering", "", 0);
    test:assertFalse(isAsyncHandlerCompleted(),
            "the ack arrived, so the handler must still be mid-flight - ASYNC acks first");

    // Now wait (bounded) for the handler to actually finish, and confirm it delivered.
    int attempts = 0;
    while !isAsyncHandlerCompleted() && attempts < 100 {
        runtime:sleep(0.1);
        attempts += 1;
    }
    test:assertTrue(isAsyncHandlerCompleted(), "handler never completed within 10s");
    test:assertEquals(recordedCount(), 1);
    test:assertEquals(recordedAt(0).shortMessage, "async ordering");
}

@test:Config {after: cleanupAsyncTest}
function testAsyncHandlerFailureNeverReflectedToSmsc() returns error? {
    clearRecorded();
    resetAsyncHandlerCompleted();
    int mockId = check mockSmscOpen(ASYNC_TEST_PORT);
    asyncTestMockId = mockId;

    Listener smsListener = check new ({
        host: "localhost",
        port: ASYNC_TEST_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        responseMode: ASYNC
    });
    asyncTestListener = smsListener;
    check smsListener.attach(new AsyncFailingService());
    check smsListener.'start();
    int connectionId = check mockSmscAwaitNextBind(mockId, 5000);

    // Pins ResponseMode.ASYNC's documented contract: the handler's failure can never
    // become a negative command_status, because the positive ack already went out.
    check mockSmscSendDeliverSm(mockId, connectionId, "async failure invisible", "", 0);

    // Confirm the handler did run (and fail) - the send succeeding wasn't because the
    // handler never executed.
    int attempts = 0;
    while !isAsyncHandlerCompleted() && attempts < 100 {
        runtime:sleep(0.1);
        attempts += 1;
    }
    test:assertTrue(isAsyncHandlerCompleted(), "handler never ran within 10s");
}
