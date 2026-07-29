// Copyright (c) 2026. SMPP trigger connector — public API types.
import ballerina/crypto;

# The SMPP bind mode. Reflects the full set of modes defined by the SMPP spec;
# `ConnectionConfig.bindType` narrows this to `ListenerBindType` (see there for why
# TRANSMITTER is excluded). Sending is done from the listener's session via
# `Caller.submit`, so a standalone transmitter bind has no role here.
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
    # Maximum time `gracefulStop` waits for in-flight work to finish before unbinding, in
    # seconds. The drain covers dispatches to the attached service AND in-flight
    # `Caller.submit` calls (including from non-handler code holding a `Caller`); submits
    # stay legal for the whole drain window - a reply-style service's in-flight replies
    # complete rather than being dropped on shutdown. After the drain, `gracefulStop`
    # also runs a ≤2s reservation sweep (correctness, not grace: it closes the race with
    # a submit that reserved its slot just before the cutoff) - so `0` here means "no
    # drain wait", with the sweep still applying. `immediateStop` skips both. Either
    # stop's unbind/close is itself bounded (~4s worst case) by a force-close watchdog,
    # even against an unresponsive peer. One caveat for both flavours: a submit already
    # awaiting its `submit_sm_resp` when the close lands is NOT woken (the underlying
    # library has no fail-pending-on-close) - mid-write it fails immediately with
    # `LINK_DOWN`, but once parked it completes only at `transactionTimeout`, with
    # `LINK_DOWN` and `possiblySubmitted: true`, so a submitting strand can outlive the
    # stop by up to that long. Must not be negative (validated at `Listener` init).
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
    # initial ``'start()`` and to every automatic rebind attempt. It bounds the TCP connect
    # and the bind-response wait *separately*, so a fully stalled attempt (a black-holed
    # host that also never answers) can take up to ~2x this value. The rebind loop is
    # single-threaded, so this also caps how long one stalled attempt (e.g. a half-open
    # SMSC that accepts the TCP connection but never answers the bind) blocks the next
    # attempt. This field is in SECONDS. Must be 1-300 (validated at `Listener` init).
    decimal bindTimeout = 60;
    # How long a `Caller.submit` waits for the SMSC's `submit_sm_resp`, in seconds.
    #
    # This bounds ONLY the requests this connector issues on your behalf (the
    # submit-family operations). The session's internal housekeeping — the `unbind_resp`
    # wait during `gracefulStop`/`immediateStop`, the `enquire_link_resp` wait that
    # detects a silently dead link, and the reader thread's exit drain — is bounded
    # separately at a short internal timer (~2s, jsmpp's own historical default for
    # exactly those paths), so raising this value does NOT slow stops or dead-link
    # detection. (jsmpp itself has one shared timer; the connector splits it — see
    # `ConnectorSession` in the native layer — and additionally bounds the whole close
    # choreography with a ~4s force-close watchdog, because the unbind write itself is
    # untimed against a pathological peer.) Worst-case `gracefulStop` ≈
    # `gracefulStopTimeout` + ~2s (sweep) + ~4s (bounded close); `immediateStop` ≈ ~4s;
    # silent-peer detection stays ≈ `enquireLinkInterval` + 2s, regardless of this
    # setting. The one exception: a submit already awaiting its response when a stop
    # closes the session completes only at THIS timeout (with `LINK_DOWN`,
    # `possiblySubmitted: true`) — the single place this value can stretch past a stop.
    #
    # The default is 30s rather than jsmpp's own 2s. Two seconds is too short for a
    # `submit_sm` under load, and a timed-out submit is the worst outcome the send path
    # has: SMPP gives no way to tell "the SMSC never got it" from "the SMSC got it and the
    # response was slow", so retrying may duplicate a message the subscriber already
    # received (`FailureMode.TIMEOUT_DELIVERY_UNKNOWN`). Prefer waiting to guessing.
    #
    # This field is in SECONDS (jsmpp's underlying knob is milliseconds). Must be 1-300
    # (validated at `Listener` init).
    decimal transactionTimeout = 30;
    # Transport security. Absent (the default) means the SMSC connection is plaintext
    # TCP, exactly as before this field existed — pre-TLS configs are unaffected. A
    # `SecureSocket` yields a verified TLS connection; an `InsecureSocket` yields a TLS
    # connection with verification disabled (dev/test only — see its docs).
    # Network-terminated TLS in front of the SMSC remains the recommended production
    # topology where you control that boundary; this field is for the in-band case where
    # you don't.
    SecureSocket|InsecureSocket secureSocket?;
    # Default source address for messages this ESME submits — the short code or sender ID
    # the subscriber sees. `OutboundSms.sourceAddr` overrides it per message.
    #
    # Typed as a plain `Address`, deliberately **not** the `string|Address` union used on
    # `OutboundSms`: this is the deployment-configured field, and on a union the compiler
    # collapses three precise `Config.toml` diagnostics into one unhelpful "incompatible
    # types" message.
    #
    # An empty `value` means "send no source address", which is spec-legal — the SMSC then
    # supplies one — so it is **not** rejected at `Listener` init.
    Address sourceAddr = {value: ""};
