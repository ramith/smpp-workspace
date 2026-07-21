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
    public isolated function init(ConnectionConfig config) returns error? {
        check self.externInit(config);
    }

    isolated function externInit(ConnectionConfig config) returns error? = @java:Method {
        'class: "io.ballerinax.smpp.NativeListener",
        name: "initListener"
    } external;

    # Attaches a service to this listener. Invoked automatically by the runtime
    # for `service ... on listener { }` declarations.
    public isolated function attach(Service s, string[]|string? name = ()) returns error? = @java:Method {
        'class: "io.ballerinax.smpp.NativeListener",
        name: "attach"
    } external;

    # Detaches a previously attached service.
    public isolated function detach(Service s) returns error? = @java:Method {
        'class: "io.ballerinax.smpp.NativeListener",
        name: "detach"
    } external;

    # Connects and binds to the SMSC, and begins receiving PDUs.
    public isolated function 'start() returns error? = @java:Method {
        'class: "io.ballerinax.smpp.NativeListener",
        name: "start"
    } external;

    # Cancels any pending rebind attempt, waits up to `ConnectionConfig.gracefulStopTimeout`
    # for in-flight dispatches to the attached service to finish, then unbinds and closes
    # the SMSC session.
    public isolated function gracefulStop() returns error? = @java:Method {
        'class: "io.ballerinax.smpp.NativeListener",
        name: "gracefulStop"
    } external;

    # Cancels any pending rebind attempt and immediately unbinds and closes the SMSC
    # session, without waiting for in-flight dispatches to finish.
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
