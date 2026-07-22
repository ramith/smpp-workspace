// Copyright (c) 2026. Test-only mock SMSC: accept-loop, bind validation, PDU senders.
package io.ballerinax.smpp.test;

import org.jsmpp.SMPPConstant;
import org.jsmpp.bean.ESMClass;
import org.jsmpp.bean.NumberingPlanIndicator;
import org.jsmpp.bean.OptionalParameter;
import org.jsmpp.bean.RawDataCoding;
import org.jsmpp.bean.RegisteredDelivery;
import org.jsmpp.bean.TypeOfNumber;
import org.jsmpp.session.BindRequest;
import org.jsmpp.session.SMPPServerSession;
import org.jsmpp.session.SMPPServerSessionListener;

import java.io.IOException;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicLong;

/**
 * One instance per test-mock: owns the listening socket, an accept-loop (per jsmpp's own
 * {@code StressServer.run()} blueprint - each accepted connection's blocking
 * {@code waitForBind} is offloaded to a pool so {@code accept()} is never blocked by a
 * slow or absent bind), an optional bind-credential validator (accept-everything by
 * default, matching Sprint 0's behavior), and a registry of accepted connections keyed by
 * handle so tests can address a specific session.
 *
 * <p>Plain Java only - no Ballerina types here. {@link MockSmscBridge} is the only file
 * in this source set that touches the Ballerina runtime API.
 */
final class MockSmsc {

    private final SMPPServerSessionListener listener;
    private final ExecutorService acceptLoop = Executors.newSingleThreadExecutor();
    // Churn-sized: the soak tests cycle accept-then-instant-drop rapidly, and a client
    // whose bind timed out leaves a pre-bind session holding a pool thread until
    // waitForBind gives up - 8 threads plus the shorter waitForBind below keep the pool
    // recycling under that load (a 4-thread/60s combination wedged empirically).
    private final ExecutorService waitBindPool = Executors.newFixedThreadPool(8);
    private final ConcurrentHashMap<Long, SMPPServerSession> connections = new ConcurrentHashMap<>();
    private final AtomicLong nextConnectionId = new AtomicLong(1);
    // Each entry is either a Long (connection handle, bind accepted) or a Throwable
    // (bind rejected / listener error), so awaitNextBind can surface both outcomes.
    private final BlockingQueue<Object> bindOutcomes = new LinkedBlockingQueue<>();
    private volatile String expectedSystemId; // null = accept any (default)
    private volatile String expectedPassword;
    private volatile boolean running = true;
    private volatile boolean closeAfterAccept = false;

    MockSmsc(int port) throws IOException {
        listener = new SMPPServerSessionListener(port);
        // Generous - the mock must never be its own bottleneck (docs/qa-strategy.md §3.7).
        listener.setPduProcessorDegree(50);
        listener.setQueueCapacity(1000);
    }

    /** Starts the accept-loop in the background; returns immediately. */
    void start() {
        acceptLoop.execute(this::runAcceptLoop);
    }

    private void runAcceptLoop() {
        while (running) {
            try {
                SMPPServerSession session = listener.accept();
                waitBindPool.execute(() -> waitForBindAndValidate(session));
            } catch (IOException e) {
                if (running) {
                    bindOutcomes.offer(e);
                }
                break; // listener closed
            }
        }
    }

    private void waitForBindAndValidate(SMPPServerSession session) {
        try {
            // 3s: generous for a healthy bind (arrives within ms of accept), short enough
            // that a pre-bind-dead session (client bind timeout under churn) releases its
            // pool thread faster than the connector's ~3s failed-attempt cadence - a 10s
            // hold here death-spiraled the pool empirically under the accept-drop soak.
            BindRequest request = session.waitForBind(3_000);
            // Rejection codes per SMPPServerSimulator's WaitBindTask - the jsmpp example
            // that actually compares credentials (StressServer's own WaitBindTask doesn't).
            String sysId = expectedSystemId;
            String pass = expectedPassword;
            if (sysId != null && !sysId.equals(request.getSystemId())) {
                request.reject(SMPPConstant.STAT_ESME_RINVSYSID);
                bindOutcomes.offer(new IllegalStateException("bind rejected: invalid systemId"));
                return;
            }
            if (pass != null && !pass.equals(request.getPassword())) {
                request.reject(SMPPConstant.STAT_ESME_RINVPASWD);
                bindOutcomes.offer(new IllegalStateException("bind rejected: invalid password"));
                return;
            }
            request.accept("mock-smsc");
            long id = nextConnectionId.getAndIncrement();
            if (closeAfterAccept) {
                // Accepted-then-instantly-dropped: the bound-race soak's cycle driver
                // (docs/sprint-plan.md Sprint 2, "closes the connection immediately
                // post-accept, looped"). Close BEFORE offering the outcome so the drop
                // has already happened by the time the test observes the bind. Not
                // registered in `connections` - the session is already dead.
                session.close();
                bindOutcomes.offer(id);
                return;
            }
            connections.put(id, session);
            bindOutcomes.offer(id);
        } catch (Exception e) {
            bindOutcomes.offer(e);
        }
    }

    /**
     * Blocks until the next bind attempt resolves (accepted or rejected).
     *
     * @return the new connection's handle if the bind was accepted
     * @throws Exception the rejection/failure if it wasn't, or a timeout
     */
    long awaitNextBind(long timeoutMillis) throws Exception {
        Object outcome = bindOutcomes.poll(timeoutMillis, TimeUnit.MILLISECONDS);
        if (outcome == null) {
            throw new TimeoutException("no bind observed within " + timeoutMillis + "ms");
        }
        if (outcome instanceof Long id) {
            return id;
        }
        throw (Exception) outcome;
    }

