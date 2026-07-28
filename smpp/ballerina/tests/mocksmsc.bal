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

# Sends one deliver_sm carrying exactly `shortMessage` as raw short_message bytes (no
# charset encoding mock-side), so a test can put a precise on-wire byte sequence — e.g.
# unpacked GSM 03.38 — in front of the connector's decoder.
#
# + mockId - the mock's handle
# + connectionId - the connection handle from `mockSmscAwaitNextBind`
# + shortMessage - the exact short_message bytes to put on the wire
# + dataCoding - the raw data_coding byte value to stamp on the PDU
isolated function mockSmscSendDeliverSmRaw(int mockId, int connectionId, byte[] shortMessage,
        int dataCoding) returns error? = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "sendDeliverSmRaw"
} external;

# Sends a deliver_sm flagged as an SMSC delivery receipt, carrying `receiptText` as its
# short_message body — for exercising the connector's receipt-parsing path end to end.
#
# + mockId - the mock's handle
# + connectionId - the connection handle from `mockSmscAwaitNextBind`
# + receiptText - the Appendix-B delivery-receipt body to put in short_message
# + return - an `error` only on misuse (unknown handle) or send failure
isolated function mockSmscSendDeliveryReceipt(int mockId, int connectionId, string receiptText)
        returns error? = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "sendDeliveryReceipt"
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

# Lowers the connection's enquire_link timer so the mock (as SMSC) probes the connector's
# liveness frequently. Combined with a short transaction timer, an unanswered probe makes
# the mock close the session — the self-inflicted-drop path the SYNC keepalive test guards.
#
# + mockId - the mock's handle
# + connectionId - the connection handle from `mockSmscAwaitNextBind`
# + timeoutMillis - the new enquire_link timer (how often the mock probes when idle)
# + return - an `error` only on misuse (unknown handle)
isolated function mockSmscSetEnquireLinkTimer(int mockId, int connectionId, int timeoutMillis)
        returns error? = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "setEnquireLinkTimer"
} external;

# Opens a TCP "black hole": a server that accepts connections but never answers the bind.
# A connector pointed here completes the TCP connect yet must time out its bind-response
# wait per `bindTimeout` (rather than jsmpp's hardcoded 60s). Returns a handle for cleanup.
#
# + port - the port to listen on
# + return - the black hole's handle, or an `error` if the socket can't be opened
isolated function mockSmscOpenBlackHole(int port) returns int|error = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "openBlackHole"
} external;

# Closes a black-hole server and drops any sockets it is holding.
#
# + blackHoleId - the black hole's handle from `mockSmscOpenBlackHole`
isolated function mockSmscCloseBlackHole(int blackHoleId) = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "closeBlackHole"
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

// --- submit_sm capture (Sprint 8, item 10) -----------------------------------------
//
// Before Sprint 8 the mock set no ServerMessageReceiverListener at all, so jsmpp answered
// every submit_sm with ESME_RX_R_APPN and no submit test could pass regardless of
// connector correctness. Captures are FIFO *per connection*, so concurrent submits on
// different links never interleave into one queue.

# Blocks until the next `submit_sm` arrives on this connection, and returns a handle to
# the captured PDU for the field accessors below. FIFO per connection.
#
# + mockId - the mock's handle
# + connectionId - the connection handle from `mockSmscAwaitNextBind`
# + timeoutMillis - how long to wait for a submit
# + return - a handle to the captured `submit_sm`, or an `error` on timeout/unknown handle
isolated function mockSmscAwaitNextSubmit(int mockId, int connectionId, int timeoutMillis)
        returns int|error = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "awaitNextSubmit"
} external;

# How many captured submits are still unread on this connection — for asserting that a
# handler sent exactly one message and no more.
#
# + mockId - the mock's handle
# + connectionId - the connection handle
# + return - the number of unread captured submits (0 if the connection is unknown)
isolated function mockSmscPendingSubmitCount(int mockId, int connectionId) returns int = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "pendingSubmitCount"
} external;

# The captured `short_message`, decoded with the charset matching the PDU's own
# `data_coding`. Use `mockSmscSubmitShortMessageBytes` when the exact octets are the thing
# under test — this decode is a convenience, not the assertion surface for encoding tests.
#
# + submitId - the handle from `mockSmscAwaitNextSubmit`
# + return - the decoded message text
isolated function mockSmscSubmitShortMessage(int submitId) returns string = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "submitShortMessage"
} external;

# The raw, undecoded `short_message` octets — the assertion surface for encoding tests.
#
# + submitId - the handle from `mockSmscAwaitNextSubmit`
# + return - the octets exactly as they arrived on the wire
isolated function mockSmscSubmitShortMessageBytes(int submitId) returns byte[] = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "submitShortMessageBytes"
} external;

