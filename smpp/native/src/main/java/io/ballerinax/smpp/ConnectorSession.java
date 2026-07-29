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
 *       submit-family operations call the <b>getter</b> — overridden to return the
 *       configured {@code transactionTimeout} only inside a connector-owned
 *       {@code ThreadLocal} submit context (entered by {@code NativeCaller} around
 *       {@code submitShortMessage}); every read outside that context — including all of
 *       jsmpp's own housekeeping threads — gets the SHORT bound.</li>
 * </ul>
 *
 * <p>Net effect with defaults: submits wait up to 30s for their response; a graceful stop
 * on a half-dead link waits ≤~2s for {@code unbind_resp} (worst-case stop ≈
 * {@code gracefulStopTimeout} + 2s instead of + 30s); a dead-link enquire probe burns 2s
 * instead of 30s; silent-peer detection stays ≈ {@code enquireLinkInterval} + 2s.
 *
 * <p><b>Version coupling, stated plainly:</b> the getter-vs-field split is a jsmpp 3.0.2
 * bytecode fact (unbind() reads the field; the submit family, sendEnquireLink and the
 * reader's awaitTermination call the getter). A jsmpp upgrade must re-run the
 * {@code javap} call-site audit from the Sprint 8 plan. There is deliberately no
 * dependency on jsmpp's thread names.
 */
final class ConnectorSession extends SMPPSession {

    /**
     * The housekeeping bound: jsmpp's own historical {@code transactionTimer} default,
     * which bounded exactly these paths for years before this connector exposed the
     * configurable timeout. Internal on purpose — additive to expose later if a
     * deployment ever needs it, per the Sprint 4 minimal-public-surface precedent.
     */
    static final long HOUSEKEEPING_TIMER_MS = 2000;

    /**
     * Marks the current thread as executing a connector-issued submit-family operation.
     * Routing by OUR OWN ThreadLocal instead of by jsmpp's thread names (owner decision,
     * 2026-07-29, on the architecture review's recommendation) removes the version
     * coupling on jsmpp's thread-naming entirely and inverts the failure direction: if
     * the context is ever missed, submits get the SHORT bound and time out loudly at 2s
     * - which {@code testSubmitWaitsBeyondHousekeepingTimer} already catches - instead
     * of dead-link detection silently degrading. jsmpp's housekeeping threads never
     * enter this context, so they always see the short field value.
     */
    private static final ThreadLocal<Boolean> SUBMIT_CONTEXT = new ThreadLocal<>();

    static void enterSubmitContext() {
        SUBMIT_CONTEXT.set(Boolean.TRUE);
    }

    static void exitSubmitContext() {
        SUBMIT_CONTEXT.remove();
    }

    private final long submitTransactionTimerMs;

    ConnectorSession(ConnectionFactory connectionFactory, long submitTransactionTimerMs) {
        super(connectionFactory);
        this.submitTransactionTimerMs = submitTransactionTimerMs;
        // The FIELD carries the short bound: unbind() reads it directly, and
        // super.getTransactionTimer() returns it everywhere outside a submit context.
        // Nothing may call setTransactionTimer() with the submit value after this.
        super.setTransactionTimer(HOUSEKEEPING_TIMER_MS);
    }

    @Override
    public long getTransactionTimer() {
        return Boolean.TRUE.equals(SUBMIT_CONTEXT.get())
                ? submitTransactionTimerMs
                : super.getTransactionTimer();
    }
}
