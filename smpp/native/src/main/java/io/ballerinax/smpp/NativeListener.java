// Copyright (c) 2026. Native lifecycle for the SMPP listener (init/attach/start/stop).
package io.ballerinax.smpp;

import io.ballerina.runtime.api.Environment;
import io.ballerina.runtime.api.creators.ValueCreator;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BArray;
import io.ballerina.runtime.api.values.BDecimal;
import io.ballerina.runtime.api.values.BMap;
import io.ballerina.runtime.api.values.BObject;
import io.ballerina.runtime.api.values.BString;

import org.jsmpp.bean.BindType;
import org.jsmpp.bean.NumberingPlanIndicator;
import org.jsmpp.bean.TypeOfNumber;
import org.jsmpp.extra.SessionState;
import org.jsmpp.session.SMPPSession;

import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Backs the Ballerina {@code smpp:Listener} lifecycle methods. State (the jsmpp
 * session, the dispatcher, the config, and rebind bookkeeping) is kept as
 * native data on the listener {@link BObject}.
 *
 * <p>On an unexpected session drop (detected via jsmpp's {@code SessionStateListener}
 * transitioning to {@code CLOSED} without a user-initiated {@code gracefulStop}/
 * {@code immediateStop}), the attached service's optional {@code onError} method is
 * notified, and — per {@code ConnectionConfig.rebindPolicy} — a rebind loop with
 * exponential backoff is scheduled. A user-initiated stop always cancels any pending
 * rebind attempt.
 */
public final class NativeListener {

    private static final String NATIVE_SESSION = "smpp.session";
    private static final String NATIVE_DISPATCHER = "smpp.dispatcher";
    private static final String NATIVE_CONFIG = "smpp.config";
    private static final String NATIVE_TLS = "smpp.tls";
    private static final String NATIVE_STATE = "smpp.state";
    private static final String NATIVE_STATE_LOCK = "smpp.stateLock";
    private static final String NATIVE_REBIND_EXECUTOR = "smpp.rebindExecutor";
    private static final String NATIVE_SESSION_USABLE = "smpp.sessionUsable";
    private static final String NATIVE_SUBMITS_IN_FLIGHT = "smpp.submitsInFlight";
    private static final String NATIVE_REBIND_ABANDONED = "smpp.rebindAbandoned";

    private static final java.util.logging.Logger LOGGER =
            java.util.logging.Logger.getLogger(NativeListener.class.getName());

    /**
     * Extra jsmpp PDU-processor threads kept beyond {@code maxConcurrentDispatch} in SYNC
     * mode, reserved so the SMSC's enquire_link keepalive is always answered even while
     * every dispatch slot is busy. One suffices: the Dispatcher's semaphore caps blocking
     * handlers at {@code maxConcurrentDispatch}, so this thread is never occupiable by one,
     * and all outbound sends serialize on a single stream (a second reserve would protect
     * nothing a stuck write doesn't already stall identically).
     */
    private static final int KEEPALIVE_RESERVE_THREADS = 1;

    /**
     * Fixed jsmpp PDU-processor pool size in ASYNC mode. Handlers run on virtual threads, so
     * these platform threads only marshal each PDU and spawn - they never block, so a small
     * pool is sufficient and one thread is always free for enquire_link regardless of load.
     */
    private static final int ASYNC_PDU_PROCESSOR_DEGREE = 3;

    /**
     * Listener lifecycle. One-way except {@code STARTING -> INIT} on a failed initial
     * bind, which is safe because a failed bind installs nothing (no session, no
     * executor, no in-flight work). {@code STOPPING}/{@code STOPPED} are terminal:
     * restart is rejected — create a new Listener instead.
     */
    enum ListenerState { INIT, STARTING, STARTED, STOPPING, STOPPED }

    // jsmpp's StringValidator rejects systemId/password/systemType at length 16/9/13
    // respectively (StringParameter.SYSTEM_ID/PASSWORD/SYSTEM_TYPE - each C-Octet-String
    // max includes the wire NUL terminator), so these are the largest usable lengths.
    private static final int MAX_SYSTEM_ID_LENGTH = 15;
    private static final int MAX_PASSWORD_LENGTH = 8;
    private static final int MAX_SYSTEM_TYPE_LENGTH = 12;

    private NativeListener() {}

