// Copyright (c) 2026. Thin static facade exposing MockSmsc instances to bal test.
package io.ballerinax.smpp.test;

import io.ballerina.runtime.api.values.BString;

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

    /** Opens a listening socket and starts the accept-loop; returns the mock's handle. */
    public static long openMock(int port) throws Exception {
        MockSmsc mock = new MockSmsc(port);
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
}