# + submitId - the handle from `mockSmscAwaitNextSubmit`
# + return - the PDU's `source_addr`
isolated function mockSmscSubmitSourceAddr(int submitId) returns string = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "submitSourceAddr"
} external;

# + submitId - the handle from `mockSmscAwaitNextSubmit`
# + return - the PDU's `destination_addr`
isolated function mockSmscSubmitDestAddr(int submitId) returns string = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "submitDestAddr"
} external;

# + submitId - the handle from `mockSmscAwaitNextSubmit`
# + return - the PDU's `service_type` (empty string when unset)
isolated function mockSmscSubmitServiceType(int submitId) returns string = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "submitServiceType"
} external;

# + submitId - the handle from `mockSmscAwaitNextSubmit`
# + return - the PDU's `validity_period` (empty string means "SMSC default")
isolated function mockSmscSubmitValidityPeriod(int submitId) returns string = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "submitValidityPeriod"
} external;

# The PDU's `esm_class`, unsigned. A wrong value here is invisible in a happy-path test
# yet changes SMSC routing and billing, so it is worth asserting explicitly.
#
# + submitId - the handle from `mockSmscAwaitNextSubmit`
# + return - the `esm_class` byte as 0-255
isolated function mockSmscSubmitEsmClass(int submitId) returns int = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "submitEsmClass"
} external;

# + submitId - the handle from `mockSmscAwaitNextSubmit`
# + return - the `data_coding` byte as 0-255
isolated function mockSmscSubmitDataCoding(int submitId) returns int = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "submitDataCoding"
} external;

# + submitId - the handle from `mockSmscAwaitNextSubmit`
# + return - the `registered_delivery` byte as 0-255
isolated function mockSmscSubmitRegisteredDelivery(int submitId) returns int = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "submitRegisteredDelivery"
} external;

# + submitId - the handle from `mockSmscAwaitNextSubmit`
# + return - the `source_addr_ton` as 0-255
isolated function mockSmscSubmitSourceAddrTon(int submitId) returns int = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "submitSourceAddrTon"
} external;

# + submitId - the handle from `mockSmscAwaitNextSubmit`
# + return - the `source_addr_npi` as 0-255
isolated function mockSmscSubmitSourceAddrNpi(int submitId) returns int = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "submitSourceAddrNpi"
} external;

# + submitId - the handle from `mockSmscAwaitNextSubmit`
# + return - the `dest_addr_ton` as 0-255
isolated function mockSmscSubmitDestAddrTon(int submitId) returns int = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "submitDestAddrTon"
} external;

# + submitId - the handle from `mockSmscAwaitNextSubmit`
# + return - the `dest_addr_npi` as 0-255
isolated function mockSmscSubmitDestAddrNpi(int submitId) returns int = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "submitDestAddrNpi"
} external;

# Makes every subsequent `submit_sm` answer with this `command_status` instead of
# succeeding; the client sees it as a negative response. Pass 0 to restore normal
# behaviour.
#
# + mockId - the mock's handle
# + commandStatus - the SMPP `command_status` to answer with, or 0 to disable
isolated function mockSmscSetSubmitFailure(int mockId, int commandStatus) = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "setSubmitFailure"
} external;

# Delays every subsequent `submit_sm_resp`. Deliberately blocks the mock's PDU-processor
# thread — that is what a slow SMSC does, and what `transactionTimeout` has to survive.
#
# + mockId - the mock's handle
# + millis - delay in milliseconds, or 0 to disable
isolated function mockSmscSetSubmitDelay(int mockId, int millis) = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "setSubmitDelay"
} external;

# When enabled, `submit_sm_resp` carries an empty `message_id` — spec-legal, and leaves
# the client with nothing to correlate a later receipt against.
#
# + mockId - the mock's handle
# + enabled - whether to answer with an empty message id
isolated function mockSmscSetSubmitEmptyMessageId(int mockId, boolean enabled) = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "setSubmitEmptyMessageId"
} external;

# Sends a delivery receipt carrying a `receipted_message_id` TLV (0x001E) alongside the
# Appendix-B body. The TLV is the spec's only *guaranteed* correlation key (§5.3.2.12) —
# the body's `id:` is vendor specific — so a test can deliberately make the two disagree.
# An empty `receiptedMessageId` sends no TLV, matching `mockSmscSendDeliveryReceipt`.
#
# + mockId - the mock's handle
# + connectionId - the connection handle
# + receiptText - the Appendix-B receipt body
# + receiptedMessageId - the TLV value, or `""` for no TLV
# + return - an `error` if the receipt cannot be sent
isolated function mockSmscSendDeliveryReceiptWithTlv(int mockId, int connectionId,
        string receiptText, string receiptedMessageId) returns error? = @java:Method {
    'class: "io.ballerinax.smpp.test.MockSmscBridge",
    name: "sendDeliveryReceiptWithTlv"
} external;