    /**
     * jsmpp PDU-processor pool sizing. Extracted (and JUnit-pinned: SYNC degree must
     * STRICTLY exceed maxConcurrentDispatch) because the reserve became load-bearing for
     * more than keepalives in Sprint 8: EVERY inbound PDU rides this pool - including
     * {@code submit_sm_resp}. A SYNC handler blocked inside {@code Caller.submit}
     * occupies one pool thread while its own completion depends on ANOTHER pool thread
     * delivering the response; with no reserve, N blocked submitting handlers deadlock
     * until transactionTimeout. The reserve is therefore a liveness requirement for the
     * submit path, not just an enquire_link nicety. KEEPALIVE_RESERVE_THREADS is
     * compiler-inlined, so no automated mutation test is possible - the manual check is:
     * set it to 0, run testConcurrentSubmitsCorrelateAndKeepaliveAnswered, and expect N
     * simultaneous TIMEOUT_DELIVERY_UNKNOWNs at transactionTimeout (a louder signature
     * than the missed keepalive).
     */
    static int pduProcessorDegree(boolean async, int maxConcurrentDispatch) {
        return async ? ASYNC_PDU_PROCESSOR_DEGREE
                     : maxConcurrentDispatch + KEEPALIVE_RESERVE_THREADS;
    }

    public static Object initListener(Environment env, BObject listener, BMap<BString, Object> config,
            Object tls) {
        listener.addNativeData(NATIVE_CONFIG, config);
        // The flat ResolvedTls record from listener.bal (null = plaintext). Stored once at
        // init like everything else; read on every bind attempt by newSession().
        listener.addNativeData(NATIVE_TLS, tls);
        int maxConcurrentDispatch = (int) ((Long) config.getIntValue(
                StringUtils.fromString("maxConcurrentDispatch"))).longValue();
        boolean decodeGsm7 = Boolean.TRUE.equals(config.get(StringUtils.fromString("decodeGsm7")));
        // SESSION and REBIND_EXECUTOR are mutated after jsmpp threads exist, so they go
        // through write-once AtomicReference holders installed here at init rather than
        // via addNativeData post-init: the runtime's native-data map is a plain HashMap
        // with unsynchronized get/put, and a post-init put racing a jsmpp-thread get would
        // be a data race. All native-data writes now happen once, at init, single-threaded.
        AtomicReference<ListenerState> stateRef = new AtomicReference<>(ListenerState.INIT);
        AtomicReference<SMPPSession> sessionRef = new AtomicReference<>();
        // The one smpp:Caller for this listener. It carries its OWN native data - the
        // same two AtomicReferences the listener uses plus the config - handed over here,
        // once, single-threaded, so NativeCaller never has to touch the listener BObject
        // (whose native-data map has the same post-init-write race documented above).
        BObject caller = ValueCreator.createObjectValue(ModuleUtils.getModule(), "Caller");
        caller.addNativeData(NativeCaller.SESSION_REF, sessionRef);
        caller.addNativeData(NativeCaller.STATE_REF, stateRef);
        caller.addNativeData(NativeCaller.CONFIG, config);
        // The connector's OWN drop verdict, readable by the submit path. getSessionState()
        // cannot serve: a wedged session claims BOUND_TRX forever (the reader-death wedge),
        // so without this flag submits would be accepted onto a dead socket for the whole
        // rebind window. Set true at install, false on drop/stop.
        AtomicBoolean sessionUsable = new AtomicBoolean(false);
        caller.addNativeData(NativeCaller.SESSION_USABLE, sessionUsable);
        listener.addNativeData(NATIVE_SESSION_USABLE, sessionUsable);
        // Submits in flight, for the drain: gracefulStop must not unbind the session
        // under a parked submit (owner decision: submits stay legal while STOPPING).
        java.util.concurrent.atomic.AtomicInteger submitsInFlight =
                new java.util.concurrent.atomic.AtomicInteger();
        caller.addNativeData(NativeCaller.SUBMITS_IN_FLIGHT, submitsInFlight);
        listener.addNativeData(NATIVE_SUBMITS_IN_FLIGHT, submitsInFlight);
        // Terminal rebind verdict (D13/F7): set at the two give-up points (rebind
        // disabled at drop time, or attempts exhausted), cleared only by a successful
        // install. The submit path reads it to answer LINK_ABANDONED instead of
        // LINK_DOWN - "retrying is futile for this Listener's life" is the one
        // distinction error wording alone could not carry (D8 revisited). Installed on
        // BOTH objects at init: the Caller never touches the listener BObject (the
        // native-data HashMap race documented above).
        AtomicBoolean rebindAbandoned = new AtomicBoolean(false);
        caller.addNativeData(NativeCaller.REBIND_ABANDONED, rebindAbandoned);
        listener.addNativeData(NATIVE_REBIND_ABANDONED, rebindAbandoned);
        listener.addNativeData(NATIVE_DISPATCHER,
                new Dispatcher(env.getRuntime(), maxConcurrentDispatch, decodeGsm7, caller));
        listener.addNativeData(NATIVE_STATE, stateRef);
        listener.addNativeData(NATIVE_STATE_LOCK, new Object());
        listener.addNativeData(NATIVE_SESSION, sessionRef);
        listener.addNativeData(NATIVE_REBIND_EXECUTOR, new AtomicReference<ScheduledExecutorService>());
        env.getRuntime().registerListener(listener);
        return null;
    }

