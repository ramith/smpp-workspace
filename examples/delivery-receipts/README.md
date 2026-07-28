# delivery-receipts

The classic receive-side workload behind A2P SMS. You submit messages (OTPs, alerts,
marketing) on a transmitter elsewhere, and collect the SMSC's **delivery receipts
(DLRs)** here to reconcile billing, drive retries, and power deliverability analytics.

This example filters to DLRs, parses each into the typed `sms.receipt`, correlates by
`id` (the `message_id` your `submit_sm_resp` returned), and branches on `finalStatus`:

- `DELIVRD` → delivered.
- `UNDELIV` / `EXPIRED` / `REJECTD` / `DELETED` → terminal failure (retry on another
  route, flag the number, ...); `errorCode` carries the SMSC/network reason.
- otherwise (`ENROUTE` / `ACCEPTD` / `UNKNOWN`) → still in transit.

A receipt whose body doesn't match SMPP Appendix B leaves `sms.receipt` `()`; the raw
text is still on `sms.shortMessage` for a custom parse.

## Run

```bash
# terminal 1
cd ../mock-smsc && ./gradlew run --args="steady 2775"

# terminal 2
bal run
```

Expected output (the mock also sends MO traffic, which this service ignores):

```
message="ignoring mobile-originated message" from="447700900001"
message="message DELIVERED" id="0123456789" doneDate="0809011131"
```

## Against a real SMSC

Override host/port/systemId/password via a `Config.toml` (see receive-sms).
