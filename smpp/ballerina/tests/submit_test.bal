// Copyright (c) 2026. Caller.submit integration tests against the mock SMSC.
import ballerina/lang.runtime;
import ballerina/test;

const int SUBMIT_TEST_PORT = 27805;
const int SUBMIT_REBIND_TEST_PORT = 27806;
const int SUBMIT_RECEIVER_TEST_PORT = 27807;
const int SUBMIT_SHAPES_TEST_PORT = 27808;
const int SUBMIT_ERRORS_TEST_PORT = 27809;

// The Caller reaches user code only as a dispatch parameter, so every test captures it
// from a service. (This is also why "submit before 'start()" is untestable by
// construction: no dispatch can have happened, so no Caller can be held - the
// lifecycle pre-check still guards the window as defense in depth.)
isolated Caller? submitTestCaller = ();
isolated int submitTestDispatches = 0;

isolated function capturedCaller() returns Caller? {
    lock {
        return submitTestCaller;
    }
}

isolated function clearCapturedCaller() {
    lock {
        submitTestCaller = ();
    }
    lock {
        submitTestDispatches = 0;
    }
}

isolated function dispatchCount() returns int {
    lock {
        return submitTestDispatches;
    }
}

// Caller LAST - the common shape.
isolated service class CallerCapturingService {
    *Service;

    remote isolated function onDeliverSm(Sms sms, Caller caller) returns error? {
        lock {
            submitTestCaller = caller;
        }
        lock {
            submitTestDispatches += 1;
        }
    }
}

// Caller FIRST - pins the order-agnostic type binding (D1 decision: both orders legal).
isolated service class CallerFirstService {
    *Service;

    remote isolated function onDeliverSm(Caller caller, Sms sms) returns error? {
        lock {
            submitTestCaller = caller;
        }
        lock {
            submitTestDispatches += 1;
        }
    }
}

// The 1.0.1 shape - must keep attaching and dispatching unchanged.
isolated service class PlainSmsService {
    *Service;

    remote isolated function onDeliverSm(Sms sms) returns error? {
        lock {
            submitTestDispatches += 1;
        }
    }
}

// Mixed arities across methods - the case a two-case test misses (gate).
isolated service class MixedArityService {
    *Service;

    remote isolated function onDeliverSm(Sms sms) returns error? {
        lock {
            submitTestDispatches += 1;
        }
    }

    remote isolated function onDataSm(Sms sms, Caller caller) returns error? {
        lock {
            submitTestCaller = caller;
        }
        lock {
            submitTestDispatches += 1;
        }
    }
}

// D1's first trap: a defaultable optional Caller would be silently skipped by an
// isDefault-based rule. Attach must reject it loudly instead.
isolated service class OptionalCallerService {
    *Service;

    remote isolated function onDeliverSm(Sms sms, Caller? caller = ()) returns error? {
    }
}

// D1's second trap: rest parameters vanish from getParameters() and panic per PDU.
isolated service class RestParamService {
    *Service;

    remote isolated function onDeliverSm(Sms... sms) returns error? {
    }
}

// Two parameters of one type: unbindable, must be rejected at attach.
isolated service class TwoSmsService {
    *Service;

    remote isolated function onDeliverSm(Sms a, Sms b) returns error? {
    }
}

# Binds a transceiver listener to a fresh mock, captures the Caller via one dispatch.
#
# + port - the mock's port
# + svc - the capturing service to attach
# + return - [mockId, connectionId, listener] or an error
function startCapturingListener(int port, Service svc)
        returns [int, int, Listener]|error {
    clearCapturedCaller();
    int mockId = check mockSmscOpen(port);
    Listener smsListener = check new ({
        host: "localhost",
        port: port,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        rebindPolicy: {initialRebindDelay: 0.2, maxRebindDelay: 1, backOffMultiplier: 2.0}
    });
    check smsListener.attach(svc);
    check smsListener.'start();
    int conn = check mockSmscAwaitNextBind(mockId, 5000);
    check mockSmscSendDeliverSm(mockId, conn, "capture", "", 0);
    test:assertTrue(pollUntil(isolated function() returns boolean {
        return capturedCaller() !is ();
    }, 5), "the dispatch never delivered a Caller");
    return [mockId, conn, smsListener];
}