    public static Object attach(BObject listener, BObject service, Object name) {
        Dispatcher.AttachOutcome outcome = dispatcher(listener).attach(service);
        return switch (outcome.result()) {
            case ATTACHED -> null;
            case ALREADY_ATTACHED -> ModuleUtils.createError(
                    "cannot attach: a service is already attached to this listener; "
                            + "detach it before attaching another");
            case NO_REMOTE_METHODS -> ModuleUtils.createError(
                    "attached service does not implement any of the supported remote methods "
                            + "(onDeliverSm, onDataSm, onError)");
            case BAD_SIGNATURE -> ModuleUtils.createError(
                    "cannot attach: " + outcome.detail());
        };
    }

    public static Object detach(BObject listener, BObject service) {
        dispatcher(listener).detachIf(service);
        return null;
    }

    public static Object start(BObject listener) {
        AtomicReference<ListenerState> state = state(listener);
        synchronized (stateLock(listener)) {
            switch (state.get()) {
                case STARTING, STARTED -> {
                    return ModuleUtils.createError("cannot start: the listener is already started");
                }
                case STOPPING, STOPPED -> {
                    return ModuleUtils.createError("cannot start: the listener has been stopped "
                            + "and cannot be restarted; create a new Listener instead");
                }
                case INIT -> state.set(ListenerState.STARTING);
            }
        }
        try {
            if (!bind(listener, config(listener))) {
                // A concurrent stop won the race while we were binding; bind() already
                // closed the fresh session and the stop path owns the state from here.
                return ModuleUtils.createError("the listener was stopped before start() completed");
            }
            return null;
        } catch (Exception e) {
            synchronized (stateLock(listener)) {
                if (state.get() == ListenerState.STARTING) {
                    // Nothing was installed - a failed start is retryable (see ListenerState doc).
                    state.set(ListenerState.INIT);
                }
                // else: a concurrent stop moved us to STOPPING/STOPPED; leave its transition alone.
            }
            return ModuleUtils.createError("failed to connect/bind to SMSC: " + e.getMessage());
        }
    }

