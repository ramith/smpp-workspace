// Copyright (c) 2026. Transport-death observer: the connector's independent drop signal.
package io.ballerinax.smpp;

import org.jsmpp.session.connection.Connection;

import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.InetAddress;
import java.net.SocketTimeoutException;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Wraps the {@link Connection} this connector hands to jsmpp so that the connector gets
 * its own, first-hand signal the instant the transport dies — independent of jsmpp's
 * {@code SessionStateListener}.
 *
 * <h2>Why this exists (Sprint 8 investigation, 2026-07-29)</h2>
 *
 * The connector's entire drop-detection/rebind machinery used to hang off exactly one
 * signal: jsmpp firing {@code CLOSED} at the session's {@code SessionStateListener}. That
 * firing is the last step of {@code AbstractSession.close()} — and a reproduced,
 * jstack-photographed failure mode exists in jsmpp 3.0.2 where it never happens:
 *
 * <ol>
 *   <li>The peer severs the socket; the {@code PDUReaderWorker} reads EOF and logs
 *       {@code "Reading PDU session ... in state BOUND_TRX: null"}.</li>
 *   <li>The reader thread then <em>dies</em> before completing {@code close()} — before
 *       interrupting the {@code EnquireLinkSender} and before {@code ctx.close()}, the
 *       only line that fires the CLOSED listener. (Observed across 16 consecutive thread
 *       dumps: the reader absent, its EnquireLinkSender orphaned in
 *       {@code AbstractSession.java:531}'s 500ms wait loop for 64+ seconds, session state
 *       still {@code BOUND_TRX} 75s after the EOF. The exact kill site inside that gap is
 *       not pinned; nothing is printed.)</li>
 *   <li>Session state stays BOUND forever, the listener never fires, the connector is
 *       never told, and no rebind is ever scheduled — a permanently deaf listener that
 *       still believes it is bound.</li>
 * </ol>
 *
 * Hit rate in the repeated-sever soak was roughly one cycle in a few hundred — rare
 * enough to look like an unexplained flake, permanent when it hits. Three alternative
 * explanations were eliminated with evidence before this fix: the mock's accept path
 * (structural proof: every path offers an outcome), {@code transactionTimer}-bounded
 * teardown (a 45s observation window outlasted the 30s timer; measured EOF→CLOSED is
 * 0-4ms when the choreography works), and silent severs (the 45s window also outlased
 * nothing — the EOF was logged, so the drop was seen and then lost).
 *
 * <h2>What it does</h2>
 *
 * The {@link #getInputStream()} wrapper reports end-of-stream and read {@code IOException}s
 * (excluding {@link SocketTimeoutException}, which is jsmpp's routine keepalive cadence —
 * the socket SO_TIMEOUT doubles as the enquire_link trigger) to a one-shot callback, at
 * the exact moment jsmpp's reader observes them. The callback is armed after the
 * per-attempt drop guards exist (see {@code NativeListener.bind}); it shares those guards,
 * so whichever of the two signals arrives first — jsmpp's CLOSED listener or this one —
 * reports the drop exactly once, and the other is a no-op.
 *
 * <p>{@link #close()} is the FOURTH signal (Sprint 8.5, stage-2 finding N2). It was
 * originally not reported, on the reasoning that "if jsmpp's choreography runs to
 * completion, the CLOSED listener fires normally" — but that reasoning fails exactly
 * where it matters: {@code AbstractSession.close()} invoked <em>by the
 * EnquireLinkSender on itself</em> (the ordinary enquire-link-timeout dead-link path,
 * AbstractSession.java:543-552) structurally skips {@code ctx.close()} via the
 * {@code Thread.currentThread() != enquireLinkSender} guard at :264 — CLOSED never
 * fires from the closing thread. Normally the reader then observes the closed socket
 * from {@code read()} and both remaining signals engage; but under inbound overflow the
 * reader can be parked on {@code monitorenter(os)} (it sends NACKs through
 * {@code SynchronizedPDUSender}, SMPPSession.java:705/:713) behind a stalled writer —
 * it never reaches {@code read()}, and with the stream signal blind and CLOSED skipped,
 * ZERO signals fire while submits keep being accepted onto a dead socket. Reporting
 * {@code close()} — which the self-closing sender has just called first-hand — closes
 * that hole, independent of the reader thread.
 *
 * <p>The conditionality lives in the SHARED guards, never here (design review,
 * FINDING-1): {@code fireOnce()} always invokes the handler, and
 * {@code scheduleTransportDeathCheck} suppresses at schedule time (state
 * STOPPING/STOPPED = user teardown) and re-checks {@code installed} + the
 * {@code dropReported} CAS at fire time (+1s). Classification of every
 * {@code Connection.close()} reacher (design-review table): connector
 * {@code closeSession}/{@code abortedByStop} — state already STOPPING, suppressed;
 * connectAndBind failure closes — {@code installed} still false at fire time,
 * suppressed; EnquireLinkSender self-close — REPORTS (the target); reader-loop and
 * pduExecutor closes — report, deduped by the CAS against the stream signal and
 * CLOSED; {@code SMPPSession.finalize()} on an abandoned session — suppressed only
 * because every abandonment path latches that attempt's {@code dropReported} first
 * (an invariant, not an accident — do not reorder).
 *
 * <p>{@link #forceClose()} is the bounded-close watchdog primitive (D11): it closes the
 * PRE-TLS raw socket and nothing else. See {@link RawConnectionFactory} for why the
 * raw socket is the only safe target, and note it deliberately does NOT fire the
 * signal — the unblocked reader's own IOException does, and the guards classify it.
 *
 * <p>This is transport observation on a stream this connector already owns (both
 * connection factories are ours) — no jsmpp behaviour is altered, no reflection is used.
 */
final class ObservedConnection implements Connection {

    private final Connection delegate;
    private final java.net.Socket rawSocket;
    private final AtomicReference<Runnable> onTransportDeath;
    private final AtomicBoolean fired = new AtomicBoolean(false);
    // jsmpp fetches the stream once per session, but idempotence is cheap: always hand
    // back the same wrapper so double-wrapping can never double-fire.
    private volatile InputStream wrappedIn;

    /**
     * @param delegate the real connection from the plain/TLS factory
     * @param rawSocket the pre-TLS raw socket beneath {@code delegate} — the
     *     {@link #forceClose()} target; may be null in unit tests (forceClose no-ops)
     * @param onTransportDeath holder for the death callback; may still be empty when the
     *     connection is created (the callback is armed later in {@code bind()}, before
     *     {@code connectAndBind} — which is what creates this connection — returns). A
     *     death observed while the holder is empty is silently dropped: pre-arm deaths
     *     happen only during the connect/bind phase, whose failures {@code connectAndBind}
     *     itself surfaces to the caller.
     */
    ObservedConnection(Connection delegate, java.net.Socket rawSocket,
            AtomicReference<Runnable> onTransportDeath) {
        this.delegate = delegate;
        this.rawSocket = rawSocket;
        this.onTransportDeath = onTransportDeath;
    }

    /**
     * Force-closes the pre-TLS raw socket — the bounded-close watchdog primitive (D11).
     * Deliberately NOT {@code delegate.close()}: on TLS that is {@code SSLSocket.close()},
     * which attempts a close_notify write and can block behind the very stall this
     * exists to break. A raw {@code Socket.close()} takes no jsmpp or JSSE lock and
     * asynchronously unblocks threads parked in read/write on this socket (JDK
     * asynchronous close — pinned by {@code forceCloseUnblocksAParkedWrite}). Idempotent;
     * never throws. Does not fire the death signal itself: the unblocked reader's own
     * IOException does, and the schedule/fire-time guards classify it (T2.4).
     */
    void forceClose() {
        if (rawSocket == null) {
            return;
        }
        try {
            rawSocket.close();
        } catch (IOException ignored) {
            // best-effort: already closed or already broken - both count as closed here
        }
    }

    private void fireOnce() {
        if (fired.compareAndSet(false, true)) {
            Runnable handler = onTransportDeath.get();
            if (handler != null) {
                try {
                    handler.run();
                } catch (Throwable t) {
                    // Never let the death signal kill jsmpp's reader thread - a throw
                    // propagating out of read() IS the wedge this class exists to survive.
                    // The signal is one-shot and now consumed; log rather than rethrow.
                    java.util.logging.Logger.getLogger(ObservedConnection.class.getName())
                            .warning("transport-death handler threw: " + t);
                }
            }
        }
    }

    @Override
    public synchronized InputStream getInputStream() {
        if (wrappedIn == null) {
            wrappedIn = new FilterInputStream(delegate.getInputStream()) {
                @Override
                public int read() throws IOException {
                    try {
                        int b = super.read();
                        if (b < 0) {
                            fireOnce();
                        }
                        return b;
                    } catch (SocketTimeoutException e) {
                        throw e; // routine keepalive cadence, not a death
                    } catch (IOException e) {
                        fireOnce();
                        throw e;
                    }
                }

                @Override
                public int read(byte[] b, int off, int len) throws IOException {
                    try {
                        int n = super.read(b, off, len);
                        if (n < 0) {
                            fireOnce();
                        }
                        return n;
                    } catch (SocketTimeoutException e) {
                        throw e;
                    } catch (IOException e) {
                        fireOnce();
                        throw e;
                    }
                }
            };
        }
        return wrappedIn;
    }

    @Override
    public boolean isOpen() {
        return delegate.isOpen();
    }

    @Override
    public InetAddress getInetAddress() {
        return delegate.getInetAddress();
    }

    @Override
    public InetAddress getLocalAddress() {
        return delegate.getLocalAddress();
    }

    @Override
    public int getPort() {
        return delegate.getPort();
    }

    @Override
    public int getLocalPort() {
        return delegate.getLocalPort();
    }

    @Override
    public void setSoTimeout(int timeout) throws IOException {
        delegate.setSoTimeout(timeout);
    }

    @Override
    public void close() throws IOException {
        // The FOURTH drop signal (stage-2 N2) - see the class doc. fireOnce() runs
        // BEFORE the delegate close and unconditionally: the conditionality (stop vs
        // bind-phase vs genuine drop) lives entirely in scheduleTransportDeathCheck's
        // split-phase guards + the dropReported CAS, which already classify every
        // caller correctly (design review, FINDING-1 - a close()-time guard here would
        // re-open the install-sliver wedge).
        fireOnce();
        delegate.close();
    }

    @Override
    public java.io.OutputStream getOutputStream() {
        return delegate.getOutputStream();
    }
}
