// Copyright (c) 2026. message_payload-over-short_message precedence, on both PDU types.
import ballerina/test;

const int MESSAGE_PAYLOAD_TEST_PORT = 27781;

Listener? messagePayloadTestListener = ();
int messagePayloadTestMockId = -1;

function cleanupMessagePayloadTest() returns error? {
    // Capture the stop outcome but ALWAYS close the mock and reset state - an early
    // `check` return here would leak the mock's port into the next test as a
    // misleading BindException (the exact failure mode Sprint 0's review reproduced).
    error? stopResult = ();
    Listener? l = messagePayloadTestListener;
    if l is Listener {
        stopResult = l.gracefulStop();
        messagePayloadTestListener = ();
    }
    if messagePayloadTestMockId != -1 {
        mockSmscClose(messagePayloadTestMockId);
        messagePayloadTestMockId = -1;
    }
    return stopResult;
}

# Per the SMPP spec, message_payload takes precedence over short_message when a PDU
# carries both; DATA_SM has no short_message field at all, so its only no-TLV fallback
# is the empty string. The pure-function version of this rule is covered in
# DispatcherTest.java; this proves it end-to-end through real PDUs.
@test:Config {after: cleanupMessagePayloadTest}
function testMessagePayloadPrecedence() returns error? {
    clearRecorded();
    int mockId = check mockSmscOpen(MESSAGE_PAYLOAD_TEST_PORT);
    messagePayloadTestMockId = mockId;

    Listener smsListener = check new ({
        host: "localhost",
        port: MESSAGE_PAYLOAD_TEST_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER
    });
    messagePayloadTestListener = smsListener;
    check smsListener.attach(new RecordingService());
    check smsListener.'start();
    int connectionId = check mockSmscAwaitNextBind(mockId, 5000);

    // 1. deliver_sm carrying BOTH: message_payload must win.
    check mockSmscSendDeliverSm(mockId, connectionId, "fallback text", "payload wins", 0);
    test:assertEquals(recordedAt(0).shortMessage, "payload wins",
            "deliver_sm: message_payload TLV must take precedence over short_message");

    // 2. deliver_sm with only short_message: falls back to it.
    check mockSmscSendDeliverSm(mockId, connectionId, "short message text", "", 0);
    test:assertEquals(recordedAt(1).shortMessage, "short message text",
            "deliver_sm: no TLV means short_message is used");

    // 3. data_sm with a message_payload TLV: used.
    check mockSmscSendDataSm(mockId, connectionId, "data sm payload", 0);
    test:assertEquals(recordedAt(2).shortMessage, "data sm payload",
            "data_sm: message_payload TLV is the payload");

    // 4. data_sm with no TLV at all: DATA_SM has no short_message field, so the only
    //    fallback is empty - the one genuinely new case nothing else covers.
    check mockSmscSendDataSm(mockId, connectionId, "", 0);
    test:assertEquals(recordedAt(3).shortMessage, "",
            "data_sm: no TLV falls back to empty");

    test:assertEquals(recordedCount(), 4);
}