    /**
     * Connects and binds to the SMSC, (re)configures the dispatcher, and installs the new
     * session - but only if the lifecycle still wants it by the time the blocking
     * connectAndBind returns. The state lock is deliberately NOT held across
     * connectAndBind (it can block for the full network bind timeout; holding the lock
     * would freeze gracefulStop/immediateStop for that long).
     *
     * @return {@code true} if the session was installed; {@code false} if a concurrent
     *     stop aborted the install (the fresh session is closed before returning)
     * @throws Exception if the connect/bind itself fails
     */
    private static boolean bind(BObject listener, BMap<BString, Object> config) throws Exception {
        Dispatcher dispatcher = dispatcher(listener);
        // Bounds both the TCP connect (via the connection factory) and the bind-response
        // wait (via connectAndBind below), on the initial start and every rebind alike.
        int bindTimeoutMillis = (int) (decimalValue(config, "bindTimeout") * 1000);
        // Armed further down, once the per-attempt drop guards exist; connections created
        // before arming (i.e. during connectAndBind's connect phase) report nothing, and
        // connect/bind-phase failures are surfaced by connectAndBind itself.
        AtomicReference<Runnable> onTransportDeath = new AtomicReference<>();
        SMPPSession session = newSession(listener, bindTimeoutMillis, onTransportDeath,
                (long) (decimalValue(config, "transactionTimeout") * 1000));
        session.setMessageReceiverListener(dispatcher);

        String host = str(config, "host");
        int port = (int) ((Long) config.getIntValue(StringUtils.fromString("port"))).longValue();
        String systemId = str(config, "systemId");
        String password = str(config, "password");
        String systemType = str(config, "systemType");
        validateCredentials(systemId, password, systemType);
        BindType bindType = toBindType(str(config, "bindType"));
        int maxConcurrentDispatch = (int) ((Long) config.getIntValue(
                StringUtils.fromString("maxConcurrentDispatch"))).longValue();
        boolean async = "ASYNC".equals(str(config, "responseMode"));
        dispatcher.setAsync(async);
        // pduProcessorDegree sizes jsmpp's shared PDU-processor pool, which handles ALL
        // inbound PDUs including the SMSC's enquire_link keepalive. Actual handler
        // concurrency is bounded by the Dispatcher's Semaphore(maxConcurrentDispatch), not
        // by this pool size. Must be set while the session is still CLOSED (before
        // connectAndBind). Sizing is mode-aware:
        //  - SYNC: handlers run ON these pool threads and block for the handler's duration,
        //    so the pool must be maxConcurrentDispatch + a reserve. The reserve (never
        //    occupiable by a blocking handler, since the Semaphore caps that at
        //    maxConcurrentDispatch) guarantees a thread is always free to answer
        //    enquire_link - the fix for the self-inflicted drop. Reserve of 1 suffices: all
        //    outbound sends serialize on one stream, so a second reserve protects nothing.
        //  - ASYNC: handlers run on virtual threads, so pool threads only marshal each PDU
        //    and spawn - they never block. A small fixed pool is plenty and avoids spinning
        //    maxConcurrentDispatch *platform* threads that would only spawn vthreads.
        int pduProcessorDegree = pduProcessorDegree(async, maxConcurrentDispatch);
        session.setPduProcessorDegree(pduProcessorDegree);

        // Connector's own keepalive/idle-probe interval and socket read timeout (seconds ->
        // millis). enquireLinkInterval is validated >= 5s, so it never disables detection.
        session.setEnquireLinkTimer((int) (decimalValue(config, "enquireLinkInterval") * 1000));

        // transactionTimeout is applied at session construction (ConnectorSession), split
        // by role: submits get the configured value, jsmpp housekeeping stays at the short
        // internal bound. Deliberately NOT set via setTransactionTimer here - that would
        // overwrite the field carrying the housekeeping bound (unbind() reads the field).

        // Per-attempt flags. `installed` gates the listener lambda: a CLOSED fired by a
        // rejected/failed bind (jsmpp self-closes inside connectAndBind) is start()'s
        // error, not an "unexpected drop". `dropReported` makes drop-reporting
        // exactly-once between the lambda and the manual post-install check below -
        // jsmpp swaps its state BEFORE running listeners (SMPPSessionContext.changeState),
        // so neither side can assume the other has or hasn't run yet.
        AtomicBoolean installed = new AtomicBoolean(false);
        AtomicBoolean dropReported = new AtomicBoolean(false);
        // Second, independent drop signal (see ObservedConnection): fires the moment
        // jsmpp's reader observes EOF/IOException on the socket. Shares the same
        // per-attempt guards as the state listener below, so whichever signal arrives
        // first reports the drop exactly once. The grace delay gives jsmpp's own CLOSED
        // notification - the normal path, measured at 0-4ms after EOF when the close
        // choreography works - every reasonable chance to win; this path only acts when
        // that choreography wedges (the reader-death failure mode).
        onTransportDeath.set(() -> scheduleTransportDeathCheck(listener, installed, dropReported));
        session.addSessionStateListener((newState, oldState, source) -> {
            if (newState != SessionState.CLOSED || !installed.get()) {
                return;
            }
            ListenerState st = state(listener).get();
            if (st == ListenerState.STOPPING || st == ListenerState.STOPPED) {
                return; // user-initiated close; never a drop
            }
            if (dropReported.compareAndSet(false, true)) {
                onUnexpectedDrop(listener,
                        "SMPP session closed unexpectedly (was " + oldState + ")");
            }
        });

        // addressRange stays null, deliberately. jsmpp's connectAndBind has exactly one
        // failure branch that does NOT close the socket - the PDUException catch
        // (SMPPSession.java:284-286) rethrows as IOException while leaving the socket
        // open and the started PDUReaderWorker running (per-attempt FD + thread leak).
        // validateCredentials makes that branch unreachable for systemId/password/
        // systemType; a non-null addressRange would reopen it (stage-2 review, N6).
        session.connectAndBind(host, port, bindType, systemId, password, systemType,
                TypeOfNumber.UNKNOWN, NumberingPlanIndicator.UNKNOWN, null, bindTimeoutMillis);

        // LOAD-BEARING CROSS-LIBRARY INVARIANT: this critical section holds stateLock and
        // reads session.getSessionState() (which takes jsmpp's stateProcessorLock), while
        // the state-listener lambda above acquires stateLock from a jsmpp thread. This is
        // deadlock-free ONLY because jsmpp releases stateProcessorLock BEFORE firing the
        // listener (SMPPSessionContext.changeState releases its write lock, then calls
        // fireStateChanged) - so the lambda's stateLock acquisition never happens while a
        // jsmpp thread holds stateProcessorLock. If a future jsmpp release moved the fire
        // inside that lock, this becomes a hard deadlock. Re-verify against jsmpp on upgrade.
        boolean abortedByStop = false;
        synchronized (stateLock(listener)) {
            ListenerState st = state(listener).get();
            // STARTING: the initial start(). STARTED: a rebind attempt (the lifecycle
            // stays STARTED across a drop; only sessions come and go).
            if (st == ListenerState.STARTING || st == ListenerState.STARTED) {
                session(listener).set(session);
                sessionUsable(listener).set(true);
                rebindAbandoned(listener).set(false);
                installed.set(true);
                state(listener).set(ListenerState.STARTED);
                // Bound-race check: if the session died in the sliver between
                // connectAndBind returning and installed.set(true), the lambda saw
                // installed == false and stayed silent - detect and report it here.
                // The CAS keeps this exactly-once against a lambda that DID see
                // installed == true. (Reentrant: onUnexpectedDrop -> scheduleRebind
                // re-acquires this same monitor.)
                if (session.getSessionState() == SessionState.CLOSED
                        && dropReported.compareAndSet(false, true)) {
                    onUnexpectedDrop(listener,
                            "SMPP session closed unexpectedly immediately after binding");
                }
            } else {
                abortedByStop = true;
            }
        }
        if (abortedByStop) {
            // Outside the lock: this does network I/O.
            session.unbindAndClose();
            return false;
        }
        return true;
    }

