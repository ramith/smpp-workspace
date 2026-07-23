// Copyright (c) 2026. Sprint 5: end-to-end opt-in GSM 03.38 decoding (data_coding 0x00).
import ballerina/test;

const int GSM7_ON_PORT = 27801;
const int GSM7_OFF_PORT = 27802;

// Unpacked GSM 03.38 bytes for "£100": £=0x01, '1'=0x31, '0'=0x30, '0'=0x30.
final byte[] GSM7_POUND_100 = [0x01, 0x31, 0x30, 0x30];

Listener? gsm7Listener = ();
int gsm7MockId = -1;

function cleanupGsm7() returns error? {
    Listener? l = gsm7Listener;
    error? stopResult = ();
    if l is Listener {
        stopResult = l.gracefulStop();
        gsm7Listener = ();
    }
    if gsm7MockId != -1 {
        mockSmscClose(gsm7MockId);
        gsm7MockId = -1;
    }
    return stopResult;
}

// With decodeGsm7 enabled, a data_coding 0x00 message of unpacked GSM-7 bytes is decoded via
// the GSM 03.38 default alphabet - proving the config flag actually reaches the decoder (the
// plumbing the JUnit decode tests can't cover).
@test:Config {groups: ["gsm7"], after: cleanupGsm7}
function testGsm7DecodeEnabledEndToEnd() returns error? {
    clearRecorded();
    int mockId = check mockSmscOpen(GSM7_ON_PORT);
    gsm7MockId = mockId;
    Listener smsListener = check new ({
        host: "localhost",
        port: GSM7_ON_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        decodeGsm7: true
    });
    gsm7Listener = smsListener;
    check smsListener.attach(new RecordingService());
    check smsListener.'start();
    int connId = check mockSmscAwaitNextBind(mockId, 5000);

    check mockSmscSendDeliverSmRaw(mockId, connId, GSM7_POUND_100, 0);
    test:assertTrue(pollUntil(isolated function() returns boolean {
        return recordedCount() == 1;
    }, 5), "the GSM-7 deliver_sm should be dispatched");
    test:assertEquals(recordedAt(0).shortMessage, "\u{00A3}100",
            "data_coding 0x00 must decode as GSM 03.38 when decodeGsm7 is enabled");
}

// The opt-in gate: with decodeGsm7 left at its default (false), the SAME bytes decode via the
// UTF-8 fallback (0x01 is U+0001), NOT as GSM-7 - so existing deployments are unaffected.
@test:Config {groups: ["gsm7"], after: cleanupGsm7}
function testGsm7DecodeDisabledByDefaultEndToEnd() returns error? {
    clearRecorded();
    int mockId = check mockSmscOpen(GSM7_OFF_PORT);
    gsm7MockId = mockId;
    Listener smsListener = check new ({
        host: "localhost",
        port: GSM7_OFF_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER
        // decodeGsm7 omitted -> false
    });
    gsm7Listener = smsListener;
    check smsListener.attach(new RecordingService());
    check smsListener.'start();
    int connId = check mockSmscAwaitNextBind(mockId, 5000);

    check mockSmscSendDeliverSmRaw(mockId, connId, GSM7_POUND_100, 0);
    test:assertTrue(pollUntil(isolated function() returns boolean {
        return recordedCount() == 1;
    }, 5), "the deliver_sm should be dispatched");
    test:assertEquals(recordedAt(0).shortMessage, "\u{0001}100",
            "with decodeGsm7 off (default), data_coding 0x00 must still use the UTF-8 fallback");
}
