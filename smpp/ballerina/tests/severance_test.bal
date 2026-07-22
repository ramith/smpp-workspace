// Copyright (c) 2026. Peer-initiated unbind semantics (Sprint 2 exit gate g).
//
// Variant A (below, enabled) pins today's INTENDED behavior per the Sprint 2 design
// review: a clean peer-initiated unbind and an abrupt severance are treated identically
// (both fire onError and trigger rebind) — the state-machine lambda deliberately does
// not distinguish them. If that decision is ever revisited (peer-unbind-as-terminal),
// the drop-in Variant B is sketched at the bottom of this file.
// The sever half of gate (g) is exercised by rebind_test.bal's
// testSeverTriggersOnErrorAndRebind.
import ballerina/test;
import ballerina/time;

const int SEVERANCE_TEST_PORT = 27786;

Listener? severanceTestListener = ();
int severanceTestMockId = -1;

function cleanupSeveranceTest() returns error? {
    error? stopResult = ();
    Listener? l = severanceTestListener;
    if l is Listener {
        stopResult = l.gracefulStop();
        severanceTestListener = ();
    }
    if severanceTestMockId != -1 {
        mockSmscClose(severanceTestMockId);
        severanceTestMockId = -1;
    }
    return stopResult;
}

@test:Config {after: cleanupSeveranceTest, groups: ["lifecycle"]}
function testPeerUnbindTriggersRebindLikeSeverance() returns error? {
    clearRecorded();
    clearRecordedErrors();
    int mockId = check mockSmscOpen(SEVERANCE_TEST_PORT);
    severanceTestMockId = mockId;

    Listener smsListener = check new ({
        host: "localhost",
        port: SEVERANCE_TEST_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        rebindPolicy: {initialRebindDelay: 0.5, maxRebindDelay: 2, backOffMultiplier: 2.0, maxRebindAttempts: -1}
    });
    severanceTestListener = smsListener;
    check smsListener.attach(new LifecycleRecordingService());
    check smsListener.'start();
    int conn1 = check mockSmscAwaitNextBind(mockId, 5000);

    check mockSmscSendDeliverSm(mockId, conn1, "before peer unbind", "", 0);
    test:assertEquals(recordedCount(), 1);

    decimal t0 = time:monotonicNow();
    // This succeeding is itself an assertion: the connector answered the unbind_resp
    // exchange — which sever() never has. That is the mechanical difference between
    // the two drop shapes (qa-strategy §3.6).
    check mockSmscPeerUnbind(mockId, conn1);

    test:assertTrue(pollUntil(() => recordedErrorCount() >= 1, 5),
            "onError did not fire within 5s of the peer unbind");
    test:assertTrue(recordedErrorsContaining("closed unexpectedly") >= 1);

    int conn2 = check mockSmscAwaitNextBind(mockId, 10000);
    decimal rebindElapsed = time:monotonicNow() - t0;
    // Floor at 0.4s: see the matching note in rebind_test.bal - tight enough to catch a
    // backoff shrunk toward zero, loose enough that a healthy ~0.5s rebind never flakes.
    test:assertTrue(rebindElapsed >= 0.4d,
            string `rebind landed after ${rebindElapsed}s - the 0.5s initial backoff was not honored`);

    check mockSmscSendDeliverSm(mockId, conn2, "after rebind", "", 0);
    test:assertEquals(recordedCount(), 2);
    test:assertEquals(recordedErrorCount(), 1);
}

// Variant B (drop-in if peer-unbind ever becomes terminal/no-rebind):
//   1. same setup through conn1;
//   2. check mockSmscPeerUnbind(mockId, conn1);
//   3. assert one onError with the (then-pinned) peer-unbind wording;
//   4. assert mockSmscAwaitNextBind(mockId, 3000) errors (no rebind; 3s = 6x the
//      0.5s first-attempt delay, so a wrongly-scheduled rebind cannot escape it);
//   5. assert smsListener.'start() is rejected per the terminal-state wording;
//   6. runtime:sleep(1); assert recordedErrorCount() == 1.