    /**
     * Rejects an oversized {@code systemId}/{@code password}/{@code systemType} before
     * {@link #bind} ever calls {@code connectAndBind}. jsmpp's own {@code StringValidator}
     * would catch the same violation, but its exception message embeds the raw (invalid)
     * value verbatim - a credential-leak path via logs/error messages. The message here
     * names the field and its limit but never echoes the value.
     *
     * @throws IllegalArgumentException if any of the three exceeds its limit
     */
    // package-private (not private): exercised directly by NativeListenerTest, a pure-logic
    // JUnit suite that needs no jsmpp session or Ballerina runtime.
    static void validateCredentials(String systemId, String password, String systemType) {
        // ASCII first, then length. jsmpp counts these fields in UTF-16 code units but
        // writes them with String.getBytes() in the JVM default charset (PDUByteBuffer),
        // so a single non-ASCII character silently overflows the C-octet field on the
        // wire - and the bind failure would surface as a bare "failed to connect/bind"
        // with no hint (stage-2 code review, H2). ASCII-only makes the length checks
        // exact. Message names the field and index, never the value - it's a credential.
        requireAscii("systemId", systemId);
        requireAscii("password", password);
        requireAscii("systemType", systemType);
        if (systemId.length() > MAX_SYSTEM_ID_LENGTH) {
            throw new IllegalArgumentException(
                    "systemId exceeds the maximum length of " + MAX_SYSTEM_ID_LENGTH + " characters");
        }
        if (password.length() > MAX_PASSWORD_LENGTH) {
            throw new IllegalArgumentException(
                    "password exceeds the maximum length of " + MAX_PASSWORD_LENGTH + " characters");
        }
        if (systemType.length() > MAX_SYSTEM_TYPE_LENGTH) {
            throw new IllegalArgumentException(
                    "systemType exceeds the maximum length of " + MAX_SYSTEM_TYPE_LENGTH + " characters");
        }
    }

    private static void requireAscii(String field, String value) {
        for (int i = 0; i < value.length(); i++) {
            if (value.charAt(i) > 0x7F) {
                throw new IllegalArgumentException(field + " contains a non-ASCII character at index "
                        + i + "; SMPP C-octet fields must be ASCII");
            }
        }
    }

    private static void onUnexpectedDrop(BObject listener, String description) {
        // Before anything else: flip the connector's own drop verdict so the submit
        // path fails fast with LINK_DOWN instead of stalling transactionTimeout against
        // a dead (or wedged, still-claiming-BOUND) session.
        sessionUsable(listener).set(false);
        dispatcher(listener).dispatchError(description);
        scheduleRebind(listener, 1);
    }

    private static AtomicBoolean sessionUsable(BObject listener) {
        return (AtomicBoolean) listener.getNativeData(NATIVE_SESSION_USABLE);
    }

    private static AtomicBoolean rebindAbandoned(BObject listener) {
        return (AtomicBoolean) listener.getNativeData(NATIVE_REBIND_ABANDONED);
    }

    private static java.util.concurrent.atomic.AtomicInteger submitsInFlight(BObject listener) {
        return (java.util.concurrent.atomic.AtomicInteger) listener.getNativeData(NATIVE_SUBMITS_IN_FLIGHT);
    }

    /**
     * How long the transport-death signal waits for jsmpp's own CLOSED notification
     * before declaring the drop itself. When jsmpp's close choreography works it fires
     * CLOSED 0-4ms after the EOF, so 1s is ~250x headroom for the normal path while still
     * recovering a wedged session ~10x faster than the tightest test budget (10s).
     */
    private static final long TRANSPORT_DEATH_GRACE_MS = 1000;

