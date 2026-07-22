// Copyright (c) 2026. Rebind backoff + exhaustion (Sprint 2 exit gate c, d).
import ballerina/lang.runtime;
import ballerina/test;
import ballerina/time;

const int REBIND_TEST_PORT = 27783;

Listener? rebindTestListener = ();
int rebindTestMockId = -1;

function cleanupRebindTest() returns error? {
    error? stopResult = ();
    Listener? l = rebindTestListener;
    if l is Listener {
        stopResult = l.gracefulStop();
        rebindTestListener = ();
    }
    if rebindTestMockId != -1 {
        mockSmscClose(rebindTestMockId);
        rebindTestMockId = -1;
    }
    return stopResult;
}

@test:Config {after: cleanupRebindTest, groups: ["lifecycle"]}
function testSeverTriggersOnErrorAndRebind() returns error? {
    clearRecorded();
    clearRecordedErrors();
    int mockId = check mockSmscOpen(REBIND_TEST_PORT);
    rebindTestMockId = mockId;

    Listener smsListener = check new ({
        host: "localhost",
        port: REBIND_TEST_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        rebindPolicy: {initialRebindDelay: 0.5, maxRebindDelay: 2, backOffMultiplier: 2.0, maxRebindAttempts: -1}
    });
    rebindTestListener = smsListener;
    check smsListener.attach(new LifecycleRecordingService());
    check smsListener.'start();
    int conn1 = check mockSmscAwaitNextBind(mockId, 5000);

    check mockSmscSendDeliverSm(mockId, conn1, "before drop", "", 0);
    test:assertEquals(recordedCount(), 1);

    decimal t0 = time:monotonicNow();
    check mockSmscSever(mockId, conn1);

    test:assertTrue(pollUntil(() => recordedErrorCount() >= 1, 5),
            "onError did not fire within 5s of severance");
    test:assertTrue(recordedErrorsContaining("closed unexpectedly") >= 1,
            "the drop notification must carry the pinned 'closed unexpectedly' wording");

    // The rebind lands on the same mock's next accept.
    int conn2 = check mockSmscAwaitNextBind(mockId, 10000);
    decimal rebindElapsed = time:monotonicNow() - t0;
    // Floor at 0.4s (not 0.2s): with a 0.5s configured initialRebindDelay, a healthy
    // rebind lands at ~0.5s + drop-detection/reconnect overhead, comfortably above 0.4s,
    // while a backoff wrongly shrunk toward zero would fall under it. (0.2s was too loose
    // to catch a shrunk-but-nonzero backoff, which the message claims to catch.)
    test:assertTrue(rebindElapsed >= 0.4d,
            string `rebind landed after ${rebindElapsed}s - the 0.5s initial backoff was not honored`);

    check mockSmscSendDeliverSm(mockId, conn2, "after rebind", "", 0);
    test:assertEquals(recordedCount(), 2);
    test:assertEquals(recordedAt(1).shortMessage, "after rebind");
    test:assertEquals(recordedErrorCount(), 1,
            "a successful first rebind attempt must add no further onError");
}

@test:Config {after: cleanupRebindTest, groups: ["lifecycle"]}
function testRebindExhaustionNotifiesPerAttemptAndGivesUp() returns error? {
    clearRecorded();
    clearRecordedErrors();
    int mockId = check mockSmscOpen(REBIND_TEST_PORT);
    rebindTestMockId = mockId;

    Listener smsListener = check new ({
        host: "localhost",
        port: REBIND_TEST_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        rebindPolicy: {initialRebindDelay: 0.3, maxRebindDelay: 5, backOffMultiplier: 2.0, maxRebindAttempts: 3}
    });
    rebindTestListener = smsListener;
    check smsListener.attach(new LifecycleRecordingService());
    check smsListener.'start();
    int conn1 = check mockSmscAwaitNextBind(mockId, 5000);

    // Nothing to rebind to (connection refused), deterministically - while the live
    // connection is still up, so its severance below is the only drop.
    mockSmscStopAccepting(mockId);

    decimal t0 = time:monotonicNow();
    check mockSmscSever(mockId, conn1);

    // Documented contract: 1 initial drop + 1 per failed attempt (x3) + 1 give-up = 5.
    test:assertTrue(pollUntil(() => recordedErrorCount() >= 5, 20),
            string `expected 5 onError notifications, got ${recordedErrorCount()}`);
    decimal elapsed = time:monotonicNow() - t0;
    test:assertTrue(elapsed >= 1.5d,
            string `exhaustion completed in ${elapsed}s - backoff delays (0.3+0.6+1.2s) were not applied`);

    // Set-membership, not ordering (onError notifications ride separate virtual threads).
    test:assertEquals(recordedErrorsContaining("closed unexpectedly"), 1);
    test:assertEquals(recordedErrorsContaining("rebind attempt 1 failed"), 1);
    test:assertEquals(recordedErrorsContaining("rebind attempt 2 failed"), 1);
    test:assertEquals(recordedErrorsContaining("rebind attempt 3 failed"), 1);
    test:assertEquals(recordedErrorsContaining("gave up rebinding"), 1);
    test:assertEquals(recordedErrorsContaining("3 attempt"), 1);

    // It actually gave up: longer than a (wrongly-scheduled) attempt 4's 2.4s delay.
    runtime:sleep(3);
    test:assertEquals(recordedErrorCount(), 5,
            "no notifications after give-up - rebinding must have stopped");

    // Post-exhaustion the lifecycle stays STARTED: stop must be a clean, ordinary stop.
    check smsListener.gracefulStop();
    rebindTestListener = ();
}
