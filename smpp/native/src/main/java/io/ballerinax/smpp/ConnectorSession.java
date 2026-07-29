// Copyright (c) 2026. SMPPSession subclass that splits the transaction timer by role.
package io.ballerinax.smpp;

import org.jsmpp.session.SMPPSession;
import org.jsmpp.session.connection.ConnectionFactory;

/**
 * jsmpp keeps ONE {@code transactionTimer} per session, and it bounds two very different
 * things: how long a <em>submit</em> waits for its {@code submit_sm_resp} (where patience
 * is safety — a false timeout means "possibly delivered, retrying may duplicate"), and how
 * long the session's own housekeeping waits — {@code unbind()} at stop, the
 * {@code EnquireLinkSender}'s response wait on a dead link, the reader thread's
 * exit drain — where patience is pure latency. One knob cannot serve both, and jsmpp
 * offers no second knob.
 *
 * <p>This subclass splits them without touching jsmpp (owner constraint), exploiting a
 * bytecode-verified asymmetry in 3.0.2:
 *
 * <ul>
 *   <li>{@code unbind()} reads the <b>field</b> directly — so the field (set once in the
 *       constructor, never via the public setter afterwards) holds the SHORT housekeeping
 *       bound, and stop paths stay snappy;</li>
 *   <li>{@code sendEnquireLink()}, {@code pduExecutor.awaitTermination}, and all five
 *       submit-family operations call the <b>getter</b> — which this class overrides to
 *       route by the calling thread: jsmpp's own housekeeping threads
 *       ({@code EnquireLinkSender-*}, {@code PDUReaderWorker-*} — names pinned by
 *       {@code ConnectorSessionTimerTest} against the vendored 3.0.2 source) get the
 *       SHORT bound, and every other thread — Ballerina strands and jsmpp's PDU-processor
 *       pool threads ({@code pool-N-thread-M}), i.e. everywhere a submit can run — gets
 *       the configured {@code transactionTimeout}.</li>
 * </ul>
 *
 * <p>Net effect with defaults: submits wait up to 30s for their response; a graceful stop
 * on a half-dead link waits ≤~2s for {@code unbind_resp} (worst-case stop ≈
 * {@code gracefulStopTimeout} + 2s instead of + 30s); a dead-link enquire probe burns 2s
 * instead of 30s; silent-peer detection stays ≈ {@code enquireLinkInterval} + 2s.
 *
 * <p><b>Version coupling, stated plainly:</b> the getter-vs-field split and the thread
 * names are jsmpp 3.0.2 facts. A jsmpp upgrade must re-verify both (the timer test pins
 * the name-routing logic; re-run the {@code javap} audit from the Sprint 8 plan for the
 * call sites).
 */
final class ConnectorSession extends SMPPSession {

    /**
     * The housekeeping bound: jsmpp's own historical {@code transactionTimer} default,
     * which bounded exactly these paths for years before this connector exposed the
     * configurable timeout. Internal on purpose — additive to expose later if a
     * deployment ever needs it, per the Sprint 4 minimal-public-surface precedent.
     */
    static final long HOUSEKEEPING_TIMER_MS = 2000;

    private final long submitTransactionTimerMs;

    ConnectorSession(ConnectionFactory connectionFactory, long submitTransactionTimerMs) {
        super(connectionFactory);
        this.submitTransactionTimerMs = submitTransactionTimerMs;
        // The FIELD carries the short bound: unbind() reads it directly, and
        // super.getTransactionTimer() returns it for the housekeeping threads below.
        // Nothing may call setTransactionTimer() with the submit value after this.
        super.setTransactionTimer(HOUSEKEEPING_TIMER_MS);
    }

    @Override
    public long getTransactionTimer() {
        String thread = Thread.currentThread().getName();
        if (thread != null && (thread.startsWith("EnquireLinkSender-")
                || thread.startsWith("PDUReaderWorker-"))) {
            return super.getTransactionTimer();
        }
        return submitTransactionTimerMs;
    }
}