    /**
     * Invoked (via {@link ObservedConnection}) on jsmpp's reader thread the moment the
     * transport dies. Schedules a delayed check rather than acting inline: the normal
     * path is that jsmpp's CLOSED listener fires within milliseconds and wins the
     * {@code dropReported} CAS, making the check a no-op. Only when the reader thread
     * dies mid-{@code close()} - leaving the session BOUND forever and the CLOSED
     * listener unfired (the wedge documented on {@link ObservedConnection}) - does this
     * path report the drop and drive the rebind.
     *
     * <p>The wedged jsmpp threads (an orphaned EnquireLinkSender, at worst) are
     * deliberately abandoned, not joined: anything that waits on jsmpp's close
     * choreography inherits the wedge. The next bind builds a fresh session; the orphan
     * exits on its own if the state ever flips, and is otherwise a bounded, logged leak.
     */
    private static void scheduleTransportDeathCheck(BObject listener, AtomicBoolean installed,
            AtomicBoolean dropReported) {
        synchronized (stateLock(listener)) {
            ListenerState st = state(listener).get();
            if (st != ListenerState.STARTING && st != ListenerState.STARTED) {
                return; // stopping/stopped: user-initiated teardown closes sockets too
            }
            try {
                rebindExecutor(listener).schedule(() -> {
                    if (state(listener).get() != ListenerState.STARTED || !installed.get()) {
                        // Bind-phase death (connectAndBind surfaces it to start()/rebind)
                        // or a stop won the race - either way, not ours to report.
                        return;
                    }
                    if (dropReported.compareAndSet(false, true)) {
                        onUnexpectedDrop(listener,
                                "SMPP transport died and jsmpp's CLOSED notification did not arrive within "
                                        + TRANSPORT_DEATH_GRACE_MS + "ms (reader-death wedge; abandoning the session)");
                    }
                }, TRANSPORT_DEATH_GRACE_MS, TimeUnit.MILLISECONDS);
            } catch (java.util.concurrent.RejectedExecutionException e) {
                // A stop shut the executor down between the state check and schedule();
                // stops own their teardown, nothing to report.
            }
        }
    }

    @SuppressWarnings("unchecked")
    private static void scheduleRebind(BObject listener, int attempt) {
        BMap<BString, Object> policy =
                (BMap<BString, Object>) config(listener).getMapValue(StringUtils.fromString("rebindPolicy"));
        long maxAttempts = policy.getIntValue(StringUtils.fromString("maxRebindAttempts"));
        if (maxAttempts == 0) {
            // Auto-rebind disabled; the onUnexpectedDrop call already reported the drop.
            // Latch the terminal verdict BEFORE returning so a submit racing in from the
            // very onError handler that learns of the drop already sees LINK_ABANDONED.
            rebindAbandoned(listener).set(true);
            LOGGER.warning("SMPP link is down and rebindPolicy.maxRebindAttempts is 0: this "
                    + "listener will not recover; submits now fail with LINK_ABANDONED");
            return;
        }
        if (maxAttempts > 0 && attempt > maxAttempts) {
            rebindAbandoned(listener).set(true);
            // The one operator-visible WARN at the transition (stage-2 F10.3): the
            // dispatchError below reaches only an attached onError handler, which a
            // default deployment may not have.
            LOGGER.warning("SMPP listener gave up rebinding after " + (attempt - 1)
                    + " attempt(s): this listener will not recover; submits now fail with "
                    + "LINK_ABANDONED");
            dispatcher(listener).dispatchError(
                    "gave up rebinding to the SMSC after " + (attempt - 1) + " attempt(s)");
            return;
        }
        double initialDelay = decimalValue(policy, "initialRebindDelay");
        double maxDelay = decimalValue(policy, "maxRebindDelay");
        double multiplier = decimalValue(policy, "backOffMultiplier");
        double delaySeconds = Math.min(initialDelay * Math.pow(multiplier, attempt - 1), maxDelay);

        synchronized (stateLock(listener)) {
            if (state(listener).get() != ListenerState.STARTED) {
                // A stop won: its STOPPING transition happened under this same monitor,
                // so there is no window between this check and .schedule() below - and
                // stop only shuts the executor down AFTER making that transition, so
                // RejectedExecutionException is structurally unreachable here.
                return;
            }
            rebindExecutor(listener).schedule(() -> {
                try {
                    attemptRebind(listener, attempt);
                } catch (Throwable t) {
                    // Belt-and-suspenders: anything a task throws inside .schedule() is
                    // swallowed into a never-read ScheduledFuture by the JDK. If a future
                    // refactor breaks attemptRebind's own handling, surface it via
                    // onError instead of silently killing the rebind loop.
                    dispatcher(listener).dispatchError(
                            "rebind attempt " + attempt + " crashed unexpectedly: " + t);
                }
            }, (long) (delaySeconds * 1000), TimeUnit.MILLISECONDS);
        }
    }

    private static void attemptRebind(BObject listener, int attempt) {
        if (state(listener).get() != ListenerState.STARTED) {
            return; // stopped while this attempt sat in the executor queue
        }
        try {
            // Returns false if a stop raced in mid-bind; bind() already closed the new
            // session and the stop path owns everything from here - nothing to report.
            bind(listener, config(listener));
        } catch (Exception e) {
            ListenerState st = state(listener).get();
            if (st == ListenerState.STOPPING || st == ListenerState.STOPPED) {
                // shutdownNow() interrupting an in-flight connect lands here; the failure
                // was caused by (or is moot because of) the stop - don't report it.
                return;
            }
            dispatcher(listener).dispatchError("rebind attempt " + attempt + " failed: " + e.getMessage());
            scheduleRebind(listener, attempt + 1);
        }
    }

    public static Object gracefulStop(Environment env, BObject listener) {
        return stop(env, listener, true);
    }

    public static Object immediateStop(Environment env, BObject listener) {
        return stop(env, listener, false);
    }

