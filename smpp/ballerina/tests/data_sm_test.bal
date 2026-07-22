// Copyright (c) 2026. Regression test for the Dispatcher.onAcceptDataSm null-return NPE.
import ballerina/lang.runtime;
import ballerina/test;

// Test files are compiled as part of this same package, so `Sms`/`Service`/`Listener`
// etc. are used unqualified here - importing `ramith/smpp` (this package itself) from
// its own tests/ is a compile error ("cyclic module imports").

// Arbitrary, fixed port for this one-off mock/connector pair. Not yet robust to port
// conflicts in parallel/CI runs - acceptable for Sprint 0's narrow scope; revisit when
// the fuller mock-SMSC rewrite (docs/qa-strategy.md) lands.
const int MOCK_SMSC_PORT = 27776;
const int BIND_TIMEOUT_MILLIS = 5000;

isolated Sms[] receivedDataSm = [];

// Set by the test, read/cleared by the @test:AfterEach below — sequential, not concurrent
// access (AfterEach runs strictly after the test function returns or fails), so a plain
// module-level variable is enough here; unlike `receivedDataSm` above, this isn't touched
// from a jsmpp dispatch thread.
Listener? testListener = ();

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

service class DataSmTestService {
    *Service;

    remote function onDataSm(Sms sms) returns error? {
        recordDataSm(sms);
    }
}

# This is the literal reproduction of the confirmed NPE: `Dispatcher.onAcceptDataSm`
# returning `null` makes jsmpp NPE internally before ever sending `data_sm_resp`. Run
# through a real `bal test` (not a bare JUnit test) because `Dispatcher.toSms` needs the
# `smpp:Sms` record type registered in a live Ballerina runtime - something that only
# exists inside an actual `bal test`/`bal run` process (see docs/sprint-plan.md's Sprint 0
# note for why an earlier, JUnit-only attempt at this test did not work).
@test:Config {}
function testDataSmDeliveredAndAcknowledged() returns error? {
    check mockSmscOpenListener(MOCK_SMSC_PORT);

    Listener smsListener = check new ({
        host: "localhost",
        port: MOCK_SMSC_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER
    });
    testListener = smsListener;
    check smsListener.attach(new DataSmTestService());

    // Both sides of a bind block until the other is ready: the mock's accept+bind must run
    // concurrently with the connector's own 'start(), not before or after it.
    future<error?> acceptFuture = start mockSmscAcceptAndBind(BIND_TIMEOUT_MILLIS);
    check smsListener.'start();
    check wait acceptFuture;

    string payload = "sprint0 data_sm regression";

    // Before the fix, this call itself fails: Dispatcher.toSms succeeds (a live Ballerina
    // runtime is registered, unlike the abandoned JUnit-only attempt this test replaced —
    // see docs/sprint-plan.md's Sprint 0 note), so onAcceptDataSm's `return null;` is
    // reached and returned cleanly with no exception thrown there. jsmpp's own
    // AbstractGenericSMPPSessionBound.processDataSm then dereferences that null result
    // (an uncaught NPE, not caught by its PDUStringException/ProcessRequestException
    // handlers) before ever sending data_sm_resp — so no response ever reaches the mock,
    // and this call times out waiting for one (org.jsmpp.extra.ResponseTimeoutException),
    // rather than failing with an explicit negative response. Verified empirically by
    // temporarily reverting the fix and re-running this test - see docs/sprint-plan.md.
    check mockSmscSendDataSm(payload);

    // In SYNC mode (this connector's default ResponseMode), Dispatcher.dispatch() blocks
    // the jsmpp thread until the attached service's remote method returns - so by the time
    // the send above completes without error, recordDataSm has already run and this loop's
    // first check always succeeds. The bound only matters if a future test exercises
    // ASYNC mode, where dispatch is no longer synchronous with the response.
    int attempts = 0;
    while receivedDataSmCount() == 0 && attempts < 20 {
        runtime:sleep(0.1);
        attempts += 1;
    }

    test:assertEquals(receivedDataSmCount(), 1, "onDataSm should have been invoked exactly once");
    Sms sms = firstReceivedDataSm();
    test:assertEquals(sms.shortMessage, payload);
    test:assertFalse(sms.deliveryReceipt, "data_sm is never a delivery receipt");
}

# Runs after every test in this file regardless of pass/fail - a failed `check`/assertion
# above aborts the test function before an inline cleanup call would be reached, which
# would otherwise leak the mock's listening socket on `MOCK_SMSC_PORT` into any later test
# in the same `bal test` run (reproduced during Sprint 0's review: a forced failure here
# caused an unrelated subsequent test to fail with a misleading `BindException` instead of
# its own real assertion).
@test:AfterEach
function cleanupDataSmTest() returns error? {
    Listener? l = testListener;
    if l is Listener {
        check l.gracefulStop();
        testListener = ();
    }
    mockSmscClose();
}
