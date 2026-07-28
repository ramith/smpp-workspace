# SMPP listener (trigger) connector

A Ballerina **listener/trigger** that receives inbound SMPP PDUs — mobile-originated
(MO) SMS and delivery receipts — from a Short Message Service Centre (SMSC). It binds
to the SMSC as an **ESME** in receiver or transceiver mode and dispatches each inbound
message to your service, wrapping the Java library [`org.jsmpp:jsmpp`](https://jsmpp.org/)
through Ballerina's Java interoperability.

The connector speaks **SMPP v3.4** (it binds with `interface_version` `0x34`). It is
receive-only by design: there is no `submit_sm`/transmit API.

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
  — parse DLRs, correlate by `id`, and branch on `finalStatus`.
- [two-way-sms](https://github.com/ramith/smpp-workspace/tree/main/examples/two-way-sms)
  — route mobile-originated messages by keyword, including `STOP` opt-out.
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
in both modes; excess is answered with `ESME_RTHROTTLED` so the SMSC backs off. A slow
service can never stall the SMSC's `enquire_link` keepalive — see the design doc.

## The `Sms` record

`sourceAddr`, `destAddr`, `shortMessage` (decoded text — see **Character encoding**),
`shortMessageBytes` (the raw payload bytes, before decoding), `deliveryReceipt`, `receipt`
(the parsed delivery receipt — see below), and `properties` (raw protocol metadata:
`dataCoding`, TON/NPI for each address, `esmClass`, and the `udhi` User-Data-Header flag).

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

## Protocol conformance and limitations

Conforms to **SMPP v3.4** (Issue 1.2) for the receiver/transceiver ESME role: bind
(`interface_version 0x34`), `deliver_sm`/`data_sm` with `deliver_sm_resp`/`data_sm_resp`,
`enquire_link` keepalive (answered even under a saturated service), and `unbind`.
Response `command_status` codes used: `ESME_ROK`, `ESME_RX_T_APPN` (SYNC handler error),
and `ESME_RTHROTTLED` (backpressure).

Known limitations (raw fields are always surfaced so an application can handle these
itself): concatenated/multipart messages are **not** reassembled — the `udhi` flag and
`shortMessageBytes` are exposed instead; delivery-receipt bodies are delivered as-is
(the receipt text is not parsed into typed fields); and packed GSM 7-bit is not decoded.

The full design rationale, concurrency model, and lifecycle state machine are documented
in `docs/architecture.md` in the source repository.
