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
    private static final String NATIVE_BOUND = "smpp.bound";
    private static final String NATIVE_STOPPING = "smpp.stopping";
    private static final String NATIVE_REBIND_EXECUTOR = "smpp.rebindExecutor";

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
        listener.addNativeData(NATIVE_BOUND, new AtomicBoolean(false));
        listener.addNativeData(NATIVE_STOPPING, new AtomicBoolean(false));
        env.getRuntime().registerListener(listener);
        return null;
    }

    public static Object attach(BObject listener, BObject service, Object name) {
        if (!dispatcher(listener).setService(service)) {
            return ModuleUtils.createError(
                    "attached service does not implement any of the supported remote methods "
                            + "(onDeliverSm, onDataSm, onError)");
        }
        return null;
    }

    public static Object detach(BObject listener, BObject service) {
        Dispatcher dispatcher = dispatcher(listener);
        if (service == dispatcher.getService()) {
            dispatcher.setService(null);
        }
        return null;
    }

    public static Object start(BObject listener) {
        try {
            bind(listener, config(listener));
            return null;
        } catch (Exception e) {
            return ModuleUtils.createError("failed to connect/bind to SMSC: " + e.getMessage());
        }
    }

    /**
     * Connects and binds to the SMSC, (re)configures the dispatcher, and registers a session
     * state listener to detect an unexpected drop. Used for both the initial {@code start()}
     * and every rebind attempt.
     */
    private static void bind(BObject listener, BMap<BString, Object> config) throws Exception {
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

        AtomicBoolean bound = bound(listener);
        bound.set(false);
        session.addSessionStateListener((newState, oldState, source) -> {
            if (newState == SessionState.CLOSED && bound.compareAndSet(true, false)
                    && !stopping(listener).get()) {
                onUnexpectedDrop(listener, oldState);
            }
        });

        session.connectAndBind(host, port, bindType, systemId, password, systemType,
                TypeOfNumber.UNKNOWN, NumberingPlanIndicator.UNKNOWN, null);
        listener.addNativeData(NATIVE_SESSION, session);
        bound.set(true);
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

    private static void onUnexpectedDrop(BObject listener, SessionState oldState) {
        dispatcher(listener).dispatchError("SMPP session closed unexpectedly (was " + oldState + ")");
        scheduleRebind(listener, 1);
    }

    @SuppressWarnings("unchecked")
    private static void scheduleRebind(BObject listener, int attempt) {
        if (stopping(listener).get()) {
            return;
        }
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

        rebindExecutor(listener).schedule(() -> attemptRebind(listener, attempt),
                (long) (delaySeconds * 1000), TimeUnit.MILLISECONDS);
    }

    private static void attemptRebind(BObject listener, int attempt) {
        if (stopping(listener).get()) {
            return;
        }
        try {
            bind(listener, config(listener));
            // Success - bind() already stored the new session and marked it bound.
        } catch (Exception e) {
            dispatcher(listener).dispatchError("rebind attempt " + attempt + " failed: " + e.getMessage());
            scheduleRebind(listener, attempt + 1);
        }
    }

    public static Object gracefulStop(BObject listener) {
        stopping(listener).set(true);
        shutdownRebindExecutor(listener);
        awaitDrain(listener);
        return closeSession(listener);
    }

    public static Object immediateStop(BObject listener) {
        stopping(listener).set(true);
        shutdownRebindExecutor(listener);
        return closeSession(listener);
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
        SMPPSession session = (SMPPSession) listener.getNativeData(NATIVE_SESSION);
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

    private static AtomicBoolean bound(BObject listener) {
        return (AtomicBoolean) listener.getNativeData(NATIVE_BOUND);
    }

    private static AtomicBoolean stopping(BObject listener) {
        return (AtomicBoolean) listener.getNativeData(NATIVE_STOPPING);
    }

    private static synchronized ScheduledExecutorService rebindExecutor(BObject listener) {
        Object existing = listener.getNativeData(NATIVE_REBIND_EXECUTOR);
        if (existing != null) {
            return (ScheduledExecutorService) existing;
        }
        ScheduledExecutorService executor = Executors.newSingleThreadScheduledExecutor();
        listener.addNativeData(NATIVE_REBIND_EXECUTOR, executor);
        return executor;
    }

    private static void shutdownRebindExecutor(BObject listener) {
        Object existing = listener.getNativeData(NATIVE_REBIND_EXECUTOR);
        if (existing != null) {
            ((ScheduledExecutorService) existing).shutdownNow();
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
