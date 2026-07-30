# two-way-sms

Inbound keyword handling for short-code / long-number campaigns: votes, competitions
("text WIN to 12345"), HELP, and — most importantly — **STOP opt-outs**, which are
legally mandated (TCPA in the US, GDPR/PECR in the EU).

As of `ramith/smpp:1.1.0` the connector is bidirectional, and this example replies on
the same SMSC session: the handler declares an `smpp:Caller` parameter and calls
`caller->submit`. It demonstrates the full 1.1.0 reply surface:

- `bindType: TRANSCEIVER` — a `RECEIVER` bind cannot transmit.
- `responseMode: ASYNC` — the documented recommendation for reply-style services: the
  inbound `deliver_sm` is acked immediately, so a submit round trip inside the handler
  can't outlive the SMSC's transaction timer and draw a duplicate redelivery.
- A listener-level `sourceAddr` (the short code, `TON_ABBREVIATED`) as the default
  sender for every reply.
- `registeredDelivery: ON_SUCCESS_OR_FAILURE` on the STOP confirmation, then
  correlating the resulting delivery receipt's `Sms.receiptedMessageId` (the only
  correlation key SMPP guarantees) against the `SubmitResult.messageId` the submit
  returned — race-safely: the receipt is dispatched on its own strand and can
  arrive *before* the submitting handler records the id, so final receipts with no
  pending entry are parked and reconciled under one lock (a real SMSC can receipt
  much faster than the mock's 1.5s).
- Submit error handling around `possiblySubmitted` — the retry-safety bit: `false`
  means a retry cannot duplicate the message, `true` means it may.

Keywords are matched on the first word, case-insensitively. Unrecognized messages are
routed onward (chatbot / agent) rather than auto-replied.

## Run

```bash
# terminal 1
cd ../mock-smsc && ./gradlew run --args="steady 2775"

# terminal 2
bal run
```

Expected output (the mock pushes a rotating MO stream and answers each submit; it
pushes a correlated DLR for the receipted STOP confirmation, and its scripted
`id:0123456789` receipt — a message this service never sent — shows up parked):

```
message="unrecognized keyword — routing to agent" subscriber="447700900001" text="Hello from the mock SMSC #0"
message="campaign entry accepted" subscriber="447700900002" keyword="WIN"
message="reply submitted" to="447700900002" messageId="0000000001"
message="OPT-OUT — suppress all future messages to this subscriber" subscriber="447700900002" shortCode="12345"
message="reply submitted" to="447700900002" messageId="0000000002"
message="opt-out confirmation DELIVERED" subscriber="447700900002" id="0000000002"
message="receipt with no matching pending opt-out" id="0123456789" status="DELIVRD" parked=true
```

## Against a real SMSC

Override host/port/systemId/password (and `shortCode`) via a `Config.toml` (see
receive-sms). Two things to size before production traffic:

- `maxConcurrentDispatch` (default 3) bounds inbound dispatch *and* is the effective
  outbound concurrency for a reply-style service; the SMSC sees `ESME_RTHROTTLED`
  when it pushes faster than the slots drain — a normal steady state, not an error.
- The connector applies no rate limiting of its own; the carrier's throttling policy
  is yours to respect.
