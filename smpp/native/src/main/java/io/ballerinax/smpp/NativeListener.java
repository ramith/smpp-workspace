// Copyright (c) 2026. Native lifecycle for the SMPP listener (init/attach/start/stop).
package io.ballerinax.smpp;

import io.ballerina.runtime.api.Environment;
import io.ballerina.runtime.api.utils.StringUtils;
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
    private static final String NATIVE_STATE = "smpp.state";
    private static final String NATIVE_STATE_LOCK = "smpp.stateLock";
    private static final String NATIVE_REBIND_EXECUTOR = "smpp.rebindExecutor";

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

    public static Object initListener(Environment env, BObject listener, BMap<BString, Object> config) {
        listener.addNativeData(NATIVE_CONFIG, config);
        listener.addNativeData(NATIVE_DISPATCHER, new Dispatcher(env.getRuntime()));
        listener.addNativeData(NATIVE_STATE, new AtomicReference<>(ListenerState.INIT));
        listener.addNativeData(NATIVE_STATE_LOCK, new Object());
        // SESSION and REBIND_EXECUTOR are mutated after jsmpp threads exist, so they go
        // through write-once AtomicReference holders installed here at init rather than
        // via addNativeData post-init: the runtime's native-data map is a plain HashMap
        // with unsynchronized get/put, and a post-init put racing a jsmpp-thread get would
        // be a data race. All native-data writes now happen once, at init, single-threaded.
        listener.addNativeData(NATIVE_SESSION, new AtomicReference<SMPPSession>());
        listener.addNativeData(NATIVE_REBIND_EXECUTOR, new AtomicReference<ScheduledExecutorService>());
        env.getRuntime().registerListener(listener);
        return null;
    }

    public static Object attach(BObject listener, BObject service, Object name) {
        return switch (dispatcher(listener).attach(service)) {
            case ATTACHED -> null;
            case ALREADY_ATTACHED -> ModuleUtils.createError(
                    "cannot attach: a service is already attached to this listener; "
                            + "detach it before attaching another");
            case NO_REMOTE_METHODS -> ModuleUtils.createError(
                    "attached service does not implement any of the supported remote methods "
                            + "(onDeliverSm, onDataSm, onError)");
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
        SMPPSession session = new SMPPSession();
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
        // Must be set while the session is still CLOSED (i.e. before connectAndBind).
        session.setPduProcessorDegree(maxConcurrentDispatch);
        dispatcher.setAsync("ASYNC".equals(str(config, "responseMode")));

        // Per-attempt flags. `installed` gates the listener lambda: a CLOSED fired by a
        // rejected/failed bind (jsmpp self-closes inside connectAndBind) is start()'s
        // error, not an "unexpected drop". `dropReported` makes drop-reporting
        // exactly-once between the lambda and the manual post-install check below -
        // jsmpp swaps its state BEFORE running listeners (SMPPSessionContext.changeState),
        // so neither side can assume the other has or hasn't run yet.
        AtomicBoolean installed = new AtomicBoolean(false);
        AtomicBoolean dropReported = new AtomicBoolean(false);
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

        session.connectAndBind(host, port, bindType, systemId, password, systemType,
                TypeOfNumber.UNKNOWN, NumberingPlanIndicator.UNKNOWN, null);

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

    private static void onUnexpectedDrop(BObject listener, String description) {
        dispatcher(listener).dispatchError(description);
        scheduleRebind(listener, 1);
    }

    @SuppressWarnings("unchecked")
    private static void scheduleRebind(BObject listener, int attempt) {
        BMap<BString, Object> policy =
                (BMap<BString, Object>) config(listener).getMapValue(StringUtils.fromString("rebindPolicy"));
        long maxAttempts = policy.getIntValue(StringUtils.fromString("maxRebindAttempts"));
        if (maxAttempts == 0) {
            // Auto-rebind disabled; the onUnexpectedDrop call already reported the drop.
            return;
        }
        if (maxAttempts > 0 && attempt > maxAttempts) {
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
            awaitDrain(listener);           // also covers in-flight onError notifications
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
        while (dispatcher.inFlightCount() > 0 && System.currentTimeMillis() < deadline) {
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