    private static Object stop(Environment env, BObject listener, boolean graceful) {
        AtomicReference<ListenerState> state = state(listener);
        synchronized (stateLock(listener)) {
            ListenerState st = state.get();
            if (st == ListenerState.STOPPING || st == ListenerState.STOPPED) {
                return null; // stop is idempotent; a concurrent second stop returns immediately
            }
            // From INIT (never started), STARTING (stop races the initial bind - the
            // binder will see this and discard its fresh session), or STARTED.
            state.set(ListenerState.STOPPING);
        }
        shutdownRebindExecutor(listener);   // no-op if never created
        if (graceful) {
            // Submits stay LEGAL during the drain (owner decision, 2026-07-29): the
            // session is bound and usable until closeSession below, and rejecting
            // submits from the very handlers being drained would drop every reply-style
            // service's replies on shutdown. The drain covers both dispatches and
            // in-flight submits.
            awaitDrain(listener);           // also covers in-flight onError notifications
        }
        // Point of no return for the send path: fail-fast any submit arriving after the
        // drain, then unbind. (immediateStop skips the drain: in-flight submits surface
        // as LINK_DOWN when the socket closes under them - documented, tested.)
        sessionUsable(listener).set(false);
        // Post-flip sweep (Phase 5 finding #2): a submit that incremented before the flip
        // may still be in flight; with increment-before-check on the submit side, this
        // bounded wait closes the reservation race - post-flip submits fail fast and
        // decrement in microseconds, so the sweep only ever waits for real sends.
        java.util.concurrent.atomic.AtomicInteger sweep = submitsInFlight(listener);
        long sweepDeadline = System.currentTimeMillis() + 2000;
        while (sweep.get() > 0 && System.currentTimeMillis() < sweepDeadline) {
            try {
                Thread.sleep(20);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            }
        }
        Object result = closeSession(listener);  // null-safe; outside the lock (network I/O)
        synchronized (stateLock(listener)) {
            state.set(ListenerState.STOPPED);
        }
        // Exactly-once: only the thread that made the STOPPING transition reaches here.
        // Deregister even if closeSession errored - the listener is terminal either way.
        env.getRuntime().deregisterListener(listener);
        return result;
    }

    /** Waits (bounded by {@code ConnectionConfig.gracefulStopTimeout}) for in-flight dispatches to finish. */
    private static void awaitDrain(BObject listener) {
        double timeoutSeconds = decimalValue(config(listener), "gracefulStopTimeout");
        long deadline = System.currentTimeMillis() + (long) (timeoutSeconds * 1000);
        Dispatcher dispatcher = dispatcher(listener);
        // Two counters: dispatches (handlers + onError vthreads) AND submits. Submits are
        // tracked separately because they can be issued from NON-handler strands (a
        // stashed Caller), which inFlight cannot see - without this, stop() could unbind
        // the session under a parked submit (concurrency-review finding #3). Submits stay
        // legal while STOPPING (owner decision), so the drain must cover them.
        java.util.concurrent.atomic.AtomicInteger submits = submitsInFlight(listener);
        while ((dispatcher.inFlightCount() > 0 || submits.get() > 0)
                && System.currentTimeMillis() < deadline) {
            try {
                Thread.sleep(50);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            }
        }
    }

    private static Object closeSession(BObject listener) {
        SMPPSession session = session(listener).get();
        if (session != null) {
            try {
                session.unbindAndClose();
            } catch (Exception e) {
                return ModuleUtils.createError("failed to unbind SMSC session: " + e.getMessage());
            }
        }
        return null;
    }

    private static Dispatcher dispatcher(BObject listener) {
        return (Dispatcher) listener.getNativeData(NATIVE_DISPATCHER);
    }

    @SuppressWarnings("unchecked")
    private static BMap<BString, Object> config(BObject listener) {
        return (BMap<BString, Object>) listener.getNativeData(NATIVE_CONFIG);
    }

    @SuppressWarnings("unchecked")
    private static AtomicReference<ListenerState> state(BObject listener) {
        return (AtomicReference<ListenerState>) listener.getNativeData(NATIVE_STATE);
    }

    private static Object stateLock(BObject listener) {
        return listener.getNativeData(NATIVE_STATE_LOCK);
    }

    @SuppressWarnings("unchecked")
    private static AtomicReference<SMPPSession> session(BObject listener) {
        return (AtomicReference<SMPPSession>) listener.getNativeData(NATIVE_SESSION);
    }

    @SuppressWarnings("unchecked")
    private static AtomicReference<ScheduledExecutorService> rebindExecutorRef(BObject listener) {
        return (AtomicReference<ScheduledExecutorService>) listener.getNativeData(NATIVE_REBIND_EXECUTOR);
    }

