// Copyright (c) 2026. SMPP trigger connector — listener + service contract.

import ballerina/crypto;
import ballerina/jballerina.java;
import ballerina/log;

# The SMPP trigger listener. Owns a jsmpp `SMPPSession`, binds to the SMSC and
# dispatches inbound PDUs to the attached service's remote methods.
#
# A user attaches a service with the `service ... on listener { }` syntax and
# implements one or more of:
# - `remote function onDeliverSm(smpp:Sms sms) returns error?`
# - `remote function onDataSm(smpp:Sms sms) returns error?`
# - `remote function onError(error err) returns error?` — notified on an unexpected
#   session drop; see `RebindPolicy`.
public isolated class Listener {

    # Creates a new SMPP listener for the given SMSC connection configuration.
    #
    # + config - the connection/bind configuration
    # + return - an `Error` if `config` fails validation (see the field docs on
    #   `ConnectionConfig`/`RebindPolicy` for the exact bounds checked), or if the
    #   native listener setup fails
    public isolated function init(ConnectionConfig config) returns error? {
        check validateConfig(config);
        check self.externInit(config, resolveTls(config.secureSocket));
    }

    isolated function externInit(ConnectionConfig config, ResolvedTls? tls) returns error? = @java:Method {
        'class: "io.ballerinax.smpp.NativeListener",
        name: "initListener"
    } external;

    # Attaches a service to this listener. Invoked automatically by the runtime
    # for `service ... on listener { }` declarations. One service per listener:
    # attaching a second service is rejected — `detach` the first one to swap.
    #
    # + s - the service to attach
    # + name - unused; part of the standard listener contract
    # + return - an `Error` if `s` implements none of `onDeliverSm`, `onDataSm`,
    #   `onError`, or if a service is already attached
    public isolated function attach(Service s, string[]|string? name = ()) returns error? = @java:Method {
        'class: "io.ballerinax.smpp.NativeListener",
        name: "attach"
    } external;

    # Detaches a previously attached service. A no-op if `s` is not the service
    # currently attached to this listener.
    #
    # + s - the service to detach
    # + return - never returns an error today; typed `error?` per the listener contract
    public isolated function detach(Service s) returns error? = @java:Method {
        'class: "io.ballerinax.smpp.NativeListener",
        name: "detach"
    } external;

    # Connects and binds to the SMSC, and begins receiving PDUs. Calling this on an
    # already-started listener is rejected; so is calling it on a stopped listener
    # (a stopped listener cannot be restarted — create a new one). A *failed* start
    # (e.g. bind rejected, host unreachable) leaves the listener startable again.
    #
    # + return - an `Error` if already started, stopped, or the connect/bind fails
    public isolated function 'start() returns error? = @java:Method {
        'class: "io.ballerinax.smpp.NativeListener",
        name: "start"
    } external;

    # Cancels any pending rebind attempt, waits up to `ConnectionConfig.gracefulStopTimeout`
    # for in-flight dispatches (including `onError` notifications) and submits to finish,
    # runs a ≤2s reservation sweep, then unbinds and closes the SMSC session — the
    # unbind/close bounded at ~4s worst case by a force-close watchdog, even against an
    # unresponsive peer. Whole-call worst case ≈ `gracefulStopTimeout` + ~2s + ~4s.
    # Idempotent: stopping an already-stopped (or never-started) listener is a no-op.
    # A stopped listener cannot be restarted.
    public isolated function gracefulStop() returns error? = @java:Method {
        'class: "io.ballerinax.smpp.NativeListener",
        name: "gracefulStop"
    } external;

    # Cancels any pending rebind attempt and immediately unbinds and closes the SMSC
    # session, without waiting for in-flight dispatches or submits (no drain, no sweep);
    # the unbind/close is bounded at ~4s worst case by a force-close watchdog. An
    # in-flight submit is NOT woken by the close: mid-write it fails immediately with
    # `LINK_DOWN`; already awaiting its `submit_sm_resp`, it completes only at
    # `transactionTimeout`, with `LINK_DOWN` and `possiblySubmitted: true`. Idempotent:
    # stopping an already-stopped (or never-started) listener is a no-op. A stopped
    # listener cannot be restarted.
    public isolated function immediateStop() returns error? = @java:Method {
        'class: "io.ballerinax.smpp.NativeListener",
        name: "immediateStop"
    } external;
}

# The SMPP service contract. Implemented by the user with at least one of the supported
# remote methods (`onDeliverSm`, `onDataSm`, `onError`). Enforcement of the available
# methods is delegated to the native dispatcher at runtime.
public type Service distinct service object {
};

