// Copyright (c) 2026. State-machine start()/stop() semantics (Sprint 2 exit gate a, b).
import ballerina/test;

const int LIFECYCLE_START_TEST_PORT = 27782;
// Pinned wordings from the Sprint 2 state-machine design (substring match, so
// peripheral rewording doesn't break the gate).
const string ALREADY_STARTED_MSG = "already started";
const string RESTART_AFTER_STOP_MSG = "create a new";

Listener? lifecycleStartTestListener = ();
int lifecycleStartTestMockId = -1;

function cleanupLifecycleStartTest() returns error? {
    error? stopResult = ();
    Listener? l = lifecycleStartTestListener;
    if l is Listener {
        stopResult = l.gracefulStop();
        lifecycleStartTestListener = ();
    }
    if lifecycleStartTestMockId != -1 {
        mockSmscClose(lifecycleStartTestMockId);
        lifecycleStartTestMockId = -1;
    }
    return stopResult;
}

@test:Config {after: cleanupLifecycleStartTest, groups: ["lifecycle"]}
function testDoubleStartRejected() returns error? {
    clearRecorded();
    clearRecordedErrors();
    int mockId = check mockSmscOpen(LIFECYCLE_START_TEST_PORT);
    lifecycleStartTestMockId = mockId;

    Listener smsListener = check new ({
        host: "localhost",
        port: LIFECYCLE_START_TEST_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER
    });
    lifecycleStartTestListener = smsListener;
    check smsListener.attach(new LifecycleRecordingService());
    check smsListener.'start();
    int conn1 = check mockSmscAwaitNextBind(mockId, 5000);

    error? second = smsListener.'start();
    test:assertTrue(second is error, "a second 'start()' on a STARTED listener must be rejected");
    if second is error {
        test:assertTrue(second is Error, "state-machine rejection must be the distinct smpp:Error type");
        test:assertTrue(second.message().includes(ALREADY_STARTED_MSG),
                string `expected '${ALREADY_STARTED_MSG}', got: ${second.message()}`);
    }

    int|error noBind = mockSmscAwaitNextBind(mockId, 1500);
    test:assertTrue(noBind is error, "a rejected second start() must not produce a second bind");

    // Listener undamaged by the rejection:
    check mockSmscSendDeliverSm(mockId, conn1, "after rejected double-start", "", 0);
    test:assertEquals(recordedCount(), 1);
    test:assertEquals(recordedAt(0).shortMessage, "after rejected double-start");
    test:assertEquals(recordedErrorCount(), 0,
            "a rejected start() is a returned error, not an onError notification");
}

@test:Config {after: cleanupLifecycleStartTest, groups: ["lifecycle"]}
function testRestartAfterStopRejected() returns error? {
    clearRecorded();
    clearRecordedErrors();
    int mockId = check mockSmscOpen(LIFECYCLE_START_TEST_PORT);
    lifecycleStartTestMockId = mockId;

    Listener smsListener = check new ({
        host: "localhost",
        port: LIFECYCLE_START_TEST_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER
    });
    // Store immediately: if any assertion below fails before the stop, cleanup must find
    // and stop this started listener (else it auto-rebinds forever against this file's
    // shared port). Re-stopping after the explicit gracefulStop below is a harmless
    // idempotent no-op (proven by testStopBeforeStartIsIdempotentNoOp).
    lifecycleStartTestListener = smsListener;
    check smsListener.attach(new LifecycleRecordingService());
    check smsListener.'start();
    _ = check mockSmscAwaitNextBind(mockId, 5000);

    check smsListener.gracefulStop();

    error? restart = smsListener.'start();
    test:assertTrue(restart is error,
            "a STOPPED listener stays stopped - 'start()' must tell the caller to create a new Listener");
    if restart is error {
        test:assertTrue(restart is Error, "rejection must be the distinct smpp:Error type");
        test:assertTrue(restart.message().includes(RESTART_AFTER_STOP_MSG),
                string `expected '${RESTART_AFTER_STOP_MSG}', got: ${restart.message()}`);
    }

    int|error noBind = mockSmscAwaitNextBind(mockId, 1500);
    test:assertTrue(noBind is error, "a rejected restart must not produce a new bind");
    test:assertEquals(recordedErrorCount(), 0,
            "user-initiated stop + rejected restart never fire onError");
}

@test:Config {groups: ["lifecycle"]}
function testAttachAfterStopIsRejected() returns error? {
    // Stage-2 F14: attach consulted NO lifecycle state, so attaching to a stopped
    // listener returned success - the service was stored, could never be dispatched to,
    // and the listener could never be restarted. A silent permanent no-op that looks
    // healthy, and one a compiler plugin cannot catch. init does no network work and a
    // never-started listener stops to STOPPED, so no mock is needed.
    Listener l = check new ({
        host: "localhost",
        port: LIFECYCLE_START_TEST_PORT,
        systemId: "test",
        password: "test"
    });
    check l.attach(new LifecycleRecordingService());
    check l.detach(new LifecycleRecordingService());
    test:assertTrue(l.gracefulStop() is (), "stop on a never-started listener is a no-op");

    error? reattach = l.attach(new LifecycleRecordingService());
    test:assertTrue(reattach is error, "attach on a stopped listener must be rejected");
    test:assertTrue((<error>reattach).message().includes(RESTART_AFTER_STOP_MSG),
            string `the remedy must be named: ${(<error>reattach).message()}`);
    // detach stays ungated on purpose: it is idempotent by contract and runs during
    // teardown, where the listener is already stopping.
    test:assertTrue(l.detach(new LifecycleRecordingService()) is (),
            "detach must remain idempotent and ungated");
}

@test:Config {groups: ["lifecycle"]}
function testStopBeforeStartIsIdempotentNoOp() returns error? {
    // init performs no network activity, so no mock is needed.
    Listener l = check new ({
        host: "localhost",
        port: LIFECYCLE_START_TEST_PORT,
        systemId: "test",
        password: "test"
    });
    test:assertTrue(l.immediateStop() is (), "stop on a never-started listener is an idempotent no-op");
    test:assertTrue(l.gracefulStop() is (), "and so is a second stop");
}

@test:Config {after: cleanupLifecycleStartTest, groups: ["lifecycle"]}
function testStartRetryAfterFailedStart() returns error? {
    // A FAILED start (bind rejected) reverts the listener to startable - only a
    // successful-start-then-stop is terminal.
    clearRecorded();
    clearRecordedErrors();
    int mockId = check mockSmscOpen(LIFECYCLE_START_TEST_PORT);
    lifecycleStartTestMockId = mockId;
    mockSmscExpectCredentials(mockId, "right-sys", "pw-ok");

    Listener smsListener = check new ({
        host: "localhost",
        port: LIFECYCLE_START_TEST_PORT,
        systemId: "wrong-sys",
        password: "pw-ok",
        bindType: TRANSCEIVER
    });
    lifecycleStartTestListener = smsListener;
    check smsListener.attach(new LifecycleRecordingService());

    error? firstTry = smsListener.'start();
    test:assertTrue(firstTry is error, "bind with wrong systemId must fail");
    int|error rejected = mockSmscAwaitNextBind(mockId, 5000);
    test:assertTrue(rejected is error, "the mock reports the rejected bind");

    // Re-point the mock to accept this listener's credentials; retrying must now work.
    mockSmscExpectCredentials(mockId, "wrong-sys", "pw-ok");
    check smsListener.'start();
    int conn = check mockSmscAwaitNextBind(mockId, 5000);
    check mockSmscSendDeliverSm(mockId, conn, "after retried start", "", 0);
    test:assertEquals(recordedCount(), 1);
}