@test:Config {groups: ["submit"]}
function testSubmitHappyPathPinsWirePdu() returns error? {
    var [mockId, conn, smsListener] = check startCapturingListener(
            SUBMIT_TEST_PORT, new CallerCapturingService());
    Caller caller = <Caller>capturedCaller();

    // Defaulted source (config sourceAddr defaults to empty = absent), LATIN1 default.
    SubmitResult r1 = check caller->submit({
        destAddr: "264811234567",
        shortMessage: "reply one"
    });
    int submit1 = check mockSmscAwaitNextSubmit(mockId, conn, 5000);
    test:assertEquals(mockSmscSubmitDestAddr(submit1), "264811234567");
    test:assertEquals(mockSmscSubmitDestAddrTon(submit1), 1, "INTERNATIONAL");
    test:assertEquals(mockSmscSubmitDestAddrNpi(submit1), 1, "ISDN");
    test:assertEquals(mockSmscSubmitSourceAddr(submit1), "", "absent source goes empty");
    test:assertEquals(mockSmscSubmitDataCoding(submit1), 0x03, "LATIN1 -> data_coding 0x03");
    test:assertEquals(mockSmscSubmitEsmClass(submit1), 0x00,
            "esm_class must be 0x00 - nonzero changes SMSC routing/billing invisibly");
    test:assertEquals(mockSmscSubmitRegisteredDelivery(submit1), 0x00,
            "no receipt requested MUST stamp 0 - the negative catches an always-on bug");
    test:assertEquals(mockSmscSubmitShortMessage(submit1), "reply one");
    test:assertEquals(mockSmscSubmitServiceType(submit1), "");
    test:assertEquals(mockSmscSubmitValidityPeriod(submit1), "", "unset = SMSC default");
    // The mock mints monotonic ids from 1000 per instance; this is its first submit.
    test:assertEquals(r1.messageId, "1000",
            "returned id must equal the mock's generated id, not merely be non-empty");

    // Per-message override: explicit Address source, UCS2, receipt requested.
    SubmitResult r2 = check caller->submit({
        destAddr: {value: "INFO", ton: TON_ALPHANUMERIC, npi: NPI_UNKNOWN},
        sourceAddr: {value: "12345", ton: TON_ABBREVIATED, npi: NPI_ISDN},
        shortMessage: "reply two",
        encoding: UCS2,
        registeredDelivery: ON_SUCCESS_OR_FAILURE,
        serviceType: "CMT"
    });
    int submit2 = check mockSmscAwaitNextSubmit(mockId, conn, 5000);
    test:assertEquals(mockSmscSubmitDestAddr(submit2), "INFO");
    test:assertEquals(mockSmscSubmitDestAddrTon(submit2), 5, "ALPHANUMERIC");
    test:assertEquals(mockSmscSubmitDestAddrNpi(submit2), 0, "UNKNOWN");
    test:assertEquals(mockSmscSubmitSourceAddr(submit2), "12345");
    test:assertEquals(mockSmscSubmitSourceAddrTon(submit2), 6, "ABBREVIATED");
    test:assertEquals(mockSmscSubmitDataCoding(submit2), 0x08, "UCS2 -> 0x08");
    test:assertEquals(mockSmscSubmitRegisteredDelivery(submit2), 0x01);
    test:assertEquals(mockSmscSubmitShortMessage(submit2), "reply two");
    test:assertEquals(mockSmscSubmitServiceType(submit2), "CMT");
    test:assertEquals(r2.messageId, "1001");
    test:assertEquals(mockSmscPendingSubmitCount(mockId, conn), 0, "and no more submits");

    check smsListener.gracefulStop();
    mockSmscClose(mockId);
}

