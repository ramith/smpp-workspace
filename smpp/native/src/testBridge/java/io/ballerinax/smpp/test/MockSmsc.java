// Copyright (c) 2026. Test-only mock SMSC: accept-loop, bind validation, PDU senders.
package io.ballerinax.smpp.test;

import org.jsmpp.SMPPConstant;
import org.jsmpp.extra.NegativeResponseException;
import org.jsmpp.extra.ProcessRequestException;
import org.jsmpp.bean.BroadcastSm;
import org.jsmpp.bean.CancelBroadcastSm;
import org.jsmpp.bean.CancelSm;
import org.jsmpp.bean.DataSm;
import org.jsmpp.bean.DeliverSm;
import org.jsmpp.bean.ESMClass;
import org.jsmpp.bean.NumberingPlanIndicator;
import org.jsmpp.bean.OptionalParameter;
import org.jsmpp.bean.QueryBroadcastSm;
import org.jsmpp.bean.QuerySm;
import org.jsmpp.bean.RawDataCoding;
import org.jsmpp.bean.RegisteredDelivery;
import org.jsmpp.bean.ReplaceSm;
import org.jsmpp.bean.SubmitMulti;
import org.jsmpp.bean.SubmitSm;
import org.jsmpp.bean.TypeOfNumber;
import org.jsmpp.session.BindRequest;
import org.jsmpp.session.BroadcastSmResult;
import org.jsmpp.session.DataSmResult;
import org.jsmpp.session.QueryBroadcastSmResult;
import org.jsmpp.session.QuerySmResult;
import org.jsmpp.session.ServerMessageReceiverListener;
import org.jsmpp.session.Session;
import org.jsmpp.session.SMPPServerSession;
import org.jsmpp.session.SMPPServerSessionListener;
import org.jsmpp.session.SubmitMultiResult;
import org.jsmpp.session.SubmitSmResult;
import org.jsmpp.session.connection.ServerConnectionFactory;
import org.jsmpp.util.MessageId;

