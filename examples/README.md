# ramith/smpp examples

Runnable examples for the [`ramith/smpp`](https://central.ballerina.io/ramith/smpp)
listener connector (`1.1.0`): it binds to an SMSC as an ESME (receiver/transceiver)
and dispatches inbound PDUs — mobile-originated (MO) SMS and delivery receipts (DLRs)
— to your service. As of 1.1.0 it is **bidirectional**: a service can declare an
`smpp:Caller` parameter and reply on the same transceiver session with
`caller->submit` (`submit_sm`), correlating later delivery receipts against the
returned `message_id`.

Each example is a self-contained Ballerina package that pulls the connector from
Ballerina Central. They run end to end against the bundled [mock SMSC](mock-smsc/),
so you need no carrier account.

## Prerequisites

- **Ballerina** Swan Lake 2201.13.x (`bal version`)
- **Java 17+** — only to run the mock SMSC (a small Gradle app)
- Network access on first build (to pull `ramith/smpp:1.1.0` from Central)

## Running an example

Every example needs an SMSC to talk to. Use two terminals:

```bash
# terminal 1 — start the mock SMSC in the scenario the example expects
cd examples/mock-smsc
./gradlew run --args="steady 2775"

# terminal 2 — run the example
cd examples/receive-sms
bal run
```

Stop each with `Ctrl-C`. Connection settings are `configurable` and default to the
mock; override them for a real SMSC with a `Config.toml` or
`bal run -- -Chost=... -Cport=... -CsystemId=... -Cpassword=...`.

## The examples

| Example | Mock scenario | What it demonstrates | Telco use case |
|---------|---------------|----------------------|----------------|
| [receive-sms](receive-sms/) | `steady 2775` | The minimal listener: bind and log every inbound message. | Inbound SMS ingestion; the starting point for any receive-side flow. |
| [delivery-receipts](delivery-receipts/) | `steady 2775` | Parse DLRs, correlate by `receiptedMessageId`, branch on `finalStatus`. | A2P delivery tracking, billing reconciliation, retry/failover. |
| [two-way-sms](two-way-sms/) | `steady 2775` | Reply on the same session via `smpp:Caller` (`TRANSCEIVER` + `ASYNC`); handle `STOP` opt-out and confirm it with a receipted reply. | Short-code campaigns, TCPA/GDPR opt-out compliance. |
| [resilient-listener](resilient-listener/) | `flaky 2775` | Tune `rebindPolicy`, surface drops via `onError`. | Carrier-grade 24/7 gateway that survives SMSC restarts. |
| [tls-smsc](tls-smsc/) | `tls 3550` | Bind over verified TLS with a truststore. | Secure interconnect where the bind must not cross the wire in cleartext. |

The [mock SMSC](mock-smsc/) harness and its scenarios are documented in
[mock-smsc/README.md](mock-smsc/README.md). Every scenario answers `submit_sm`, and a
submit that requests a receipt on success-or-failure gets a correlated delivery
receipt pushed back — so the reply path is exercised end to end, mock included.
