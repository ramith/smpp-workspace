// Copyright (c) 2026. End-to-end smoke coverage per data_coding branch (full matrix is JUnit's).
import ballerina/test;

const int DATA_CODING_TEST_PORT = 27780;

Listener? dataCodingTestListener = ();
int dataCodingTestMockId = -1;

function cleanupDataCodingTest() returns error? {
    // Capture the stop outcome but ALWAYS close the mock and reset state - an early
    // `check` return here would leak the mock's port into the next test as a
    // misleading BindException (the exact failure mode Sprint 0's review reproduced).
    error? stopResult = ();
    Listener? l = dataCodingTestListener;
    if l is Listener {
        stopResult = l.gracefulStop();
        dataCodingTestListener = ();
    }
    if dataCodingTestMockId != -1 {
        mockSmscClose(dataCodingTestMockId);
        dataCodingTestMockId = -1;
    }
    return stopResult;
}

# One representative case per decoder branch, reusing DispatcherTest.java's fixtures
# verbatim (the full edge-case matrix lives there - this proves the end-to-end wiring:
# real jsmpp PDU encode -> wire -> jsmpp parse -> Dispatcher decode -> Sms record).
# The 0x00 case pins the documented UTF-8 *fallback* (this connector deliberately ships
# no GSM 03.38 codec), not correct GSM-7 decoding.
@test:Config {after: cleanupDataCodingTest}
function testDataCodingSmokeMatrix() returns error? {
    clearRecorded();
    int mockId = check mockSmscOpen(DATA_CODING_TEST_PORT);
    dataCodingTestMockId = mockId;

    Listener smsListener = check new ({
        host: "localhost",
        port: DATA_CODING_TEST_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER
    });
    dataCodingTestListener = smsListener;
    check smsListener.attach(new RecordingService());
    check smsListener.'start();
    int connectionId = check mockSmscAwaitNextBind(mockId, 5000);

    // [dataCoding, fixture] - fixtures verbatim from DispatcherTest.java. The mock
    // encodes each with the same charset the connector's decoder uses for that value,
    // so a pass here proves the *wire* round trip, not just symmetric string handling.
    [int, string][] cases = [
        [0x00, "\u{0}"], // GSM-7 default -> documented UTF-8 fallback (NUL stays NUL, not '@')
        [0x01, "Hello, World! @ #1 - 100%"], // IA5/ASCII
        [0x03, "Café, mañana, naïve, ¿qué?"], // Latin-1, real 0x80-0xFF content
        [0x08, "こんにちは"], // UCS2, non-Latin BMP content
        [0x02, "reserved value"] // reserved value -> UTF-8 fallback
    ];

    int expectedCount = 0;
    foreach [int, string] [dataCoding, fixture] in cases {
        check mockSmscSendDeliverSm(mockId, connectionId, fixture, "", dataCoding);
        expectedCount += 1;
        test:assertEquals(recordedCount(), expectedCount,
                string `case dataCoding=${dataCoding}: exactly one delivery expected`);
        Sms sms = recordedAt(expectedCount - 1);
        test:assertEquals(sms.shortMessage, fixture,
                string `case dataCoding=${dataCoding}: decoded text mismatch`);
        test:assertEquals(sms.properties["dataCoding"], dataCoding,
                string `case dataCoding=${dataCoding}: properties.dataCoding mismatch`);
    }
}
