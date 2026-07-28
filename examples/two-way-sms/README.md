# two-way-sms

Inbound keyword handling for short-code / long-number campaigns: votes, competitions
("text WIN to 12345"), HELP, and — most importantly — **STOP opt-outs**, which are
legally mandated (TCPA in the US, GDPR/PECR in the EU).

This connector is **receive-only**, so it cannot send the reply itself. The realistic
pattern is to classify the inbound message here and hand the action to whatever sends
(an HTTP call to your messaging API, a transmitter session, a queue). This example
logs the routing decision that outbound path would act on, matching the first keyword
case-insensitively.

## Run

```bash
# terminal 1
cd ../mock-smsc && ./gradlew run --args="steady 2775"

# terminal 2
bal run
```

Expected output:

```
message="unrecognized keyword — routing to agent" subscriber="447700900001" text="Hello from the mock SMSC #0"
message="campaign entry accepted" subscriber="447700900002" keyword="WIN"
message="OPT-OUT — suppress all future messages to this subscriber" subscriber="447700900002" shortCode="12345"
```

## Against a real SMSC

Override host/port/systemId/password via a `Config.toml` (see receive-sms).
