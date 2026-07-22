// Copyright (c) 2026. Regression test for the Dispatcher.onAcceptDataSm null-return NPE.
import ballerina/lang.runtime;
import ballerina/test;

// Test files are compiled as part of this same package, so `Sms`/`Service`/`Listener`
// etc. are used unqualified here - importing `ramith/smpp` (this package itself) from
// its own tests/ is a compile error ("cyclic module imports").

// Fixed per-file port; each test file in this suite uses its own so files can't collide.
// Not yet robust to conflicts with unrelated processes in parallel/CI runs - tracked in
// docs/qa-strategy.md as a known gap.
const int DATA_SM_TEST_PORT = 27776;

isolated Sms[] receivedDataSm = [];

isolated function recordDataSm(Sms sms) {
    lock {
        receivedDataSm.push(sms.clone());
    }
}

isolated function receivedDataSmCount() returns int {
    lock {
        return receivedDataSm.length();
    }
}

isolated function firstReceivedDataSm() returns Sms {
    lock {
        return receivedDataSm[0].clone();
    }
}

// Deliberately NOT converged on testutils.bal's RecordingService: implementing ONLY
// onDataSm (no onDeliverSm/onError) is part of what this test pins - a service exposing
// just one of the three optional remote methods still receives its PDU type.
service class DataSmTestService {
    *Service;

    remote function onDataSm(Sms sms) returns error? {
        recordDataSm(sms);
    }
}

// Set by the test, read/cleared by its `after:` cleanup below - sequential access only
// (the cleanup runs strictly after the test function returns or fails).
Listener? dataSmTestListener = ();
int dataSmTestMockId = -1;

# Cleanup for `testDataSmDeliveredAndAcknowledged`, run via `@test:Config {after: ...}` so
# it executes even when an earlier `check`/assertion aborts the test body - inline cleanup
# at the end of a test function is skipped on failure, leaking the mock's listening socket
# into whatever test runs next (reproduced during Sprint 0's review as a misleading
# `BindException` in an unrelated test). Per-test `after:` is used instead of
# `@test:AfterEach` because BeforeEach/AfterEach hooks are suite-global in Ballerina (they
# fire around every test in the module, not just this file's).
function cleanupDataSmTest() returns error? {
    // Capture the stop outcome but ALWAYS close the mock and reset state - an early
    // `check` return here would leak the mock's port into the next test as a
    // misleading BindException (the exact failure mode Sprint 0's review reproduced).
    error? stopResult = ();
    Listener? l = dataSmTestListener;
    if l is Listener {
        stopResult = l.gracefulStop();
        dataSmTestListener = ();
    }
    if dataSmTestMockId != -1 {
        mockSmscClose(dataSmTestMockId);
        dataSmTestMockId = -1;
    }
    return stopResult;
}

# This is the literal reproduction of the confirmed NPE: `Dispatcher.onAcceptDataSm`
# returning `null` makes jsmpp NPE internally before ever sending `data_sm_resp`. Run
# through a real `bal test` (not a bare JUnit test) because `Dispatcher.toSms` needs the
# `smpp:Sms` record type registered in a live Ballerina runtime - something that only
# exists inside an actual `bal test`/`bal run` process (see docs/sprint-plan.md's Sprint 0
# note for why an earlier, JUnit-only attempt at this test did not work).
@test:Config {after: cleanupDataSmTest}
function testDataSmDeliveredAndAcknowledged() returns error? {
    int mockId = check mockSmscOpen(DATA_SM_TEST_PORT);
    dataSmTestMockId = mockId;

    Listener smsListener = check new ({
        host: "localhost",
        port: DATA_SM_TEST_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER
    });
    dataSmTestListener = smsListener;
    check smsListener.attach(new DataSmTestService());

    // The mock's accept-loop runs in the background, so 'start() and awaitNextBind can
    // run sequentially (unlike Sprint 0's single-shot bridge, which required both sides
    // of the bind to block concurrently).
    check smsListener.'start();
    int connectionId = check mockSmscAwaitNextBind(mockId, 5000);

    string payload = "sprint0 data_sm regression";

    // Before the fix, this call itself fails: Dispatcher.toSms succeeds (a live Ballerina
    // runtime is registered, unlike the abandoned JUnit-only attempt this test replaced -
    // see docs/sprint-plan.md's Sprint 0 note), so onAcceptDataSm's `return null;` is
    // reached and returned cleanly with no exception thrown there. jsmpp's own
    // AbstractGenericSMPPSessionBound.processDataSm then dereferences that null result
    // (an uncaught NPE, not caught by its PDUStringException/ProcessRequestException
    // handlers) before ever sending data_sm_resp - so no response ever reaches the mock,
    // and this call times out waiting for one (org.jsmpp.extra.ResponseTimeoutException),
    // rather than failing with an explicit negative response. Verified empirically by
    // temporarily reverting the fix and re-running this test - see docs/sprint-plan.md.
    check mockSmscSendDataSm(mockId, connectionId, payload, 0);

    // In SYNC mode (this connector's default ResponseMode), Dispatcher.dispatch() blocks
    // the jsmpp thread until the attached service's remote method returns - so by the time
    // the send above completes without error, recordDataSm has already run and this loop's
    // first check always succeeds. The bound only matters for ASYNC-mode tests, where
    // dispatch is no longer synchronous with the response.
    int attempts = 0;
    while receivedDataSmCount() == 0 && attempts < 20 {
        runtime:sleep(0.1);
        attempts += 1;
    }

    test:assertEquals(receivedDataSmCount(), 1, "onDataSm should have been invoked exactly once");
    Sms sms = firstReceivedDataSm();
    test:assertEquals(sms.shortMessage, payload);
    test:assertEquals(check string:fromBytes(sms.shortMessageBytes), payload,
            "shortMessageBytes should carry the same (UTF-8) payload bytes");
    test:assertFalse(sms.deliveryReceipt, "data_sm is never a delivery receipt");
}