# Validates `config` against the bounds documented on `ConnectionConfig`/`RebindPolicy`,
# before any native listener setup happens.
#
# + config - the configuration to validate
# + return - an `Error` describing the first violated constraint, or `()` if valid
isolated function validateConfig(ConnectionConfig config) returns error? {
    if config.port < 1 || config.port > 65535 {
        return error Error(string `port must be between 1 and 65535, got ${config.port}`);
    }
    if config.maxConcurrentDispatch < 1 {
        return error Error(string `maxConcurrentDispatch must be at least 1, got ${config.maxConcurrentDispatch}`);
    }
    if config.maxConcurrentDispatch > 1024 {
        // In SYNC each unit is one OS worker thread (plus the keepalive reserve), so an
        // accidental huge value would exhaust threads; cap it at a generous ceiling.
        return error Error(string `maxConcurrentDispatch must not exceed 1024, got ${config.maxConcurrentDispatch}`);
    }
    if config.enquireLinkInterval < 5d {
        // 0/negative would disable dead-link detection (jsmpp maps it to an infinite
        // socket read timeout); sub-5s risks colliding with the internal response window
        // and floods the SMSC with keepalives.
        return error Error(string `enquireLinkInterval must be at least 5 seconds, got ${config.enquireLinkInterval}`);
    }
    if config.enquireLinkInterval > 3600d {
        // Upper bound doubles as a unit-confusion guard: this field is SECONDS, while
        // jsmpp's knob is milliseconds - someone typing 60000 would otherwise get ~16h.
        return error Error(string `enquireLinkInterval must not exceed 3600 seconds - note this field is in SECONDS, not milliseconds, got ${config.enquireLinkInterval}`);
    }
    if config.bindTimeout < 1d {
        // A sub-second bind timeout would time out nearly every real TLS+bind handshake.
        return error Error(string `bindTimeout must be at least 1 second, got ${config.bindTimeout}`);
    }
    if config.bindTimeout > 300d {
        // Same seconds-vs-milliseconds unit-confusion guard as enquireLinkInterval.
        return error Error(string `bindTimeout must not exceed 300 seconds - note this field is in SECONDS, not milliseconds, got ${config.bindTimeout}`);
    }
    if config.transactionTimeout < 1d {
        // Sub-second would time out responses the SMSC is merely slow to send. This same
        // value also bounds enquire_link, so a tiny value would flap an otherwise healthy
        // link as well as breaking submits.
        return error Error(string `transactionTimeout must be at least 1 second, got ${config.transactionTimeout}`);
    }
    if config.transactionTimeout > 300d {
        // Same seconds-vs-milliseconds unit-confusion guard as enquireLinkInterval.
        return error Error(string `transactionTimeout must not exceed 300 seconds - note this field is in SECONDS, not milliseconds, got ${config.transactionTimeout}`);
    }
    if config.gracefulStopTimeout < 0d {
        return error Error(string `gracefulStopTimeout must not be negative, got ${config.gracefulStopTimeout}`);
    }
    check validateRebindPolicy(config.rebindPolicy);
    SecureSocket|InsecureSocket? secureSocket = config.secureSocket;
    if secureSocket is SecureSocket {
        check validateSecureSocket(secureSocket);
    }
    // An InsecureSocket needs no validation (its one field admits only `true`); the loud
    // warning for it is logged at resolve time, once per listener init.
}

# Validates a `SecureSocket` against this connector's TLS floor.
#
# + secureSocket - the TLS configuration to validate
# + return - an `Error` describing the first violated constraint, or `()` if valid
isolated function validateSecureSocket(SecureSocket secureSocket) returns error? {
    crypto:TrustStore|string cert = secureSocket.cert;
    if cert is string {
        if cert.trim().length() == 0 {
            return error Error("secureSocket.cert path must not be empty");
        }
    } else if cert.path.trim().length() == 0 {
        return error Error("secureSocket.cert.path (truststore path) must not be empty");
    }
    if secureSocket.protocolVersions.length() == 0 {
        return error Error("secureSocket.protocolVersions must enable at least one TLS version");
    }
    foreach string v in secureSocket.protocolVersions {
        if v != "TLSv1.2" && v != "TLSv1.3" {
            // Rejects TLSv1.1, TLSv1, SSLv3, SSLv2Hello, and typos alike: this connector
            // enforces a TLS 1.2 floor rather than letting the JVM maybe-negotiate a
            // known-weak protocol.
            return error Error(string `secureSocket.protocolVersions: '${v}' is not allowed - this connector negotiates only TLSv1.2 and TLSv1.3`);
        }
    }
}

