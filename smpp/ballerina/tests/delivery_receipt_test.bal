// Copyright (c) 2026. Sprint 7: end-to-end SMSC delivery-receipt (DLR) parsing.
import ballerina/test;

const int DLR_PORT = 27803;
const int DLR_MALFORMED_PORT = 27804;

Listener? dlrListener = ();
int dlrMockId = -1;

function cleanupDlr() returns error? {
    Listener? l = dlrListener;
    error? stopResult = ();
    if l is Listener {
        stopResult = l.gracefulStop();
        dlrListener = ();
    }
    if dlrMockId != -1 {
        mockSmscClose(dlrMockId);
        dlrMockId = -1;
    }
    return stopResult;
}

// Opens a mock, binds a RecordingService, and returns the accepted connection id.
function bindDlrListener(int port) returns int|error {
    int mockId = check mockSmscOpen(port);
    dlrMockId = mockId;
    Listener smsListener = check new ({
        host: "localhost",
        port,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER
    });
    dlrListener = smsListener;
    check smsListener.attach(new RecordingService());
    check smsListener.'start();
    return mockSmscAwaitNextBind(mockId, 5000);
}

// A well-formed Appendix-B receipt is surfaced as a typed `Sms.receipt`, and `deliveryReceipt`
// is true. Proves the config->native->record plumbing (which the pure JUnit parseReceipt tests
// can't exercise) works end to end.
@test:Config {groups: ["dlr"], after: cleanupDlr}
function testDeliveryReceiptParsedEndToEnd() returns error? {
    clearRecorded();
    int connId = check bindDlrListener(DLR_PORT);

    check mockSmscSendDeliveryReceipt(dlrMockId, connId,
            "id:0123456789 sub:001 dlvrd:001 submit date:0809011130 done date:0809011131 "
            + "stat:DELIVRD err:000 text:Hello");
    test:assertTrue(pollUntil(isolated function() returns boolean {
        return recordedCount() == 1;
    }, 5), "the delivery receipt should be dispatched");

    Sms sms = recordedAt(0);
    test:assertTrue(sms.deliveryReceipt, "deliveryReceipt must be true for a DLR");
    DeliveryReceipt? receipt = sms.receipt;
    test:assertTrue(receipt is DeliveryReceipt, "receipt must be parsed for a well-formed DLR");
    if receipt is DeliveryReceipt {
        test:assertEquals(receipt.id, "0123456789");
        test:assertEquals(receipt.finalStatus, DELIVRD);
        test:assertEquals(receipt.submitted, 1);
        test:assertEquals(receipt.delivered, 1);
        test:assertEquals(receipt.submitDate, "0809011130");
        test:assertEquals(receipt.doneDate, "0809011131");
        test:assertEquals(receipt.errorCode, "000");
    }
}

// A DLR whose body jsmpp can't parse (non-standard stat token) still dispatches, with
// deliveryReceipt=true but receipt=() — and the raw body preserved on shortMessage. Proves the
// lenient never-throw contract end to end (a throw here would NACK -> endless redelivery).
@test:Config {groups: ["dlr"], after: cleanupDlr}
function testMalformedDeliveryReceiptDispatchesRawWithNilReceipt() returns error? {
    clearRecorded();
    int connId = check bindDlrListener(DLR_MALFORMED_PORT);

    string rawBody = "id:9 stat:BUFFERED err:XYZ done date:whenever";
    check mockSmscSendDeliveryReceipt(dlrMockId, connId, rawBody);
    test:assertTrue(pollUntil(isolated function() returns boolean {
        return recordedCount() == 1;
    }, 5), "even a malformed DLR must still be dispatched, not NACKed");

    Sms sms = recordedAt(0);
    test:assertTrue(sms.deliveryReceipt, "esm_class DLR bit is still set, so deliveryReceipt is true");
    test:assertTrue(sms.receipt is (), "an unparseable receipt body yields a nil receipt");
    test:assertEquals(sms.shortMessage, rawBody, "the raw receipt body stays on shortMessage");
}