@test:Config {groups: ["submit"]}
function testSubmitOnReceiverBindIsRejected() returns error? {
    clearCapturedCaller();
    int mockId = check mockSmscOpen(SUBMIT_RECEIVER_TEST_PORT);
    Listener smsListener = check new ({
        host: "localhost",
        port: SUBMIT_RECEIVER_TEST_PORT,
        systemId: "test",
        password: "test",
        bindType: RECEIVER
    });
    check smsListener.attach(new CallerCapturingService());
    check smsListener.'start();
    int conn = check mockSmscAwaitNextBind(mockId, 5000);
    check mockSmscSendDeliverSm(mockId, conn, "capture", "", 0);
    test:assertTrue(pollUntil(isolated function() returns boolean {
        return capturedCaller() !is ();
    }, 5), "RECEIVER bind still dispatches - the Caller parameter itself is legal");
    Caller caller = <Caller>capturedCaller();

    SubmitResult|Error r = caller->submit({destAddr: "264811234567", shortMessage: "x"});
    test:assertTrue(r is Error, "submit on a RECEIVER bind must fail");
    Error e = <Error>r;
    string msg = e.message();
    test:assertTrue(msg.includes("bindType") && msg.includes("TRANSCEIVER"),
            string `must name the config field and the fix: ${msg}`);
    test:assertFalse(msg.includes("BOUND_RX"),
            "jsmpp state names must not leak - that is the guard-absent signature");
    test:assertEquals(e.detail().failureMode, INVALID_REQUEST);

    check smsListener.gracefulStop();
    mockSmscClose(mockId);
}

@test:Config {groups: ["submit"]}
function testSubmitSurvivesRebindOnNewSession() returns error? {
    var [mockId, conn1, smsListener] = check startCapturingListener(
            SUBMIT_REBIND_TEST_PORT, new CallerCapturingService());
    Caller caller = <Caller>capturedCaller();

    // Two full sever->rebind cycles: kills both a cached session AND a refresh-once cache.
    int previousConn = conn1;
    string previousId = "";
    foreach int cycle in 1 ... 2 {
        // A submit BEFORE the sever, captured on the current connection - without this, a
        // lazy resolve-on-first-use cache would never be caught being stale.
        SubmitResult before = check caller->submit({
            destAddr: "264811234567",
            shortMessage: string `pre-sever ${cycle}`
        });
        int preSubmit = check mockSmscAwaitNextSubmit(mockId, previousConn, 5000);
        test:assertEquals(mockSmscSubmitShortMessage(preSubmit), string `pre-sever ${cycle}`);
        test:assertTrue(before.messageId != previousId, "ids must differ across submits");

        check mockSmscSever(mockId, previousConn);
        int newConn = check mockSmscAwaitNextBind(mockId, 10000);

        // Poll: the mock accepting the bind can precede the connector installing the
        // fresh session by a sliver; a submit in that sliver correctly fails fast.
        SubmitResult? after = ();
        int attempts = 0;
        while after is () {
            SubmitResult|Error r = caller->submit({
                destAddr: "264811234567",
                shortMessage: string `post-rebind ${cycle}`
            });
            if r is SubmitResult {
                after = r;
            } else {
                attempts += 1;
                test:assertTrue(attempts < 50,
                        string `submit never succeeded after rebind: ${r.message()}`);
                runtime:sleep(0.1);
            }
        }
        SubmitResult confirmed = <SubmitResult>after;
        int postSubmit = check mockSmscAwaitNextSubmit(mockId, newConn, 5000);
        test:assertEquals(mockSmscSubmitShortMessage(postSubmit),
                string `post-rebind ${cycle}`, "the post-rebind submit must land on the NEW connection");
        test:assertTrue(confirmed.messageId != before.messageId, "ids must differ");
        previousConn = newConn;
        previousId = confirmed.messageId;
    }

    check smsListener.gracefulStop();
    mockSmscClose(mockId);
}

