# Adding `submit_sm` (outbound SMS) to `ramith/smpp`

> ## ⚠️ SUPERSEDED IN PART — read this box before implementing anything below
>
> This report went through the process it asked for: a five-SME panel (`architect-reviewer`,
> `java-architect`, `ballerina-developer`, `qa-expert`, plus a dedicated **SMPP v3.4 conformance
> audit**) followed by a hostile `the-fool` red-team pass. The result is
> **[sprint-plan.md § Sprint 8](sprint-plan.md), which is now the authoritative spec.**
>
> The report's §2 survey of existing code, its §3 placement analysis, its §5 file map and its §6.1
> stale-session finding all survived — several of them were strengthened. **Its protocol design did
> not.** Do not implement §4 or §7 as written. Specifically:
>
> | § | Claim | Status |
> |---|---|---|
> | 4 | `onDeliverSm(smpp:Caller caller, smpp:Sms sms)` | **Wrong order.** The caller goes **last**. mqtt's own code template is `onMessage(Message, Caller)` and its validator enforces that; ftp's plugin says "(WatchEvent) or (WatchEvent & Caller)". Caller-first is the pattern only where the caller is *mandatory*. |
> | 4 | `Encoding.GSM7` — "GSM 03.38, packed. The carrier default." | **Does not ship, in any form.** Packed was already ruled out as F3 (sprint-plan.md:592). Unpacked was then proposed and also refuted: jsmpp's own `Concatenation.java:71-80` documents `data_coding 0x00` as *"normally ISO Latin 1 unpacked as default SMSC alphabet"* and emits Latin-1 bytes while using `GSMCharset` only to *count* septets. Also: §5.2.19 note c says the protocol has **no** default `data_coding`, so "the carrier default" is connector policy, not spec. |
> | 4 | `decimal? validityPeriod` "in seconds" | **Not a number.** `validity_period` is a 16-octet SMPP time string (`YYMMDDhhmmsstnnp`, or relative), or NULL for the SMSC default. jsmpp validates it as null/empty/**exactly 16 chars** and ships `AbsoluteTimeFormatter`/`RelativeTimeFormatter` for it. |
> | 4 | `boolean requestDeliveryReceipt` | **Wrong type, and unfixable later** — widening a published `boolean` to an enum is a verified compile break. `registered_delivery` is a bit-mask; "receipt on failure only" is a normal carrier setup. Ships as a **three**-member enum (jsmpp's `SMSCDeliveryReceipt.SUCCESS` is javadoc'd "Introduced in SMPP 5.0" and `0x03` is reserved on IF_34). |
> | 4 | `int` for TON/NPI | **Enums.** NPI's legal set is non-contiguous (0,1,3,4,6,8,9,10,14,18), so `int` accepts non-values, and `valueOf` then throws an unchecked exception that escapes as a Ballerina **panic**. `ALPHANUMERIC = 5` — needed for brand sender IDs — is undiscoverable behind `int destAddrTon = 1`. |
> | 4 | no `sourceAddrTon`/`sourceAddrNpi`; `sourceAddr` as a bare string | **Alphanumeric sender IDs are inexpressible** — the motivating short-code example cannot say what it is. Ships as an `Address` record behind a `string\|Address` union. |
> | 4 | `returns string\|Error` | **Result record.** `getMessageId()` can be **null on an `ESME_ROK` response**, which `string` cannot honestly represent — you would have to return `""` (silently breaking correlation) or fabricate an error for a successful submit. |
> | 4 | `sourceAddr` validated in `validateConfig` | **Would break every existing user at runtime on upgrade.** `validateConfig` runs on `Listener.init` for receive-only users too. Default it; validate at submit time. |
> | 4/5 | `esm_class`, `service_type`, `protocol_id`, `priority_flag`, `replace_if_present_flag`, `sm_default_msg_id`, `schedule_delivery_time` | **All silently omitted, all mandatory PDU fields.** `esm_class` has no jsmpp default and **NPEs on null**; it must be an explicit `0x00`. |
> | 5 | "One `Caller` per listener… it holds only the session reference" | **It must hold no session at all** — that contradicts §6.1. And read-through is mandatory for a reason stronger than staleness: `SMPPSession`'s `conn`/`in`/`out` are **non-volatile**, so the `AtomicReference` is the only safe-publication edge for jsmpp's own internals. |
> | 6.1 / 6.6 | treated as unrelated | **Same jsmpp code path.** `ensureTransmittable` throws a bare `IOException` for wrong-bind-mode, closed-session and dead-link alike. Also: the session reference is **never cleared** on a drop, so mid-rebind it holds a CLOSED session, not null. |
> | 6.3 | "A single `submit_sm` carries 140 octets" | **254.** 140 is the GSM air-interface (TP-UD) budget, not an SMPP field limit. `sm_length` allows 1–254 with 255 explicitly disallowed; jsmpp caps `SHORT_MESSAGE` at 254. |
> | 6.5 | "verify [concurrent-submit safety] under load rather than assuming it" | **Settled by inspection: safe by construction.** `SMPPSession(ConnectionFactory)` — the only form this connector uses — wraps the sender in `SynchronizedPDUSender`, and the monitor is provably one object per session. So "assert no interleaving corruption" is an *unfalsifiable* test and was replaced. |
> | 7 | `ESME_RINVBNDSTS` for wrong bind state; `ESME_RINVMSGLEN` in the same table | **Conflates local and remote failures.** Wrong bind state is a local bare `IOException`; oversize is a local `PDUStringException` with **no** `getCommandStatus()`. jsmpp also mislabels the *destination*-address error as `RINVSRCADR`, so mapping cannot key on the code. |
> | 7 | suggest `commandStatusName` + `retriable` | **Both dropped.** jsmpp already formats hex + description into `getMessage()` and has no status→name helper; a hand-kept table is spec duplication, and the reflection alternative would put reflection into shipped native code. `retriable` cannot express the timeout case, where the PDU is provably already on the wire. Replaced by a `FailureMode` enum derived from the exception class. |
> | 1 | "`getMessageId()` … the value that later appears as `id:` in the DLR body" | **Not guaranteed.** §5.2.23 makes `message_id` opaque and SMSC-defined; Appendix B calls the receipt format "SMSC vendor specific" and types `id` as 10 octets *decimal*. jsmpp ships both a hex and a decimal id generator rather than resolving it. The spec's only guaranteed key is the `receipted_message_id` TLV (0x001E), now added. `types.bal:263` overstates this today and is corrected in Sprint 8. |
>
> **Three things the report missed entirely, all now first-class sprint items:** jsmpp's
> `transactionTimer` defaults to **2000 ms** and the connector never sets it, so every submit would
> give up after 2 s; `submit_sm_resp` arrives on the **same bounded pool that runs the handlers**,
> which makes the keepalive-reserve rationale stated in three shipped documents incomplete; and a
> `submit` inside a SYNC handler puts a network round trip **inside the inbound transaction
> window**, making duplicate MTs the likely outcome under load rather than the exotic one — the
> single biggest risk in the feature.
>
> The report's own suggestion in §6.2 to ship non-GSM-7 encodings first turned out to be right, for
> reasons it didn't have. Its §10 open questions are all answered in Sprint 8's reconciliation notes.

**Status:** design report / handoff — **partly superseded, see the box above**. No code written.
**Target repo:** [`ramith/smpp-workspace`](https://github.com/ramith/smpp-workspace) — the connector at `smpp/`.
**Written against:** `smpp@1.0.1` as published on Central, `main` of smpp-workspace as of 2026-07-28.
**Audience:** the implementing session, which has the smpp-workspace repo but not the conversation this came from.

## Why this exists

`ramith/smpp` is a receive-only trigger. It binds as an SMPP receiver/transceiver and
dispatches inbound PDUs, but exposes no way to send. That blocks the single most common
short-code use case: **receive an MO message and reply to it**.

This came out of building a balance-enquiry example (a Namibian operator's `1200` short
code: subscriber texts `BAL` → connector receives → REST call to billing → reply SMS). The
example works end to end except the last hop — it composes the reply text and logs it,
because the connector cannot submit. The connector's own `examples/two-way-sms` has the
same hole and says so in its README.

Closing it needs `submit_sm`, and the payoff is bigger than one example: with a returned
`message_id`, the existing delivery-receipt support finally has something to correlate
against, so the full MO → REST → MT → DLR circuit becomes expressible.

This report is intended as the input to **Phase 2 — Plan** in `docs/development-process.md`.
Follow the repo's existing process from there; don't treat this as a substitute for it.

---

## 1. Does jsmpp support it? Yes — verified

The connector pins **jsmpp 3.0.2** (`smpp/gradle.properties:13`) against **ballerinaLangVersion
2201.13.0** (`:7`). I inspected that exact jar with `javap`; these are real signatures, not
recalled from memory:

```java
// org.jsmpp.session.SMPPSession — the same class NativeListener already holds
public SubmitSmResult submitShortMessage(
    String serviceType,
    TypeOfNumber sourceAddrTon, NumberingPlanIndicator sourceAddrNpi, String sourceAddr,
    TypeOfNumber destAddrTon, NumberingPlanIndicator destAddrNpi, String destinationAddr,
    ESMClass esmClass, byte protocolId, byte priorityFlag,
    String scheduleDeliveryTime, String validityPeriod,
    RegisteredDelivery registeredDelivery, byte replaceIfPresentFlag,
    DataCoding dataCoding, byte smDefaultMsgId, byte[] shortMessage,
    OptionalParameter... optionalParameters)
  throws PDUException, ResponseTimeoutException, InvalidResponseException,
         NegativeResponseException, IOException;
```

```java
// org.jsmpp.session.SubmitSmResult
public String getMessageId();
public OptionalParameter[] getOptionalParameters();
```

`getMessageId()` is the `message_id` from `submit_sm_resp` — the value that later appears as
`id:` in the DLR body. Note that jsmpp 2.x returned a bare `String` from
`submitShortMessage`; **3.x returns `SubmitSmResult`**. Any jsmpp snippet found online may
show the old shape.

Also present on `SMPPSession`, should you want them later: `submitMultiple`,
`queryShortMessage`, `cancelShortMessage`, `replaceShortMessage`.

### What jsmpp does *not* give you

Two gaps that will shape the work — both verified by inspecting the jar contents:

| Need | Status in jsmpp 3.0.2 |
|---|---|
| GSM 03.38 (7-bit) **encoder** | **Absent.** The jar has only `org.jsmpp.bean.Alphabet` (the `data_coding` constant enum). No charset/codec class. You must write the encoder. |
| Long-message splitting | **Partial.** `org.jsmpp.bean.LongSMS.splitMessage8Bit(byte[]) → byte[][]` only. 8-bit UDH concatenation; nothing for 7-bit packed. |

The connector already has the *decode* half of the first gap —
`Dispatcher.decodeGsm0338Unpacked` (`Dispatcher.java:~471`) plus the `data_coding` switch at
`~457`. The encoder is its inverse and belongs beside it.

---

## 2. What already exists (and helps)

The groundwork is better than you'd expect. Nothing here needs redesigning.

**The bind types are already declared.** `types.bal:7` defines the full `BindType` enum
including `TRANSMITTER` and `TRANSCEIVER`; `types.bal:21` narrows to
`ListenerBindType = RECEIVER|TRANSCEIVER`. A transceiver bind is *already* a legal listener
config, and a TRX session is bidirectional. Nothing blocks submitting on it today.

**The session is reachable.** `NativeListener` stores it as native data on the Ballerina
`Listener` object:

| Key | Type | Where |
|---|---|---|
| `smpp.session` | `AtomicReference<SMPPSession>` | `NativeListener.java:38`, set at `:98` |
| `smpp.dispatcher` | `Dispatcher` | `:39` |
| `smpp.config` | `BMap<BString, Object>` | `:40` |
| `smpp.state` | `AtomicReference<ListenerState>` | `:42` |

**Errors have a house style.** `ModuleUtils.createError(String)` — used throughout
`NativeListener` (`:107`, `:126`, `:150`, `:419`). Ballerina side: `public type Error distinct error;`
(`types.bal:294`).

**Dispatch is centralised.** `Dispatcher` calls the service via
`runtime.callMethod(svc, method, meta, sms)` at two sites — the ASYNC virtual-thread path
(`~607`) and the SYNC path (`~628`) — with `StrandMetadata(false, null)`.

**There is a real test double.** `smpp/native/src/testBridge/.../MockSmsc.java` +
`MockSmscBridge.java` expose 18 static bridge methods to Ballerina tests (`openMock`,
`awaitNextBind`, `sendDeliverSm`, `sendDeliveryReceipt`, `sever`, `peerUnbind`,
`setTransactionTimer`, …), wrapped by `smpp/ballerina/tests/mocksmsc.bal`. 21 test files
already exist. You will extend this, not build it.

---

## 3. The design decision

**Where does `submit` live?** This is the only genuinely contested question; everything else
follows from it.

### Option A — `smpp:Caller` passed to the remote method ✅ recommended

```ballerina
remote function onDeliverSm(smpp:Caller caller, smpp:Sms sms) returns error? {
    string messageId = check caller->submit({
        destAddr: sms.sourceAddr,
        shortMessage: "MTC: Airtime N$47.50. Valid to 2026-08-11.",
        requestDeliveryReceipt: true
    });
}
```

- Matches the established Ballerina pattern for replying on the session a message arrived
  on (`http:Caller`, `websocket:Caller`, gRPC callers). Users will already know it.
- Reuses the single TRX session. No second bind, no second set of credentials.
- Scopes the capability where it makes sense: you reply *to* something.
- Cheap: the session is already there, the dispatch path is already there.

### Option B — a `submit` method on `Listener`

Least code. But a "listener" that sends reads wrong, and it's callable from anywhere in the
program with no inbound context — including before `start()` and after `gracefulStop()`,
which you'd then have to guard.

### Option C — a standalone `smpp:Client` with its own bind

Genuinely needed *eventually*, for MT-only applications (bulk send, no inbound at all) —
a case A cannot serve, since with no inbound message there is no caller. But it means
reimplementing everything `NativeListener` already does: bind lifecycle, `enquire_link`
keepalive, rebind with backoff, graceful stop, TLS. Starting here means two copies of the
rebind logic.

### Recommendation

**Ship A first. Do C in a later sprint, and only after extracting the session lifecycle out
of `NativeListener` into a shared connection type that both `Listener` and `Client` own.**
A is the smallest change that unblocks the dominant use case; C without the refactor is a
maintenance trap.

### Backward compatibility — important

The package is published at 1.0.1. Existing services declare `onDeliverSm(smpp:Sms sms)`.

**Make the `Caller` parameter opt-in**, detected by inspecting the method's parameter list,
so both arities dispatch correctly:

- `onDeliverSm(smpp:Sms sms)` — keeps working, unchanged
- `onDeliverSm(smpp:Caller caller, smpp:Sms sms)` — new, gets the caller

Opt-in makes this a **minor** release (1.1.0). Making the parameter mandatory would break
every existing user and force 2.0.0. `Dispatcher.attach` currently validates by method
*name* only (`Dispatcher.java:216-231`, collecting `objType.getMethods()` into a name set) —
it never looks at parameters. `MethodType` is already imported (`Dispatcher.java:8`), so
`method.getParameters().length` is right there.

---

## 4. Proposed public API

Sketch, not final — argue with it during Phase 1/2 review.

```ballerina
# How the short message is encoded on the wire, and hence the PDU's `data_coding`.
public enum Encoding {
    # GSM 03.38 7-bit default alphabet, packed. data_coding 0x00. The carrier default.
    GSM7,
    # Latin-1. data_coding 0x03.
    LATIN1,
    # UCS-2 big-endian — needed for non-Latin scripts. data_coding 0x08. Halves capacity.
    UCS2
}

# An outbound short message (`submit_sm`).
public type OutboundSms record {|
    # Recipient MSISDN. E.164 without the leading `+` for TON=INTERNATIONAL.
    string destAddr;
    # Sender address; defaults to `ConnectionConfig.sourceAddr` when omitted.
    string sourceAddr?;
    # The message text.
    string shortMessage;
    # Ask the SMSC for a delivery receipt. The DLR arrives later on `onDeliverSm`
    # with `deliveryReceipt == true` and `receipt.id` matching the returned message id.
    boolean requestDeliveryReceipt = false;
    # Wire encoding; determines `data_coding`.
    Encoding encoding = GSM7;
    # Destination address type-of-number / numbering-plan-indicator.
    int destAddrTon = 1;    // INTERNATIONAL
    int destAddrNpi = 1;    // ISDN
    # How long the SMSC should keep trying, in seconds. `()` = the SMSC's default.
    decimal? validityPeriod = ();
|};

# Replies on the SMSC session an inbound message arrived on. Obtained by declaring it as
# the first parameter of a remote method; never constructed directly.
public isolated distinct client class Caller {
    # Submits a short message (`submit_sm`) and waits for `submit_sm_resp`.
    #
    # + sms - the message to send
    # + return - the SMSC's `message_id` (correlate DLRs against this), or an `Error`
    remote isolated function submit(OutboundSms sms) returns string|Error;
}
```

Deliberate choices worth defending or overturning:

- **Do not reuse `Sms` for outbound.** It carries `deliveryReceipt`, `receipt`,
  `shortMessageBytes` and a decoded-on-receive `properties` map — all meaningless when
  sending. A separate record keeps both honest.
- **Return `string` (the message id), not `()`.** This is what makes DLR correlation
  possible and is the whole reason the receive side's receipt parsing becomes useful.
- **`int` for TON/NPI** mirrors how the inbound `Sms.properties` already reports them
  (`types.bal:220` documents `sourceAddrTon`/`destAddrNpi` etc. as `int`). Typed enums would
  be nicer but would be inconsistent until the inbound side changes too. Pick one and be
  consistent.
- **New `ConnectionConfig` field: `sourceAddr`** (the short code / sender ID), so callers
  don't repeat it per message. Add validation in `validateConfig` (`listener.bal:~100`).

---

## 5. Implementation plan

### Phase 1 — `Caller.submit` on a transceiver bind

| # | File | Change |
|---|---|---|
| 1 | `smpp/ballerina/types.bal` | Add `Encoding`, `OutboundSms`. Add `sourceAddr` to `ConnectionConfig`. |
| 2 | `smpp/ballerina/caller.bal` *(new)* | `Caller` client class; `submit` externs to `NativeCaller.submit`. |
| 3 | `smpp/ballerina/listener.bal` | Validate `sourceAddr` in `validateConfig`. Extend the `Service` type docs to describe the two-arity contract. |
| 4 | `smpp/native/.../NativeCaller.java` *(new)* | `submit(BObject caller, BMap<BString,Object> sms)`. Reads the session, encodes, calls `submitShortMessage`, maps exceptions, returns the message id as `BString`. |
| 5 | `smpp/native/.../Dispatcher.java` | In `attach` (`:216`), inspect `method.getParameters().length` and record the arity per method. At the two `callMethod` sites (`~607`, `~628`), pass `caller, sms` for the 2-arity form and `sms` for 1-arity. |
| 6 | `smpp/native/.../NativeListener.java` | Construct one `Caller` BObject at `initListener` (or first attach), hand it to the `Dispatcher`. Store under a new native-data key, e.g. `smpp.caller`. |
| 7 | `smpp/native/.../Gsm0338.java` *(new, or fold into `Dispatcher`)* | The GSM 03.38 encoder — inverse of `decodeGsm0338Unpacked`, including the escape table. |

**One `Caller` per listener is enough.** It holds only the session reference; nothing is
request-scoped. Don't allocate one per PDU.

### Phase 2 — standalone `smpp:Client` (later sprint)

Prerequisite refactor: lift bind/rebind/keepalive/stop out of `NativeListener` into a shared
connection type. Then `Client` is a thin `bind_transmitter` wrapper over it. Do not attempt
before Phase 1 ships.

---

## 6. Things that will bite you

Ordered by how likely they are to cost you a day.

### 6.1 The session is swapped on rebind — never cache it

`smpp.session` is an `AtomicReference<SMPPSession>` (`NativeListener.java:98`) and
`attemptRebind` (`:345`) **replaces its contents**. A `Caller` that grabs the `SMPPSession`
at construction will submit on a dead socket after the first reconnect — and it will look
like an intermittent, load-dependent bug.

**Read through the `AtomicReference` on every submit.** Then decide, explicitly, what
`submit` does while a rebind is in flight: fail fast with a distinguishable error, or block
briefly? Fail fast is easier to reason about and easier to test; say so in the docs either
way.

### 6.2 GSM-7 encoding is yours to write

No encoder in jsmpp (§1). The escape-table characters are where implementations go wrong:
`€ [ ] { } \ ~ | ^` each occupy **two** septets. Get it wrong and subscribers see mojibake,
or the message silently truncates.

**Suggested sequencing:** ship Phase 1 with `LATIN1` and `UCS2` (trivial — `String.getBytes`
with the right charset) and make one of them the default. Add `GSM7` as a focused follow-up
with its own test vectors. That keeps the plumbing work separate from the codec work, and
`gsm7_test.bal` already exists as a home for the tests.

### 6.3 Long messages

A single `submit_sm` carries 140 octets — 160 GSM-7 septets, or 70 UCS-2 characters. Beyond
that you need UDH concatenation (`LongSMS.splitMessage8Bit`, 8-bit only) or the
`message_payload` TLV.

**Decide before you design the return type:** if `submit` auto-splits, it produces *several*
message ids, and `returns string|Error` becomes `returns string[]|Error` — a breaking change
if you add splitting later. Either return an array from day one, or reject oversize input
with a clear error and add a separate `submitLong` later. Don't paint yourself into a corner
here.

The connector already declines to *reassemble* inbound concatenated messages and documents
`udhi` in `Sms.properties` — staying symmetrical (reject, document, let the user split) is a
defensible v1.

### 6.4 Throttling

Carriers cap submits per second and answer `ESME_RTHROTTLED` past the cap. The inbound path
already models this idea — `maxConcurrentDispatch` exhaustion returns
`STAT_ESME_RTHROTTLED` (`Dispatcher.java:~589`).

Decide whether rate limiting belongs in the connector or the user's code. Surfacing a
*distinguishable* throttle error is the minimum; a built-in limiter is a nice-to-have.

### 6.5 Concurrency and the transaction timer

`submitShortMessage` is **synchronous** — it blocks until `submit_sm_resp` arrives or the
transaction timer fires. jsmpp matches responses by `sequence_number`, so concurrent submits
on one session should be fine, **but verify this under load rather than assuming it** — it
interacts with `maxConcurrentDispatch`, since in SYNC mode a handler that submits is holding
a dispatch permit while it blocks. A slow SMSC could stall inbound dispatch entirely.

Worth an explicit test: N concurrent handlers each submitting, against a mock with a
deliberately slow `submit_sm_resp`.

### 6.6 Bind-state guard

jsmpp will reject a submit on a session that isn't `BOUND_TX`/`BOUND_TRX`. Return a clear
error for `bindType: RECEIVER` rather than letting a jsmpp exception leak. This **cannot**
be caught at compile time — `bindType` comes from `configurable` values — so it's a runtime
check with a good message: name the offending config field and the fix.

### 6.7 Both mock SMSCs need submit support before any test can pass

- `smpp/native/src/testBridge/.../MockSmsc.java` — grep finds **no** `onAcceptSubmitSm` at
  all. Submit handling has to be added, plus a bridge method (e.g.
  `mockSmscAwaitNextSubmit(mockId, connectionId, timeoutMillis)`) so tests can assert on what
  arrived, and one to force a negative response for the error-mapping tests.
- The example repo's standalone mock (`mock-smsc/src/main/java/MockSmsc.java` in
  smpp-ballerina-example) has a `NoOpListener` whose `onAcceptSubmitSm` **returns `null`** —
  it must return a real `SubmitSmResult` with a generated message id, and ideally print the
  MT so the example's round trip is visible.

---

## 7. Error mapping

This is most of what makes the connector more valuable than a raw jsmpp wrapper: the caller
needs to distinguish *retry* from *don't bother*.

`NegativeResponseException.getCommandStatus()` carries the SMPP `command_status`. Surface it
in the error detail — don't flatten everything into one opaque message.

| `command_status` | Meaning | Caller should |
|---|---|---|
| `ESME_RTHROTTLED` | Over the contracted TPS | Back off and retry |
| `ESME_RMSGQFUL` | SMSC queue full | Back off and retry |
| `ESME_RSUBMITFAIL` | Submit failed, unspecified | Retry with caution |
| `ESME_RINVDSTADR` | Invalid destination address | **Never retry** — bad MSISDN |
| `ESME_RINVSRCADR` | Invalid source address | **Never retry** — fix config |
| `ESME_RINVMSGLEN` | Message too long | **Never retry** — split it |
| `ESME_RINVBNDSTS` | Wrong bind state for this operation | **Never retry** — bug |

Use jsmpp's `SMPPConstant.STAT_*` constants rather than hex literals; don't hand-transcribe
values from the spec.

The other four checked exceptions want distinct treatment too: `ResponseTimeoutException`
(transient — the SMSC may still have accepted it, so retrying risks a duplicate; say so in
the docs), `IOException` (link is gone, a rebind is probably already underway),
`PDUException` and `InvalidResponseException` (programming/interop bugs, not worth retrying).

**Suggestion:** give `Error` a detail record with `commandStatus` (int) and
`commandStatusName` (string), and consider a `retriable` boolean so users don't have to
memorise the table. Whether that belongs in the connector or the user's code is a real
design question — raise it in review.

---

## 8. Test plan

`docs/qa-strategy.md` defines the levels; slot into them rather than inventing a new scheme.

**Level 2.1 — JUnit, pure native logic, no session.** The GSM-7 encoder is a perfect fit:
round-trip every character in the default alphabet plus the escape table against the existing
decoder, and assert the packed-septet byte layout against known vectors. Also `OutboundSms` →
jsmpp-argument mapping, if you factor that into a pure function (worth doing).

**Level 2.2 — `bal test` integration, real jsmpp round trip.** New files alongside the
existing 21:

| Test | What it pins |
|---|---|
| `submit_test.bal` | Happy path: submit, mock receives it, returned id matches the mock's generated id. |
| `submit_encoding_test.bal` | GSM7 / LATIN1 / UCS2 each produce the right `data_coding` and the right bytes at the mock. Mirror the existing `data_coding_test.bal` matrix. |
| `submit_error_test.bal` | Mock forces each negative `command_status`; assert the mapped error and its detail. |
| `submit_bind_type_test.bal` | Submitting on a `RECEIVER` bind fails with a clear error. |
| `submit_rebind_test.bal` | **The §6.1 regression.** Submit, `sever`, wait for rebind, submit again — must succeed on the new session. This is the test that catches a cached-session bug. |
| `caller_arity_test.bal` | A 1-param `onDeliverSm` still dispatches (the backward-compat guarantee), and a 2-param one receives a working caller. |
| `submit_concurrency_test.bal` | N concurrent handlers submitting against a slow-responding mock; assert no interleaving corruption and that §6.5 behaves as documented. |

**End-to-end.** The balance-enquiry example in `smpp-ballerina-example` is a ready-made
acceptance test: switch its listener to `TRANSCEIVER`, add the `caller` parameter, replace
the `reply()` log with `caller->submit(...)`, and confirm the full MO → REST → MT → DLR loop
including receipt correlation on the returned message id. Its mock already pushes a DLR whose
`id:0123456789` currently correlates with nothing.

---

## 9. Docs to update

Bundled docs are part of the published package — don't let them lag.

- `smpp/ballerina/Module.md` and `Package.md` — both currently describe a **receive-only
  trigger**. That framing changes.
- `docs/architecture.md` — `### Bind modes` (`:161`) and `## Service contract` (`:270`) need
  the transceiver/submit story and the two-arity remote-method contract.
- `examples/two-way-sms/README.md` — explicitly says the connector can't send the reply.
  This is the example that most wants rewriting once Phase 1 lands.
- `examples/README.md` — the framing paragraph makes the same receive-only claim.

---

## 10. Open questions for review

Decide these in Phase 1/2, not mid-implementation:

1. **Auto-split long messages, or reject them?** Determines whether `submit` returns
   `string` or `string[]`. Hardest to change later. (§6.3)
2. **Default `Encoding`?** `GSM7` is what carriers expect but needs the new encoder;
   `LATIN1` ships sooner. Affects whether Phase 1 can land without the codec.
3. **Rate limiting in the connector, or the user's problem?** (§6.4)
4. **Does `Error` carry a structured detail** (`commandStatus`, `retriable`), or just a
   message? (§7)
5. **Behaviour of `submit` during a rebind** — fail fast, or block? (§6.1)
6. **TON/NPI as `int` or typed enums?** Consistency with inbound `Sms.properties` says
   `int`; ergonomics say enums. Changing both sides is a bigger, separate piece of work.

---

## Appendix — how the jsmpp claims were verified

Reproduce any of this before trusting §1:

```bash
JAR=$(find ~/.gradle/caches -name "jsmpp-3.0.2.jar" | head -1)

javap -cp "$JAR" org.jsmpp.session.SMPPSession | grep -i submit
javap -cp "$JAR" org.jsmpp.session.SubmitSmResult
javap -cp "$JAR" org.jsmpp.bean.LongSMS

# No GSM 03.38 codec — only the Alphabet enum:
unzip -l "$JAR" | grep -iE "0338|gsm7|Alphabet"
```

Everything in §2 came from reading `smpp/native/src/main/java/io/ballerinax/smpp/*.java`,
`smpp/ballerina/{types,listener}.bal`, and `smpp/gradle.properties` at `main`. Line numbers
are from that revision and will drift — treat them as pointers, not addresses.

Two claims are **not** verified and are flagged as such in the text: jsmpp's thread-safety
for concurrent submits on one session (§6.5), and the exact `SMPPConstant.STAT_*` values
(§7). Confirm both in code rather than taking this document's word.
