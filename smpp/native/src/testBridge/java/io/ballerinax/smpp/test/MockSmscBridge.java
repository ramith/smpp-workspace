// Copyright (c) 2026. Thin static facade exposing MockSmsc instances to bal test.
package io.ballerinax.smpp.test;

import io.ballerina.runtime.api.creators.ValueCreator;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BArray;
import io.ballerina.runtime.api.values.BString;

import org.jsmpp.bean.SubmitSm;
import org.jsmpp.session.connection.ServerConnectionFactory;

import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

/**
 * The {@code @java:Method} surface consumed by {@code tests/mocksmsc.bal}. Maps opaque
 * {@code long} handles to {@link MockSmsc} instances (and, within each mock, to accepted
 * connections), so multiple tests — or multiple connections within one test — never
 * collide through shared static session state (Sprint 0's single-shot design did exactly
 * that, deliberately, for its one test; Sprint 1's multi-test suite can't).
 *
 * <p>The only Ballerina-runtime-typed file in this source set: Ballerina {@code string}
 * interops as {@link BString}, not {@code java.lang.String} (and Ballerina {@code byte[]}
 * doesn't interop-map onto Java's signed {@code byte[]} at all) — payload text crosses
 * the boundary as {@code BString} and is charset-encoded on the Java side per the PDU's
 * {@code data_coding}, mirroring {@code Dispatcher.decodeShortMessage}.
 */
public final class MockSmscBridge {

    private static final AtomicLong NEXT_MOCK_ID = new AtomicLong(1);
    private static final ConcurrentHashMap<Long, MockSmsc> MOCKS = new ConcurrentHashMap<>();

    private MockSmscBridge() {}

    /** Opens a plaintext listening socket and starts the accept-loop; returns the handle. */
    public static long openMock(int port) throws Exception {
        return register(new MockSmsc(port));
    }

    /**
     * Opens a TLS-terminating mock presenting the given server keystore's cert (server-auth
     * TLS; the mock verifies nothing about the client). All other mock operations work
     * identically against the returned handle.
     */
    public static long openMockTls(int port, BString serverKeystorePath,
                                   BString serverKeystorePassword) throws Exception {
        ServerConnectionFactory factory = new TlsServerConnectionFactory(
                serverKeystorePath.getValue(), serverKeystorePassword.getValue().toCharArray(),
                null, null);
        return register(new MockSmsc(port, factory));
    }

    /**
     * Opens an mTLS mock: presents the server cert AND requires the client to present a
     * cert trusted by the given client truststore (via SSLServerSocket setNeedClientAuth).
     */
    public static long openMockMutualTls(int port, BString serverKeystorePath,
            BString serverKeystorePassword, BString clientTruststorePath,
            BString clientTruststorePassword) throws Exception {
        ServerConnectionFactory factory = new TlsServerConnectionFactory(
                serverKeystorePath.getValue(), serverKeystorePassword.getValue().toCharArray(),
                clientTruststorePath.getValue(), clientTruststorePassword.getValue().toCharArray());
        return register(new MockSmsc(port, factory));
    }

    private static long register(MockSmsc mock) {
        mock.start();
        long id = NEXT_MOCK_ID.getAndIncrement();
        MOCKS.put(id, mock);
        return id;
    }

    /**
     * Configures the mock to only accept binds carrying exactly these credentials,
     * rejecting others with the distinguishing SMPP status code (invalid-systemId vs
     * invalid-password). Call before the connector's {@code 'start()}.
     */
    public static void expectCredentials(long mockId, BString systemId, BString password) {
        mock(mockId).expectCredentials(systemId.getValue(), password.getValue());
    }

    /**
     * Blocks until the next bind attempt on this mock resolves. Returns the accepted
     * connection's handle, or throws the rejection/failure (surfaced to Ballerina as an
     * {@code error} per the extern's {@code returns long|error} contract).
     */
    public static long awaitNextBind(long mockId, long timeoutMillis) throws Exception {
        return mock(mockId).awaitNextBind(timeoutMillis);
    }