@test:Config {groups: ["submit"]}
function testSubmitDuringRebindFailsFastAndAfterStopIsRejected() returns error? {
    var [mockId, conn, smsListener] = check startCapturingListener(
            SUBMIT_ERRORS_TEST_PORT, new CallerCapturingService());
    Caller caller = <Caller>capturedCaller();

    // Stop accepting so the rebind cannot succeed, then sever: the session is down for
    // good, and submit must fail fast with the connector's own wording.
    mockSmscStopAccepting(mockId);
    check mockSmscSever(mockId, conn);
    Error? sawRebindWording = ();
    foreach int i in 1 ... 50 {
        SubmitResult|Error r = caller->submit({destAddr: "264811234567", shortMessage: "x"});
        if r is Error {
            sawRebindWording = r;
            break;
        }
        // A submit that still succeeded raced the sever - the wire may buffer briefly.
        runtime:sleep(0.1);
    }
    test:assertTrue(sawRebindWording !is (), "submit must start failing once the link is down");
    Error e = <Error>sawRebindWording;
    string msg = e.message();
    test:assertTrue(msg.includes("rebind") || msg.includes("not currently bound"),
            string `the connector's own wording, not jsmpp's: ${msg}`);
    test:assertFalse(msg.includes("CLOSED"), string `jsmpp state names must not leak: ${msg}`);
    test:assertEquals(e.detail().failureMode, INVALID_REQUEST);

    // After a graceful stop the message names the lifecycle, not the session.
    check smsListener.gracefulStop();
    SubmitResult|Error afterStop = caller->submit({destAddr: "264811234567", shortMessage: "x"});
    test:assertTrue(afterStop is Error);
    Error stopErr = <Error>afterStop;
    test:assertTrue(stopErr.message().includes("stopped"),
            string `must name the lifecycle state: ${stopErr.message()}`);
    test:assertEquals(stopErr.detail().failureMode, INVALID_REQUEST);
    mockSmscClose(mockId);
}

@test:Config {groups: ["submit"]}
function testCallerParamShapes() returns error? {
    // Positive shapes: each attaches AND dispatches. Caller-first pins the D1 decision
    // (order-agnostic type binding - the case mqtt would reject and ftp accepts).
    Service[] accepted = [
        new PlainSmsService(),
        new CallerCapturingService(),
        new CallerFirstService()
    ];
    int port = SUBMIT_SHAPES_TEST_PORT;
    foreach Service svc in accepted {
        clearCapturedCaller();
        int mockId = check mockSmscOpen(port);
        Listener l = check new ({
            host: "localhost",
            port: port,
            systemId: "test",
            password: "test",
            bindType: TRANSCEIVER
        });
        check l.attach(svc);
        check l.'start();
        int conn = check mockSmscAwaitNextBind(mockId, 5000);
        check mockSmscSendDeliverSm(mockId, conn, "shape", "", 0);
        test:assertTrue(pollUntil(isolated function() returns boolean {
            return dispatchCount() >= 1;
        }, 5), "dispatch must reach every accepted shape");
        check l.gracefulStop();
        mockSmscClose(mockId);
        port += 20; // fresh port per sub-case; stays within an unclaimed range
    }

    // Mixed service: onDeliverSm 1-arity and onDataSm 2-arity coexist; the data_sm path
    // is a separate dispatch site and must position the Caller independently.
    clearCapturedCaller();
    int mockId = check mockSmscOpen(port);
    Listener mixed = check new ({
        host: "localhost",
        port: port,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER
    });
    check mixed.attach(new MixedArityService());
    check mixed.'start();
    int conn = check mockSmscAwaitNextBind(mockId, 5000);
    check mockSmscSendDeliverSm(mockId, conn, "one-arity", "", 0);
    check mockSmscSendDataSm(mockId, conn, "two-arity", 0);
    test:assertTrue(pollUntil(isolated function() returns boolean {
        return dispatchCount() >= 2 && capturedCaller() !is ();
    }, 5), "both arities must dispatch, and onDataSm must receive the Caller");
    // The Caller captured via onDataSm must actually work.
    Caller caller = <Caller>capturedCaller();
    SubmitResult r = check caller->submit({destAddr: "264811234567", shortMessage: "via data_sm"});
    int sub = check mockSmscAwaitNextSubmit(mockId, conn, 5000);
    test:assertEquals(mockSmscSubmitShortMessage(sub), "via data_sm");
    test:assertTrue(r.messageId.length() > 0);
    check mixed.gracefulStop();
    mockSmscClose(mockId);

    // Negative shapes: rejected at attach, loudly, with the reason.
    Listener rejecting = check new ({
        host: "localhost",
        port: port + 20,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER
    });
    error? optional = rejecting.attach(new OptionalCallerService());
    test:assertTrue(optional is error, "optional Caller must be rejected at attach (D1 trap 1)");
    test:assertTrue((<error>optional).message().includes("Caller"),
            (<error>optional).message());
    error? rest = rejecting.attach(new RestParamService());
    test:assertTrue(rest is error, "rest parameter must be rejected at attach (D1 trap 2)");
    test:assertTrue((<error>rest).message().includes("rest"), (<error>rest).message());
    error? twoSms = rejecting.attach(new TwoSmsService());
    test:assertTrue(twoSms is error, "two same-type parameters must be rejected at attach");
}

