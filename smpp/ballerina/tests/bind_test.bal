// Copyright (c) 2026. Bind-rejection coverage (bind success is every other test's precondition).
import ballerina/test;

const int BIND_TEST_PORT = 27777;

Listener? bindTestListener = ();
int bindTestMockId = -1;

function cleanupBindTest() returns error? {
    // Defensive listener stop FIRST: on the expected (rejected-bind) path there's nothing
    // to stop, but if the mock ever wrongly accepted the bind, an un-stopped bound
    // listener would treat the mock closing below as an "unexpected drop" and start the
    // infinite rebind loop against a dead port for the rest of the suite.
    error? stopResult = ();
    Listener? l = bindTestListener;
    if l is Listener {
        stopResult = l.immediateStop();
        bindTestListener = ();
    }
    if bindTestMockId != -1 {
        mockSmscClose(bindTestMockId);
        bindTestMockId = -1;
    }
    return stopResult;
}

# The connector today wraps every bind failure into one generic error string; these tests
# pin the substring that lets a caller at least distinguish rejection reasons by message.
# (Structured rejection-reason errors are a known gap flagged in docs/qa-strategy.md §3.3.)
@test:Config {after: cleanupBindTest}
function testBindRejectedForInvalidSystemId() returns error? {
    int mockId = check mockSmscOpen(BIND_TEST_PORT);
    bindTestMockId = mockId;
    mockSmscExpectCredentials(mockId, "expected-sys", "pw-ok");

    Listener smsListener = check new ({
        host: "localhost",
        port: BIND_TEST_PORT,
        systemId: "wrong-sys",
        password: "pw-ok",
        bindType: TRANSCEIVER
    });
    bindTestListener = smsListener;

    error? startResult = smsListener.'start();
    test:assertTrue(startResult is error, "bind with a wrong systemId must fail 'start()'");
    if startResult is error {
        test:assertTrue(startResult.message().includes("Invalid System ID"),
                string `expected an Invalid System ID rejection, got: ${startResult.message()}`);
    }

    // The mock observed the same rejection from its own side - proves the validator
    // actually fired rather than the connector failing for an unrelated reason.
    int|error bindOutcome = mockSmscAwaitNextBind(mockId, 5000);
    test:assertTrue(bindOutcome is error, "the mock must report the rejected bind as an error");
}

@test:Config {after: cleanupBindTest}
function testBindRejectedForInvalidPassword() returns error? {
    int mockId = check mockSmscOpen(BIND_TEST_PORT);
    bindTestMockId = mockId;
    mockSmscExpectCredentials(mockId, "expected-sys", "pw-ok");

    Listener smsListener = check new ({
        host: "localhost",
        port: BIND_TEST_PORT,
        systemId: "expected-sys",
        password: "wrong-pw",
        bindType: TRANSCEIVER
    });
    bindTestListener = smsListener;

    error? startResult = smsListener.'start();
    test:assertTrue(startResult is error, "bind with a wrong password must fail 'start()'");
    if startResult is error {
        test:assertTrue(startResult.message().includes("Invalid Password"),
                string `expected an Invalid Password rejection, got: ${startResult.message()}`);
    }

    int|error bindOutcome = mockSmscAwaitNextBind(mockId, 5000);
    test:assertTrue(bindOutcome is error, "the mock must report the rejected bind as an error");
}