|};

# An SMPP address: the digits plus the two fields that say how to read them. SMPP carries
# `ton`/`npi` alongside every address, and getting them wrong is a common cause of an SMSC
# silently misrouting an otherwise correct MSISDN.
#
# Where a plain `string` is accepted instead of this record, it is shorthand for
# `{value: <the string>}` — i.e. the defaults below.
public type Address record {|
    # The address itself. For `TON_INTERNATIONAL` this is E.164 **without** a leading `+`
    # (the `ton` field is what carries that meaning on the wire). Empty means "absent",
    # which is spec-legal for a source address — and when it is empty, the connector
    # sends TON/NPI as Unknown/Unknown regardless of the fields below (§4.4.1: a NULL
    # address and its TON/NPI move together).
    string value;
    # Type of number. Defaults to `TON_INTERNATIONAL`, the right answer for an ordinary
    # MSISDN; short codes and alphanumeric sender IDs need an explicit value.
    Ton ton = TON_INTERNATIONAL;
    # Numbering plan. Defaults to `NPI_ISDN` (E.163/E.164), which pairs with the `ton`
    # default above.
    Npi npi = NPI_ISDN;
|};

# Type of number, per SMPP v3.4 §5.2.5.
#
# Member names are prefixed because Ballerina enum members are **module-scoped string
# constants**: unprefixed, `UNKNOWN` would collide with the already-published
# `DeliveryReceiptStatus.UNKNOWN` and `NATIONAL` would collide with `Npi`, producing build
# warnings — one of them retroactively on a shipped doc comment.
#
# Each member's value equals its member name, so what a `Config.toml` author writes is
# exactly what the docs show (owner decision, 2026-07-29 — this also keeps jsmpp's
# identifier spelling out of the published contract). The native layer strips the
# `TON_` prefix and resolves the remainder against `org.jsmpp.bean.TypeOfNumber`.
public enum Ton {
    # `TypeOfNumber.UNKNOWN` (0) — let the SMSC decide.
    TON_UNKNOWN = "TON_UNKNOWN",
    # `TypeOfNumber.INTERNATIONAL` (1) — E.164 without a leading `+`.
    TON_INTERNATIONAL = "TON_INTERNATIONAL",
    # `TypeOfNumber.NATIONAL` (2).
    TON_NATIONAL = "TON_NATIONAL",
    # `TypeOfNumber.NETWORK_SPECIFIC` (3).
    TON_NETWORK_SPECIFIC = "TON_NETWORK_SPECIFIC",
    # `TypeOfNumber.SUBSCRIBER_NUMBER` (4).
    TON_SUBSCRIBER_NUMBER = "TON_SUBSCRIBER_NUMBER",
    # `TypeOfNumber.ALPHANUMERIC` (5) — an alphanumeric sender ID rather than digits.
    TON_ALPHANUMERIC = "TON_ALPHANUMERIC",
    # `TypeOfNumber.ABBREVIATED` (6) — short codes.
    TON_ABBREVIATED = "TON_ABBREVIATED"
}

