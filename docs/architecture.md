# Architecture

`ramith/smpp` is a Ballerina trigger/listener that receives inbound SMPP PDUs —
mobile-originated (MO) SMS and delivery receipts (DLRs) — by binding to an SMSC
as an SMPP client. It wraps [`org.jsmpp:jsmpp`](https://jsmpp.org/) via
Ballerina's Java interoperability.

This connector is receive-only. It does not submit outbound messages
(`submit_sm`); its only job is to bind to an SMSC and dispatch inbound PDUs to
your service. Everything below describes what actually happens, end to end,
when you use it.

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
  implemented it (if you haven't, the error is printed as a stack trace on
  stderr instead — same caveat as ASYNC failures below).
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
| `gracefulStopTimeout` | `decimal` | `30` (seconds) | See [Shutting down](#shutting-down). |
| `rebindPolicy` | `RebindPolicy` | retries indefinitely | See [RebindPolicy](#rebindpolicy). |

### Bind modes

The SMPP spec defines three bind modes — `bind_transmitter`, `bind_receiver`,
and `bind_transceiver` — but only a receiver- or transceiver-bound session is
ever sent `deliver_sm`/`data_sm` by the SMSC. A transmitter-bound session is
send-only and structurally cannot drive this connector's callbacks. For that
reason, `bindType` is typed as `ListenerBindType`
(`RECEIVER|TRANSCEIVER`) rather than the full `BindType` enum — configuring a
transmitter bind here is a compile-time error, not something that connects
successfully and then silently never calls your service.

`RECEIVER` and `TRANSCEIVER` behave identically for this connector's
purposes: both receive `deliver_sm`/`data_sm`. `TRANSCEIVER` additionally
allows submitting messages over the same session, but since this connector
has no API for that, choosing it only matters if you separately intend the
same bind to double as a submission path outside this connector.

### Dispatch concurrency and response mode

Every inbound PDU is converted to an `Sms` record (see
[The Sms record](#the-sms-record)) and dispatched to your service's
`onDeliverSm` or `onDataSm` method. How and when that dispatch happens is
controlled by `responseMode`:

- **`SYNC`** (default) — dispatch waits for your remote method to return
  before the connector responds to the SMSC. If your method returns
  successfully, the SMSC gets a positive `deliver_sm_resp`/`data_sm_resp`
  (`command_status = ESME_ROK`). If it returns an `error`, the SMSC gets a
  *negative* response instead, so it knows the message wasn't handled and
  can retry it. `maxConcurrentDispatch` (default `3`) caps how many PDUs can
  be in flight to your service at once; if the SMSC sends faster than your
  service drains, PDUs queue up and the SMSC is signaled to throttle rather
  than being accepted at an unbounded rate.
- **`ASYNC`** — the connector responds to the SMSC immediately, with a
  positive `command_status`, before your remote method has even run.
  `maxConcurrentDispatch` no longer limits handler concurrency, since dispatch
  doesn't wait (it still sizes jsmpp's internal PDU-processing pool). This trades correctness for throughput: if your method later fails,
  the SMSC never finds out, and — as of this writing — the failure isn't
  routed through `ballerina/log` either; it's printed as a raw stack trace
  on stderr (routing it through `ballerina/log` is tracked as backlog). Use
  this if you'd rather not have a slow handler apply backpressure to the
  SMSC connection, and you're prepared to handle failures entirely on your
  own side (including watching stderr for them, for now).

If your remote method isn't implemented at all (e.g. a service that only
implements `onDeliverSm`), an inbound `data_sm` is simply not dispatched
anywhere — the SMSC still gets a positive response, since there's nothing to
report as failed.

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

If your service implements none of the applicable methods for an incoming
PDU type, or implements no service at all, that PDU is simply not delivered
anywhere — it's still acknowledged to the SMSC as if handled.

### The `Sms` record

```ballerina
public type Sms record {|
    string sourceAddr;
    string destAddr;
    string shortMessage;
    byte[] shortMessageBytes = [];
    boolean deliveryReceipt = false;
    map<anydata> properties = {};
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
  GSM 7-bit default alphabet and any other/unrecognized `data_coding` value
  fall back to UTF-8 — this is a deliberate choice, not an oversight: the raw
  GSM 03.38 alphabet requires a dedicated codec, and whether an SMSC sends it
  as packed 7-bit septets or one byte per character over SMPP varies by
  vendor, so guessing here would risk a subtler bug than the one being
  avoided. If your SMSC sends GSM 7-bit content and the UTF-8 fallback
  doesn't decode correctly for you (or anything else the UTF-8 fallback gets
  wrong), use `properties.dataCoding` to detect it and `shortMessageBytes`
  (below) to decode the real bytes yourself — re-decoding `shortMessage`
  itself is not a reliable path back to the original bytes once a lossy
  UTF-8 fallback has already been applied.
- **`shortMessageBytes`** — the same payload as `shortMessage`, before any
  charset decoding: the exact bytes left after resolving the
  `message_payload`-over-`short_message` precedence rule described above,
  but before `shortMessage`'s `data_coding`-driven decode is applied. This
  is the actual escape hatch for GSM 7-bit default-alphabet payloads and
  any other `data_coding` this connector doesn't decode precisely.
- **`deliveryReceipt`** — see `onDeliverSm` above.
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