@test:Config {groups: ["submit"]}
function testSubmitErrorMappingPerCommandStatus() returns error? {
    var [mockId, conn, smsListener] = check startCapturingListener(
            SUBMIT_ERRORS_TEST_PORT + 20, new CallerCapturingService());
    Caller caller = <Caller>capturedCaller();

    // Each forced negative command_status must surface as REJECTED with the exact code.
    // 0x58 ESME_RTHROTTLED (retriable-by-backoff), 0x0B ESME_RINVDSTADR (never retry).
    foreach int status in [0x58, 0x0B] {
        mockSmscSetSubmitFailure(mockId, status);
        SubmitResult|Error r = caller->submit({destAddr: "264811234567", shortMessage: "x"});
        test:assertTrue(r is Error, "forced negative response must surface as an error");
        Error e = <Error>r;
        test:assertEquals(e.detail().failureMode, REJECTED);
        test:assertEquals(e.detail().commandStatus, status);
    }
    mockSmscSetSubmitFailure(mockId, 0);
    // The two rejected submits DID reach the wire (the SMSC received them and said no) -
    // drain their captures so the local-rejection assertion below starts from zero.
    _ = check mockSmscAwaitNextSubmit(mockId, conn, 5000);
    _ = check mockSmscAwaitNextSubmit(mockId, conn, 5000);

    // Local validation: oversize (255 Latin-1 octets) rejected before anything reaches
    // the wire - the mock must observe NOTHING NEW.
    string oversize = "";
    foreach int i in 1 ... 255 {
        oversize += "a";
    }
    SubmitResult|Error tooLong = caller->submit({destAddr: "264811234567", shortMessage: oversize});
    test:assertTrue(tooLong is Error);
    test:assertEquals((<Error>tooLong).detail().failureMode, INVALID_REQUEST);
    test:assertEquals(mockSmscPendingSubmitCount(mockId, conn), 0,
            "an oversize submit must be rejected BEFORE it reaches the wire");

    // Spec-legal empty message_id: succeeds with an empty id, visibly - not an error.
    mockSmscSetSubmitEmptyMessageId(mockId, true);
    SubmitResult empty = check caller->submit({destAddr: "264811234567", shortMessage: "x"});
    test:assertEquals(empty.messageId, "");
    mockSmscSetSubmitEmptyMessageId(mockId, false);

    check smsListener.gracefulStop();
    mockSmscClose(mockId);
}
