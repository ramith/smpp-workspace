// Copyright (c) 2026. Minimal test-only mock SMSC bridge for bal test.
package io.ballerinax.smpp.test;

import io.ballerina.runtime.api.values.BString;
import org.jsmpp.bean.ESMClass;
import org.jsmpp.bean.GeneralDataCoding;
import org.jsmpp.bean.NumberingPlanIndicator;
import org.jsmpp.bean.OptionalParameter;
import org.jsmpp.bean.RegisteredDelivery;
import org.jsmpp.bean.TypeOfNumber;
import org.jsmpp.session.BindRequest;
import org.jsmpp.session.SMPPServerSession;
import org.jsmpp.session.SMPPServerSessionListener;

import java.nio.charset.StandardCharsets;

/**
 * A minimal, single-connection, test-only mock SMSC: open a listening socket, accept and
 * bind exactly one connection, send one {@code data_sm} PDU. Exposed to {@code bal test}
 * (see {@code tests/mocksmsc.bal}) via plain-Java-typed static methods, so no
 * Ballerina-runtime types are needed here at all.
 *
 * <p>This is deliberately not the general-purpose mock SMSC described in
 * docs/qa-strategy.md (accept-loop, configurable bind validation, bursts, etc.) - it is
 * scoped to exactly what Sprint 0 needs to prove the {@code data_sm} fix through a real
 * {@code bal test} round trip (see docs/sprint-plan.md). The fuller rewrite is deferred to
 * when Sprint 1 needs it for bind/SYNC/ASYNC coverage.
 */
public final class MockSmscBridge {

    private static SMPPServerSessionListener listener;
    private static SMPPServerSession session;

    private MockSmscBridge() {}

    /** Opens the listening socket. Does not block - accepting a connection is a separate step. */
    public static void openListener(int port) throws Exception {
        listener = new SMPPServerSessionListener(port);
    }

    /**
     * Blocks until a connection arrives and the bind handshake completes. Call this
     * concurrently with the connector's own {@code 'start()} (e.g. via a Ballerina
     * {@code start} expression) - both sides of a bind block until the other is ready.
     */
    public static void acceptAndBind(long bindTimeoutMillis) throws Exception {
        session = listener.accept();
        BindRequest bindRequest = session.waitForBind(bindTimeoutMillis);
        bindRequest.accept("mock-smsc");
    }

    /**
     * Sends one data_sm PDU carrying {@code payload} (UTF-8 encoded) as a message_payload
     * TLV. Takes a {@link BString} (Ballerina's interop representation of {@code string} -
     * a plain {@code java.lang.String} parameter does not interop-match) rather than
     * {@code byte[]} - Ballerina's {@code byte} (0-255) doesn't interop-map cleanly onto
     * Java's signed {@code byte} either. Exact byte-level payload fidelity is already
     * covered by the JUnit decode-matrix suite (DispatcherTest), not something this
     * end-to-end test needs to re-prove.
     */
    public static void sendDataSm(BString payload) throws Exception {
        byte[] bytes = payload.getValue().getBytes(StandardCharsets.UTF_8);
        session.dataShortMessage(
                "", TypeOfNumber.INTERNATIONAL, NumberingPlanIndicator.ISDN, "12345",
                TypeOfNumber.INTERNATIONAL, NumberingPlanIndicator.ISDN, "99999",
                new ESMClass(), new RegisteredDelivery((byte) 0),
                new GeneralDataCoding(),
                new OptionalParameter.Message_payload(bytes));
    }

    /** Best-effort cleanup; safe to call even if {@link #openListener} was never called. */
    public static void close() {
        if (session != null) {
            session.unbindAndClose();
            session = null;
        }
        if (listener != null) {
            try {
                listener.close();
            } catch (Exception ignored) {
                // best-effort cleanup
            }
            listener = null;
        }
    }
}
