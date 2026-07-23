// Copyright (c) 2026. SMPP trigger connector — public API types.
import ballerina/crypto;

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
    # error becomes a negative `command_status` — `ESME_RX_T_APPN` (the SMPP v3.4
    # receiver "temporary app error" code) — telling the SMSC the message was not
    # handled; most SMSCs treat this as a signal to redeliver, so a transient failure
    # doesn't lose the message. (SMPP v3.4 does not itself mandate the SMSC's reaction
    # to a negative response.) A handler that fails *permanently* will therefore keep
    # being redelivered until the SMSC's own retry/validity limit — return successfully,
    # or dead-letter such messages yourself, rather than always erroring. Matches jsmpp's
    # documented listener contract, and bounds concurrency to `maxConcurrentDispatch`.
    SYNC,
    # Sends `command_status = ESME_ROK` immediately, without waiting for the service —
    # maximizing throughput at the cost of never reflecting a later service failure back
    # to the SMSC (the positive ack has already gone out); such a failure is instead
    # logged via `ballerina/log` at error level. `maxConcurrentDispatch` still bounds
    # concurrency here: it caps how many service invocations run at once, and PDUs
    # arriving beyond that limit are answered with `ESME_RTHROTTLED` rather than spawning
    # unbounded work. (This bounding is new: earlier releases documented ASYNC as ignoring
    # `maxConcurrentDispatch` entirely.)
    ASYNC
}

# Controls automatic rebinding to the SMSC after an unexpected session drop (e.g. the SMSC
# closes the connection, or a network failure occurs) — detected via jsmpp's
# `SessionStateListener`, not engaged for a user-initiated `gracefulStop`/`immediateStop`.
# The attached service's optional `onError` remote method is notified once for the initial
# drop, then again for *every* failed rebind attempt (not just the final one), and once
# more if rebinding is eventually exhausted after `maxRebindAttempts` — `onError` can fire
# repeatedly during an extended outage, not just once or twice.
public type RebindPolicy record {|
    # Delay before the first rebind attempt, in seconds. Must not be negative
    # (validated at `Listener` init).
    decimal initialRebindDelay = 1;
    # Maximum delay between rebind attempts, in seconds — caps the exponential backoff.
    # Must be >= `initialRebindDelay` (validated at `Listener` init).
    decimal maxRebindDelay = 60;
    # Multiplier applied to the delay after each failed attempt (exponential backoff).
    # Must be >= 1 (validated at `Listener` init) — values below 1 would shrink, not
    # back off.
    decimal backOffMultiplier = 2.0;
    # Maximum number of rebind attempts before giving up. `0` disables automatic rebinding
    # entirely (a drop still notifies `onError` once, but nothing is retried). `-1` retries
    # indefinitely. Other negative values are rejected at `Listener` init.
    int maxRebindAttempts = -1;
|};

