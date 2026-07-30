# SMPP listener (trigger) connector

A Ballerina **listener/trigger** that receives inbound SMPP PDUs — mobile-originated
(MO) SMS and delivery receipts — from a Short Message Service Centre (SMSC). It binds
to the SMSC as an **ESME** in receiver or transceiver mode and dispatches each inbound
message to your service, wrapping the Java library [`org.jsmpp:jsmpp`](https://jsmpp.org/)
through Ballerina's Java interoperability.

The connector speaks **SMPP v3.4** (it binds with `interface_version` `0x34`) and is
**bidirectional**: a service may declare an `smpp:Caller` parameter and reply on the same
session with `caller->submit(...)` (`submit_sm`), receiving the SMSC's `message_id` to
correlate delivery receipts against. Sending requires `bindType: TRANSCEIVER`; a
`RECEIVER` bind stays receive-only.

Correlating a receipt back to the submit that caused it needs care: match the
`message_id` you got from `submit` against **`Sms.receiptedMessageId`** (the
`receipted_message_id` TLV, §5.3.2.12) — that is the only field SMPP guarantees for this.
`Sms.receipt.id`, parsed out of the receipt's human-readable body, is best-effort and
SMSCs vary in how (and whether) they populate it.

## Quickstart

```ballerina
import ramith/smpp;
import ballerina/io;

configurable string systemId = ?;
configurable string password = ?;

listener smpp:Listener smsListener = check new ({
    host: "localhost",
    port: 2775,
    systemId,
    password,
    bindType: smpp:RECEIVER
});

service on smsListener {
    remote function onDeliverSm(smpp:Sms sms) returns error? {
        io:println(string `SMS from ${sms.sourceAddr}: ${sms.shortMessage}`);
    }
}
```

Supply the credentials via a `Config.toml` next to your `Ballerina.toml` (never
hardcode them in source):

```toml
systemId = "your-system-id"
password = "your-password"
```

## Examples

Runnable, end-to-end examples live in the
[`examples/`](https://github.com/ramith/smpp-workspace/tree/main/examples) directory of
the source repository. Each runs against a bundled mock SMSC, so no carrier account is
needed:

- [receive-sms](https://github.com/ramith/smpp-workspace/tree/main/examples/receive-sms)
  — the minimal listener: bind and log every inbound message.
- [delivery-receipts](https://github.com/ramith/smpp-workspace/tree/main/examples/delivery-receipts)
  — parse DLRs, correlate by `receiptedMessageId`, and branch on `finalStatus`.
- [two-way-sms](https://github.com/ramith/smpp-workspace/tree/main/examples/two-way-sms)
  — reply on the same session via `smpp:Caller` (`TRANSCEIVER` + `ASYNC`): route
  mobile-originated messages by keyword and confirm `STOP` opt-outs with a receipted,
  receipt-correlated reply.
- [resilient-listener](https://github.com/ramith/smpp-workspace/tree/main/examples/resilient-listener)
  — tune `rebindPolicy` and surface unexpected drops via `onError`.
- [tls-smsc](https://github.com/ramith/smpp-workspace/tree/main/examples/tls-smsc)
  — bind over verified TLS with a truststore.

## The service contract

Attach one service implementing at least one of these remote methods:

- `remote function onDeliverSm(smpp:Sms sms) returns error?` — an inbound `deliver_sm`
  (an MO short message, or a delivery receipt when `sms.deliveryReceipt` is `true`).
- `remote function onDataSm(smpp:Sms sms) returns error?` — an inbound `data_sm` (the
  alternative MO transfer PDU; its payload always arrives in `message_payload`).
- `remote function onError(error err) returns error?` — an unexpected session drop
  (see **Resilience**). If you don't implement it, drops are logged via `ballerina/log`.

An inbound PDU whose handler your service does **not** implement is NACKed with
`ESME_RX_P_APPN` (permanent application error) and logged once per PDU type — it is
never silently acknowledged, which would discharge the SMSC's at-least-once guarantee
against a message nothing consumed. If you want to ignore a PDU type, implement its
method and return successfully. A PDU arriving before any service is attached gets
`ESME_RX_T_APPN` instead, so the SMSC redelivers it.

**Compile-time validation.** The package ships a compiler plugin that checks your
service shape as you type — the same contract the listener enforces at `attach`, plus
the cases nothing at runtime can catch: a typo'd method name (`onDeliverSM`), a handler
missing the `remote` qualifier, a `resource` method, or a return type other than
`error?` — each of which would otherwise compile clean and silently never fire.
Diagnostics carry `SMPP_1xx` codes; an empty service offers code actions that insert
handler templates (with or without the reply `caller`). One warning worth heeding:
`SMPP_112` flags a non-isolated handler, which forces every dispatch through the
runtime's process-wide lock — legal, but it quietly stops `maxConcurrentDispatch`
being a parallelism knob.

The plugin is deliberately **stricter than the runtime** in two places, standard for
Ballerina listener plugins: an extra remote method with an unrecognized name is a
compile error (`SMPP_102` — the runtime merely ignores it, which is how a typo'd
handler silently receives nothing), and a non-`error?` return is a compile error
(`SMPP_105` — the runtime dispatches it fine but discards the return, so a handler
failure could never reach the SMSC). A 1.0.x program relying on either tolerated shape
compiles again after deleting the stray method or fixing the return type.

> **Breaking change (vs 1.0.x):** the listener now discovers handlers via remote-method
> lookup, so a handler declared **without** `remote` — which 1.0.x dispatched — is
> invisible: attach fails if it was the only handler, and the compiler plugin flags it
> at the exact line (`SMPP_103`). Add the `remote` qualifier.

**Response mode** (`responseMode`, default `SYNC`) controls *when* the connector answers
the SMSC:

- `SYNC` — the connector waits for your method to return, then answers. A successful
  return acks `ESME_ROK`; a returned `error` acks `ESME_RX_T_APPN` (the SMPP v3.4
  receiver "temporary app error" code), which tells the SMSC the message wasn't handled
  — most SMSCs then redeliver, so a permanently-failing handler will loop until the
  SMSC's retry limit (return successfully, or dead-letter such messages yourself).
- `ASYNC` — the connector acks `ESME_ROK` immediately and runs your method on a
  virtual thread; a later failure can't be reflected to the SMSC and is logged instead.

`maxConcurrentDispatch` (default 3) bounds how many messages run in your service at once,
in both modes; excess is answered with `ESME_RTHROTTLED` so the SMSC backs off and
retains the message. For a **reply-style** service (one that calls `caller->submit` from
its handler) this is also the effective outbound concurrency, and throttling is a normal
steady state rather than an anomaly — see **Throughput** below. The connector logs
throttling on a geometric schedule so it is visible without flooding.

A slow service does not stall the SMSC's `enquire_link` keepalive: the connector reserves
a PDU-processor thread beyond `maxConcurrentDispatch` for exactly that. Note the reserve
also carries every `submit_sm_resp`, so keepalive liveness and submit completion share it
— see the design doc.

## The `Sms` record

`sourceAddr`, `destAddr`, `shortMessage` (decoded text — see **Character encoding**),
`shortMessageBytes` (the raw payload bytes, before decoding), `deliveryReceipt`, `receipt`
(the parsed delivery receipt — see below), `receiptedMessageId` (the
`receipted_message_id` TLV — the reliable correlation key, `()` on ordinary messages), and
`properties` (raw protocol metadata: `dataCoding`, TON/NPI for each address, `esmClass`,
and the `udhi` User-Data-Header flag).

## Delivery receipts

When `sms.deliveryReceipt` is `true`, the PDU is an SMSC delivery receipt (DLR). Its
Appendix-B body is parsed by jsmpp into the typed `sms.receipt` (`DeliveryReceipt?`):
`id`, `finalStatus` (a `DeliveryReceiptStatus` enum — `DELIVRD`, `EXPIRED`, `UNDELIV`, …),
`submitted`/`delivered` counts, `submitDate`/`doneDate` (raw `yyMMddHHmm` strings — the wire
carries no timezone, so parse them against your SMSC's documented zone), `errorCode`, and a
short `text` echo. Every field is optional because SMSCs diverge from the Appendix-B layout.

`receipt` is `()` (and `deliveryReceipt` may still be `true`) when the SMSC's receipt body
doesn't conform to the format — the raw receipt text is always available on
`sms.shortMessage` regardless. The connector adds no interpretation of its own here; it is a
faithful surface of what jsmpp's receipt parser produces.

## Bind modes

`bindType` is `smpp:RECEIVER` (default) or `smpp:TRANSCEIVER`. Only receiver- and
transceiver-bound sessions are sent `deliver_sm`/`data_sm` by the SMSC.

## Resilience

After an unexpected drop the connector notifies `onError` and rebinds automatically with
exponential backoff (`rebindPolicy`, retries indefinitely by default). `enquireLinkInterval`
(default 60s) is the connector's own keepalive/idle-probe interval, and `bindTimeout`
(default 60s) bounds each connect + bind attempt (initial and rebind).

## Character encoding

`shortMessage` is decoded from the PDU's `data_coding`: IA5/ASCII (`0x01`), Latin-1
(`0x03`), and UCS2 (`0x08`, as UTF-16BE) are decoded precisely; everything else — including
the GSM 7-bit default alphabet (`0x00`) — falls back to UTF-8. Set `decodeGsm7: true` to
decode `data_coding 0x00` as **unpacked** GSM 03.38 instead. When the built-in decoding
doesn't fit your SMSC, read `properties.dataCoding` and decode `shortMessageBytes` yourself.

## TLS

SMPP binds send the `systemId`/`password` in cleartext unless the transport is encrypted.
For an SMSC that terminates TLS in-band, add `secureSocket`:

```ballerina
listener smpp:Listener smsListener = check new ({
    host: "smsc.example.com",
    port: 3550,
    systemId,
    password,
    secureSocket: {
        cert: {path: "./truststore.p12", password: trustStorePass}
    }
});
```

`cert` (required) verifies the server against a PKCS12/JKS truststore or a PEM CA
certificate path; hostname verification is on by default; only TLS 1.2/1.3 are negotiated;
set `key` (a `crypto:KeyStore`) for mutual TLS. See the module docs on `SecureSocket` for
the full surface, including the loudly-labeled development-only `InsecureSocket` escape hatch.

## Throughput

For a **reply-style** service — one that answers each inbound message with
`caller->submit` — the sustained outbound rate is roughly
`maxConcurrentDispatch ÷ SMSC round-trip time`. At the shipped defaults (3 slots,
~300 ms round trip) that is **≈10 messages/second**. There is no separate
submit-concurrency knob: in `SYNC` mode a handler waiting for its `submit_sm_resp`
occupies its dispatch slot for the whole round trip. Inbound traffic beyond the limit
is answered `ESME_RTHROTTLED` and redelivered by the SMSC — by design, not an error,
but it is the number to size against. Raise `maxConcurrentDispatch`, or use
`responseMode: ASYNC` so handlers don't hold a slot while blocking (noting the JDK
caveat under **Known limitations**).

## Protocol conformance and limitations

Conforms to **SMPP v3.4** (Issue 1.2) for the receiver/transceiver ESME role: bind
(`interface_version 0x34`), `deliver_sm`/`data_sm` with `deliver_sm_resp`/`data_sm_resp`,
`submit_sm`/`submit_sm_resp` (transceiver), `enquire_link` keepalive (answered even under
a saturated service), and `unbind`. Response `command_status` codes used: `ESME_ROK`,
`ESME_RX_T_APPN` (SYNC handler error, or a PDU with no service attached),
`ESME_RX_P_APPN` (no handler implemented for that PDU type), `ESME_RTHROTTLED`
(backpressure), and `ESME_RSYSERR` (internal inconsistency).

### Known limitations

Everything below is deliberate and documented rather than hidden; raw protocol fields are
surfaced so an application can handle most of these itself.

**Messaging features**

- **No concatenation/multipart** in either direction. Inbound: long messages arrive as
  separate PDUs and are not reassembled — the `udhi` flag and `shortMessageBytes` are
  exposed so you can reassemble them. Outbound: a message longer than 254 octets is
  rejected locally; build the parts yourself with `BinarySms` and set `udhi: true`.
- **No packed GSM 7-bit**, encoding or decoding. Outbound text is ASCII, Latin-1, or
  UCS-2. `decodeGsm7: true` handles *unpacked* GSM 03.38 inbound. For packed septets,
  encode them yourself and send a `BinarySms`. (For plain ASCII text on an SMSC that
  insists on `data_coding 0x00`, a `BinarySms` with the ASCII bytes and `dataCoding: 0`
  is byte-identical to what a GSM-7 encoder would produce.)
- **No outbound `message_payload` TLV.** The 254-octet `short_message` field is the only
  outbound payload carrier, so >254 octets is a hard local rejection. Inbound
  `message_payload` *is* read.
- **The connector does not validate a UDH.** `BinarySms.udhi` sets the UDHI bit; whether
  the payload actually starts with a well-formed User Data Header is your responsibility,
  and getting it wrong renders as garbage text on the handset.
- **Not exposed on `submit`:** `schedule_delivery_time`, `priority_flag`, `protocol_id`,
  `replace_if_present_flag`, `sm_default_msg_id`. They ship as protocol defaults (0).
- **Only `submit_sm`** of the submit family — no `submit_multi`, `query_sm`, `cancel_sm`,
  or `replace_sm`.
- **Listener-only.** A `Caller` exists solely to reply on a listener's session; there is
  no standalone client, so an MT-only (send-only) program is not expressible.

**Delivery, retries, and duplicates**

- **SMPP cannot tell "never arrived" from "arrived, response lost".** A submit that times
  out returns `TIMEOUT_DELIVERY_UNKNOWN`; retrying it may duplicate the message. Check
  `ErrorDetail.possiblySubmitted` — `false` means a retry is safe — and prefer reconciling
  via delivery receipts for billing-relevant traffic.
- **Replying inline in `SYNC` mode can produce a duplicate MT.** A slow reply delays the
  `deliver_sm_resp` past the SMSC's own transaction timer, so the SMSC redelivers the
  inbound message and your service answers it twice. Prefer `responseMode: ASYNC` for
  reply-style services, and carry your own idempotency key where duplicates are costly.
- **In-flight submits are not woken when the link dies or the listener stops.** The
  underlying library has no fail-pending-on-close, so a submit already awaiting its
  response completes only at `transactionTimeout` (default 30s). In `SYNC` mode it holds
  a dispatch slot for that whole time — with all slots so held, inbound dispatch is
  throttled until they clear, including on a freshly rebound session.
- **After rebinding is exhausted or disabled the listener is permanently dead.** Submits
  then fail with `LINK_ABANDONED`; only a new `Listener` recovers. Note
  `maxRebindAttempts` counts *consecutive* failures and resets only after ~60s of stable
  uptime, so a flapping link does terminate.
- **No rate limiting.** The connector never paces submits; carrier throttling policy is
  yours to respect (`REJECTED` with `command_status` `0x58` is the SMSC saying so).

**Operational**

- **Stop latency.** `gracefulStop` ≈ `gracefulStopTimeout` + ~2s (reservation sweep) +
  ~4s (bounded close); `immediateStop` ≈ ~4s. The close is bounded by a force-close
  watchdog even against an unresponsive peer — but a submit parked awaiting its response
  still completes only at `transactionTimeout`, so a submitting strand can outlive the
  stop by that long.
- **A rare library-level wedge is detected, not prevented.** If the SMPP library's close
  choreography wedges (observed roughly once in a few hundred drop/rebind cycles), the
  connector detects it independently within ~1s, force-closes the transport, and rebinds.
  What it cannot reclaim is that dead session's internal thread pool: about
  `maxConcurrentDispatch + 1` idle threads leak per occurrence. Long-lived deployments on
  a persistently flapping link should be sized with that in mind.
- **Detection of a wedge can be delayed** by up to `bindTimeout` if the single-threaded
  rebind worker is simultaneously stalled inside a connect attempt against a half-open
  SMSC.
- **`maxConcurrentDispatch`'s ceiling is per listener, not per process.** Ten listeners at
  1024 in `SYNC` mode is a legal configuration that would attempt ~10 000 platform
  threads.
- **On JDK 21, `ASYNC` + `submit` pins virtual-thread carriers.** A submitting handler
  blocks on a `synchronized` region inside the SMPP library, which pins its carrier
  thread on JDK 21 (fixed by JEP 491 in JDK 24). Since `ASYNC` is also the recommendation
  for reply-style services, keep `maxConcurrentDispatch` modest relative to your core
  count on JDK 21.
- **No metrics.** Ballerina observability is not wired up. Throttling, submit timeouts,
  rebinds, and unhandled-PDU rejections are logged via `ballerina/log`; counting them is
  the application's job.
- **The reader can stall up to 60s** if the library's fixed 100-deep inbound queue
  overflows on a *response* PDU — reachable only under sustained saturation.
- **Empty message bodies are rejected**, and an empty per-message `sourceAddr` means
  "send no source address" rather than falling back to the configured one.

**Versioning**

- `FailureMode`, `Encoding`, `DeliveryReceiptRequest`, `Ton`, and `Npi` are closed enums:
  members cannot be added within 1.x without breaking exhaustive `match` statements.
  `ErrorDetail` is deliberately **open**, so new detail *fields* are always additive.
- The SMPP library version is pinned and bundled; the connector depends on a number of its
  internal behaviours, all catalogued in `docs/jsmpp-upgrade-checklist.md` in the source
  repository.

The full design rationale, concurrency model, and lifecycle state machine are documented
in `docs/architecture.md` in the source repository.