    void expectCredentials(String systemId, String password) {
        this.expectedSystemId = systemId;
        this.expectedPassword = password;
    }

    private SMPPServerSession connection(long connectionId) {
        SMPPServerSession session = connections.get(connectionId);
        if (session == null) {
            throw new IllegalArgumentException("no such connection handle: " + connectionId);
        }
        return session;
    }

    /**
     * Sends a {@code deliver_sm} on the given connection, blocking until the
     * {@code deliver_sm_resp} arrives (or throwing on a negative/timed-out response).
     * {@code messagePayload} being non-null adds a {@code message_payload} TLV alongside
     * (or instead of) the {@code short_message} field, for precedence testing.
     */
    void sendDeliverSm(long connectionId, String shortMessage, String messagePayload, int dataCoding)
            throws Exception {
        OptionalParameter[] params = messagePayload == null
                ? new OptionalParameter[0]
                : new OptionalParameter[] {
                        new OptionalParameter.Message_payload(encode(messagePayload, dataCoding)) };
        connection(connectionId).deliverShortMessage(
                "", TypeOfNumber.INTERNATIONAL, NumberingPlanIndicator.ISDN, "12345",
                TypeOfNumber.INTERNATIONAL, NumberingPlanIndicator.ISDN, "99999",
                new ESMClass(), (byte) 0, (byte) 0,
                new RegisteredDelivery(0),
                new RawDataCoding((byte) dataCoding),
                encode(shortMessage, dataCoding),
                params);
    }

    /**
     * Sends a {@code data_sm} on the given connection. {@code messagePayload} being null
     * sends no {@code message_payload} TLV at all (DATA_SM has no short_message field, so
     * that exercises the connector's empty-fallback path).
     */
    void sendDataSm(long connectionId, String messagePayload, int dataCoding) throws Exception {
        OptionalParameter[] params = messagePayload == null
                ? new OptionalParameter[0]
                : new OptionalParameter[] {
                        new OptionalParameter.Message_payload(encode(messagePayload, dataCoding)) };
        connection(connectionId).dataShortMessage(
                "", TypeOfNumber.INTERNATIONAL, NumberingPlanIndicator.ISDN, "12345",
                TypeOfNumber.INTERNATIONAL, NumberingPlanIndicator.ISDN, "99999",
                new ESMClass(), new RegisteredDelivery(0),
                new RawDataCoding((byte) dataCoding),
                params);
    }

    /**
     * Encodes text with the charset matching the given {@code data_coding} value —
     * deliberately mirroring {@code Dispatcher.decodeShortMessage}'s switch exactly, so
     * what this mock puts on the wire is what that decoder expects to find for each value.
     * Keep the two in sync if either ever changes.
     */
    private static byte[] encode(String text, int dataCoding) {
        Charset charset = switch (dataCoding & 0xFF) {
            case 0x01 -> StandardCharsets.US_ASCII;
            case 0x03 -> StandardCharsets.ISO_8859_1;
            case 0x08 -> StandardCharsets.UTF_16BE;
            default -> StandardCharsets.UTF_8;
        };
        return text.getBytes(charset);
    }

    /**
     * Abrupt severance: closes the connection's socket directly, with NO unbind exchange
     * (jsmpp AbstractSession.close() sends nothing - docs/qa-strategy.md §3.6). From the
     * connector's side this is indistinguishable from a network failure / crashed SMSC.
     * Removed from the registry: the handle is dead afterwards, and close() must not
     * later attempt unbindAndClose on it.
     */
    void sever(long connectionId) {
        SMPPServerSession session = connection(connectionId);
        connections.remove(connectionId);
        session.close();
    }

    /**
     * Clean, peer-initiated unbind: sends an unbind PDU and blocks awaiting unbind_resp,
     * then closes (unbindAndClose() == unbind() + close(), per §3.6). The trailing close
     * only makes the connector's CLOSED transition prompt and deterministic; the unbind
     * exchange is what distinguishes this from sever() - this method returning normally
     * proves the connector answered unbind_resp.
     */
    void peerUnbind(long connectionId) throws Exception {
        SMPPServerSession session = connection(connectionId);
        connections.remove(connectionId);
        session.unbindAndClose();
    }

    /**
     * Stops accepting new connections (closes the server socket) while leaving already
     * accepted connections alive - so an exhaustion test can make every rebind attempt
     * fail deterministically (connection refused), with no race between severing the
     * live connection and closing the whole mock.
     */
    void stopAccepting() {
        running = false;
        try {
            listener.close();
        } catch (Exception ignored) {
            // best-effort; the accept-loop exits on the resulting IOException
        }
    }

    /** When enabled, every subsequent bind is accepted and then immediately closed. */
    void setCloseAfterAccept(boolean enabled) {
        this.closeAfterAccept = enabled;
    }

    /**
     * Raises this connection's transaction timer (jsmpp default: 2000 ms) so a blocking
     * mock-side send can outwait a deliberately slow SYNC handler without a
     * ResponseTimeoutException (needed by the gracefulStop drain test).
     */
    void setTransactionTimer(long connectionId, long millis) {
        connection(connectionId).setTransactionTimer(millis);
    }

    void close() {
        running = false;
        connections.values().forEach(SMPPServerSession::unbindAndClose);
        connections.clear();
        try {
            listener.close();
        } catch (Exception ignored) {
            // best-effort cleanup
        }
        acceptLoop.shutdownNow();
        waitBindPool.shutdownNow();
    }
}