# Validates a `RebindPolicy` against its documented bounds.
#
# + policy - the policy to validate
# + return - an `Error` describing the first violated constraint, or `()` if valid
isolated function validateRebindPolicy(RebindPolicy policy) returns error? {
    if policy.initialRebindDelay < 0d {
        return error Error(string `rebindPolicy.initialRebindDelay must not be negative, got ${policy.initialRebindDelay}`);
    }
    if policy.maxRebindDelay < policy.initialRebindDelay {
        return error Error(string `rebindPolicy.maxRebindDelay (${policy.maxRebindDelay}) must be >= initialRebindDelay (${policy.initialRebindDelay})`);
    }
    if policy.backOffMultiplier < 1d {
        return error Error(string `rebindPolicy.backOffMultiplier must be at least 1, got ${policy.backOffMultiplier}`);
    }
    if policy.maxRebindAttempts < -1 {
        // Only -1 means "infinite"; other negatives are almost certainly typos (e.g. -3
        // intending 3) and would otherwise silently behave as infinite too.
        return error Error(string `rebindPolicy.maxRebindAttempts must be -1 (infinite), 0 (disabled), or positive, got ${policy.maxRebindAttempts}`);
    }
}

# Internal, flat resolution of the `SecureSocket|InsecureSocket?` union — the native layer
# reads fixed fields off this record with no union-tag inspection (empty string = absent).
type ResolvedTls record {|
    # `true` only for `InsecureSocket`: chain verification is disabled entirely.
    boolean trustAll;
    # Truststore file path, when `cert` was a `crypto:TrustStore`; else empty.
    string trustStorePath;
    # Truststore password, when `cert` was a `crypto:TrustStore`; else empty.
    string trustStorePassword;
    # PEM CA-certificate path, when `cert` was a plain path string; else empty.
    string trustCertPath;
    # Keystore file path, when mTLS `key` was supplied; else empty.
    string keyStorePath;
    # Keystore password, when mTLS `key` was supplied; else empty.
    string keyStorePassword;
    # Validated (TLS 1.2 floor) protocol versions to enable.
    string[] protocolVersions;
    # Cipher suites to enable; empty = JDK defaults.
    string[] ciphers;
    # Whether to enable JSSE endpoint identification (hostname verification).
    boolean verifyHostName;
|};

# Collapses the public TLS union into `ResolvedTls` (or `()` for plaintext), logging the
# loud dev-only warning when an `InsecureSocket` is in effect.
#
# + secureSocket - the configured union, if any
# + return - the flat resolution, or `()` when the connection should stay plaintext
# Routes a native-layer dispatch error through `ballerina/log`. Invoked from the Java
# `Dispatcher` via `Runtime.callFunction` as the fallback when a service has no `onError`
# method, when an `onError` handler itself errors, or for an ASYNC handler failure that can't
# be reflected back to the SMSC — so these land in the application's log rather than on stderr.
#
# + message - a description of where/why the error occurred
# + err - the error to log alongside `message`
isolated function logDispatchError(string message, error err) {
    log:printError(message, 'error = err);
}

isolated function resolveTls(SecureSocket|InsecureSocket? secureSocket) returns ResolvedTls? {
    if secureSocket is () {
        return ();
    }
    if secureSocket is InsecureSocket {
        log:printWarn("SMPP TLS: server-certificate verification is DISABLED (InsecureSocket). "
                + "The connection is encrypted but NOT authenticated and is open to "
                + "man-in-the-middle. Never use this against a production SMSC.");
        return {
            trustAll: true,
            trustStorePath: "",
            trustStorePassword: "",
            trustCertPath: "",
            keyStorePath: "",
            keyStorePassword: "",
            protocolVersions: ["TLSv1.3", "TLSv1.2"],
            ciphers: [],
            verifyHostName: false
        };
    }
    string trustStorePath = "";
    string trustStorePassword = "";
    string trustCertPath = "";
    crypto:TrustStore|string cert = secureSocket.cert;
    if cert is crypto:TrustStore {
        trustStorePath = cert.path;
        trustStorePassword = cert.password;
    } else {
        trustCertPath = cert;
    }
    string keyStorePath = "";
    string keyStorePassword = "";
    crypto:KeyStore? key = secureSocket?.key;
    if key is crypto:KeyStore {
        keyStorePath = key.path;
        keyStorePassword = key.password;
    }
    return {
        trustAll: false,
        trustStorePath,
        trustStorePassword,
        trustCertPath,
        keyStorePath,
        keyStorePassword,
        protocolVersions: secureSocket.protocolVersions,
        ciphers: secureSocket.ciphers,
        verifyHostName: secureSocket.verifyHostName
    };
}