# Numbering plan indicator, per SMPP v3.4 §5.2.6. Prefixed, value-equals-member-name,
# and prefix-stripped natively — for the same reasons as `Ton`.
public enum Npi {
    # `NumberingPlanIndicator.UNKNOWN` (0).
    NPI_UNKNOWN = "NPI_UNKNOWN",
    # `NumberingPlanIndicator.ISDN` (1) — E.163/E.164, the usual choice for an MSISDN.
    NPI_ISDN = "NPI_ISDN",
    # `NumberingPlanIndicator.DATA` (3) — X.121.
    NPI_DATA = "NPI_DATA",
    # `NumberingPlanIndicator.TELEX` (4) — F.69.
    NPI_TELEX = "NPI_TELEX",
    # `NumberingPlanIndicator.LAND_MOBILE` (6) — E.212.
    NPI_LAND_MOBILE = "NPI_LAND_MOBILE",
    # `NumberingPlanIndicator.NATIONAL` (8).
    NPI_NATIONAL = "NPI_NATIONAL",
    # `NumberingPlanIndicator.PRIVATE` (9).
    NPI_PRIVATE = "NPI_PRIVATE",
    # `NumberingPlanIndicator.ERMES` (10).
    NPI_ERMES = "NPI_ERMES",
    # `NumberingPlanIndicator.INTERNET` (14) — IP.
    NPI_INTERNET = "NPI_INTERNET",
    # `NumberingPlanIndicator.WAP` (18) — WAP client id.
    NPI_WAP = "NPI_WAP"
}

# How an outbound message's text is encoded, and hence the `data_coding` it is sent with.
#
# Only the three schemes this connector also **decodes** precisely are offered. The GSM
# 03.38 7-bit default alphabet (`data_coding 0x00`) is **not** available for sending: it
# needs a packed-septet encoder, which jsmpp does not provide, and adding protocol logic
# jsmpp lacks is outside this connector's remit. Use a `BinarySms` with an explicit
# `dataCoding` if you need to put such a payload on the wire yourself.
public enum Encoding {
    # IA5/ASCII — `data_coding 0x01`. 7-bit US-ASCII only; anything else is rejected.
    ASCII,
    # Latin-1 — `data_coding 0x03`. The default: covers English, Afrikaans and most
    # Western European text. Note some carriers/aggregators accept only `0x00`
    # (their provisioned default) and `0x08`, and may reject or transcode `0x03`; for
    # pure-ASCII text, `ASCII` produces byte-identical payloads under `data_coding
    # 0x01` — a zero-cost switch if your SMSC dislikes `0x03`.
    LATIN1,
    # UCS-2 big-endian — `data_coding 0x08`. Any script, at half the characters per PDU.
    UCS2
}

# Whether, and when, the SMSC should return a delivery receipt for a submitted message,
# per SMPP v3.4 §5.2.17.
#
# Three members, not four: jsmpp also defines `SUCCESS` (`0x03`), but its own javadoc marks
# that as introduced in SMPP 5.0, and `xxxxxx11` is *reserved* in the v3.4 table this
# connector implements.
public enum DeliveryReceiptRequest {
    # `xxxxxx00` — no receipt. The SMPP default.
    NONE,
    # `xxxxxx01` — a receipt on final delivery or final failure.
    ON_SUCCESS_OR_FAILURE,
    # `xxxxxx10` — a receipt only if delivery ultimately fails.
    ON_FAILURE_ONLY
}

# Fields shared by every outbound message shape. Not used directly — submit takes an
# `OutboundSms`, i.e. `TextSms` or `BinarySms`.
public type OutboundBase record {|
    # Recipient. A plain `string` is shorthand for an international ISDN address. ASCII
    # only: SMPP address fields are octet-counted C-octet strings, and this connector
    # rejects anything a platform charset could inflate on the wire.
    string|Address destAddr;
    # Sender. Omitted means `ConnectionConfig.sourceAddr`, which is the usual arrangement:
    # the short code is a property of the binding, not of each message. ASCII only (see
    # `destAddr`) — this includes `TON_ALPHANUMERIC` sender IDs.
    string|Address sourceAddr?;
    # Whether to ask the SMSC for a delivery receipt. A receipt arrives later at
    # `onDeliverSm` with `deliveryReceipt` set, not as part of the submit.
    DeliveryReceiptRequest registeredDelivery = NONE;
    # SMPP `service_type`. Empty (the default) means the SMSC's default service. ASCII only.
    string serviceType = "";
    # SMPP `validity_period`: how long the SMSC should keep trying. Omitted means the
    # SMSC's own default. When set, it must be EXACTLY 16 characters in the §7.1.1 time
    # format `YYMMDDhhmmsstnnp` — absolute, e.g. `240115143000000+` (UTC+offset), or
    # relative, e.g. `000000020000000R` (2 hours). Any other length or shape is rejected
    # locally before anything reaches the wire.
    string validityPeriod?;
|};