    /**
     * Sends a deliver_sm on the given connection and blocks for its deliver_sm_resp.
     * {@code messagePayload} being an empty string means "no message_payload TLV"
     * (Ballerina has no clean null-string interop for this direction; empty-means-absent
     * is documented on the .bal wrapper).
     */
    public static void sendDeliverSm(long mockId, long connectionId, BString shortMessage,
                                     BString messagePayload, int dataCoding) throws Exception {
        String payload = messagePayload.getValue();
        mock(mockId).sendDeliverSm(connectionId, shortMessage.getValue(),
                payload.isEmpty() ? null : payload, dataCoding);
    }

    /**
     * Sends a data_sm on the given connection and blocks for its data_sm_resp.
     * {@code messagePayload} being an empty string means "no message_payload TLV at all"
     * (exercises the connector's DATA_SM empty-fallback path).
     */
    public static void sendDataSm(long mockId, long connectionId, BString messagePayload,
                                  int dataCoding) throws Exception {
        String payload = messagePayload.getValue();
        mock(mockId).sendDataSm(connectionId, payload.isEmpty() ? null : payload, dataCoding);
    }

    /**
     * Sends a deliver_sm with exactly these raw short_message bytes (no charset encoding on
     * the mock side), so a test can hand the connector's decoder a precise on-wire sequence
     * such as unpacked GSM 03.38.
     */
    public static void sendDeliverSmRaw(long mockId, long connectionId, BArray shortMessage,
                                        int dataCoding) throws Exception {
        mock(mockId).sendDeliverSmRaw(connectionId, shortMessage.getBytes(), dataCoding);
    }

    /**
     * Sends a deliver_sm flagged as an SMSC delivery receipt carrying {@code receiptText} as
     * its short_message body — exercises the connector's receipt-parsing path end to end.
     */
    public static void sendDeliveryReceipt(long mockId, long connectionId, BString receiptText)
            throws Exception {
        mock(mockId).sendDeliveryReceipt(connectionId, receiptText.getValue());
    }

    /**
     * As above, plus a {@code receipted_message_id} TLV (0x001E) — the spec's only
     * guaranteed correlation key (§5.3.2.12), as against the vendor-specific {@code id:}
     * in the Appendix-B body. An empty {@code receiptedMessageId} means "no TLV", so a
     * test can send a receipt whose TLV and body id deliberately disagree.
     */
    public static void sendDeliveryReceiptWithTlv(long mockId, long connectionId,
                                                  BString receiptText, BString receiptedMessageId)
            throws Exception {
        String tlv = receiptedMessageId.getValue();
        mock(mockId).sendDeliveryReceipt(connectionId, receiptText.getValue(),
                tlv.isEmpty() ? null : tlv);
    }

    // --- submit_sm capture (Sprint 8, item 10) ---------------------------------------
    //
    // A captured submit_sm is a Java bean, which does not cross into Ballerina as a value.
    // awaitNextSubmit therefore registers it here and returns an opaque handle, matching
    // the mockId/connectionId idiom used above; the field accessors read through it. The
    // registry is never pruned - a test run captures a bounded handful of PDUs, and
    // keeping them readable after the connection is severed is the point.

    private static final AtomicLong NEXT_SUBMIT_ID = new AtomicLong(1);
    private static final ConcurrentHashMap<Long, SubmitSm> SUBMITS = new ConcurrentHashMap<>();
    // Which mock minted each handle. The message_id lives on the mock, not on the SubmitSm
    // bean (it is a field of the RESPONSE), so submitMessageId has to get back to the right
    // instance. Kept parallel to SUBMITS rather than changing that map's value type, so the
    // dozen existing accessors are untouched.
    private static final ConcurrentHashMap<Long, Long> SUBMIT_MOCKS = new ConcurrentHashMap<>();

    /**
     * Blocks until the next submit_sm arrives on this connection; returns a handle to it.
     * FIFO per connection, so a test on one link never sees another link's PDU.
     */
    public static long awaitNextSubmit(long mockId, long connectionId, long timeoutMillis)
            throws Exception {
        SubmitSm submitSm = mock(mockId).awaitNextSubmit(connectionId, timeoutMillis);
        long handle = NEXT_SUBMIT_ID.getAndIncrement();
        SUBMITS.put(handle, submitSm);
        SUBMIT_MOCKS.put(handle, mockId);
        return handle;
    }

