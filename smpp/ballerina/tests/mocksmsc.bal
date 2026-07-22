// Copyright (c) 2026. Thin wrapper over the test-only MockSmscBridge native jar.
import ballerina/jballerina.java;

# Opens a mock SMSC (listening socket + background accept-loop) and returns its handle.
# Multiple mocks (and multiple accepted connections per mock) can coexist — nothing is a
# singleton, so tests never collide through shared static state.
#
# + port - the port to listen on
# + return - the mock's handle, or an `error` if the socket can't be opened
isolated function mockSmscOpen(int port) returns int|error = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "openMock"
} external;

# Configures the mock to only accept binds carrying exactly these credentials, rejecting
# others with the distinguishing SMPP status (invalid-systemId vs invalid-password).
# Call before the connector's `'start()`. Without this, the mock accepts any credentials.
#
# + mockId - the mock's handle from `mockSmscOpen`
# + systemId - the only accepted system_id
# + password - the only accepted password
isolated function mockSmscExpectCredentials(int mockId, string systemId, string password) = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "expectCredentials"
} external;

# Blocks until the next bind attempt on this mock resolves. The accept-loop runs in the
# background, so — unlike Sprint 0's single-shot bridge — this does NOT need to run
# concurrently with the connector's `'start()`; calling it right after works too. Running
# it concurrently (via `start`) is still fine and slightly faster.
#
# + mockId - the mock's handle
# + timeoutMillis - how long to wait for a bind attempt
# + return - the accepted connection's handle, or an `error` carrying the rejection/timeout
isolated function mockSmscAwaitNextBind(int mockId, int timeoutMillis) returns int|error = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "awaitNextBind"
} external;

# Sends one deliver_sm on the given connection, blocking until its deliver_sm_resp
# arrives; a negative response (e.g. the attached service's handler returned an error in
# SYNC mode) surfaces here as an `error`. `messagePayload` empty means "no message_payload
# TLV" — pass a non-empty value to exercise the payload-over-short_message precedence.
# Text is charset-encoded on the Java side per `dataCoding`, mirroring the connector's
# own decoder.
#
# + mockId - the mock's handle
# + connectionId - the connection handle from `mockSmscAwaitNextBind`
# + shortMessage - the short_message field's text
# + messagePayload - message_payload TLV text; empty string = omit the TLV entirely
# + dataCoding - the raw data_coding byte value to stamp on the PDU
isolated function mockSmscSendDeliverSm(int mockId, int connectionId, string shortMessage,
        string messagePayload, int dataCoding) returns error? = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "sendDeliverSm"
} external;

# Sends one data_sm on the given connection, blocking until its data_sm_resp arrives.
# `messagePayload` empty means "no message_payload TLV at all" (DATA_SM has no
# short_message field, so that exercises the connector's empty-payload fallback).
#
# + mockId - the mock's handle
# + connectionId - the connection handle from `mockSmscAwaitNextBind`
# + messagePayload - message_payload TLV text; empty string = omit the TLV entirely
# + dataCoding - the raw data_coding byte value to stamp on the PDU
isolated function mockSmscSendDataSm(int mockId, int connectionId, string messagePayload,
        int dataCoding) returns error? = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "sendDataSm"
} external;

# Closes the mock's connections, listener, and pools. Safe to call with a handle that
# was already closed.
#
# + mockId - the mock's handle
isolated function mockSmscClose(int mockId) = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "closeMock"
} external;

# Abruptly severs an accepted connection: closes its socket with NO unbind exchange
# (jsmpp `AbstractSession.close()` — docs/qa-strategy.md §3.6). From the connector's side
# this is indistinguishable from a network failure. The connection handle is dead afterwards.
#
# + mockId - the mock's handle
# + connectionId - the connection handle from `mockSmscAwaitNextBind`
# + return - an `error` only on misuse (unknown/already-severed connection handle)
isolated function mockSmscSever(int mockId, int connectionId) returns error? = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "sever"
} external;

# Cleanly unbinds an accepted connection from the mock's (SMSC's) side: sends an unbind
# PDU, blocks until the connector answers unbind_resp, then closes. This returning without
# error is itself an assertion that the unbind exchange happened — the distinguishing
# feature vs `mockSmscSever`.
#
# + mockId - the mock's handle
# + connectionId - the connection handle from `mockSmscAwaitNextBind`
# + return - an `error` if the unbind exchange fails or times out
isolated function mockSmscPeerUnbind(int mockId, int connectionId) returns error? = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "peerUnbind"
} external;

# Stops the mock accepting new connections (closes the server socket) while leaving
# already-accepted connections alive — so rebind attempts fail deterministically
# (connection refused). `mockSmscClose` afterwards is still required and still safe.
#
# + mockId - the mock's handle
isolated function mockSmscStopAccepting(int mockId) = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "stopAccepting"
} external;

# When enabled, every subsequent bind on this mock is accepted and the connection is then
# immediately closed (no unbind) — the accepted-then-instantly-dropped pattern the
# bound-race soak needs. Each such bind still produces a `mockSmscAwaitNextBind` outcome
# (so cycles can be counted), but the returned connection handle is dead.
#
# + mockId - the mock's handle
# + enabled - `true` to drop every accepted bind immediately; `false` to restore normal accepts
isolated function mockSmscSetCloseAfterAccept(int mockId, boolean enabled) = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "setCloseAfterAccept"
} external;

# Raises the connection's jsmpp transaction timer (default 2000 ms) so a blocking
# `mockSmscSendDeliverSm` can outwait a deliberately slow SYNC handler.
#
# + mockId - the mock's handle
# + connectionId - the connection handle from `mockSmscAwaitNextBind`
# + timeoutMillis - the new transaction timer
# + return - an `error` only on misuse (unknown handle)
isolated function mockSmscSetTransactionTimer(int mockId, int connectionId, int timeoutMillis)
        returns error? = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "setTransactionTimer"
} external;

# Opens a TLS-terminating mock SMSC presenting the cert in `serverKeystorePath` (PKCS12).
# The mock verifies nothing about the client (server-auth TLS); use `mockSmscOpenMutualTls`
# for mTLS. All other mock operations work identically against the returned handle.
#
# + port - the port to listen on
# + serverKeystorePath - path to the server PKCS12 keystore (cert + private key)
# + serverKeystorePassword - the keystore password
# + return - the mock's handle, or an `error` if the socket/keystore can't be opened
isolated function mockSmscOpenTls(int port, string serverKeystorePath,
        string serverKeystorePassword) returns int|error = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "openMockTls"
} external;

# Opens an mTLS mock: presents `serverKeystorePath`'s cert AND requires the connecting
# client to present a cert trusted by `clientTruststorePath` (SSLServerSocket
# setNeedClientAuth). A client presenting no/untrusted cert fails the handshake.
#
# + port - the port to listen on
# + serverKeystorePath - server PKCS12 keystore (cert + key)
# + serverKeystorePassword - server keystore password
# + clientTruststorePath - PKCS12 truststore of client cert(s) the mock will accept
# + clientTruststorePassword - client truststore password
# + return - the mock's handle, or an `error`
isolated function mockSmscOpenMutualTls(int port, string serverKeystorePath,
        string serverKeystorePassword, string clientTruststorePath,
        string clientTruststorePassword) returns int|error = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "openMockMutualTls"
} external;