import java.io.IOException;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.Map;
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
    // Reverse of `connections`: the capturing listener is handed a session, not a handle,
    // so this is the only way an inbound submit_sm can be attributed to a connection.
    // Identity-keyed on purpose - SMPPServerSession does not override equals/hashCode, and
    // relying on inherited identity semantics implicitly would be fragile if it ever did.
    private final Map<SMPPServerSession, Long> connectionIds = Collections.synchronizedMap(new IdentityHashMap<>());
    // Per-connection FIFO of captured submit_sm PDUs, so concurrent submits on different
    // connections cannot interleave into one queue and tests can await a specific link.
    private final ConcurrentHashMap<Long, BlockingQueue<SubmitSm>> submitCaptures = new ConcurrentHashMap<>();
    private final AtomicLong nextConnectionId = new AtomicLong(1);
    // Monotonic so a test can assert which submit produced which id, and so the value is
    // stable across runs (jsmpp's own generators are random).
    private final AtomicLong nextMessageId = new AtomicLong(1000);
    // Identity-keyed record of which message_id this mock minted for which submit_sm, so a
    // test can assert that the id the connector RETURNED is the id this mock actually sent -
    // rather than inferring it from the monotonic counter, which stops being predictable the
    // moment a test submits more than once or two tests share a mock. Identity, not equals:
    // SubmitSm inherits Object identity, but two submits with the same body would collide
    // under any value-based key.
    private final Map<SubmitSm, String> submitMessageIds =
            Collections.synchronizedMap(new IdentityHashMap<>());
    // Fault injection, both off by default. 0 = respond normally.
    private volatile int submitFailureStatus = 0;
    private volatile long submitDelayMillis = 0;
    // When true, submit_sm_resp carries an empty message_id - a spec-legal response that
    // leaves the client with nothing to correlate a later receipt against.
    private volatile boolean submitEmptyMessageId = false;
    // Each entry is either a Long (connection handle, bind accepted) or a Throwable
    // (bind rejected / listener error), so awaitNextBind can surface both outcomes.
    private final BlockingQueue<Object> bindOutcomes = new LinkedBlockingQueue<>();
    private volatile String expectedSystemId; // null = accept any (default)
    private volatile String expectedPassword;
    private volatile boolean running = true;
    private volatile boolean closeAfterAccept = false;

    MockSmsc(int port) throws IOException {
        this(new SMPPServerSessionListener(port));   // plain socket
    }

    /** TLS variant: the listener terminates TLS via the supplied server-side factory. */
    MockSmsc(int port, ServerConnectionFactory factory) throws IOException {
        this(new SMPPServerSessionListener(port, factory));
    }

    private MockSmsc(SMPPServerSessionListener listener) {
        this.listener = listener;
        // Generous - the mock must never be its own bottleneck (docs/qa-strategy.md §3.7).
        listener.setPduProcessorDegree(50);
        listener.setQueueCapacity(1000);
        // Set ONCE, here: SMPPServerSessionListener.accept() copies this reference into
        // every session it returns, so there is no accept-then-set window in which an
        // early submit_sm could arrive at a session with no listener. Setting it
        // per-session after accept() would reintroduce exactly that race.
        //
        // Before Sprint 8 no receiver listener was set at all, which made jsmpp answer
        // every submit_sm with ESME_RX_R_APPN - so a submit test would have failed
        // regardless of connector correctness.
        listener.setMessageReceiverListener(new CapturingReceiverListener());
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
            // Mint the handle and register the session BEFORE accepting the bind. The
            // client may submit the instant bind_resp lands, and the capturing listener
            // attributes an inbound submit_sm by looking the session up in
            // `connectionIds` - so if registration happened after accept(), a submit
            // arriving on the heels of bind_resp would be unattributable (Sprint 8, D9).
            long id = nextConnectionId.getAndIncrement();
            connections.put(id, session);
            connectionIds.put(session, id);
            submitCaptures.put(id, new LinkedBlockingQueue<>());
            try {
                request.accept("mock-smsc");
            } catch (Exception e) {
                // The registration above is speculative (it must precede accept() so an
                // instant submit_sm is attributable - D9); if accept() itself throws
                // (e.g. the peer vanished between bind and bind_resp) the session is
                // already BOUND jsmpp-side, and leaving it registered would make close()
                // unbindAndClose() a dead session - up to a transactionTimer stall each,
                // serially, in test teardown. Undo and rethrow (review finding, 016f450).
                forget(id, session);
                throw e;
            }
            if (closeAfterAccept) {
                // Accepted-then-instantly-dropped: the bound-race soak's cycle driver
                // (docs/sprint-plan.md Sprint 2, "closes the connection immediately
                // post-accept, looped"). Close BEFORE offering the outcome so the drop
                // has already happened by the time the test observes the bind. Undo the
                // registration above - the session is already dead, and Sprint 2's soak
                // cycles this rapidly, so leaving entries behind would leak per-cycle.
                forget(id, session);
                session.close();
                bindOutcomes.offer(id);
                return;
            }
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
        try {
            connection(connectionId).deliverShortMessage(
                    "", TypeOfNumber.INTERNATIONAL, NumberingPlanIndicator.ISDN, "12345",
                    TypeOfNumber.INTERNATIONAL, NumberingPlanIndicator.ISDN, "99999",
                    new ESMClass(), (byte) 0, (byte) 0,
                    new RegisteredDelivery(0),
                    new RawDataCoding((byte) dataCoding),
                    encode(shortMessage, dataCoding),
                    params);
        } catch (NegativeResponseException e) {
            // Distinguish the statuses tests pin, by TYPE - Ballerina interop surfaces the
            // thrown exception's CLASS NAME as error.message(). Wire-level by construction:
            // the status compared here was decoded from the actual deliver_sm_resp PDU,
            // which is the only observation that catches jsmpp's catch-all rewriting a
            // connector exception of the wrong type into RX_T_APPN (D14 trap).
            throw classify(e);
        }
    }

    /** Maps a negative resp's decoded command_status to its distinctly-named test type. */
    private static Exception classify(NegativeResponseException e) {
        return switch (e.getCommandStatus()) {
            case SMPPConstant.STAT_ESME_RTHROTTLED -> new ThrottledException(e.getCommandStatus());
            case SMPPConstant.STAT_ESME_RX_P_APPN -> new PermanentAppErrorException(e.getCommandStatus());
            case SMPPConstant.STAT_ESME_RX_T_APPN -> new TemporaryAppErrorException(e.getCommandStatus());
            default -> e;
        };
    }

    /**
     * Sends a {@code deliver_sm} carrying exactly the given raw {@code short_message} bytes
     * (no charset encoding on the mock side), so a test can put a precise on-wire byte
     * sequence — e.g. unpacked GSM 03.38 — in front of the connector's decoder.
     */
    void sendDeliverSmRaw(long connectionId, byte[] shortMessage, int dataCoding) throws Exception {
        connection(connectionId).deliverShortMessage(
                "", TypeOfNumber.INTERNATIONAL, NumberingPlanIndicator.ISDN, "12345",
                TypeOfNumber.INTERNATIONAL, NumberingPlanIndicator.ISDN, "99999",
                new ESMClass(), (byte) 0, (byte) 0,
                new RegisteredDelivery(0),
                new RawDataCoding((byte) dataCoding),
                shortMessage,
                new OptionalParameter[0]);
    }

    /**
     * Sends a {@code deliver_sm} flagged as an SMSC delivery receipt (the SMSC-delivery-receipt
     * esm_class message-type bit) carrying {@code receiptText} as its short_message body — for
     * exercising the connector's receipt-parsing path end to end.
     */
    void sendDeliveryReceipt(long connectionId, String receiptText) throws Exception {
        sendDeliveryReceipt(connectionId, receiptText, null);
    }

    /**
     * As above, but additionally carrying the {@code receipted_message_id} TLV (0x001E)
     * when {@code receiptedMessageId} is non-null.
     *
     * <p>This is the spec's only <em>guaranteed</em> correlation key (§5.3.2.12): the
     * {@code id:} field in an Appendix-B receipt body is "SMSC vendor specific", which is
     * why the hex-vs-decimal radix mismatch exists in the wild at all. A test needs to be
     * able to send a receipt whose TLV and whose body id disagree, so the connector's
     * correlation can be pinned to the right one.
     */
    void sendDeliveryReceipt(long connectionId, String receiptText, String receiptedMessageId)
            throws Exception {
        OptionalParameter[] params = receiptedMessageId == null
                ? new OptionalParameter[0]
                : new OptionalParameter[] {
                        new OptionalParameter.Receipted_message_id(receiptedMessageId) };
        connection(connectionId).deliverShortMessage(
                "", TypeOfNumber.INTERNATIONAL, NumberingPlanIndicator.ISDN, "12345",
                TypeOfNumber.INTERNATIONAL, NumberingPlanIndicator.ISDN, "99999",
                new ESMClass(DeliverSm.composeSmscDeliveryReceipt((byte) 0)), (byte) 0, (byte) 0,
                new RegisteredDelivery(0), new RawDataCoding((byte) 0),
                receiptText.getBytes(StandardCharsets.US_ASCII), params);
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
        try {
            connection(connectionId).dataShortMessage(
                    "", TypeOfNumber.INTERNATIONAL, NumberingPlanIndicator.ISDN, "12345",
                    TypeOfNumber.INTERNATIONAL, NumberingPlanIndicator.ISDN, "99999",
                    new ESMClass(), new RegisteredDelivery(0),
                    new RawDataCoding((byte) dataCoding),
                    params);
        } catch (NegativeResponseException e) {
            // Same typed classification as sendDeliverSm - data_sm is the other PDU type
            // the D14 NACK split applies to.
            throw classify(e);
        }
    }

    // --- submit_sm capture (Sprint 8, item 10) ---------------------------------------

    /**
     * Receives client-originated PDUs. Only {@code submit_sm} is implemented; the rest
     * answer the way jsmpp's own {@code SMPPServerSimulator} does for unsupported
     * operations, rather than returning {@code null} (which is what
     * {@code Dispatcher.onAcceptDataSm} was fixed for in Sprint 0 — a null here is a
     * latent NPE inside jsmpp's response writer, not a benign no-op).
     *
     * <p>One instance is shared by every session this mock accepts, so it holds no
     * per-connection state: attribution is by session identity via {@code connectionIds}.
     *
     * <p><b>Invariant - nothing in this listener may block the enquire_link path.</b>
     * On the server side jsmpp runs {@code onAcceptEnquireLink} BEFORE sending
     * {@code enquire_link_resp} (AbstractGenericSMPPSessionBound), and this class
     * deliberately does not override that default no-op. An override that blocks (a
     * delay knob, a capture) would delay the keepalive answer and can make the
     * connector's session time out - destabilizing every soak test in ways that look
     * like connector bugs. If you need enquire_link observability, count and return.
     */
    private final class CapturingReceiverListener implements ServerMessageReceiverListener {

        @Override
        public SubmitSmResult onAcceptSubmitSm(SubmitSm submitSm, SMPPServerSession source)
                throws ProcessRequestException {
            Long id = connectionIds.get(source);
            if (id != null) {
                // Registered before accept(), so this cannot miss a submit that races
                // bind_resp. A null id means the session was already severed/forgotten -
                // capture nothing rather than resurrect a dead connection's queue.
                BlockingQueue<SubmitSm> queue = submitCaptures.get(id);
                if (queue != null) {
                    queue.offer(submitSm);
                }
            }

            long delay = submitDelayMillis;
            if (delay > 0) {
                // Deliberately blocks the jsmpp PDU-processor thread, which is exactly
                // what a slow SMSC does - that is the condition the connector's
                // transactionTimeout (item 5) has to survive.
                try {
                    Thread.sleep(delay);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    throw new ProcessRequestException("interrupted while delaying submit_sm",
                            SMPPConstant.STAT_ESME_RSYSERR);
                }
            }

            int failure = submitFailureStatus;
            if (failure != 0) {
                // Becomes the submit_sm_resp command_status, which jsmpp surfaces to the
                // client as NegativeResponseException - the connector's REJECTED path.
                throw new ProcessRequestException("injected submit failure", failure);
            }

            String messageId = submitEmptyMessageId
                    ? ""
                    : Long.toString(nextMessageId.getAndIncrement());
            // Recorded after the failure/delay branches above, so a submit that was rejected
            // or that timed out has no entry - which is correct: no message_id was ever sent.
            submitMessageIds.put(submitSm, messageId);
            try {
                // The String ctors of SubmitSmResult are package-private; MessageId is the
                // only public route. It declares PDUStringException but accepts both ""
                // and ordinary decimal ids, so neither branch above can trip it.
                return new SubmitSmResult(new MessageId(messageId), new OptionalParameter[0]);
            } catch (Exception e) {
                throw new ProcessRequestException("could not build submit_sm_resp: " + e.getMessage(),
                        SMPPConstant.STAT_ESME_RSYSERR, e);
            }
        }

        @Override
        public SubmitMultiResult onAcceptSubmitMulti(SubmitMulti submitMulti, SMPPServerSession source)
                throws ProcessRequestException {
            throw new ProcessRequestException("submit_multi not supported by this mock",
                    SMPPConstant.STAT_ESME_RINVCMDID);
        }

        @Override
        public QuerySmResult onAcceptQuerySm(QuerySm querySm, SMPPServerSession source)
                throws ProcessRequestException {
            throw new ProcessRequestException("query_sm not supported by this mock",
                    SMPPConstant.STAT_ESME_RINVCMDID);
        }

        @Override
        public void onAcceptReplaceSm(ReplaceSm replaceSm, SMPPServerSession source)
                throws ProcessRequestException {
            throw new ProcessRequestException("replace_sm not supported by this mock",
                    SMPPConstant.STAT_ESME_RINVCMDID);
        }

        @Override
        public void onAcceptCancelSm(CancelSm cancelSm, SMPPServerSession source)
                throws ProcessRequestException {
            throw new ProcessRequestException("cancel_sm not supported by this mock",
                    SMPPConstant.STAT_ESME_RINVCMDID);
        }

        @Override
        public BroadcastSmResult onAcceptBroadcastSm(BroadcastSm broadcastSm, SMPPServerSession source)
                throws ProcessRequestException {
            throw new ProcessRequestException("broadcast_sm not supported by this mock",
                    SMPPConstant.STAT_ESME_RINVCMDID);
        }

        @Override
        public void onAcceptCancelBroadcastSm(CancelBroadcastSm cancelBroadcastSm, SMPPServerSession source)
                throws ProcessRequestException {
            throw new ProcessRequestException("cancel_broadcast_sm not supported by this mock",
                    SMPPConstant.STAT_ESME_RINVCMDID);
        }

        @Override
        public QueryBroadcastSmResult onAcceptQueryBroadcastSm(QueryBroadcastSm queryBroadcastSm,
                                                               SMPPServerSession source)
                throws ProcessRequestException {
            throw new ProcessRequestException("query_broadcast_sm not supported by this mock",
                    SMPPConstant.STAT_ESME_RINVCMDID);
        }

        @Override
        public DataSmResult onAcceptDataSm(DataSm dataSm, Session source) throws ProcessRequestException {
            // The connector only ever receives data_sm; a client-originated one is not
            // something these tests exercise.
            throw new ProcessRequestException("data_sm not supported by this mock",
                    SMPPConstant.STAT_ESME_RINVCMDID);
        }
    }

    /**
     * Blocks until the next {@code submit_sm} arrives on this connection, and returns it.
     * FIFO per connection, so a test on one link is never handed another link's PDU.
     */
    SubmitSm awaitNextSubmit(long connectionId, long timeoutMillis) throws Exception {
        BlockingQueue<SubmitSm> queue = submitCaptures.get(connectionId);
        if (queue == null) {
            throw new IllegalArgumentException("no such connection handle: " + connectionId);
        }
        SubmitSm submitSm = queue.poll(timeoutMillis, TimeUnit.MILLISECONDS);
        if (submitSm == null) {
            throw new TimeoutException("no submit_sm observed on connection " + connectionId
                    + " within " + timeoutMillis + "ms");
        }
        return submitSm;
    }

    /**
     * The {@code message_id} this mock returned in the {@code submit_sm_resp} for that exact
     * PDU, or {@code null} if it never sent one (injected failure, or the response has not
     * been built yet). A test awaits the submit, lets its own {@code submit} call return,
     * then compares the two.
     */
    String messageIdFor(SubmitSm submitSm) {
        return submitMessageIds.get(submitSm);
    }

    /**
     * How many captured submits are still unread on this connection. Throws on an
     * unknown/severed handle rather than returning 0: "and no more submits arrived" must
     * never pass vacuously against a dead handle (review minor).
     */
    int pendingSubmitCount(long connectionId) {
        BlockingQueue<SubmitSm> queue = submitCaptures.get(connectionId);
        // -1 (not 0) for an unknown/severed handle, so "and no more submits" can never
        // pass vacuously against a dead connection - and no exception crosses the
        // interop boundary (a Java throw panics the strand even under int|error).
        return queue == null ? -1 : queue.size();
    }

    /**
     * Makes every subsequent submit_sm answer with this {@code command_status} instead of
     * succeeding. 0 restores normal behaviour.
     */
    void setSubmitFailure(int commandStatus) {
        this.submitFailureStatus = commandStatus;
    }

    /** Delays every subsequent submit_sm_resp by this many ms. 0 disables. */
    void setSubmitDelay(long millis) {
        this.submitDelayMillis = millis;
    }

    /** When enabled, submit_sm_resp carries an empty message_id. */
    void setSubmitEmptyMessageId(boolean enabled) {
        this.submitEmptyMessageId = enabled;
    }

    /** Drops every registration for a connection. Idempotent. */
    private void forget(long connectionId, SMPPServerSession session) {
        connections.remove(connectionId);
        submitCaptures.remove(connectionId);
        if (session != null) {
            connectionIds.remove(session);
        }
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
        forget(connectionId, session);
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
        forget(connectionId, session);
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

    /**
     * Lowers this connection's enquire_link timer (jsmpp default: 60000 ms) so the mock,
     * acting as the SMSC, probes the connector's liveness frequently. Combined with a short
     * transaction timer, an unanswered enquire_link makes the mock close the session - which
     * is exactly the self-inflicted-drop path the SYNC keepalive test asserts against.
     */
    void setEnquireLinkTimer(long connectionId, int millis) {
        connection(connectionId).setEnquireLinkTimer(millis);
    }

    void close() {
        running = false;
        connections.values().forEach(SMPPServerSession::unbindAndClose);
        connections.clear();
        // Clear the sibling registries too: bounded by the mock's lifetime, but a close()
        // that leaves connectionIds/submitCaptures populated is misleadingly named and
        // would bite if mocks were ever pooled (review minor).
        connectionIds.clear();
        submitCaptures.clear();
        submitMessageIds.clear();
        try {
            listener.close();
        } catch (Exception ignored) {
            // best-effort cleanup
        }
        acceptLoop.shutdownNow();
        waitBindPool.shutdownNow();
    }
}
