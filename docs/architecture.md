# Architecture

`ramith/smpp` is a Ballerina trigger/listener that receives inbound SMPP PDUs —
mobile-originated (MO) SMS and delivery receipts (DLRs) — by binding to an SMSC
as an SMPP client. It wraps [`org.jsmpp:jsmpp`](https://jsmpp.org/) via
Ballerina's Java interoperability.

This connector binds to an SMSC, dispatches inbound PDUs to your service, and —
since Sprint 8 — submits outbound messages (`submit_sm`) via the `smpp:Caller`
delivered to remote methods that declare it (`bindType: TRANSCEIVER` required).
Everything below describes what actually happens, end to end, when you use it.

**Outbound in one paragraph:** one `Caller` exists per listener, valid across
rebinds (every submit resolves the current session). Submits wait up to
`transactionTimeout` for the `submit_sm_resp`; jsmpp housekeeping is bounded
separately (~2s). Failures map to `FailureMode` (see `types.bal`). In `SYNC`
mode an inline reply holds a dispatch slot AND relies on the PDU-processor
reserve thread: **`submit_sm_resp` PDUs ride the same jsmpp pool as inbound
dispatches**, so the reserve beyond `maxConcurrentDispatch` is a liveness
requirement for the submit path itself, not just an enquire_link nicety — a
handler blocked in `submit` completes only because a spare pool thread can
deliver its response. Prefer `responseMode: ASYNC` for reply-style services.

## Connection lifecycle

The listener enforces an explicit one-way lifecycle
(`INIT → STARTING → STARTED → STOPPING → STOPPED`): a second `'start()` on a running
listener is rejected with an error, and a stopped listener cannot be restarted —
create a new `Listener` instead. The one exception to one-way-ness: a *failed*
`'start()` (bind rejected, host unreachable) reverts the listener to startable, since
nothing was installed. Stops are idempotent — stopping an already-stopped or
never-started listener is a no-op. One service per listener: attaching a second
service is rejected (detach the first to swap).

A listener goes through four phases:

1. **`init`** — validates and stores your `ConnectionConfig`. No network
   activity happens yet.
2. **`'start()`** — opens a TCP connection to the SMSC and performs the SMPP
   bind handshake (`bind_receiver` or `bind_transceiver`, depending on
   `bindType`). If this fails — wrong credentials, an oversized credential
   (rejected locally before any connection is attempted; see the SMPP length
   limits in the configuration reference), unreachable host, the SMSC
   rejects the bind — `'start()` returns an `error` and nothing further
   happens; this is not retried automatically.
3. **Running** — once bound, the SMSC pushes `deliver_sm` and `data_sm` PDUs
   to you as MO messages and DLRs arrive, and your attached service's remote
   methods are invoked for each one. See [Service contract](#service-contract)
   below for exactly how.
4. **Stopping** — `gracefulStop()` or `immediateStop()` unbinds
   (`unbind`/`unbind_resp`) and closes the connection. See
   [Shutting down](#shutting-down).

### If the connection drops unexpectedly

Once bound, the connection can drop for reasons outside your control: the
SMSC closes it, a network blip severs it, and so on. When this happens (and
only when it happens outside of your own `gracefulStop()`/`immediateStop()`
call):

- Your service's `onError` method is notified immediately, if you've
  implemented it (if you haven't, the drop is written to `ballerina/log` at
  error level instead — as are ASYNC handler failures below).
- The listener then automatically attempts to rebind, governed by
  `ConnectionConfig.rebindPolicy` — see [RebindPolicy](#rebindpolicy) below.
  By default this retries indefinitely with exponential backoff. **Every**
  failed rebind attempt notifies `onError` again — not just the initial drop
  or the final give-up — so during an extended outage `onError` can fire
  many times in a row, once per failed attempt. If you'd rather handle
  reconnection yourself, set `rebindPolicy.maxRebindAttempts` to `0` to
  disable it; you'll still get the one `onError` notification for the
  initial drop.
- If automatic rebinding is enabled and eventually exhausts
  `maxRebindAttempts`, `onError` is notified one final time reporting the
  give-up.
- A successful rebind resumes normal operation silently — there's no
  separate "reconnected" notification, since the next successfully
  dispatched PDU is itself evidence that things are working again.

This is distinct from a failed *initial* `'start()` call, which is always
returned to you directly as an `error` and never retried by `rebindPolicy`.

**How drops are detected (two independent signals).** The primary signal is jsmpp's own
session-state listener firing `CLOSED` — normally 0–4ms after the socket dies. jsmpp 3.0.2
also has a rare failure mode (roughly one sever in a few hundred under soak) where its
reader thread dies mid-close and that notification **never** fires, leaving the session
claiming to be bound forever. The connector therefore observes the transport itself: both
connection factories wrap every socket stream, and an EOF or read error fires a second,
independent drop signal. Whichever signal arrives first wins (exactly-once guarded); if
the primary hasn't fired within a 1s grace, the connector declares the drop itself —
`onError` message `"SMPP transport died and jsmpp's CLOSED notification did not arrive
..."` instead of `"SMPP session closed unexpectedly ..."` — abandons the wedged session,
and proceeds with the same rebind flow. Code that matches on `onError` message text should
treat either wording as "the link dropped". See `ObservedConnection.java` and the Sprint 8
Phase 3 incident record in [sprint-plan.md](sprint-plan.md) for the full forensics.

## Configuration reference

All fields live on `ConnectionConfig`, passed to `new (...)` when you create
the listener.

| Field | Type | Default | Purpose |
|---|---|---|---|
| `host` | `string` | — | SMSC host name or IP address. |
| `port` | `int` | `2775` | SMSC port. |
| `systemId` | `string` | — | The `system_id` (username) used to bind. |
| `password` | `string` | — | The password used to bind. |
| `systemType` | `string` | `""` | The optional `system_type`. |
| `bindType` | `ListenerBindType` | `RECEIVER` | See [Bind modes](#bind-modes). |
| `maxConcurrentDispatch` | `int` | `3` | See [Dispatch concurrency](#dispatch-concurrency-and-response-mode). |
| `responseMode` | `ResponseMode` | `SYNC` | See [Dispatch concurrency](#dispatch-concurrency-and-response-mode). |
| `decodeGsm7` | `boolean` | `false` | Opt-in: decode `data_coding` `0x00` as unpacked GSM 03.38 instead of the UTF-8 fallback. See [The Sms record](#the-sms-record). |
| `gracefulStopTimeout` | `decimal` | `30` (seconds) | See [Shutting down](#shutting-down). |
| `rebindPolicy` | `RebindPolicy` | retries indefinitely | See [RebindPolicy](#rebindpolicy). |
| `enquireLinkInterval` | `decimal` | `60` (seconds) | Connector's own keepalive/idle-probe interval toward the SMSC. See [Dispatch concurrency](#dispatch-concurrency-and-response-mode). |
| `bindTimeout` | `decimal` | `60` (seconds) | Bounds the connect + bind handshake (initial and every rebind). See [RebindPolicy](#rebindpolicy). |
| `secureSocket` | `SecureSocket \| InsecureSocket` | none (plaintext) | See [Transport security (TLS)](#transport-security-tls). |

### Transport security (TLS)

By default the SMSC connection is **plaintext TCP** — the same behavior this connector
has always had, and the right default only when the link to the SMSC is already protected
out of band (a private network, a VPN, or a TLS-terminating proxy in front of the SMSC).
Terminating TLS at that boundary, where you control it, remains the recommended production
topology.

When you don't control that boundary — a public or shared network path to the SMSC — set
`ConnectionConfig.secureSocket` to wrap the SMPP session in TLS directly. The SMPP bind
exchanges your `systemId`/`password` in the clear on the wire, so an unencrypted path to
an SMSC you don't fully trust exposes those credentials; in-band TLS closes that.

```ballerina
smpp:ConnectionConfig config = {
    host: "smsc.example.com",
    port: 3550,
    systemId,
    password,
    secureSocket: {
        cert: { path: "./resources/truststore.p12", password: tsPass }
    }
};
```

Supplying a `SecureSocket` turns on full verification:

- The SMSC's server certificate is verified against `cert` — either a `crypto:TrustStore`
  (PKCS12/JKS file + password) or a path to a PEM CA certificate. `cert` is required;
  there is no silent fallback to a system truststore.
- The certificate's subject is matched against `host` (`verifyHostName`, default `true`).
  Set it to `false` only to relax the hostname match against a test SMSC whose certificate
  is issued for a different name — the chain is still fully verified. (This is stronger
  than jsmpp's own SSL factories, which perform no hostname verification at all.)
- Only TLS 1.2 and TLS 1.3 are negotiated. Configuring `protocolVersions` with TLS 1.1 or
  below is rejected at listener init.
- For mutual TLS, set `key` to a `crypto:KeyStore`. Omit it for ordinary one-way TLS.

A bad or untrusted certificate fails the handshake eagerly, so it surfaces as an `error`
from `'start()` (or drives the rebind loop, if it happens after a successful initial
bind), never silently later.

Internally the `.bal` layer flattens the union into a `ResolvedTls` record handed to the
native layer, and the native readers for it are deliberately **strict** — a missing field
throws instead of defaulting. The general config readers are lenient, but here a silent
default is a security downgrade (a defaulted `verifyHostName` would read as `false`,
turning hostname verification off after a one-sided field rename), so drift between the
two layers fails loudly at bind time rather than weakening verification. The test suite
pins both headline guarantees with negatives: a trusted-but-wrong-hostname certificate
must fail (`verifyHostName` default), and an mTLS mock that demands a client certificate
must reject a connector that has no `key`.

#### Disabling verification (development only)

To test against a local or self-signed SMSC without minting a truststore, set
`secureSocket` to an `InsecureSocket` instead of a `SecureSocket`:

```ballerina
secureSocket: { disableSslVerification: true }
```

This still encrypts the wire but accepts **any** certificate the peer presents, which
defeats TLS's authentication and leaves the connection open to a man-in-the-middle. It is
a distinct record type, and its single field is required and can only be `true`, precisely
so verification can never be switched off by a defaulted or copy-pasted field. Never point
it at a production SMSC; a warning is logged at startup whenever it is in effect.

### Bind modes

The SMPP spec defines three bind modes — `bind_transmitter`, `bind_receiver`,
and `bind_transceiver` — but only a receiver- or transceiver-bound session is
ever sent `deliver_sm`/`data_sm` by the SMSC. A transmitter-bound session is
send-only and structurally cannot drive this connector's callbacks. For that
reason, `bindType` is typed as `ListenerBindType`
(`RECEIVER|TRANSCEIVER`) rather than the full `BindType` enum — configuring a
transmitter bind here is a compile-time error, not something that connects
successfully and then silently never calls your service.

`RECEIVER` and `TRANSCEIVER` both receive `deliver_sm`/`data_sm` identically.
`TRANSCEIVER` additionally allows submitting on the same session — it is the
bind type `Caller.submit` requires: a service that replies must bind
`TRANSCEIVER`, and a `RECEIVER` bind's Caller fails fast with an error naming
the fix.

### Dispatch concurrency and response mode

Every inbound PDU is converted to an `Sms` record (see
[The Sms record](#the-sms-record)) and dispatched to your service's
`onDeliverSm` or `onDataSm` method. How and when that dispatch happens is
controlled by `responseMode`:

`maxConcurrentDispatch` (default `3`) caps how many PDUs are dispatched to
your service concurrently — in **both** modes. Anything beyond that limit is
answered immediately with `ESME_RTHROTTLED` (a NACK, so the SMSC backs off and
retains the message for retry — SMPP is at-least-once), rather than being queued
unboundedly or spawning unbounded work. The two modes differ only in *when* the
`deliver_sm_resp`/`data_sm_resp` is sent and whether a handler failure reaches
the SMSC:

- **`SYNC`** (default) — dispatch waits for your remote method to return
  before the connector responds. A successful return yields a positive
  `deliver_sm_resp`/`data_sm_resp` (`command_status = ESME_ROK`); an `error`
  return yields a *negative* response with `ESME_RX_T_APPN` (the SMPP v3.4
  receiver "temporary app error" code, 0x64), telling the SMSC the message
  wasn't handled. SMPP v3.4 doesn't mandate the SMSC's reaction, but most treat
  a temporary error as a signal to redeliver — so a permanently-failing handler
  will keep receiving the message until the SMSC's own retry/validity limit.
- **`ASYNC`** — the connector responds immediately with `ESME_ROK`, before your
  remote method has run. This trades correctness for latency: a later handler
  failure never reaches the SMSC — it is written to `ballerina/log` at error
  level (there is no negative response to send once `ESME_ROK` has gone out).
  `maxConcurrentDispatch` still bounds concurrent handler executions
  here (earlier releases documented ASYNC as ignoring it — that is no longer the
  case); the difference from `SYNC` is the immediate ack, not unbounded dispatch.

If your remote method isn't implemented at all (e.g. a service that only
implements `onDeliverSm`, receiving an inbound `data_sm`), the PDU is **NACKed
with `ESME_RX_P_APPN`** — the SMPP v3.4 receiver "permanent app error" code
(0x65) — and a warning is logged once per PDU type naming the missing method.

Permanent, not temporary, and not a positive ack:

- A **positive ack** (what releases before 8.5 sent) told the SMSC the message
  had been consumed while the connector dropped it on the floor — silently
  discharging SMPP's at-least-once guarantee against nothing, with no log, no
  `onError`, and no metric. For a service without `onDeliverSm`, that silently
  swallowed every delivery receipt.
- A **temporary** error (`ESME_RX_T_APPN`, used for handler failures) would
  invite redelivery — but a missing remote method is a property of the deployed
  code and cannot appear at runtime, so every redelivery would fail identically:
  a guaranteed poison loop for the life of the deployment.

A PDU arriving when **no service is attached at all** — the window between
`'start()` and `attach`, or after a `detach` — is genuinely transient and gets
`ESME_RX_T_APPN` instead, so the SMSC retains and redelivers it.

If you legitimately want to ignore a PDU type, implement its remote method and
return successfully; that consumes the traffic and acknowledges it positively.
(`alert_notification` is unaffected either way: SMPP v3.4 defines no response
PDU for it, so there is nothing to acknowledge.)

#### Why a busy service does not stall keepalive

Inbound PDUs and the SMSC's own `enquire_link` keepalive share one jsmpp
worker pool. If that pool were sized to exactly `maxConcurrentDispatch`, then in
`SYNC` mode `maxConcurrentDispatch` slow handlers would occupy every thread and
the SMSC's next `enquire_link` would sit unanswered behind them — the SMSC would
conclude the link is dead and drop it, a disconnect the connector *provoked
itself*, which then forces a rebind. Backpressure (throttling the SMSC) is
intended; a dropped link is not.

To prevent this, the connector decouples handler concurrency from pool size. A
`Semaphore(maxConcurrentDispatch)` — owned by the dispatcher, so the bound spans
the listener's whole life, not one session — gates handler *entry* with a
non-blocking `tryAcquire`; overflow is `ESME_RTHROTTLED`'d without ever blocking
a pool thread. The pool itself is sized *mode-aware*:

- `SYNC`: `maxConcurrentDispatch + 1`. Handlers run on pool threads and block for
  the handler's duration, but the semaphore caps blocking handlers at
  `maxConcurrentDispatch`, so the `+1` reserve thread is never occupiable by a
  handler and is always free to answer `enquire_link`. One reserve suffices — all
  outbound sends serialize on a single stream, so a second would protect nothing.
- `ASYNC`: a small fixed pool. Handlers run on virtual threads, so pool threads
  only marshal each PDU and spawn — they never block, so keepalive is never
  starved regardless of `maxConcurrentDispatch`.

Because the semaphore is per-listener, a handler still running from a *dropped*
session keeps its permit, so it counts against the rebound session's budget too
(the bound protects a shared downstream, not a single connection). A permanently
stuck handler therefore throttles the rebound session until it clears or
`gracefulStop` times out — an intended consequence of a listener-wide bound, and
the same stuck handler that would already stall the `gracefulStop` drain.

`enquireLinkInterval` is a separate knob: it controls the *connector's own*
liveness probes toward the SMSC (and its socket read timeout, hence how fast it
detects a silently dead SMSC and drives `rebindPolicy`) — not how the SMSC's
probes toward the connector are answered.

### RebindPolicy

```ballerina
public type RebindPolicy record {|
    decimal initialRebindDelay = 1;
    decimal maxRebindDelay = 60;
    decimal backOffMultiplier = 2.0;
    int maxRebindAttempts = -1;
|};
```

After an unexpected session drop, the first rebind attempt happens after
`initialRebindDelay` seconds. Each subsequent failed attempt waits longer,
multiplying the previous delay by `backOffMultiplier`, capped at
`maxRebindDelay`. `maxRebindAttempts` controls how many attempts are made
before giving up: `-1` (the default) retries indefinitely; `0` disables
automatic rebinding entirely, so a drop only ever produces the one initial
`onError` notification.

## Service contract

A service attached to the listener (`service on smsListener { ... }`)
implements any combination of three optional remote methods:

```ballerina
remote function onDeliverSm(smpp:Sms sms) returns error?;
remote function onDataSm(smpp:Sms sms) returns error?;
remote function onError(error err) returns error?;
```

- **`onDeliverSm`** fires for a `deliver_sm` PDU — either a mobile-originated
  SMS or an SMSC delivery receipt. `sms.deliveryReceipt` tells you which:
  `true` for a DLR, `false` for a real inbound message.
- **`onDataSm`** fires for a `data_sm` PDU. Unlike `deliver_sm`, `data_sm` has
  no `deliveryReceipt` distinction — it's always treated as `false`.
- **`onError`** fires when the SMPP session drops unexpectedly (see
  [If the connection drops unexpectedly](#if-the-connection-drops-unexpectedly)
  above). It is never called for a failed initial `'start()`, only for a
  drop after a successful bind.

If your service implements no method for an incoming PDU type, that PDU is
NACKed with `ESME_RX_P_APPN` (permanent); if no service is attached at all, it
is NACKed with `ESME_RX_T_APPN` (transient, so the SMSC redelivers). Neither is
silently acknowledged — see
[Dispatch concurrency and response mode](#dispatch-concurrency-and-response-mode).

### The `Sms` record

```ballerina
public type Sms record {|
    string sourceAddr;
    string destAddr;
    string shortMessage;
    byte[] shortMessageBytes = [];
    boolean deliveryReceipt = false;
    map<anydata> properties = {};
    DeliveryReceipt? receipt = ();
|};
```

- **`sourceAddr`** / **`destAddr`** — the sender and receiver addresses
  (MSISDN or short code) as plain strings. The SMPP-level type-of-number and
  numbering-plan-indicator for each address are not promoted to typed
  fields — see `properties` below if you need them.
- **`shortMessage`** — the message text. This connector picks the payload
  bytes per the SMPP spec's precedence rule (a PDU's `message_payload`
  optional parameter takes priority over its `short_message` field when both
  are present — relevant mainly for messages too long to fit in
  `short_message`, and for `data_sm`, which only ever uses
  `message_payload`), then decodes those bytes according to the PDU's
  `data_coding`. Only the unambiguous single-byte-per-character encodings are
  decoded precisely: IA5/ASCII, Latin-1 (ISO-8859-1), and UCS2 (as UTF-16BE).
  The GSM 7-bit default alphabet (`data_coding` `0x00`) and any other/unrecognized
  value fall back to UTF-8 by default — because whether an SMSC sends GSM 7-bit
  as packed septets or one byte per octet over SMPP varies by vendor, so guessing
  would risk a subtler bug. If your SMSC sends the **unpacked** GSM 7-bit default
  alphabet, set `decodeGsm7: true` (see below): `data_coding` `0x00` is then decoded
  via the GSM 03.38 default alphabet and its extension table instead of UTF-8. It is
  opt-in and off by default so existing deployments are unaffected, and it does not
  attempt packed 7-bit. For anything the built-in decoding still gets wrong, use
  `properties.dataCoding` to detect the scheme and `shortMessageBytes` (below) to
  decode the raw bytes yourself — re-decoding `shortMessage` is not a reliable path
  back to the original bytes once a lossy fallback has been applied.
- **`shortMessageBytes`** — the same payload as `shortMessage`, before any
  charset decoding: the exact bytes left after resolving the
  `message_payload`-over-`short_message` precedence rule described above,
  but before `shortMessage`'s `data_coding`-driven decode is applied. This
  is the actual escape hatch for GSM 7-bit default-alphabet payloads and
  any other `data_coding` this connector doesn't decode precisely.
- **`deliveryReceipt`** — see `onDeliverSm` above.
- **`receipt`** — the parsed SMSC delivery receipt (`DeliveryReceipt?`), present
  only when `deliveryReceipt == true` **and** jsmpp could parse the Appendix-B
  receipt body. This is a faithful surface of jsmpp's own receipt parser
  (`DeliverSm.getShortMessageAsDeliveryReceipt()`), mapped 1:1 — the connector adds
  no interpretation of its own, and reads no delivery TLVs jsmpp's parser doesn't.
  All fields are optional (`id`, `finalStatus` as a `DeliveryReceiptStatus` enum,
  `submitted`/`delivered`, `submitDate`/`doneDate` as raw `yyMMddHHmm` strings —
  the wire has no timezone — `errorCode`, `text`) because SMSCs diverge from the
  Appendix-B layout. It is `()` when the body doesn't conform (jsmpp's parser throws
  on that, and the connector catches it rather than NACKing the receipt — the raw
  body stays on `shortMessage`), so `deliveryReceipt == true` does not guarantee a
  non-nil `receipt`. Only `deliver_sm` carries a receipt body; `data_sm` receipts
  are out of scope.
- **`properties`** — protocol metadata not promoted to a typed field:
  - `dataCoding` (`int`) — the raw `data_coding` value.
  - `sourceAddrTon` / `sourceAddrNpi` / `destAddrTon` / `destAddrNpi`
    (`int`) — type-of-number and numbering-plan-indicator for each address.
  - `esmClass` (`int`) — the raw `esm_class` byte.
  - `udhi` (`boolean`) — the User Data Header Indicator bit of `esm_class`.
    When set, the message is part of a concatenated (multipart) message or contains
    binary user data; this connector does not reassemble multipart messages
    or parse the header — you receive each segment independently if `udhi`
    is set.

## Shutting down

```ballerina
public isolated function gracefulStop() returns error?;
public isolated function immediateStop() returns error?;
```

Both methods cancel any pending rebind attempt and then unbind and close the
SMSC session. They differ in one respect: `gracefulStop()` first waits — up
to `ConnectionConfig.gracefulStopTimeout` seconds (default `30`) — for any
PDUs currently being dispatched to your service to finish, so an in-flight
`onDeliverSm`/`onDataSm` call gets a chance to complete before the connection
goes away. `immediateStop()` does not wait at all.
