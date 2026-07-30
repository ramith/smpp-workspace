# delivery-receipts

The classic receive-side workload behind A2P SMS. You submit messages (OTPs, alerts,
marketing) elsewhere — e.g. with `caller->submit` on a transceiver session (see
[two-way-sms](../two-way-sms/)) — and collect the SMSC's **delivery receipts (DLRs)**
here to reconcile billing, drive retries, and power deliverability analytics.

This example filters to DLRs, parses each into the typed `sms.receipt`, correlates by
`sms.receiptedMessageId` — the `receipted_message_id` TLV, the only field SMPP
guarantees to match the `message_id` your submit returned (the Appendix-B body's
`id:` is vendor-specific and may even use a different radix; it serves as fallback
only) — and branches on `finalStatus`:

- `DELIVRD` → delivered.
- `UNDELIV` / `EXPIRED` / `REJECTD` / `DELETED` → terminal failure (retry on another
  route, flag the number, ...); `errorCode` carries the SMSC/network reason.
- `ACCEPTD` → **also final**: accepted by the SMSC on the recipient's behalf — no
  further delivery attempt (or receipt) is coming, so don't keep waiting for one.
- `ENROUTE` → genuinely in transit; another receipt is coming.
- `UNKNOWN` → **indeterminate, not in-flight**: §5.2.28 calls this an invalid state —
  the SMSC cannot say what happened and promises no further receipt. Investigate
  rather than wait.

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
message="ignoring mobile-originated message" from="447700900002"
message="ignoring mobile-originated message" from="447700900002"
message="message DELIVERED" id="0123456789" doneDate="0809011131"
```

## Against a real SMSC

Override host/port/systemId/password via a `Config.toml` (see receive-sms).