# Configuration used to connect and bind to an SMSC.
public type ConnectionConfig record {|
    # SMSC host name or IP address.
    string host;
    # SMSC port. Defaults to the common SMPP port `2775`. Must be 1-65535 (validated
    # at `Listener` init).
    int port = 2775;
    # The `system_id` (username) used to bind.
    string systemId;
    # The password used to bind.
    string password;
    # The optional `system_type`. Empty by default.
    string systemType = "";
    # The bind mode. Defaults to `RECEIVER`.
    ListenerBindType bindType = RECEIVER;
    # Maximum number of inbound PDUs (`DELIVER_SM`/`DATA_SM`) dispatched to the attached
    # service concurrently — the concurrency limit on your service, in both `SYNC` and
    # `ASYNC` mode. When the SMSC sends PDUs faster than this limit drains, the excess is
    # answered immediately with `ESME_RTHROTTLED` so the SMSC backs off and retains the
    # message (SMPP is at-least-once — a NACK is not a drop). Inbound throughput is bounded
    # by design, not best-effort. The connector guarantees the SMSC's `enquire_link`
    # keepalive is always answered promptly even while every dispatch slot is busy — so a
    # slow service can no longer provoke the SMSC into dropping the link (in `SYNC` mode via
    # a reserved worker thread beyond this limit; in `ASYNC` mode handlers run on virtual
    # threads, so pool threads never block — see `docs/architecture.md`). Must be 1-1024
    # (validated at `Listener` init).
    int maxConcurrentDispatch = 3;
    # Controls when the `deliver_sm_resp`/`data_sm_resp` is sent back to the SMSC
    # relative to the attached service's processing of the PDU. Defaults to `SYNC`.
    ResponseMode responseMode = SYNC;
    # When `true`, a message with `data_coding` `0x00` (the SMSC default alphabet) is decoded
    # as **unpacked** GSM 03.38 (the 7-bit default alphabet plus its extension table) instead
    # of the default UTF-8 fallback. Opt-in and off by default, so it never changes decoding
    # for anyone relying on the existing UTF-8 behavior; enable it only against an SMSC that
    # actually sends the GSM 7-bit alphabet with one septet per octet (packed 7-bit is not
    # handled). Other `data_coding` values (IA5, Latin-1, UCS-2, …) are unaffected. The raw
    # `data_coding` is always available on `Sms.properties` for services that must decode a
    # different scheme themselves.
    boolean decodeGsm7 = false;
    # Maximum time `gracefulStop` waits for in-flight dispatches to the attached service to
    # finish before unbinding, in seconds. `immediateStop` does not wait at all.
    # Must not be negative (validated at `Listener` init).
    decimal gracefulStopTimeout = 30;
    # Controls automatic rebinding after an unexpected session drop. Defaults to retrying
    # indefinitely with exponential backoff; set `maxRebindAttempts: 0` to disable.
    RebindPolicy rebindPolicy = {};
    # How often the connector sends an `enquire_link` to the SMSC when the session is
    # otherwise idle, in seconds. This is the connector's own keepalive/liveness probe:
    # it keeps NAT/firewall state alive and is how the connector detects a silently dead
    # SMSC (an unanswered probe fails the link and drives `rebindPolicy`). It does NOT
    # control how long the SMSC waits before dropping the connector — that is the SMSC's
    # own policy; see `maxConcurrentDispatch` for why a busy service no longer trips it.
    # This field is in SECONDS (jsmpp's underlying knob is milliseconds). Must be 5-3600
    # (validated at `Listener` init); `0`/disabled is not allowed, since it would also
    # disable dead-link detection.
    decimal enquireLinkInterval = 60;
    # Maximum time the connect-and-bind handshake may take, in seconds — applied to the
    # initial `'start()` and to every automatic rebind attempt. It bounds the TCP connect
    # and the bind-response wait *separately*, so a fully stalled attempt (a black-holed
    # host that also never answers) can take up to ~2x this value. The rebind loop is
    # single-threaded, so this also caps how long one stalled attempt (e.g. a half-open
    # SMSC that accepts the TCP connection but never answers the bind) blocks the next
    # attempt. This field is in SECONDS. Must be 1-300 (validated at `Listener` init).
    decimal bindTimeout = 60;
    # Transport security. Absent (the default) means the SMSC connection is plaintext
    # TCP, exactly as before this field existed — pre-TLS configs are unaffected. A
    # `SecureSocket` yields a verified TLS connection; an `InsecureSocket` yields a TLS
    # connection with verification disabled (dev/test only — see its docs).
    # Network-terminated TLS in front of the SMSC remains the recommended production
    # topology where you control that boundary; this field is for the in-band case where
    # you don't.
    SecureSocket|InsecureSocket secureSocket?;
|};

