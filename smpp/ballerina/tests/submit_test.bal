// Copyright (c) 2026. Caller.submit integration tests against the mock SMSC.
import ballerina/lang.runtime;
import ballerina/test;
import ballerina/time;

const int SUBMIT_TEST_PORT = 27805;
const int SUBMIT_REBIND_TEST_PORT = 27806;
const int SUBMIT_RECEIVER_TEST_PORT = 27807;
const int SUBMIT_SHAPES_TEST_PORT = 27808;
const int SUBMIT_ERRORS_TEST_PORT = 27809;
const int SUBMIT_TIMER_TEST_PORT = 27810;
// The shapes test iterates several sub-cases; every port it uses is declared here so
// `grep 'const int .*PORT'` (the suite's collision check) sees them (review finding M5).
const int SUBMIT_SHAPES_PORT_2 = 27811;
const int SUBMIT_SHAPES_PORT_3 = 27812;
const int SUBMIT_SHAPES_MIXED_PORT = 27813;
const int SUBMIT_SHAPES_REJECT_PORT = 27814;
const int SUBMIT_ERRORS_MAPPING_PORT = 27815;
const int SUBMIT_DLR_TEST_PORT = 27816;
const int SUBMIT_ONERROR_TEST_PORT = 27817;
const int SUBMIT_THROTTLE_TEST_PORT = 27818;
const int SUBMIT_REBIND_TIMER_PORT = 27819;
const int SUBMIT_CONCURRENT_TEST_PORT = 27820;
const int SUBMIT_STALL_TEST_PORT = 27821;
const int SUBMIT_LATE_RESP_PORT = 27822;
const int SUBMIT_DUP_MT_PORT = 27823;
const int SUBMIT_UDHI_TEST_PORT = 27824;
const int SUBMIT_ABANDONED_TEST_PORT = 27825;

// Cleanup state for the after: hooks (the house pattern - see data_sm_test.bal for why
// @test:AfterEach is unusable). A listener leaked by a failed assertion would otherwise
// rebind forever at ~1s cadence against a closed mock AND keep writing the module-level
// capture globals, contaminating every later test in this file (review finding H1).
Listener? submitTestListener = ();
int submitTestMockId = -1;

function cleanupSubmitTest() returns error? {
    Listener? l = submitTestListener;
    submitTestListener = ();
    error? stopResult = ();
    if l is Listener {
        stopResult = l.gracefulStop();
    }
    if submitTestMockId != -1 {
        mockSmscClose(submitTestMockId);
        submitTestMockId = -1;
    }
    return stopResult;
}

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

isolated string? lastReceiptTlv = ();
isolated string? lastReceiptBodyId = ();

isolated function recordedReceiptTlv() returns string? {
    lock {
        return lastReceiptTlv;
    }
}

isolated function recordedReceiptBodyId() returns string? {
    lock {
        return lastReceiptBodyId;
    }
}

