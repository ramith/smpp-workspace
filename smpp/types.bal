// Copyright (c) 2026. SMPP trigger connector — public API types.

# The SMPP bind mode. Reflects the full set of modes defined by the SMPP spec;
# `ConnectionConfig.bindType` narrows this to `ListenerBindType` since this connector
# is a receive-only trigger (see `ListenerBindType`).
public enum BindType {
    # Receiver bind — the session only receives inbound PDUs (MO messages, delivery receipts).
    RECEIVER,
    # Transmitter bind — send only. Per the SMPP spec, a transmitter-bound session is never
    # sent `DELIVER_SM`/`DATA_SM` by the SMSC, so it cannot drive this trigger's callbacks.
    TRANSMITTER,
    # Transceiver bind — a single session that both sends and receives.
    TRANSCEIVER
}

# The bind modes usable with this listener. Excludes `BindType:TRANSMITTER` at the type
# level — a transmitter-bound session structurally cannot receive `DELIVER_SM`/`DATA_SM`
# (see `BindType`), so attempting to configure it is rejected at compile time rather than
# connecting successfully and then never invoking the attached service.
public type ListenerBindType RECEIVER|TRANSCEIVER;

# Controls the timing of the `deliver_sm_resp`/`data_sm_resp` sent back to the SMSC.
public enum ResponseMode {
    # Waits for the service's remote method to return before responding. A returned
    # error becomes a negative `command_status` (`ESME_RSYSERR`) via jsmpp's
    # `ProcessRequestException`, so the SMSC can retry. Matches jsmpp's documented
    # listener contract, and bounds concurrency to `maxConcurrentDispatch`.
    SYNC,
    # Sends `command_status = ESME_ROK` immediately, without waiting for the service.
    # Maximizes throughput and ignores `maxConcurrentDispatch` as a concurrency limit
    # (dispatch is unbounded), but a later service failure is never reflected back to
    # the SMSC — only visible via `ballerina/log`.
    ASYNC
}

# Controls automatic rebinding to the SMSC after an unexpected session drop (e.g. the SMSC
# closes the connection, or a network failure occurs) — detected via jsmpp's
# `SessionStateListener`, not engaged for a user-initiated `gracefulStop`/`immediateStop`.
# Every drop, rebound or not, notifies the attached service's optional `onError` remote
# method first; a rebind attempt (or the final give-up after `maxRebindAttempts`) notifies
# it again.
public type RebindPolicy record {|
    # Delay before the first rebind attempt, in seconds.
    decimal initialRebindDelay = 1;
    # Maximum delay between rebind attempts, in seconds — caps the exponential backoff.
    decimal maxRebindDelay = 60;
    # Multiplier applied to the delay after each failed attempt (exponential backoff).
    decimal backOffMultiplier = 2.0;
    # Maximum number of rebind attempts before giving up. `0` disables automatic rebinding
    # entirely (a drop still notifies `onError` once, but nothing is retried). `-1` retries
    # indefinitely.
    int maxRebindAttempts = -1;
|};

# Configuration used to connect and bind to an SMSC.
public type ConnectionConfig record {|
    # SMSC host name or IP address.
    string host;
    # SMSC port. Defaults to the common SMPP port `2775`.
    int port = 2775;
    # The `system_id` (username) used to bind.
    string systemId;
    # The password used to bind.
    string password;
    # The optional `system_type`. Empty by default.
    string systemType = "";
    # The bind mode. Defaults to `RECEIVER`.
    ListenerBindType bindType = RECEIVER;
    # Maximum number of inbound PDUs (`DELIVER_SM`/`DATA_SM`) dispatched to the
    # attached service concurrently. Each dispatch blocks until the service's
    # remote method returns, so this is also the concurrency limit on your
    # service. When the SMSC sends PDUs faster than this limit drains, jsmpp
    # queues them (up to its internal queue capacity) and signals the SMSC to
    # throttle — inbound throughput is bounded by design, not best-effort.
    int maxConcurrentDispatch = 3;
    # Controls when the `deliver_sm_resp`/`data_sm_resp` is sent back to the SMSC
    # relative to the attached service's processing of the PDU. Defaults to `SYNC`.
    ResponseMode responseMode = SYNC;
    # Maximum time `gracefulStop` waits for in-flight dispatches to the attached service to
    # finish before unbinding, in seconds. `immediateStop` does not wait at all.
    decimal gracefulStopTimeout = 30;
    # Controls automatic rebinding after an unexpected session drop. Defaults to retrying
    # indefinitely with exponential backoff; set `maxRebindAttempts: 0` to disable.
    RebindPolicy rebindPolicy = {};
|};

# A received short message (DELIVER_SM / DATA_SM) surfaced to the service.
public type Sms record {|
    # Source address (sender MSISDN / short code).
    string sourceAddr;
    # Destination address (receiver).
    string destAddr;
    # The message payload, decoded according to the PDU's `data_coding` where that encoding
    # is unambiguous (IA5/ASCII, Latin-1, UCS2); falls back to UTF-8 otherwise — see
    # `properties.dataCoding` if you need to decode a GSM 7-bit default-alphabet payload
    # yourself.
    string shortMessage;
    # `true` when this PDU is an SMSC delivery receipt (DLR) rather than a mobile-originated message.
    boolean deliveryReceipt = false;
    # Protocol metadata not promoted to a typed field above: `dataCoding` (`int`, raw
    # `data_coding` value), `sourceAddrTon`/`sourceAddrNpi`/`destAddrTon`/`destAddrNpi`
    # (`int`, address type-of-number/numbering-plan-indicator), `esmClass` (`int`, the raw
    # `esm_class` byte), and `udhi` (`boolean`, User Data Header Indicator — set for
    # concatenated/binary short messages, which this connector does not reassemble).
    map<anydata> properties = {};
|};

# The distinct error type raised by the SMPP connector.
public type Error distinct error;