    /**
     * The {@code message_id} the mock returned for this submit, or {@code ""} if it sent none.
     *
     * <p>Capture happens before the response is built, so this is only populated once the
     * connector's own {@code submit} has returned. That ordering is the point: a test awaits
     * the PDU, lets its submit complete, then asserts the two ids are the same string. The
     * alternative - predicting the monotonic counter - stops working the moment a test
     * submits twice.
     */
    public static BString submitMessageId(long submitId) {
        SubmitSm submitSm = submit(submitId);
        Long mockId = SUBMIT_MOCKS.get(submitId);
        String id = mockId == null ? null : mock(mockId).messageIdFor(submitSm);
        return StringUtils.fromString(id == null ? "" : id);
    }

    /**
     * The {@code sequence_number} jsmpp assigned to this submit — the only correlation handle
     * a failed submit has, and what item 7 surfaces in the error detail.
     */
    public static int submitSequenceNumber(long submitId) {
        return submit(submitId).getSequenceNumber();
    }

    /** Captured submits not yet read on this connection — for asserting "and no more". */
    public static int pendingSubmitCount(long mockId, long connectionId) {
        return mock(mockId).pendingSubmitCount(connectionId);
    }

    /**
     * The short_message decoded with the charset matching the PDU's own data_coding —
     * the inverse of what the mock does when sending, and of the connector's decoder.
     * Use {@link #submitShortMessageBytes} when the exact octets are what is under test.
     */
    public static BString submitShortMessage(long submitId) {
        SubmitSm submitSm = submit(submitId);
        byte[] body = submitSm.getShortMessage();
        if (body == null) {
            return StringUtils.fromString("");
        }
        Charset charset = switch (submitSm.getDataCoding() & 0xFF) {
            case 0x01 -> StandardCharsets.US_ASCII;
            case 0x03 -> StandardCharsets.ISO_8859_1;
            case 0x08 -> StandardCharsets.UTF_16BE;
            default -> StandardCharsets.UTF_8;
        };
        return StringUtils.fromString(new String(body, charset));
    }

    /** The raw short_message octets, undecoded — for asserting exact on-wire encoding. */
    public static BArray submitShortMessageBytes(long submitId) {
        byte[] body = submit(submitId).getShortMessage();
        return ValueCreator.createArrayValue(body == null ? new byte[0] : body);
    }

    public static BString submitSourceAddr(long submitId) {
        return StringUtils.fromString(nullToEmpty(submit(submitId).getSourceAddr()));
    }

    public static BString submitDestAddr(long submitId) {
        return StringUtils.fromString(nullToEmpty(submit(submitId).getDestAddress()));
    }

    public static BString submitServiceType(long submitId) {
        return StringUtils.fromString(nullToEmpty(submit(submitId).getServiceType()));
    }

    /** Empty string when the PDU carries no validity_period (the SMSC-default case). */
    public static BString submitValidityPeriod(long submitId) {
        return StringUtils.fromString(nullToEmpty(submit(submitId).getValidityPeriod()));
    }

    /** Unsigned, so a test asserting esm_class == 0x00 is not tripped by sign extension. */
    public static int submitEsmClass(long submitId) {
        return submit(submitId).getEsmClass() & 0xFF;
    }

    public static int submitDataCoding(long submitId) {
        return submit(submitId).getDataCoding() & 0xFF;
    }

    public static int submitRegisteredDelivery(long submitId) {
        return submit(submitId).getRegisteredDelivery() & 0xFF;
    }

    public static int submitSourceAddrTon(long submitId) {
        return submit(submitId).getSourceAddrTon() & 0xFF;
    }

    public static int submitSourceAddrNpi(long submitId) {
        return submit(submitId).getSourceAddrNpi() & 0xFF;
    }

    public static int submitDestAddrTon(long submitId) {
        return submit(submitId).getDestAddrTon() & 0xFF;
    }

    public static int submitDestAddrNpi(long submitId) {
        return submit(submitId).getDestAddrNpi() & 0xFF;
    }