# A text message: the connector encodes `shortMessage` per `encoding` and stamps the
# matching `data_coding` on the wire. This is the shape almost every service wants.
public type TextSms record {|
    *OutboundBase;
    # The message text, encoded per `encoding`. Must not be empty: `sm_length = 0` means
    # "payload is in the message_payload TLV" (§5.2.21), which this connector never sets,
    # so an empty body is rejected locally instead of drawing `ESME_RINVMSGLEN`.
    string shortMessage;
    # How to encode `shortMessage`.
    Encoding encoding = LATIN1;
|};

# A pre-encoded payload, sent verbatim: the escape hatch for anything `Encoding` cannot
# express. The connector does not validate, split, or reassemble what you put in it.
public type BinarySms record {|
    *OutboundBase;
    # The payload octets, sent verbatim. Must not be empty (see `TextSms.shortMessage`).
    byte[] shortMessageBytes;
    # The raw `data_coding` byte describing how `shortMessageBytes` is encoded (0-255).
    # Required — the SMSC and handset can only interpret the payload through it.
    int dataCoding;
    # Sets the UDHI bit (`esm_class` bit 6, `0x40`): declares that `shortMessageBytes`
    # STARTS with a User Data Header — required by §5.2.12 whenever a UDH is present
    # (concatenation, WAP push, port addressing per 3GPP TS 23.040, where the first
    # octet is the UDH length). The connector does not validate the UDH structure:
    # setting `udhi` without a well-formed UDH at the front of the payload is a user
    # error nothing here can detect, and leaving it `false` WITH a UDH makes the
    # handset render the header octets as visible garbage text. Independent of
    # `registeredDelivery` and of the receipt bits the SMSC sets on inbound messages.
    boolean udhi = false;
|};

# A message to submit to the SMSC (`submit_sm`).
#
# A union rather than one record with optional fields: text and binary payloads have
# different required fields (`encoding` belongs only to text, `dataCoding`/`udhi` only
# to binary), and the union makes the wrong combinations unrepresentable at compile
# time instead of runtime-rejected. In-line record literals pick their member by shape:
# `{destAddr, shortMessage: "hi"}` is a `TextSms`.
public type OutboundSms TextSms|BinarySms;

# The outcome of a successful `submit`.
#
# `messageId` is required rather than optional: an SMSC that accepts a `submit_sm` must
# return one (§4.4.2), and typing it optional would push a nil check onto every caller for
# a case a conforming SMSC cannot produce. A non-conforming SMSC returning an empty id
# yields an empty string here — visible, rather than silently absent.
public type SubmitResult record {|
    # The SMSC's `message_id`. Correlate a later delivery receipt against this — see
    # `Sms.receiptedMessageId` for the caveat about which field actually carries it back.
    string messageId;
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
    # The `receipted_message_id` TLV (0x001E) when the SMSC attached one — the spec's only
    # GUARANTEED correlation key (§5.3.2.12) between a delivery receipt and the
    # `SubmitResult.messageId` your submit returned. The Appendix-B body's `id:` field
    # (`receipt.id`) is vendor specific and can differ in radix; prefer this when present.
    # `()` when the receipt carries no TLV (many SMSCs only populate the body).
    string? receiptedMessageId = ();
    # Protocol metadata not promoted to a typed field above: `dataCoding` (`int`, raw
    # `data_coding` value), `sourceAddrTon`/`sourceAddrNpi`/`destAddrTon`/`destAddrNpi`
    # (`int`, address type-of-number/numbering-plan-indicator), `esmClass` (`int`, the raw
    # `esm_class` byte), and `udhi` (`boolean`, User Data Header Indicator — set for
    # concatenated/binary short messages, which this connector does not reassemble).
    map<anydata> properties = {};
    # The parsed delivery receipt, present only when this PDU is an SMSC delivery receipt
    # (`deliveryReceipt == true`) AND jsmpp could parse the Appendix-B receipt body. A
    # delivery receipt whose body doesn't conform to the format leaves this `()` — so
    # `deliveryReceipt == true` does NOT guarantee a non-nil `receipt`; the raw receipt text
    # is always available on `shortMessage`/`shortMessageBytes` regardless. `()` for ordinary
    # mobile-originated messages.
    DeliveryReceipt? receipt = ();
|};

