// Copyright (c) 2026. SMPP trigger connector — listener + service contract.

import ballerina/jballerina.java;

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
        check self.externInit(config);
    }

    isolated function externInit(ConnectionConfig config) returns error? = @java:Method {
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
    # for in-flight dispatches (including `onError` notifications) to finish, then unbinds
    # and closes the SMSC session. Idempotent: stopping an already-stopped (or
    # never-started) listener is a no-op. A stopped listener cannot be restarted.
    public isolated function gracefulStop() returns error? = @java:Method {
        'class: "io.ballerinax.smpp.NativeListener",
        name: "gracefulStop"
    } external;

    # Cancels any pending rebind attempt and immediately unbinds and closes the SMSC
    # session, without waiting for in-flight dispatches to finish. Idempotent: stopping
    # an already-stopped (or never-started) listener is a no-op. A stopped listener
    # cannot be restarted.
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
    if config.gracefulStopTimeout < 0d {
        return error Error(string `gracefulStopTimeout must not be negative, got ${config.gracefulStopTimeout}`);
    }
    check validateRebindPolicy(config.rebindPolicy);
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