    /**
     * Makes every subsequent submit_sm answer with this command_status instead of
     * succeeding; 0 restores normal behaviour. The client sees a NegativeResponseException.
     */
    public static void setSubmitFailure(long mockId, int commandStatus) {
        mock(mockId).setSubmitFailure(commandStatus);
    }

    /**
     * Delays every subsequent submit_sm_resp. Blocks the mock's PDU-processor thread on
     * purpose — that is what a slow SMSC does, and what transactionTimeout must survive.
     */
    public static void setSubmitDelay(long mockId, long millis) {
        mock(mockId).setSubmitDelay(millis);
    }

    /** When enabled, submit_sm_resp carries an empty message_id (spec-legal, unhelpful). */
    public static void setSubmitEmptyMessageId(long mockId, boolean enabled) {
        mock(mockId).setSubmitEmptyMessageId(enabled);
    }

    private static SubmitSm submit(long submitId) {
        SubmitSm submitSm = SUBMITS.get(submitId);
        if (submitSm == null) {
            throw new IllegalArgumentException("no such submit handle: " + submitId);
        }
        return submitSm;
    }

    private static String nullToEmpty(String s) {
        return s == null ? "" : s;
    }

    /** Abruptly severs the connection: socket close, no unbind exchange (qa-strategy §3.6). */
    public static void sever(long mockId, long connectionId) throws Exception {
        mock(mockId).sever(connectionId);
    }

    /** Clean peer-initiated unbind: unbind PDU + awaited unbind_resp, then close. */
    public static void peerUnbind(long mockId, long connectionId) throws Exception {
        mock(mockId).peerUnbind(connectionId);
    }

    /** Stops accepting new connections; already-accepted connections stay alive. */
    public static void stopAccepting(long mockId) {
        mock(mockId).stopAccepting();
    }

    /** When enabled, every subsequent bind is accepted and then immediately closed. */
    public static void setCloseAfterAccept(long mockId, boolean enabled) {
        mock(mockId).setCloseAfterAccept(enabled);
    }

    /** Raises the connection's transaction timer (jsmpp default 2000 ms). */
    public static void setTransactionTimer(long mockId, long connectionId, long millis)
            throws Exception {
        mock(mockId).setTransactionTimer(connectionId, millis);
    }

    /**
     * Lowers the connection's enquire_link timer so the mock (as SMSC) probes the connector
     * frequently; with a short transaction timer an unanswered probe closes the session.
     */
    public static void setEnquireLinkTimer(long mockId, long connectionId, int millis)
            throws Exception {
        mock(mockId).setEnquireLinkTimer(connectionId, millis);
    }

    /** Closes the mock's connections, listener, and pools. Safe to call twice. */
    public static void closeMock(long mockId) {
        MockSmsc mock = MOCKS.remove(mockId);
        if (mock != null) {
            mock.close();
        }
    }

    private static MockSmsc mock(long mockId) {
        MockSmsc mock = MOCKS.get(mockId);
        if (mock == null) {
            throw new IllegalArgumentException("no such mock handle: " + mockId);
        }
        return mock;
    }

    // ---- black-hole server: accepts TCP connections and never answers the bind ----

    private static final ConcurrentHashMap<Long, BlackHole> BLACK_HOLES = new ConcurrentHashMap<>();

    /**
     * Opens a plain TCP server that accepts connections and then does nothing - it never
     * reads the bind PDU and never responds. A connector pointed here completes the TCP
     * connect but its bind-response wait must time out, exercising the configurable
     * bindTimeout (vs jsmpp's hardcoded 60s default). Returns a handle for cleanup.
     */
    public static long openBlackHole(int port) throws Exception {
        BlackHole hole = new BlackHole(port);
        hole.start();
        long id = NEXT_MOCK_ID.getAndIncrement();
        BLACK_HOLES.put(id, hole);
        return id;
    }

    /** Closes a black-hole server and drops any sockets it is holding. */
    public static void closeBlackHole(long handle) {
        BlackHole hole = BLACK_HOLES.remove(handle);
        if (hole != null) {
            hole.close();
        }
    }
}