# Transport-layer security (TLS) for the SMSC connection. Attach this to
# `ConnectionConfig.secureSocket` to wrap the SMPP session in TLS. Whenever a
# `SecureSocket` is supplied, the SMSC's server certificate is verified against `cert`,
# and (unless `verifyHostName` is turned off) its subject is matched against
# `ConnectionConfig.host`.
public type SecureSocket record {|
    # Trust anchor used to verify the SMSC's server certificate. Either a
    # `crypto:TrustStore` (a PKCS12/JKS truststore file plus its password) or a path to
    # a PEM-encoded CA certificate. Required: a TLS connection with no way to
    # authenticate the peer is not a supported `SecureSocket` — use `InsecureSocket` if
    # you knowingly want an unverified dev/test connection.
    crypto:TrustStore|string cert;
    # Client key material for mutual TLS (mTLS), when the SMSC authenticates the ESME by
    # client certificate: a `crypto:KeyStore` (PKCS12/JKS keystore plus password). Omit
    # for ordinary one-way, server-authenticated TLS, which is what most SMSCs use.
    crypto:KeyStore key?;
    # Enabled TLS protocol versions, as JSSE protocol names. Defaults to TLS 1.3 and
    # TLS 1.2. TLS 1.1 and below are rejected at listener init — this connector enforces
    # a TLS 1.2 floor and will not negotiate a downgraded, known-weak protocol even if
    # configured to.
    string[] protocolVersions = ["TLSv1.3", "TLSv1.2"];
    # Enabled cipher suites, as JSSE suite names. Empty (the default) uses the JDK's
    # default suite set for the negotiated protocol, which already excludes the
    # known-broken suites on a current JDK. Leave it empty unless your SMSC requires a
    # specific suite.
    string[] ciphers = [];
    # Whether the SMSC certificate's subject must match `ConnectionConfig.host` (the
    # CN/SAN hostname check). Leave `true` for production. Setting `false` relaxes ONLY
    # the hostname match; the certificate chain is still fully verified against `cert`.
    # Use it when a test SMSC presents a certificate issued for a name other than the
    # one you dial.
    boolean verifyHostName = true;
|};

# DEV/TEST ONLY — a TLS connection with server-certificate verification turned off
# entirely. Supplying this in place of a `SecureSocket` still encrypts the wire, but
# accepts ANY certificate the peer presents (self-signed, expired, wrong-host, or
# attacker-substituted). That defeats the authentication half of TLS and leaves the
# connection open to a man-in-the-middle, so it must never point at a production SMSC.
# It exists only so a local or self-signed test SMSC can be exercised without minting a
# truststore first — prefer a real `SecureSocket` with a `crypto:TrustStore` even in
# tests where you reasonably can. A warning is logged at listener init whenever this is
# in effect.
public type InsecureSocket record {|
    # Must be written explicitly as `true`; the field is required and its type admits no
    # other value. The deliberate friction is the point: verification can never be
    # switched off by a defaulted field or a stray `false` left in a copied config —
    # reaching this state takes naming `InsecureSocket` and spelling the flag out.
    true disableSslVerification;
|};

# A received short message (DELIVER_SM / DATA_SM) surfaced to the service.
public type Sms record {|
    # Source address (sender MSISDN / short code).
    string sourceAddr;
    # Destination address (receiver).
    string destAddr;
    # The message payload, decoded according to the PDU's `data_coding` where that encoding
    # is unambiguous (IA5/ASCII, Latin-1, UCS2); falls back to UTF-8 otherwise — see
    # `shortMessageBytes` if you need to decode a GSM 7-bit default-alphabet payload (or
    # anything else the UTF-8 fallback gets wrong) yourself; `properties.dataCoding` tells
    # you when that's needed.
    string shortMessage;
    # The same payload as `shortMessage`, as raw undecoded bytes — captured after SMPP's
    # `message_payload`-over-`short_message` precedence rule is resolved but before any
    # charset decoding. Use this together with `properties.dataCoding` to decode a payload
    # yourself; re-decoding `shortMessage` is not a reliable way to recover the original
    # bytes once a lossy UTF-8 fallback has already been applied to them.
    byte[] shortMessageBytes = [];
    # `true` when this PDU is an SMSC delivery receipt (DLR) rather than a mobile-originated message.
    boolean deliveryReceipt = false;
    # Protocol metadata not promoted to a typed field above: `dataCoding` (`int`, raw
    # `data_coding` value), `sourceAddrTon`/`sourceAddrNpi`/`destAddrTon`/`destAddrNpi`
    # (`int`, address type-of-number/numbering-plan-indicator), `esmClass` (`int`, the raw
    # `esm_class` byte), and `udhi` (`boolean`, User Data Header Indicator — set for
    # concatenated/binary short messages, which this connector does not reassemble).
    map<anydata> properties = {};
|};

# The distinct error type raised by the SMPP connector. Returned from `Listener` init on
# invalid configuration, from `'start()` on a failed connect/bind, and passed to a service's
# `onError` method on an unexpected session drop. Match it with `err is smpp:Error` to
# distinguish connector errors from other errors in your handler.
public type Error distinct error;
