// Copyright (c) 2026. SYNC ResponseMode: the ack reflects the handler's real outcome.
import ballerina/test;

const int SYNC_TEST_PORT = 27778;

# A deliver_sm handler that records, then fails - for proving a handler error becomes a
# negative deliver_sm_resp (ESME_RSYSERR, 0x00000008) in SYNC mode.
service class SyncFailingService {
    *Service;

    remote function onDeliverSm(Sms sms) returns error? {
        recordSms(sms);
        return error("simulated handler failure");
    }
}

Listener? syncTestListener = ();
int syncTestMockId = -1;

function cleanupSyncTest() returns error? {
    // Capture the stop outcome but ALWAYS close the mock and reset state - an early
    // `check` return here would leak the mock's port into the next test as a
    // misleading BindException (the exact failure mode Sprint 0's review reproduced).
    error? stopResult = ();
    Listener? l = syncTestListener;
    if l is Listener {
        stopResult = l.gracefulStop();
        syncTestListener = ();
    }
    if syncTestMockId != -1 {
        mockSmscClose(syncTestMockId);
        syncTestMockId = -1;
    }
    return stopResult;
}

@test:Config {after: cleanupSyncTest}
function testSyncPositiveAck() returns error? {
    clearRecorded();
    int mockId = check mockSmscOpen(SYNC_TEST_PORT);
    syncTestMockId = mockId;

    Listener smsListener = check new ({
        host: "localhost",
        port: SYNC_TEST_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER
        // responseMode defaults to SYNC
    });
    syncTestListener = smsListener;
    check smsListener.attach(new RecordingService());
    check smsListener.'start();
    int connectionId = check mockSmscAwaitNextBind(mockId, 5000);

    // SYNC: this blocks until the handler has returned and the positive resp is sent.
    check mockSmscSendDeliverSm(mockId, connectionId, "sync positive", "", 0);

    test:assertEquals(recordedCount(), 1, "handler should have run exactly once");
    test:assertEquals(recordedAt(0).shortMessage, "sync positive");
}

@test:Config {after: cleanupSyncTest}
function testSyncNegativeAck() returns error? {
    clearRecorded();
    int mockId = check mockSmscOpen(SYNC_TEST_PORT);
    syncTestMockId = mockId;

    Listener smsListener = check new ({
        host: "localhost",
        port: SYNC_TEST_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER
    });
    syncTestListener = smsListener;
    check smsListener.attach(new SyncFailingService());
    check smsListener.'start();
    int connectionId = check mockSmscAwaitNextBind(mockId, 5000);

    error? sendResult = mockSmscSendDeliverSm(mockId, connectionId, "sync negative", "", 0);
    test:assertTrue(sendResult is error,
            "a handler error in SYNC mode must surface as a negative deliver_sm_resp");
    if sendResult is error {
        // Dispatcher.dispatch converts the handler's error into ProcessRequestException
        // with STAT_ESME_RSYSERR (0x00000008); jsmpp reports it back as "System Error".
        // A Java exception crossing the interop boundary puts the class name in
        // `message()` and the real text in the error detail - assert on toString(),
        // which includes both.
        test:assertTrue(sendResult.toString().includes("00000008"),
                string `expected an ESME_RSYSERR (0x00000008) negative response, got: ${sendResult.toString()}`);
    }

    // SYNC ordering: the negative ack reflects a handler that already ran - the direct
    // counterpart to the ASYNC test's "acks before the handler completes".
    test:assertEquals(recordedCount(), 1, "the failing handler still ran (and recorded) first");
}
