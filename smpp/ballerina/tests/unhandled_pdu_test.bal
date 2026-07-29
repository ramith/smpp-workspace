// Copyright (c) 2026. D14: unhandled PDU types are NACKed, never silently positive-ACKed.
import ballerina/test;

const int UNHANDLED_PDU_TEST_PORT = 27828;
const int NO_SERVICE_TEST_PORT = 27829;

// The exact decoded command_status, surfaced by class name through interop (see
// PermanentAppErrorException / TemporaryAppErrorException). Asserting the STATUS at the
// wire - not merely "it failed" - is the only observation that catches jsmpp's callback
// catch-alls silently rewriting a wrong-typed connector exception into RX_T_APPN, which
// would turn this permanent NACK into a guaranteed redelivery poison loop.
const string RX_P_APPN_MARKER = "PermanentAppErrorException";
const string RX_T_APPN_MARKER = "TemporaryAppErrorException";

Listener? unhandledPduTestListener = ();
int unhandledPduTestMockId = -1;

function cleanupUnhandledPduTest() returns error? {
    error? stopResult = ();
    Listener? l = unhandledPduTestListener;
    if l is Listener {
        stopResult = l.gracefulStop();
        unhandledPduTestListener = ();
    }
    if unhandledPduTestMockId != -1 {
        mockSmscClose(unhandledPduTestMockId);
        unhandledPduTestMockId = -1;
    }
    return stopResult;
}

// A legal attach (names is non-empty) that nonetheless handles no deliver_sm. Before
// D14 every inbound deliver_sm - INCLUDING every delivery receipt - was answered
// ESME_ROK and dropped on the floor, with no log, no onError, and no metric: the SMSC's
// at-least-once guarantee discharged against a message that reached nothing.
isolated service class DataSmOnlyService {
    *Service;

    remote isolated function onDataSm(Sms sms) returns error? {
        recordSms(sms);
    }
}

@test:Config {after: cleanupUnhandledPduTest, groups: ["dispatch"]}
function testUnhandledPduTypeIsNackedPermanently() returns error? {
    clearRecorded();
    int mockId = check mockSmscOpen(UNHANDLED_PDU_TEST_PORT);
    unhandledPduTestMockId = mockId;
    Listener smsListener = check new ({
        host: "localhost",
        port: UNHANDLED_PDU_TEST_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER
    });
    unhandledPduTestListener = smsListener;
    check smsListener.attach(new DataSmOnlyService());
    check smsListener.'start();
    int conn = check mockSmscAwaitNextBind(mockId, 5000);

    // deliver_sm: no handler for it on this service -> permanent NACK, so the SMSC
    // records a delivery failure instead of believing the message was consumed.
    error? deliverOutcome = mockSmscSendDeliverSm(mockId, conn, "unhandled", "", 0);
    test:assertTrue(deliverOutcome is error,
            "an unhandled deliver_sm must be NACKed, not positively acknowledged");
    test:assertTrue((<error>deliverOutcome).message().includes(RX_P_APPN_MARKER),
            string `must be ESME_RX_P_APPN (permanent - the handler can never appear at ` +
            string `runtime, so a transient status would poison-loop): ` +
            (<error>deliverOutcome).message());
    test:assertEquals(recordedCount(), 0, "nothing should have been dispatched");

    // The handler the service DOES implement still works - the NACK is per PDU type,
    // not a session-wide failure.
    check mockSmscSendDataSm(mockId, conn, "handled", 0);
    test:assertTrue(pollUntil(isolated function() returns boolean {
        return recordedCount() == 1;
    }, 5), "the implemented onDataSm handler must still receive its own PDU type");

    check smsListener.gracefulStop();
    unhandledPduTestListener = ();
    mockSmscClose(mockId);
    unhandledPduTestMockId = -1;
}

@test:Config {after: cleanupUnhandledPduTest, groups: ["dispatch"]}
function testNoServiceAttachedIsNackedTemporarily() returns error? {
    clearRecorded();
    int mockId = check mockSmscOpen(NO_SERVICE_TEST_PORT);
    unhandledPduTestMockId = mockId;
    Listener smsListener = check new ({
        host: "localhost",
        port: NO_SERVICE_TEST_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER
    });
    unhandledPduTestListener = smsListener;
    // Deliberately NO attach: a PDU arriving in the start()-before-attach window (or
    // after a detach) is a TRANSIENT condition - the service may be attached a
    // millisecond later - so it must invite redelivery, unlike the permanent case above.
    check smsListener.'start();
    int conn = check mockSmscAwaitNextBind(mockId, 5000);

    error? outcome = mockSmscSendDeliverSm(mockId, conn, "no service", "", 0);
    test:assertTrue(outcome is error, "a PDU with no attached service must be NACKed");
    test:assertTrue((<error>outcome).message().includes(RX_T_APPN_MARKER),
            string `must be ESME_RX_T_APPN (temporary - attaching later resolves it): ` +
            (<error>outcome).message());

    check smsListener.gracefulStop();
    unhandledPduTestListener = ();
    mockSmscClose(mockId);
    unhandledPduTestMockId = -1;
}