# The final delivery state reported in an SMSC delivery receipt — the seven-character `stat:`
# token defined in SMPP v3.4 Appendix B, as parsed by jsmpp. Only these eight spec-defined
# tokens are represented; a delivery receipt whose `stat:` is a non-standard vendor token
# fails jsmpp's parse entirely (leaving `DeliveryReceipt` `()`), so this enum never carries an
# unknown value — read the raw `stat:` token from `Sms.shortMessage` if your SMSC is exotic.
public enum DeliveryReceiptStatus {
    # In transit; not yet in a final state.
    ENROUTE,
    # Delivered to the handset.
    DELIVRD,
    # Validity period expired before delivery.
    EXPIRED,
    # Deleted by the SMSC.
    DELETED,
    # Undeliverable — a terminal failure.
    UNDELIV,
    # Accepted by the SMSC on the recipient's behalf (no further delivery attempt).
    ACCEPTD,
    # State unknown to the SMSC.
    UNKNOWN,
    # Rejected by the SMSC.
    REJECTD
}

# A parsed SMSC delivery receipt (DLR), as produced by jsmpp's Appendix-B receipt parser
# (`DeliverSm.getShortMessageAsDeliveryReceipt`). This is a faithful surface of jsmpp's
# `DeliveryReceipt` — the connector adds no interpretation of its own. Every field is optional
# because real SMSCs diverge from the Appendix-B layout (omitting/reordering fields), so
# "field absent" is a routine, meaningful outcome. The full raw receipt is always available on
# `Sms.shortMessage`.
public type DeliveryReceipt record {|
    # The SMSC's message id for the original submission (Appendix-B `id:`). Appendix B is
    # "SMSC vendor specific": some SMSCs emit this in a different radix (hex vs decimal)
    # than the `message_id` they returned in the `submit_sm_resp`, so it is NOT a
    # guaranteed correlation key — `Sms.receiptedMessageId` (the §5.3.2.12 TLV) is.
    string id?;
    # The `sub:` count — messages originally submitted (usually 1). Advisory: many SMSCs
    # omit or zero-fill it.
    int submitted?;
    # The `dlvrd:` count — messages delivered (usually 1). Advisory, as `submitted`.
    int delivered?;
    # The `submit date:` field — the original submission time, as the ten-digit `yyMMddHHmm`
    # wire value (a receipt that carries seconds is normalized to `yyMMddHHmm`, matching
    # jsmpp's own receipt date format). It carries NO timezone on the wire, so it is surfaced
    # as a string rather than a `time` value (converting would assume the SMSC's local zone,
    # which is unknown, and present false precision). Parse it against your SMSC's documented
    # timezone.
    string submitDate?;
    # The `done date:` field — the final-state time; same format and same no-timezone caveat
    # as `submitDate`.
    string doneDate?;
    # The final delivery state, from the Appendix-B `stat:` token. See `DeliveryReceiptStatus`.
    DeliveryReceiptStatus finalStatus?;
    # The `err:` field — a network/SMSC-specific error code (typically three characters), NOT
    # standardized by SMPP; present on a failure when the SMSC populates it. (Named
    # `errorCode` because `error` is a reserved Ballerina identifier.)
    string errorCode?;
    # The `Text:` field — a short (≤20 char per Appendix B) echo of the original message.
    # Advisory only; use `Sms.shortMessage` for the full receipt body.
    string text?;
|};

