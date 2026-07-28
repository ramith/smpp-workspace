# resilient-listener

A carrier-grade, always-on receiver. SMSC links drop — the SMSC restarts, a firewall
times out an idle NAT mapping, the network blips. The connector detects the drop and
**rebinds automatically with exponential backoff**; this example tunes that policy and
surfaces every drop via `onError` (where you'd wire alerting).

It configures:

- `enquireLinkInterval: 15` — how often to probe an idle link, so a silently-dead SMSC
  (no FIN, just gone) is detected within ~one interval.
- `rebindPolicy` — `1s → 2s → 4s → ...` backoff capped at `30s`, retrying forever
  (`maxRebindAttempts: -1`; set `0` to disable rebinding entirely).

## Run

Use the `flaky` scenario, which accepts the bind, pushes a few messages, then
**hard-drops** the link so you can watch the rebind loop recover:

```bash
# terminal 1
cd ../mock-smsc && ./gradlew run --args="flaky 2775"

# terminal 2
bal run
```

Expected output — messages, a drop, then automatic recovery, repeating:

```
message="inbound message" from="447700900001" text="Hello from the mock SMSC #2"
level=ERROR message="SMSC session dropped — connector is rebinding with backoff" error={... "SMPP session closed unexpectedly (was BOUND_RX)" ...}
message="inbound message" from="447700900001" text="Hello from the mock SMSC #0"   # reconnected
```

`onError` fires once for the initial drop and again for every failed rebind attempt,
so an extended outage produces repeated calls — deliberate, for alerting. It is *not*
called for a deliberate `gracefulStop`/`immediateStop`.

## Against a real SMSC

Override host/port/systemId/password via a `Config.toml` (see receive-sms).