    /** Must be called while holding {@code stateLock(listener)} (sole caller: scheduleRebind). */
    private static ScheduledExecutorService rebindExecutor(BObject listener) {
        AtomicReference<ScheduledExecutorService> ref = rebindExecutorRef(listener);
        ScheduledExecutorService existing = ref.get();
        if (existing != null) {
            return existing;
        }
        ScheduledExecutorService executor = Executors.newSingleThreadScheduledExecutor();
        ref.set(executor);
        return executor;
    }

    private static void shutdownRebindExecutor(BObject listener) {
        ScheduledExecutorService existing = rebindExecutorRef(listener).get();
        if (existing != null) {
            existing.shutdownNow();
        }
    }

    /**
     * A fresh session per bind attempt. Plaintext uses a connect-timeout-bounded factory
     * (jsmpp's stock plaintext connect is unbounded); TLS builds a fresh per-attempt factory
     * with the same connect bound. Called once per bind attempt (initial start and every
     * rebind), so no factory/SSLContext is shared across attempts - and rotated TLS trust
     * material is picked up on the next rebind for free. {@code connectTimeoutMillis} bounds
     * the TCP connect (and, for TLS, the handshake read); the bind-response wait is bounded
     * separately by the timeout passed to {@code connectAndBind}.
     */
    @SuppressWarnings("unchecked")
    private static SMPPSession newSession(BObject listener, int connectTimeoutMillis,
            AtomicReference<Runnable> onTransportDeath, long submitTransactionTimerMs) throws Exception {
        Object tls = listener.getNativeData(NATIVE_TLS);
        org.jsmpp.session.connection.ConnectionFactory delegate = tls == null
                ? new SmppPlainConnectionFactory(connectTimeoutMillis)
                : buildSslFactory((BMap<BString, Object>) tls, connectTimeoutMillis);
        // Every connection this session ever opens is observed - the connector's own
        // transport-death signal, independent of jsmpp's CLOSED listener. See
        // ObservedConnection for the reader-death wedge this guards against. The session
        // itself is a ConnectorSession: submits wait the configured transactionTimeout,
        // jsmpp's housekeeping (unbind, enquire-link probes, reader exit) is bounded at
        // ConnectorSession.HOUSEKEEPING_TIMER_MS - see that class for the split.
        return new ConnectorSession((host, port) ->
                new ObservedConnection(delegate.createConnection(host, port), onTransportDeath),
                submitTransactionTimerMs);
    }

    /** Field names here mirror listener.bal's internal ResolvedTls record exactly. */
    private static SmppSslConnectionFactory buildSslFactory(BMap<BString, Object> tls,
            int connectTimeoutMillis) throws Exception {
        return SmppSslConnectionFactory.create(
                tlsStr(tls, "trustStorePath"),
                tlsStr(tls, "trustStorePassword").toCharArray(),
                tlsStr(tls, "trustCertPath"),
                tlsStr(tls, "keyStorePath"),
                tlsStr(tls, "keyStorePassword").toCharArray(),
                tlsStringArray(tls, "protocolVersions"),
                tlsStringArray(tls, "ciphers"),
                tlsBool(tls, "trustAll"),
                tlsBool(tls, "verifyHostName"),
                connectTimeoutMillis);
    }

    // The TLS readers below are STRICT: ResolvedTls (listener.bal) is a closed record with
    // no nilable fields, so a null here means the .bal record and this native reader have
    // drifted out of sync - a programming error, never a config value. We fail loudly
    // rather than defaulting, because a silently-defaulted verifyHostName (false) would
    // turn hostname verification off - a fail-open the lenient config readers must not risk.
    private static Object tlsRequire(BMap<BString, Object> tls, String key) {
        Object v = tls.get(StringUtils.fromString(key));
        if (v == null) {
            throw new IllegalStateException(
                    "internal error: TLS field '" + key + "' missing from ResolvedTls");
        }
        return v;
    }

    private static String tlsStr(BMap<BString, Object> tls, String key) {
        return ((BString) tlsRequire(tls, key)).getValue();
    }

    private static boolean tlsBool(BMap<BString, Object> tls, String key) {
        return (Boolean) tlsRequire(tls, key);
    }

    private static String[] tlsStringArray(BMap<BString, Object> tls, String key) {
        BArray arr = (BArray) tlsRequire(tls, key);   // present-but-empty is valid (JVM defaults)
        String[] out = new String[(int) arr.size()];
        for (int i = 0; i < out.length; i++) {
            out[i] = arr.getBString(i).getValue();
        }
        return out;
    }

    private static String str(BMap<BString, Object> config, String key) {
        BString v = config.getStringValue(StringUtils.fromString(key));
        return v == null ? "" : v.getValue();
    }

    private static double decimalValue(BMap<BString, Object> map, String key) {
        return ((BDecimal) map.get(StringUtils.fromString(key))).floatValue();
    }

    private static BindType toBindType(String mode) {
        return switch (mode) {
            case "TRANSMITTER" -> BindType.BIND_TX;
            case "TRANSCEIVER" -> BindType.BIND_TRX;
            default -> BindType.BIND_RX;
        };
    }
}
