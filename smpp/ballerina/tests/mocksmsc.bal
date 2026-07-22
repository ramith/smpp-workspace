// Copyright (c) 2026. Thin wrapper over the test-only MockSmscBridge native jar.
import ballerina/jballerina.java;

# Opens the mock SMSC's listening socket. Does not block - use `mockSmscAcceptAndBind`
# separately (concurrently with the connector's own `'start()`) to complete a bind.
isolated function mockSmscOpenListener(int port) returns error? = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "openListener"
} external;

# Blocks until a connection arrives and the bind handshake completes. Run this as a
# concurrent `start` expression alongside the connector's own `'start()` - both sides of
# a bind block until the other is ready.
isolated function mockSmscAcceptAndBind(int bindTimeoutMillis) returns error? = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "acceptAndBind"
} external;

# Sends one data_sm PDU carrying `payload` (UTF-8 encoded) as a message_payload TLV.
isolated function mockSmscSendDataSm(string payload) returns error? = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "sendDataSm"
} external;

# Best-effort cleanup; safe to call even if `mockSmscOpenListener` was never called.
isolated function mockSmscClose() = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "close"
} external;
