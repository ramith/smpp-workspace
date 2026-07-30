# receive-sms

The smallest possible `ramith/smpp` program: bind to an SMSC as a **receiver** and
log every inbound message. This is the starting point for any receive-side
integration — two-way SMS, delivery tracking, campaign ingestion, and so on.

It implements the one callback a receiver needs, `onDeliverSm`, and distinguishes a
mobile-originated (MO) message from a delivery receipt via `sms.deliveryReceipt`.

## Run

```bash
# terminal 1
cd ../mock-smsc && ./gradlew run --args="steady 2775"

# terminal 2
bal run
```

Expected output:

```
message="inbound SMS received" from="447700900001" to="12345" text="Hello from the mock SMSC #0"
message="inbound SMS received" from="447700900002" to="12345" text="WIN"
message="inbound SMS received" from="447700900002" to="12345" text="STOP"
message="delivery receipt received" from="447700900001" status="DELIVRD" id="0123456789"
```

## Against a real SMSC

Override the defaults with a `Config.toml`:

```toml
host = "smsc.example.com"
port = 2775
systemId = "your-system-id"
password = "your-password"
```