# How a `submit` failed, mapped from the jsmpp exception that surfaced it. The six
# members deliberately partition by WHAT THE CALLER SHOULD DO, not by exception class:
public enum FailureMode {
    # The SMSC answered the submit with a negative `command_status` — it received the
    # request and said no. `ErrorDetail.commandStatus` carries the exact status. The
    # message was NOT accepted; whether a retry can succeed depends on the status
    # (throttling: yes, after backing off; invalid destination: no).
    REJECTED,
    # No response arrived within `transactionTimeout`. The worst outcome the send path
    # has: SMPP gives no way to tell "the SMSC never got it" from "the SMSC accepted it
    # and the response was slow or lost" — so retrying MAY DELIVER A DUPLICATE to the
    # subscriber. Decide per use case; for billing-relevant traffic, prefer reconciling
    # via delivery receipts over blind retry.
    TIMEOUT_DELIVERY_UNKNOWN,
    # The link is the problem: it died while sending or waiting, OR it was already
    # down/rebinding when the submit was attempted (one bucket for one operational
    # condition — owner decision, 2026-07-29). For a mid-flight death the message may
    # or may not have reached the SMSC (`ErrorDetail.possiblySubmitted` tells you
    # which); for an already-down link nothing was sent. If `rebindPolicy` is enabled,
    # retry once rebound; when rebinding is disabled or exhausted the submit fails with
    # `LINK_ABANDONED` instead, so this member always means "worth retrying later".
    LINK_DOWN,
    # The link is down and this connector will NOT try to restore it: `rebindPolicy`
    # was disabled (`maxRebindAttempts: 0`) at the time of the drop, or its attempts
    # are exhausted. Unlike `LINK_DOWN`, retrying against this `Listener` is futile for
    # the rest of its life — the only remedy is a new `Listener`. Nothing was sent.
    # (Names the decision THIS connector made; the SMSC itself may be healthy.)
    LINK_ABANDONED,
    # This connector refused to send: the request failed local validation (oversize,
    # unencodable character, bad field) or the lifecycle/config does not permit a
    # submit (not started, stopped, RECEIVER bind). Nothing reached the wire; fix the
    # request or the configuration. (A down/rebinding LINK is `LINK_DOWN`, not this.)
    INVALID_REQUEST,
    # jsmpp raised something outside the four categories above (a malformed response,
    # an unexpected runtime failure inside the client). Not safely classifiable;
    # treat like `TIMEOUT_DELIVERY_UNKNOWN` for retry purposes.
    PROTOCOL_ERROR
}

# The detail record carried by `Error`. Deliberately **open** with all-optional fields:
# closed would turn every `e.detail()["anything"]` a 1.0.x user wrote into a compile
# error, and openness costs typed reads nothing (D3). Fields are populated on `submit`
# failures; errors from other paths (config validation, start, drops) may carry none.
public type ErrorDetail record {
    # Which way the submit failed — the field to branch retry logic on.
    FailureMode failureMode?;
    # The SMPP `command_status` from the negative response, when `failureMode` is
    # `REJECTED`. Compare against SMPP v3.4 §5.1.3 (e.g. 0x00000058 = ESME_RTHROTTLED).
    int commandStatus?;
    # Whether the message may already have reached the SMSC — the single most useful
    # bit for retry logic. `false`: retrying CANNOT duplicate the message (it either
    # provably never left this connector, or the SMSC received it and definitively
    # refused it). `true`: the SMSC may have accepted it (response lost or unusable,
    # or the link died mid-flight), so a retry MAY DELIVER A DUPLICATE to the
    # subscriber. Populated on every `submit` failure.
    boolean possiblySubmitted?;
};

# The distinct error type raised by the SMPP connector. Returned from `Listener` init on
# invalid configuration, from `'start()` on a failed connect/bind, from `Caller.submit`
# on a failed send (with `ErrorDetail` populated — see `FailureMode`), and passed to a
# service's `onError` method on an unexpected session drop. Match it with
# `err is smpp:Error` to distinguish connector errors from other errors in your handler.
#
# Known 1.0.x compile break, accepted and recorded (D3): once the detail type names any
# field, `error smpp:Error("m", myOwnField = 42)` no longer compiles. `e.detail()["k"]`
# reads keep compiling because `ErrorDetail` is open.
public type Error distinct error<ErrorDetail>;