// Caller LAST - the common shape. Also records delivery receipts for the DLR tests.
isolated service class CallerCapturingService {
    *Service;

    remote isolated function onError(Error err) returns error? {
        recordError(err);
    }

    remote isolated function onDeliverSm(Sms sms, Caller caller) returns error? {
        lock {
            submitTestCaller = caller;
        }
        if sms.deliveryReceipt {
            string? tlv = sms.receiptedMessageId;
            lock {
                lastReceiptTlv = tlv;
            }
            string? bodyId = sms.receipt?.id;
            lock {
                lastReceiptBodyId = bodyId;
            }
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

// Submits from onError (via a stashed Caller) - Sprint 5 recorded that runtime work on
// this exact path once derailed scheduleRebind; the gate demands it not happen again.
isolated service class OnErrorSubmittingService {
    *Service;

    remote isolated function onDeliverSm(Sms sms, Caller caller) returns error? {
        lock {
            submitTestCaller = caller;
        }
        lock {
            submitTestDispatches += 1;
        }
    }

    remote isolated function onError(Error err) returns error? {
        Caller? c = ();
        lock {
            c = submitTestCaller;
        }
        if c is Caller {
            // Expected to fail (the link just dropped) - the point is that this runtime
            // work must not derail the rebind that is being scheduled around it.
            SubmitResult|Error r = c->submit({destAddr: "264811234567", shortMessage: "from onError"});
            if r is Error {
                lock {
                    submitTestDispatches += 0; // outcome irrelevant; must simply not panic
                }
            }
        }
    }
}

isolated map<string> concurrentReplies = {};

isolated function recordedReplyCount() returns int {
    lock {
        return concurrentReplies.length();
    }
}

isolated function recordedReplyId(string text) returns string? {
    lock {
        return concurrentReplies[text];
    }
}

// Each dispatch replies inline with text derived from the inbound message and records
// the id ITS submit returned - the correlation the concurrency test pins.
isolated service class CorrelatingReplyService {
    *Service;

    remote isolated function onError(Error err) returns error? {
        recordError(err);
    }

    remote isolated function onDeliverSm(Sms sms, Caller caller) returns error? {
        string replyText = string `re:${sms.shortMessage}`;
        SubmitResult|Error r = caller->submit({destAddr: "264811234567", shortMessage: replyText});
        if r is SubmitResult {
            string id = r.messageId;
            lock {
                concurrentReplies[replyText] = id;
            }
        }
    }
}

// Replies inline from the handler (SYNC): while the submit waits, the handler holds its
// dispatch permit - the seam the throttle test pins.
isolated service class InlineReplyService {
    *Service;

    remote isolated function onDeliverSm(Sms sms, Caller caller) returns error? {
        lock {
            submitTestDispatches += 1;
        }
        SubmitResult|Error r = caller->submit({destAddr: sms.sourceAddr, shortMessage: "reply"});
        _ = r is Error;
    }
}

// The 1.0.1 compat shape: trailing defaulted non-Caller params are skipped, not rejected.
isolated service class DefaultedExtraService {
    *Service;

    remote isolated function onDeliverSm(Sms sms, string extra = "x") returns error? {
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
    submitTestMockId = mockId;
    Listener smsListener = check new ({
        host: "localhost",
        port: port,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        rebindPolicy: {initialRebindDelay: 0.2, maxRebindDelay: 1, backOffMultiplier: 2.0}
    });
    submitTestListener = smsListener;
    check smsListener.attach(svc);
    check smsListener.'start();
    int conn = check mockSmscAwaitNextBind(mockId, 5000);
    check mockSmscSendDeliverSm(mockId, conn, "capture", "", 0);
    test:assertTrue(pollUntil(isolated function() returns boolean {
        return capturedCaller() !is ();
    }, 5), "the dispatch never delivered a Caller");
    return [mockId, conn, smsListener];
}

@test:Config {after: cleanupSubmitTest, groups: ["submit"]}
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

    // Wire-byte + accessor assertions (review H2/M6/D5): a non-ASCII Latin-1 fixture,
    // the EXACT octets at the mock (an encoder that substituted '?' would pass any
    // decoded-string comparison), and the id correlated via the mock's own record.
    SubmitResult rLatin = check caller->submit({
        destAddr: "264811234567",
        shortMessage: "Café mañana"
    });
    int submitLatin = check mockSmscAwaitNextSubmit(mockId, conn, 5000);
    byte[] expectedLatin1 = [0x43, 0x61, 0x66, 0xE9, 0x20, 0x6D, 0x61, 0xF1, 0x61, 0x6E, 0x61];
    test:assertEquals(mockSmscSubmitShortMessageBytes(submitLatin), expectedLatin1,
            "exact Latin-1 octets on the wire - 0xE9/0xF1, never '?' substitution");
    test:assertEquals(rLatin.messageId, mockSmscSubmitMessageId(submitLatin),
            "the returned id must be the id the mock minted for THIS capture");
    test:assertEquals(mockSmscSubmitSourceAddrTon(submitLatin), 0,
            "empty source must ship TON Unknown (4.4.1) - asserted at the wire");
    test:assertEquals(mockSmscSubmitSourceAddrNpi(submitLatin), 0);

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
    test:assertEquals(r2.messageId, mockSmscSubmitMessageId(submit2));
    test:assertEquals(mockSmscPendingSubmitCount(mockId, conn), 0, "and no more submits");

    check smsListener.gracefulStop();
    mockSmscClose(mockId);
}

@test:Config {after: cleanupSubmitTest, groups: ["submit"]}
function testUdhiBinarySubmitPinsEsmClassAtWire() returns error? {
    var [mockId, conn, smsListener] = check startCapturingListener(
            SUBMIT_UDHI_TEST_PORT, new CallerCapturingService());
    Caller caller = <Caller>capturedCaller();

    // A 6-octet concatenation UDH (05 00 03 ref total seq) + two payload octets,
    // declared via BinarySms.udhi (D15). Without bit 6 the handset would render the
    // header octets as visible garbage - the wire byte is the whole point here.
    byte[] udhPayload = [0x05, 0x00, 0x03, 0x2A, 0x02, 0x01, 0x41, 0x42];
    SubmitResult r = check caller->submit({
        destAddr: "264811234567",
        shortMessageBytes: udhPayload,
        dataCoding: 0x00,
        udhi: true
    });
    int submitUdh = check mockSmscAwaitNextSubmit(mockId, conn, 5000);
    test:assertEquals(mockSmscSubmitEsmClass(submitUdh), 0x40,
            "udhi must set exactly esm_class bit 6 at the wire (section 5.2.12)");
    test:assertEquals(mockSmscSubmitShortMessageBytes(submitUdh), udhPayload,
            "the UDH-bearing payload must pass verbatim");
    test:assertEquals(mockSmscSubmitDataCoding(submitUdh), 0x00);
    test:assertEquals(r.messageId, mockSmscSubmitMessageId(submitUdh));

    // udhi is per-message, not sticky: a following default-path submit stays 0x00.
    _ = check caller->submit({destAddr: "264811234567", shortMessage: "plain"});
    int submitPlain = check mockSmscAwaitNextSubmit(mockId, conn, 5000);
    test:assertEquals(mockSmscSubmitEsmClass(submitPlain), 0x00,
            "default esm_class must remain 0x00 on the very next submit");

    check smsListener.gracefulStop();
    mockSmscClose(mockId);
}

@test:Config {after: cleanupSubmitTest, groups: ["submit"]}
function testSubmitOnReceiverBindIsRejected() returns error? {
    clearCapturedCaller();
    int mockId = check mockSmscOpen(SUBMIT_RECEIVER_TEST_PORT);
    submitTestMockId = mockId;
    Listener smsListener = check new ({
        host: "localhost",
        port: SUBMIT_RECEIVER_TEST_PORT,
        systemId: "test",
        password: "test",
        bindType: RECEIVER
    });
    submitTestListener = smsListener;
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

@test:Config {after: cleanupSubmitTest, groups: ["submit"]}
function testExhaustedRebindYieldsLinkAbandoned() returns error? {
    clearCapturedCaller();
    int mockId = check mockSmscOpen(SUBMIT_ABANDONED_TEST_PORT);
    submitTestMockId = mockId;
    Listener smsListener = check new ({
        host: "localhost",
        port: SUBMIT_ABANDONED_TEST_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        rebindPolicy: {maxRebindAttempts: 0}
    });
    submitTestListener = smsListener;
    check smsListener.attach(new CallerCapturingService());
    check smsListener.'start();
    int conn = check mockSmscAwaitNextBind(mockId, 5000);
    check mockSmscSendDeliverSm(mockId, conn, "capture", "", 0);
    test:assertTrue(pollUntil(isolated function() returns boolean {
        return capturedCaller() !is ();
    }, 5), "the dispatch never delivered a Caller");
    Caller caller = <Caller>capturedCaller();

    check mockSmscSever(mockId, conn);

    // Poll until the drop is detected AND the terminal verdict latched: a submit in
    // the sliver between sessionUsable=false and the latch may correctly see
    // LINK_DOWN once - the two flags flip microseconds apart, in that order.
    Error? abandoned = ();
    int attempts = 0;
    while abandoned is () {
        SubmitResult|Error r = caller->submit({destAddr: "264811234567", shortMessage: "x"});
        if r is Error && r.detail().failureMode == LINK_ABANDONED {
            abandoned = r;
        } else {
            attempts += 1;
            test:assertTrue(attempts < 50,
                    "LINK_ABANDONED never surfaced with maxRebindAttempts: 0 after a sever");
            runtime:sleep(0.1);
        }
    }
    Error e = <Error>abandoned;
    test:assertTrue(e.message().includes("new Listener"),
            string `the remedy must be named in the message: ${e.message()}`);
    test:assertEquals(e.detail().possiblySubmitted, false,
            "an abandoned-link refusal provably never wrote - resubmit on a new Listener is safe");

    check smsListener.gracefulStop();
    mockSmscClose(mockId);
}

@test:Config {after: cleanupSubmitTest, groups: ["submit"]}
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

        // Non-vacuous conn1 check (Phase 5 finding #3a): assert on the LIVE handle,
        // BEFORE the sever forgets it - post-sever the accessor returns -1 forever.
        test:assertEquals(mockSmscPendingSubmitCount(mockId, previousConn), 0,
                "gate: submitCount(conn1) unchanged - all captures drained, nothing extra");
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

@test:Config {after: cleanupSubmitTest, groups: ["submit"]}
function testSubmitDuringRebindFailsFastAndAfterStopIsRejected() returns error? {
    var [mockId, conn, smsListener] = check startCapturingListener(
            SUBMIT_ERRORS_TEST_PORT, new CallerCapturingService());
    Caller caller = <Caller>capturedCaller();

    // Stop accepting so the rebind cannot succeed, then sever: the session is down for
    // good, and submit must fail fast with the connector's own wording.
    mockSmscStopAccepting(mockId);
    check mockSmscSever(mockId, conn);
    // The first error may be the MID-FLIGHT IOException path (a submit racing the sever);
    // keep sampling until the fail-fast PRE-CHECK wording appears - the drop verdict
    // (sessionUsable) flips within the ~1s transport-death grace, after which every
    // submit must fail instantly without touching the dead socket.
    Error? preCheckError = ();
    foreach int i in 1 ... 100 {
        SubmitResult|Error r = caller->submit({destAddr: "264811234567", shortMessage: "x"});
        if r is Error {
            // Every failure on a down link must be LINK_DOWN and must never leak jsmpp
            // state names, regardless of which path (mid-flight or pre-check) produced it.
            test:assertEquals(r.detail().failureMode, LINK_DOWN);
            test:assertFalse(r.message().includes("CLOSED"),
                    string `jsmpp state names must not leak: ${r.message()}`);
            if r.message().includes("session is down") {
                preCheckError = r;
                break;
            }
        }
        runtime:sleep(0.1);
    }
    test:assertTrue(preCheckError !is (),
            "the fail-fast pre-check wording must appear once the drop verdict lands");
    Error e = <Error>preCheckError;
    // Both phrases asserted (not OR - a regression dropping either must fail), and the
    // wording promises nothing a disabled/exhausted rebind cannot deliver (D8).
    test:assertTrue(e.message().includes("session is down") && e.message().includes("rebindPolicy"),
            string `the connector's own wording: ${e.message()}`);

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

@test:Config {after: cleanupSubmitTest, groups: ["submit"]}
function testCallerParamShapes() returns error? {
    // Positive shapes: each attaches AND dispatches. Caller-first pins the D1 decision
    // (order-agnostic type binding - the case mqtt would reject and ftp accepts).
    Service[] accepted = [
        new PlainSmsService(),
        new CallerCapturingService(),
        new CallerFirstService()
    ];
    int[] shapePorts = [SUBMIT_SHAPES_TEST_PORT, SUBMIT_SHAPES_PORT_2, SUBMIT_SHAPES_PORT_3];
    int portIndex = 0;
    foreach Service svc in accepted {
        int port = shapePorts[portIndex];
        portIndex += 1;
        clearCapturedCaller();
        int mockId = check mockSmscOpen(port);
        submitTestMockId = mockId;
        Listener l = check new ({
            host: "localhost",
            port: port,
            systemId: "test",
            password: "test",
            bindType: TRANSCEIVER
        });
        submitTestListener = l;
        check l.attach(svc);
        check l.'start();
        int conn = check mockSmscAwaitNextBind(mockId, 5000);
        check mockSmscSendDeliverSm(mockId, conn, "shape", "", 0);
        test:assertTrue(pollUntil(isolated function() returns boolean {
            return dispatchCount() >= 1;
        }, 5), "dispatch must reach every accepted shape");
        check l.gracefulStop();
        mockSmscClose(mockId);
        submitTestListener = ();
        submitTestMockId = -1;
    }

    // Mixed service: onDeliverSm 1-arity and onDataSm 2-arity coexist; the data_sm path
    // is a separate dispatch site and must position the Caller independently.
    clearCapturedCaller();
    int mockId = check mockSmscOpen(SUBMIT_SHAPES_MIXED_PORT);
    submitTestMockId = mockId;
    Listener mixed = check new ({
        host: "localhost",
        port: SUBMIT_SHAPES_MIXED_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER
    });
    submitTestListener = mixed;
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
        port: SUBMIT_SHAPES_REJECT_PORT,
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
    // The 1.0.1 compatibility shape (D5's required case): a trailing defaulted extra
    // parameter is a legal, WORKING 1.0.1 program and must keep attaching - this is the
    // test whose absence let the compat break ship the first time (review major #1).
    error? compat = rejecting.attach(new DefaultedExtraService());
    test:assertTrue(compat is (), compat is error ? compat.message() : "");
}

@test:Config {after: cleanupSubmitTest, groups: ["submit"]}
function testSubmitWaitsBeyondHousekeepingTimer() returns error? {
    // The split-timer behavioral pin: the mock delays its submit_sm_resp by 3s - longer
    // than ConnectorSession's 2s housekeeping bound, well under transactionTimeout (30s).
    // If the submit-context routing ever mis-bucketed caller threads, this submit would
    // ResponseTimeout at 2s; success proves submits ride the configured long bound while
    // teardown/keepalive stay short (JUnit pins the routing itself).
    var [mockId, conn, smsListener] = check startCapturingListener(
            SUBMIT_TIMER_TEST_PORT, new CallerCapturingService());
    Caller caller = <Caller>capturedCaller();
    mockSmscSetSubmitDelay(mockId, 3000);
    decimal t0 = time:monotonicNow();
    SubmitResult r = check caller->submit({destAddr: "264811234567", shortMessage: "patient"});
    decimal elapsed = time:monotonicNow() - t0;
    test:assertTrue(elapsed >= 2.9d,
            string `the mock's delay knob must actually delay (took ${elapsed}s) - without this the test passes vacuously if the knob regresses (review M3)`);
    test:assertTrue(r.messageId.length() > 0);
    mockSmscSetSubmitDelay(mockId, 0);
    _ = check mockSmscAwaitNextSubmit(mockId, conn, 5000);
    check smsListener.gracefulStop();
    mockSmscClose(mockId);
}

@test:Config {after: cleanupSubmitTest, groups: ["submit"]}
function testSubmitFromOnErrorDoesNotDerailRebind() returns error? {
    var [mockId, conn, smsListener] = check startCapturingListener(
            SUBMIT_ONERROR_TEST_PORT, new OnErrorSubmittingService());
    check mockSmscSever(mockId, conn);
    // The gate's two clauses: the onError-issued submit errors (asserted inside the
    // service - it must not panic), AND the rebind still lands.
    int conn2 = check mockSmscAwaitNextBind(mockId, 10000);
    check mockSmscSendDeliverSm(mockId, conn2, "post-rebind", "", 0);
    test:assertTrue(pollUntil(isolated function() returns boolean {
        return dispatchCount() >= 2;
    }, 5), "the rebound session must dispatch - onError's submit must not derail the rebind");
    check smsListener.gracefulStop();
    mockSmscClose(mockId);
    submitTestListener = ();
    submitTestMockId = -1;
}

@test:Config {after: cleanupSubmitTest, groups: ["submit"]}
function testSubmitStarvesInboundDispatchWithThrottle() returns error? {
    // Pins the DOCUMENTED consequence caller.bal names: in SYNC mode a handler blocked in
    // submit holds its dispatch permit; with all maxConcurrentDispatch permits held, the
    // next inbound deliver_sm answers ESME_RTHROTTLED (the bridge surfaces that as an
    // error whose message names ThrottledException).
    clearCapturedCaller();
    int mockId = check mockSmscOpen(SUBMIT_THROTTLE_TEST_PORT);
    submitTestMockId = mockId;
    Listener smsListener = check new ({
        host: "localhost",
        port: SUBMIT_THROTTLE_TEST_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        maxConcurrentDispatch: 1
    });
    submitTestListener = smsListener;
    check smsListener.attach(new InlineReplyService());
    check smsListener.'start();
    int conn = check mockSmscAwaitNextBind(mockId, 5000);
    // The handler acks the deliver_sm only after its ~3s inline reply completes - the
    // mock's own 2s transaction timer must outwait that (the graceful_stop_test pattern).
    check mockSmscSetTransactionTimer(mockId, conn, 15000);
    mockSmscSetSubmitDelay(mockId, 3000);
    // First deliver_sm occupies the ONLY permit (its handler blocks ~3s in submit)...
    future<error?> first = start mockSmscSendDeliverSm(mockId, conn, "occupy", "", 0);
    runtime:sleep(0.5);
    // ...so the second must come back throttled, not queued behind the handler.
    error? second = mockSmscSendDeliverSm(mockId, conn, "starved", "", 0);
    test:assertTrue(second is error && (<error>second).message().includes("Throttled"),
            second is error ? (<error>second).message() : "second deliver_sm must be RTHROTTLED");
    error? firstOutcome = wait first;
    test:assertTrue(firstOutcome is (), "the occupying dispatch itself must complete");
    mockSmscSetSubmitDelay(mockId, 0);
    check smsListener.gracefulStop();
    mockSmscClose(mockId);
    submitTestListener = ();
    submitTestMockId = -1;
}

@test:Config {after: cleanupSubmitTest, groups: ["submit"]}
function testSubmitTimerReappliedOnRebind() returns error? {
    // Item 5's justification for living in bind() is that the submit bound survives
    // rebinds; without this test, dropping it from the rebind path would silently turn
    // every post-rebind slow response into TIMEOUT_DELIVERY_UNKNOWN (review risk #3).
    var [mockId, conn, smsListener] = check startCapturingListener(
            SUBMIT_REBIND_TIMER_PORT, new CallerCapturingService());
    Caller caller = <Caller>capturedCaller();
    check mockSmscSever(mockId, conn);
    int conn2 = check mockSmscAwaitNextBind(mockId, 10000);
    // Post-rebind: a 3s-delayed resp must still succeed (2s housekeeping bound would fail).
    mockSmscSetSubmitDelay(mockId, 3000);
    SubmitResult? postRebind = ();
    foreach int i in 1 ... 50 {
        SubmitResult|Error r = caller->submit({destAddr: "264811234567", shortMessage: "patient"});
        if r is SubmitResult {
            postRebind = r;
            break;
        }
        runtime:sleep(0.1);
    }
    test:assertTrue(postRebind !is (),
            "a 3s-delayed submit must succeed on the REBOUND session - the configured "
            + "transactionTimeout must be re-applied, not jsmpp's or the housekeeping default");
    mockSmscSetSubmitDelay(mockId, 0);
    check smsListener.gracefulStop();
    mockSmscClose(mockId);
    submitTestListener = ();
    submitTestMockId = -1;
}

@test:Config {after: cleanupSubmitTest, groups: ["submit"]}
function testConcurrentSubmitsCorrelateAndKeepaliveAnswered() returns error? {
    // N concurrent SYNC handlers each blocked ~500ms in submit; every handler must get
    // the id for ITS OWN text (jsmpp correlates by sequence_number - this is the
    // regression guard for that machinery and for the pool reserve that keeps responses
    // flowing while all dispatch permits are held). recordedErrorCount()==0 doubles as
    // the keepalive assertion: a missed enquire_link would drop the link mid-test.
    lock {
        concurrentReplies = {};
    }
    clearCapturedCaller();
    clearRecordedErrors();
    int mockId = check mockSmscOpen(SUBMIT_CONCURRENT_TEST_PORT);
    submitTestMockId = mockId;
    Listener smsListener = check new ({
        host: "localhost",
        port: SUBMIT_CONCURRENT_TEST_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        maxConcurrentDispatch: 4
    });
    submitTestListener = smsListener;
    check smsListener.attach(new CorrelatingReplyService());
    check smsListener.'start();
    int conn = check mockSmscAwaitNextBind(mockId, 5000);
    check mockSmscSetTransactionTimer(mockId, conn, 15000);
    mockSmscSetSubmitDelay(mockId, 500);
    future<error?>[] sends = [];
    foreach int i in 1 ... 4 {
        future<error?> f = start mockSmscSendDeliverSm(mockId, conn, string `msg${i}`, "", 0);
        sends.push(f);
    }
    foreach var f in sends {
        error? outcome = wait f;
        test:assertTrue(outcome is (), outcome is error ? (<error>outcome).message() : "");
    }
    test:assertEquals(recordedReplyCount(), 4, "every concurrent handler must complete its reply");
    mockSmscSetSubmitDelay(mockId, 0);
    // Correlation: drain the four captures; each captured reply's minted id must equal
    // the id the handler that SENT that text received back.
    foreach int i in 1 ... 4 {
        int captured = check mockSmscAwaitNextSubmit(mockId, conn, 5000);
        string text = mockSmscSubmitShortMessage(captured);
        test:assertEquals(recordedReplyId(text), mockSmscSubmitMessageId(captured),
                string `handler for '${text}' must hold the id minted for its own capture`);
    }
    test:assertEquals(recordedErrorCount(), 0, "no drops, no keepalive failures");
    check smsListener.gracefulStop();
    mockSmscClose(mockId);
    submitTestListener = ();
    submitTestMockId = -1;
}

isolated function submitBlocker(Caller caller) returns SubmitResult|Error {
    return caller->submit({destAddr: "264811234567", shortMessage: "blocker"});
}

@test:Config {after: cleanupSubmitTest, groups: ["submit"]}
function testSubmitDoesNotStallUnrelatedStrands() returns error? {
    // Pins the strand-isolation fix (remediation wave 1): an isolated service's handler
    // blocked ~3s inside submit must NOT hold the runtime's process-wide non-isolated
    // lock - unrelated work must make progress while it waits.
    var [mockId, conn, smsListener] = check startCapturingListener(
            SUBMIT_STALL_TEST_PORT, new CallerCapturingService());
    Caller caller = <Caller>capturedCaller();
    check mockSmscSetTransactionTimer(mockId, conn, 15000);
    mockSmscSetSubmitDelay(mockId, 3000);
    future<SubmitResult|Error> blocked = start submitBlocker(caller);
    decimal t0 = time:monotonicNow();
    int progress = 0;
    while time:monotonicNow() - t0 < 1.0d {
        progress += 1;
        runtime:sleep(0.05);
    }
    test:assertTrue(progress >= 10,
            string `unrelated strand made only ${progress} iterations in 1s - a blocked submit is stalling the program`);
    SubmitResult|Error blockedResult = wait blocked;
    test:assertTrue(blockedResult is SubmitResult, "the blocked submit itself must still succeed");
    mockSmscSetSubmitDelay(mockId, 0);
    check smsListener.gracefulStop();
    mockSmscClose(mockId);
    submitTestListener = ();
    submitTestMockId = -1;
}

@test:Config {after: cleanupSubmitTest, groups: ["submit"]}
function testLateSubmitResponseIsTimeoutDeliveryUnknown() returns error? {
    // Item 12's falsifiable half (D5): transactionTimeout: 1 with a 2.5s-delayed resp.
    // Note this legally puts the caller bound BELOW the 2s housekeeping bound - the
    // validated floor is 1s, and nothing exercised that ordering before.
    clearCapturedCaller();
    clearRecordedErrors();
    int mockId = check mockSmscOpen(SUBMIT_LATE_RESP_PORT);
    submitTestMockId = mockId;
    Listener smsListener = check new ({
        host: "localhost",
        port: SUBMIT_LATE_RESP_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        transactionTimeout: 1
    });
    submitTestListener = smsListener;
    check smsListener.attach(new CallerCapturingService());
    check smsListener.'start();
    int conn = check mockSmscAwaitNextBind(mockId, 5000);
    check mockSmscSendDeliverSm(mockId, conn, "capture", "", 0);
    test:assertTrue(pollUntil(isolated function() returns boolean {
        return capturedCaller() !is ();
    }, 5), "capture dispatch");
    Caller caller = <Caller>capturedCaller();
    mockSmscSetSubmitDelay(mockId, 2500);
    SubmitResult|Error late = caller->submit({destAddr: "264811234567", shortMessage: "late"});
    test:assertTrue(late is Error, "a resp after transactionTimeout must be a timeout error");
    test:assertEquals((<Error>late).detail().failureMode, TIMEOUT_DELIVERY_UNKNOWN);
    // The "possibly delivered" half is what makes the caveat true, not rhetorical:
    int captured = check mockSmscAwaitNextSubmit(mockId, conn, 5000);
    test:assertEquals(mockSmscSubmitShortMessage(captured), "late",
            "the SMSC DID receive the submit whose response timed out");
    mockSmscSetSubmitDelay(mockId, 0);
    // The late, unmatched resp must not be mistaken for a session fault...
    runtime:sleep(2.5);
    test:assertEquals(recordedErrorCount(), 0, "a late resp is not a drop");
    // ...and the link survived: a fresh submit succeeds.
    SubmitResult again = check caller->submit({destAddr: "264811234567", shortMessage: "after"});
    test:assertTrue(again.messageId.length() > 0);
    check smsListener.gracefulStop();
    mockSmscClose(mockId);
    submitTestListener = ();
    submitTestMockId = -1;
}

@test:Config {after: cleanupSubmitTest, groups: ["submit"]}
function testSyncSubmitOutlivesSmscTransactionTimer() returns error? {
    // Item 12's actual hazard, fully deterministic: the SMSC's OWN transaction timer
    // (mock-side, 1s) expires while a SYNC handler spends ~2s replying inline - the SMSC
    // concludes the MO was unanswered WHILE the MT reply was nonetheless sent. Resending
    // the identical MO (explicitly simulating SMSC redelivery POLICY - jsmpp itself
    // implements none) then produces a SECOND MT: the documented duplicate chain.
    lock {
        concurrentReplies = {};
    }
    clearCapturedCaller();
    int mockId = check mockSmscOpen(SUBMIT_DUP_MT_PORT);
    submitTestMockId = mockId;
    Listener smsListener = check new ({
        host: "localhost",
        port: SUBMIT_DUP_MT_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER
    });
    submitTestListener = smsListener;
    check smsListener.attach(new CorrelatingReplyService());
    check smsListener.'start();
    int conn = check mockSmscAwaitNextBind(mockId, 5000);
    check mockSmscSetTransactionTimer(mockId, conn, 1000);
    mockSmscSetSubmitDelay(mockId, 2000);
    error? mo1 = mockSmscSendDeliverSm(mockId, conn, "dup", "", 0);
    test:assertTrue(mo1 is error,
            "the SMSC's 1s timer must expire while the handler is mid-reply");
    int mt1 = check mockSmscAwaitNextSubmit(mockId, conn, 10000);
    test:assertEquals(mockSmscSubmitShortMessage(mt1), "re:dup",
            "the MT was nonetheless sent - that is what makes redelivery a DUPLICATE");
    mockSmscSetSubmitDelay(mockId, 0);
    // Simulated SMSC redelivery of the identical MO:
    check mockSmscSendDeliverSm(mockId, conn, "dup", "", 0);
    int mt2 = check mockSmscAwaitNextSubmit(mockId, conn, 10000);
    test:assertEquals(mockSmscSubmitShortMessage(mt2), "re:dup");
    test:assertTrue(mockSmscSubmitMessageId(mt1) != mockSmscSubmitMessageId(mt2),
            "two distinct MTs for one logical MO - the item-12 chain, pinned end to end");
    check smsListener.gracefulStop();
    mockSmscClose(mockId);
    submitTestListener = ();
    submitTestMockId = -1;
}

@test:Config {after: cleanupSubmitTest, groups: ["submit"]}
function testDlrCorrelatesWithReturnedMessageIdAndTlvSurfaced() returns error? {
    var [mockId, conn, smsListener] = check startCapturingListener(
            SUBMIT_DLR_TEST_PORT, new CallerCapturingService());
    Caller caller = <Caller>capturedCaller();
    SubmitResult r = check caller->submit({
        destAddr: "264811234567",
        shortMessage: "track me",
        registeredDelivery: ON_SUCCESS_OR_FAILURE
    });
    _ = check mockSmscAwaitNextSubmit(mockId, conn, 5000);
    // The SMSC's receipt carries the guaranteed key in the TLV and a DIFFERENT radix in
    // the vendor-specific body id: - correlation must pin to the TLV (item 9 / 5.3.2.12).
    string bodyStyleId = string `deadbeef`; // deliberately unlike the mock's decimal ids
    check mockSmscSendDeliveryReceiptWithTlv(mockId, conn,
            string `id:${bodyStyleId} sub:001 dlvrd:001 submit date:2607290000 done date:2607290001 stat:DELIVRD err:000 text:x`,
            r.messageId);
    test:assertTrue(pollUntil(isolated function() returns boolean {
        return recordedReceiptTlv() !is ();
    }, 5), "the receipt must reach onDeliverSm with the TLV surfaced");
    test:assertEquals(recordedReceiptTlv(), r.messageId,
            "receiptedMessageId (TLV 0x001E) must equal the id submit returned");
    test:assertEquals(recordedReceiptBodyId(), bodyStyleId,
            "the vendor-specific body id stays independently available on receipt.id");
    // And a receipt WITHOUT the TLV leaves the field () - absence is meaningful.
    lock {
        lastReceiptTlv = "sentinel";
    }
    check mockSmscSendDeliveryReceipt(mockId, conn,
            "id:0000000042 sub:001 dlvrd:001 submit date:2607290000 done date:2607290001 stat:DELIVRD err:000 text:x");
    test:assertTrue(pollUntil(isolated function() returns boolean {
        return recordedReceiptBodyId() == "0000000042";
    }, 5), "second receipt must arrive");
    test:assertEquals(recordedReceiptTlv(), (),
            "no TLV on the wire must surface as (), never a stale or invented value");
    check smsListener.gracefulStop();
    mockSmscClose(mockId);
    submitTestListener = ();
    submitTestMockId = -1;
}

@test:Config {after: cleanupSubmitTest, groups: ["submit"]}
function testSubmitErrorMappingPerCommandStatus() returns error? {
    var [mockId, conn, smsListener] = check startCapturingListener(
            SUBMIT_ERRORS_MAPPING_PORT, new CallerCapturingService());
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
