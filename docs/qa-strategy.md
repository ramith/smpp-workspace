# QA strategy — `ramith/smpp`

Living reference for what "adequately tested" means for this connector before and after
its Ballerina Central release. Read this before adding a feature, fixing a bug, or judging
whether a change needs new tests. Companion to `docs/architecture.md` (behavior/design
rationale); this document is about how that behavior is verified and kept verified.

## 1. Scope and quality goals

`ramith/smpp` is an SMPP trigger listener with reply support (bind as RECEIVER/TRANSCEIVER,
dispatch inbound `deliver_sm`/`data_sm` to a user service). "Done" for a public Ballerina
Central release means, at minimum:

- Every branch in the native glue (`Dispatcher`, `NativeListener`) that can be reached by
  a real SMSC interaction has been exercised at least once by an automated test, not just
  read and reasoned about.
- Every documented behavior in `docs/architecture.md` (bind modes, `ResponseMode`,
  `RebindPolicy`, `gracefulStop`/`immediateStop`, `data_coding` decoding, `message_payload`
  precedence) has a test that would fail if that behavior regressed.
- Zero automated tests may pass "by coincidence" — see the data-coding test design below
  for why plain ASCII fixtures are explicitly disallowed for most cases.
- The `data_sm` NPE class of bug (a native callback returning a value jsmpp's own PDU
  processor dereferences unconditionally) cannot recur silently: any PDU type the
  connector claims to support must be sent through a real jsmpp session round-trip by at
  least one test.

Before this document, the only verification artifact in this repo was a manual,
single-path smoke test (`mock-smsc/MockSmsc.java` + `smpp_tester/main.bal`): one bind,
one unconditionally-accepted credential check, one ASCII `deliver_sm`. There was no
`tests/` directory at all. That is the gap this document and the accompanying rewrite
close.

## 2. Test levels

Three levels, each with a distinct job. Do not duplicate coverage across levels — push
each case to the cheapest level that can actually exercise it.

### 2.1 Fast JUnit tests (pure native logic, no jsmpp session, no Ballerina runtime) ✅ DONE (Sprint 0)

**Status:** implemented in Sprint 0 — see `smpp/native/src/test/java/io/ballerinax/smpp/DispatcherTest.java`
(14 cases) and `NativeListenerTest.java` (6 cases, covering the credential-length
validation added in the same sprint). 20/20 passing via `./gradlew :smpp-native:test`.

**Scope:** `Dispatcher.decodeShortMessage(byte[], byte)` and `Dispatcher.payloadBytes(AbstractSmCommand, byte[])`
(made package-private directly, not extracted into a separate `PduCodec` utility — the
simpler of the two originally-considered options, and sufficient) so a JUnit test in the
same package can call them directly without reflection.

Both are pure functions: no socket, no jsmpp `Session`, no Ballerina `Runtime`/`BObject`.
`payloadBytes` only needs a constructed jsmpp bean (`DeliverSm`/`DataSm` with an
`OptionalParameter.Message_payload` set on it, a few lines), not a live session. This
makes the full `data_coding` × precedence × null/empty-input combinatorial matrix cheap
to enumerate exhaustively here (milliseconds per case) instead of expensively via a full
`bal test` round trip (JVM + Ballerina runtime + socket bind + jsmpp handshake, seconds
per case).

**Tooling:** native glue now builds as a proper Gradle subproject
(`smpp/native/build.gradle`, part of the `smpp/` root multi-project build — see
`docs/sprint-plan.md`'s build-restructuring note). Use that directly rather than a
hand-rolled script: add JUnit 5 (`org.junit.jupiter:junit-jupiter`) as a `testImplementation`
dependency in `native/build.gradle`, put test sources under
`smpp/native/src/test/java/io/ballerinax/smpp/`, and run them with Gradle's own `test` task
(`useJUnitPlatform()`) — `./gradlew :smpp-native:test` from `smpp/`, or transitively via
`./gradlew build`. No separate console-standalone jar or shell script needed; Gradle's
`java-library` plugin already wires JUnit discovery and reporting. Java test class files
stay PascalCase (`DispatcherTest.java`) — this is a Java-toolchain
naming requirement (class name must equal file name), exempt from this project's
lowercase-filename convention the same way `Ballerina.toml`/`Module.md` are.

**What belongs here, not in `bal test`:**
- All 4 `data_coding` branches (0x00/0x01/0x03/0x08) plus at least one reserved/unknown
  value (e.g. 0x02, 0x0F) confirming the UTF-8 fallback, using the exact byte fixtures
  defined in §3.4 below.
- `payloadBytes` precedence: `message_payload` present vs. absent, on both a `DeliverSm`
  (falls back to `getShortMessage()`) and a `DataSm` (falls back to empty — it has no
  `short_message` field at all).
- `decodeShortMessage` edge cases: null input, empty input (both must return `""`).

Run this suite on every native-glue change, independent of the full Ballerina toolchain —
it's the fastest feedback loop in the whole test pyramid. `native/build.gradle`'s `build`
task depends on both this suite and the native jar (Gradle's standard `check`/`assemble`
wiring doesn't order one before the other, so don't rely on the jar reflecting a test
failure — rely on `build` failing outright), so `./gradlew build` from `smpp/` gates on it
automatically — no separate script needed.

**Effort:** ~9h estimated (refactor for testability 1h, tooling setup 2h, writing the
matrix 5h, wiring 1h) — actual.

### 2.2 `bal test` integration tests (real jsmpp round trip via a rewritten mock SMSC)

**Scope:** everything that requires a real jsmpp `SMPPSession`/`SMPPServerSession` pair
talking over a real socket — bind negotiation, dispatch timing (`SYNC`/`ASYNC`), listener
lifecycle (`gracefulStop`/`immediateStop`), session-drop detection and rebind, and
end-to-end PDU decode (proving the *whole path*, not just the pure decode function,
works — real jsmpp PDU parsing → `Dispatcher` → Ballerina `Sms` record → attached
service).

This is the level that would have caught the `Dispatcher.onAcceptDataSm` NPE (returns
`null`, which jsmpp's own `AbstractGenericSMPPSessionBound.processDataSm` dereferences
unconditionally via `dataSmResult.getMessageId()` before ever reaching a `catch` clause
that would handle it) — no JUnit test against the pure decode functions would ever have
touched that code path, since the bug is in the `DataSmResult` *return value*, not in
decoding. See §3 for the concrete redesign and test list; see §4 for why `data_sm`
end-to-end must be the very first test in this suite, written test-first against the
still-buggy code.

Given the pure-decode matrix now lives cheaply in §2.1's JUnit suite, this level's own
`data_coding`/`message_payload` tests should be trimmed to 1-2 representative smoke cases
per branch (proving wiring end-to-end), not the full edge-case matrix — that would be
redundant coverage at the most expensive level.

**Effort:** ~40h — see §3 and §4 for the itemized breakdown.

### 2.3 Manual/exploratory — intentionally minimal going forward

The existing `smpp_tester/main.bal` + a lightly-adapted `mock-smsc/MockSmsc.java`
demo path may remain as a standalone, runnable "getting started" example (useful for a
Ballerina Central user kicking the tyres, and referenced informally from `Package.md`),
but it is explicitly **not** part of this connector's coverage claim once §2.1/§2.2 land.
Nothing that can be automated should be left to manual verification only. The only things
this project expects to stay manual/exploratory indefinitely are listed as non-goals in
§6 (they're either out of scope entirely, or need infrastructure — e.g. TLS certs, a real
carrier-grade SMSC — disproportionate to this connector's current needs).

## 3. MockSmsc redesign and test case list

### 3.1 Design decision: rewrite as an in-process test double, not a subprocess

Reject patching the existing monolithic `MockSmsc.main()` in place — every new scenario
(rebind, bind-reject, `data_sm`, the `data_coding` matrix, abrupt drop, burst) would mean
either duplicating the whole file or growing an ever-larger CLI-arg branch in one
`main()`, and it still couldn't be *driven per test case* from `bal test`.

Reject a subprocess-based mock (spawn a separate `java` process per test, drive it over a
stdin/TCP control protocol) too: it would require designing and debugging a whole new IPC
protocol, and — critically — the test categories most likely to be flaky (rebind backoff
timing, `gracefulStop` draining, `immediateStop` non-waiting) are exactly the ones an
extra process boundary and IPC latency would make *harder* to assert on precisely.

**Recommendation:** rewrite `MockSmsc` as a small, reusable Java class exposing an
imperative API (accept-loop, configurable bind validator, PDU senders, two distinct
"drop" methods, a burst sender), bridged into `.bal` test files via the exact same
`ballerina/jballerina.java` interop mechanism the production connector already uses for
`Dispatcher`/`NativeListener` — a new `tests/native/io/ballerinax/smpp/test/MockSmscBridge.java`
(PascalCase — Java convention) with `@java:Method` externs, wrapped by a thin
`tests/mocksmsc.bal` Ballerina object (all `.bal` test-support files stay directly under
`tests/` — Ballerina does not support subdirectories within `tests/` as separate
compilation units). Build this bridge class the same way the production native glue is
built — as part of the `smpp/native` Gradle subproject (a distinct source set or a
second small Gradle module alongside it is fine; a one-off shell script is not needed now
that Gradle owns the native build). This keeps the mock in the same JVM as `bal test` itself: no IPC,
direct method-call assertions (a Java exception or return value, not parsed subprocess
output), and no extra timing-jitter source for the lifecycle tests.

One acknowledged trade-off: an in-process mock can't simulate a genuine OS-level TCP RST
as convincingly as a truly separate process being killed. `session.close()` (see §3.5)
from the same JVM still produces a real, independently-observable local socket close
distinct from a clean `unbind()` exchange, which is sufficient fidelity for this
connector's needs — a full network-partition simulation (e.g. via toxiproxy) would be
overkill for what's being tested here.

**Precedent used to ground this design:** jsmpp's own maintainers ship reference
client/server implementations at `jsmpp/jsmpp-examples/src/main/java/org/jsmpp/examples/`
in this workspace. Every concrete capability below cites the specific file/lines that
informed it, rather than inventing patterns from scratch.

### 3.2 (a) Multiple sequential connections — accept-loop

Blueprint: `StressServer.run()` (`jsmpp-examples/.../StressServer.java:58-76`) —
`while (true) { SMPPServerSession serverSession = sessionListener.accept(); ...;
waitBindExecService.execute(new WaitBindTask(serverSession, 60000)); }`, offloading the
blocking `waitForBind` onto a small thread pool so `accept()` itself is never blocked by
a slow or absent bind on the previous connection. `MockSmsc`'s rewrite adopts this
verbatim: an `acceptLoop()` background thread/virtual-thread calling `ssl.accept()`
repeatedly, each returned `SMPPServerSession` handed to a bind-wait task. This is what
makes rebind-after-drop testable at all: force a drop (§3.5), then the loop's next
`accept()` call is what the connector's rebind attempt actually connects to.

### 3.3 (b) Configurable bind-credential validation

Blueprint: `AcceptingConnectionAndBindExample.java:50-67` (simplest form — check
`systemId`/`password`, `request.accept("sys")` or `request.reject(SMPPConstant.STAT_ESME_RINVPASWD)`)
and the richer `WaitBindTask` in both `SMPPServerSimulator.java:233-271` and
`StressServer.java:184-205`, which distinguish *why* a bind is rejected — wrong
`systemId` (`STAT_ESME_RINVSYSID`) vs. wrong password (`STAT_ESME_RINVPASWD`) vs. wrong
bind type (`STAT_ESME_RBINDFAIL`) — using different `BindRequest.reject(int errorCode)`
codes per cause. `MockSmsc` adopts a pluggable validator with this same granularity
(default: accept everything, matching today's behavior, so the existing happy-path
demo keeps working unmodified).

**Finding worth flagging, not just testing:** `NativeListener.start()` today wraps any
bind failure into a single generic error string (`"failed to connect/bind to SMSC: " +
e.getMessage()`) — it does not surface *which* `STAT_ESME_*` rejection code the SMSC
actually sent. Writing this test will make that concrete: assert what the connector's
`error` actually contains today, and flag to the connector author whether callers should
be able to distinguish "bad credentials" from "wrong bind type" from "SMSC unreachable"
programmatically, not just by string-matching an error message.

### 3.4 (c) `data_sm` PDUs, incl. `message_payload` TLV — the bug-catching capability

`DATA_SM` has no `short_message` field at all (confirmed via jsmpp's class hierarchy —
`DataSm extends AbstractSmCommand` directly, skipping `MessageRequest` where
`shortMessage` lives) — its payload is always the `message_payload` TLV.

Blueprint for sending: `StressClient.newSendTaskData()` (`StressClient.java:235-268`) —
`new OptionalParameter.Message_payload(bytes)` passed as an `OptionalParameter` vararg
into `dataShortMessage(...)`. That method lives on `AbstractSession` (confirmed:
`AbstractSession.java:231-247`) and is inherited concretely by `SMPPServerSession` — so
the mock (playing the SMSC) can call `session.dataShortMessage(...)` directly to push a
`data_sm` down to the connector, exactly mirroring the client-side example's call shape
even though no example in this codebase happens to show a *server* making this call (the
SMSC-to-ESME direction for `DATA_SM` is unusual — most real traffic uses `deliver_sm` —
but it is a plain inherited public method, nothing jsmpp-internal blocks it).

**This is the literal reproduction of the confirmed NPE.** `dataShortMessage(...)` blocks
awaiting `data_sm_resp` (`AbstractSession.java:245`, `executeSendCommand(task,
getTransactionTimer())`). Trace of what happens today: the connector's jsmpp session
receives the PDU, `AbstractGenericSMPPSessionBound.processDataSm` (jsmpp) calls
`responseHandler.processDataSm(dataSm)` → `Dispatcher.onAcceptDataSm` → returns `null` →
back in jsmpp, `log.debug("...", dataSmResult.getMessageId(), ...)`
(`AbstractGenericSMPPSessionBound.java:128`) NPEs immediately, uncaught by the
surrounding `catch (PDUStringException | ProcessRequestException)` block — so no
`data_sm_resp` is ever sent back. From the mock's side, that means
`session.dataShortMessage(...)` **times out** (`ResponseTimeoutException`) rather than
returning normally. A test that calls this and asserts a real `DataSmResult` (non-null
message ID) comes back is a direct, mechanical repro of the bug and a direct verification
of the fix — see §4 for why this must be written first.

**Upstream reference implementations confirm the fix shape, three separate times, one of
them literally the same interface `Dispatcher` implements:**
- `MessageReceiverListenerImpl.onAcceptDataSm` (`MessageReceiverListenerImpl.java:77-81`)
  — implements `org.jsmpp.session.MessageReceiverListener`, the *exact same interface*
  `Dispatcher` implements — throws `ProcessRequestException(DATASM_NOT_IMPLEMENTED,
  SMPPConstant.STAT_ESME_RINVCMDID)`.
- `SMPPServerSimulator.onAcceptDataSm` (`SMPPServerSimulator.java:176-181`) — same
  pattern, `STAT_ESME_RSYSERR`.
- `StressServer.onAcceptDataSm` (`StressServer.java:119-127`) — the one example that
  actually implements the behavior rather than stubbing it: constructs and returns a real
  `new DataSmResult(messageId, new OptionalParameter[]{})`.

None of the three ever returns `null`. This is decisive, citable, external evidence (not
just this project's own jsmpp-source reading) that `Dispatcher.onAcceptDataSm` returning
`null` unconditionally violates the library's own documented usage contract.

### 3.5 (d) `data_coding` matrix — real, non-coincidental byte content

Plain ASCII content passes "by accident" under almost any codec — it is not a meaningful
test for 3 of these 4 branches. Concrete fixtures:

- **0x00 (GSM-7 default/fallback), `Alphabet.ALPHA_DEFAULT`:** the connector *deliberately*
  does not implement a real GSM 03.38 codec and falls back to UTF-8 for this value (see
  `docs/architecture.md`/`Dispatcher.decodeShortMessage` doc comment) — so the correct
  test is not "GSM7 decodes correctly" (it doesn't, by design) but a regression pin on the
  documented fallback. Send the raw byte `0x00` itself: in real GSM 03.38 this is `'@'`
  (COMMERCIAL AT), not NUL — assert the connector's actual UTF-8-fallback decode of that
  byte (not `'@'`), so a future contributor who adds a real GSM7 codec without updating
  this test gets a loud, explicit failure instead of a silent behavior change. Also
  include the GSM7 extension-table escape byte `0x1B` in the fixture to confirm the
  fallback path doesn't choke on it either.
- **0x01 (IA5/ASCII), `Alphabet.ALPHA_IA5`:** this is the *one* branch where ASCII content
  is legitimately meaningful, since IA5 is ASCII. Use the full printable range plus
  boundary bytes: `"Hello, World! @ #1 - 100%"` (space `0x20` through `~` `0x7E`), plus a
  standalone `0x7F` (DEL) to confirm no crash at the edge.
- **0x03 (Latin-1/ISO-8859-1), `Alphabet.ALPHA_LATIN1`:** use real Latin-1 code points in
  the `0x80`-`0xFF` range that are invalid as standalone UTF-8 — e.g.
  `"Café, mañana, naïve, ¿qué?"` encoded via `ISO_8859_1` (é=`0xE9`, ñ=`0xF1`, ï=`0xEF`,
  ¿=`0xBF`). Do **not** include `€` — it's not representable in true ISO-8859-1 (that's
  Latin-9/CP1252 territory), and using it would silently test the wrong codec.
- **0x08 (UCS2/UTF-16BE), `Alphabet.ALPHA_UCS2`:** must be non-Latin script content, or a
  naive "every other byte is 0x00" padding bug could hide behind it. Blueprint:
  `SendUnicode.java:51-61` — literally jsmpp's own example for this exact data coding —
  builds the Arabic word for "house" from raw Unicode escapes
  (`"بَيْٺُ"`) and encodes it via
  `getBytes(StandardCharsets.UTF_16BE)`, with an explicit comment: *"UCS-2 is subset of
  the UTF-16BE charset, only the Basic Multilingual Plane codepoints are encodeable as
  UCS-2."* Reuse this fixture verbatim (or an equally non-Latin BMP alternative, e.g.
  Japanese "こんにちは") as the primary case. As a secondary/stretch case, also send a real
  UTF-16 surrogate pair (e.g. an emoji) — technically outside strict UCS-2's BMP-only
  contract, but real SMSCs do sometimes send UTF-16 mislabeled as UCS2, and Java's
  `UTF_16BE` decoder will reassemble a valid surrogate pair correctly since UTF-16BE is
  a superset in that specific case — worth one assertion documenting that real-world
  leniency, clearly labeled as "beyond spec" in the test comment.
- **Optional, cheap addendum — UDHI passthrough (not full concatenation):** the connector
  explicitly does not reassemble concatenated/binary short messages (documented in
  `Sms.properties.udhi`'s doc comment) — so the one thing worth pinning here is that a
  PDU with `esm_class`'s UDHI flag set (`GSMSpecificFeature.UDHI`, see
  `SubmitMultipartMultilangualExample.java:104-110`) surfaces `properties.udhi == true`
  and passes the raw bytes through untouched, rather than attempting (and mishandling) any
  reassembly. Exact 6-byte UDH prefix to use, taken directly from jsmpp's own
  concatenation helper (`jsmpp-examples/.../util/Concatenation.java:113-133`,
  `concatenate8bit`): `05 00 03 <ref> <total> <seq>` (header length 0x05, IE identifier
  0x00 = concatenated SM 8-bit reference, IE length 0x03, then the 1-byte reference
  number, total-segment count, and this segment's sequence number) followed by segment
  content bytes. A single trivial `total=1, seq=1` "segment" is enough — the point is
  proving pass-through, not exercising real multi-segment splitting.

### 3.6 (e) Abrupt/hard severance vs. peer-initiated unbind — two distinct methods

Confirmed via `AbstractSession.java`: `close()` (line 251) closes the underlying
`connection()` socket directly — no `unbind` PDU sent at all; `unbind()` (line 428) sends
an `unbind` PDU and blocks awaiting `unbind_resp`; `unbindAndClose()` (line 453) is simply
`unbind()` then `close()`. The mock exposes both as separately callable methods:
`sever()` → `session.close()` (abrupt), and `peerUnbind()` → `session.unbind()` (clean,
peer-initiated). `StressServer`'s `SessionStateListenerImpl`
(`StressServer.java:167-173`) is the blueprint for observing/logging the resulting state
transitions from the mock side during test development.

**Finding worth flagging:** `NativeListener`'s own `SessionStateListener` (in `bind()`)
does not distinguish these two cases today — both eventually surface as a transition to
`SessionState.CLOSED`, and the only guard is the `bound`/`stopping` `AtomicBoolean` pair,
which is only set by the connector's *own* `gracefulStop`/`immediateStop`. That means a
clean, peer-initiated `unbind` (e.g. "SMSC going down for maintenance, reconnect later")
is treated identically to an abrupt severance: `onError` fires and a rebind is scheduled
in both cases. That may well be intentional, but today it is untested and undocumented as
a deliberate choice — item 3.6's tests should assert on whatever the *intended* behavior
is (confirm with whoever owns the in-flight lifecycle work, per §4), not just pin
whatever the code happens to do.

### 3.7 (f) Burst PDUs — `maxConcurrentDispatch` backpressure

Both `deliverShortMessage` and `dataShortMessage` block the calling (mock-side) thread
until their own response arrives (`executeSendCommand`, `AbstractSession.java`) — so a
single mock sender thread calling these serially can never produce genuine concurrent
in-flight PDUs; each call fully completes (including waiting for the connector's
response) before the next begins. Genuine concurrency requires multiple mock-side sender
threads.

Blueprint: `StressClient` (`StressClient.java:82-101, 183-185, 270-293`) — a bounded
`Executors.newFixedThreadPool(maxOutstanding)` sender pool, each task making one blocking
send call and timing its own round trip, plus a `TrafficWatcherThread` logging
requests/responses-per-second and max delay every second. `MockSmsc.sendBurst(count,
concurrency)` adopts this shape directly: `concurrency` sender threads (set to
`maxConcurrentDispatch + 2`, to prove the excess genuinely queues/blocks rather than
being dispatched immediately), each with a unique tagged payload, submitting `count`
total PDUs. The mock's own `SMPPServerSessionListener` `pduProcessorDegree`/
`queueCapacity` (`StressServer.java:62`, `SMPPServerSessionListener.java:96-108`) should
be set generously on the mock side, so the *test's* only bottleneck is the connector's
own `maxConcurrentDispatch` (`session.setPduProcessorDegree(...)` in
`NativeListener.bind()`), not an accidental one on the mock side.

On the Ballerina test side: the attached test service's handler tracks concurrent
invocation count (an `isolated` counter with a `lock`) and sleeps briefly inside the
handler to widen the observable window, then asserts peak concurrency is both
`<= maxConcurrentDispatch` (the bound holds) and `== maxConcurrentDispatch` at some point
during the burst (the bound is actually reached, not just never violated by chance).

### 3.8 Effort

~30h total: design/spike proving the in-process jballerina.java bridge approach (4h);
core `MockSmsc` rewrite — accept-loop, validator, `sever()`/`peerUnbind()`,
`sendDeliverSm`/`sendDataSm` with `data_coding`+`message_payload` params, `sendBurst`
(10h); native bridge + `tests/mocksmsc.bal` wrapper + `tests/build-native-tests.sh` (6h);
byte-content fixtures per §3.5, incl. the UTF-8-fallback pin and UDHI passthrough case
(3h); hardening — port reuse across parallel test runs, deterministic per-test cleanup,
javadoc (4h); review/iteration buffer (3h).

## 4. Prioritized, phased rollout

### Phase 0 — Unblock and verify the `data_sm` fix ✅ DONE (Sprint 0)

**Status:** done, but with a smaller bridge than originally scoped here. Rather than the
full accept-loop/bridge scaffolding (§3.2's 16h core-rewrite budget), Sprint 0 shipped a
deliberately minimal one: `MockSmscBridge.java` opens a listener, accepts and binds
**exactly one** connection, and can send **one** `data_sm` — no accept-loop, no
credential-rejection, no bursts. This was enough to prove the fix test-first (confirmed
failure mode: an uncaught NPE in jsmpp's `AbstractGenericSMPPSessionBound.processDataSm`,
not the `SMPPSession$ResponseHandlerImpl`-level catch originally guessed at in §3.4 —
close to the predicted mechanism but one layer removed; see `docs/sprint-plan.md`'s Sprint
0 section for the corrected trace) and now guards against it recurring. See
`docs/sprint-plan.md`'s Sprint 0 entry for the full account, including two earlier
approaches that didn't work and why.

**Consequence for Phase 1 below:** its "depends on Phase 0's bridge scaffolding existing"
assumption is only partly true now — the *existence* of a working `@java:Method` bridge
pattern (Gradle `testBridge` source set → `testOnly` Ballerina.toml dependency →
`tests/mocksmsc.bal` wrapper) is proven and reusable, but `MockSmscBridge.java`'s internals
(static `listener`/`session` fields, single-shot `acceptAndBind`) don't fit an accept-*loop*
serving multiple connections over the listener's lifetime — Phase 1 needs to **restructure**
that state model (static fields → an instance/registry addressable per-connection) before it
can extend it with credential validation, bursts, etc. Budget for a rewrite of
`acceptAndBind`/`sendDataSm`'s internals, not an additive change; `openListener`/`close` and
the surrounding Gradle/Ballerina.toml wiring survive as-is.

The JUnit suite (§2.1, 9h estimated) is also done — see its own status note above.

### Phase 1 — Independent coverage, no blockers ✅ DONE (Sprint 1)

**Status:** shipped in Sprint 1. The bridge was restructured (not just extended) per the
consequence note above: `MockSmsc.java` is now an instance-based accept-loop server
(wait-bind offloaded to a small pool, per `StressServer`'s blueprint) with configurable
bind-credential validation (distinguishing `RINVSYSID`/`RINVPASWD` per
`SMPPServerSimulator`'s `WaitBindTask`), and `MockSmscBridge.java` is a thin handle-based
static facade (`openMock`/`awaitNextBind`/`sendDeliverSm`/`sendDataSm`/`closeMock`) — no
shared singleton state between tests. The five test files all landed: `bind_test.bal`
(rejection ×2), `sync_dispatch_test.bal` (positive + negative ack, incl. proof the failing
handler ran before the negative resp), `async_dispatch_test.bal` (ack-before-handler
ordering via a completion-marker, plus handler-failure-invisible-to-SMSC),
`data_coding_test.bal` (one smoke case per decoder branch, fixtures verbatim from
`DispatcherTest.java`), `message_payload_test.bal` (precedence ×4, incl. DATA_SM's
no-TLV empty fallback). The **burst sender (§3.7) was deferred to Sprint 4** (recorded in
sprint-plan.md's Sprint 1 scope adjustments — its only consuming test is Sprint 4's
saturation test, and shipping an untested capability cuts against §2.3's own bar).

**Known gap — fixed test ports (tracked here, referenced from the test files):** each of
the six `bal test` files binds a hardcoded, file-unique port (27776–27781). Distinct
ports prevent the files colliding with each other, but nothing protects against an
unrelated process holding one of them, or against TIME_WAIT rebinding flakiness when two
tests in one file (e.g. `bind_test.bal`) close and reopen the same port back-to-back.
The fix (ephemeral port-0 binding + `SMPPServerSessionListener.getPort()` read-back) is
deliberately deferred until it first flakes in practice or CI parallelism arrives,
whichever comes first.

### Phase 2 — Lifecycle-timing coverage (~26h, gated)

`NativeListener`'s rebind/`gracefulStop`/`immediateStop` machinery is fully implemented
today and was manually smoke-tested once (see project history), but has never been
covered by an automated, repeatable test — these tests would be the *first* automated
exercise of that code path. If the native-layer lifecycle machinery is being actively
reworked in parallel (as flagged for this rollout), **hold this phase** until that work
is confirmed landed and stable: asserting precise rebind-backoff timing, drain-timeout
behavior, or `maxRebindAttempts` exhaustion against code that's still moving is testing
against a moving target, and the tests would need rewriting anyway once it settles.

Before starting, spend ~1-2h confirming intended behavior for the two concrete latent
issues this review surfaced by inspection, so tests are written against the *intended*
final behavior rather than whatever the code happens to do today:
- the `stopping` `AtomicBoolean` (`NativeListener`) is set `true` by `gracefulStop`/
  `immediateStop` and never reset — restarting a listener after a stop would silently
  and permanently suppress all future rebind attempts;
- the abrupt-severance-vs-peer-unbind distinction noted in §3.6 is currently untested and
  possibly unintentional.

Work: mock's `sever()`/`peerUnbind()` (§3.6, ~4h); `graceful_stop_test.bal` (gracefulStop
actually waits up to `gracefulStopTimeout` for an in-flight SYNC dispatch, 5h);
`immediate_stop_test.bal` (immediateStop does not wait, 3h); `rebind_test.bal` (backoff
timing after an unexpected drop, and `maxRebindAttempts` exhaustion producing a final
`onError`, 8h); a CI flakiness-stabilization pass across all timing-sensitive tests from
every phase (6h).

**Total across all phases: ~81h (roughly 2 developer-weeks for one engineer, or about a
week with two engineers running Phase 0's two tracks and Phase 1 in parallel).**

## 5. Regression/CI expectations going forward

- `run-native-tests.sh` (§2.1's JUnit suite) runs on every change under `smpp/native/`,
  as a fast gate — before, or as part of, `build-native.sh`. It should never take more
  than a few seconds.
- `bal test` runs on every change to `.bal` sources and before any release build/publish
  to Ballerina Central. A release must not ship with a red `bal test` run.
- New behavior in `Dispatcher`/`NativeListener` is not considered complete until it has a
  corresponding `bal test` case (or a JUnit case, if it's pure logic per §2.1) — the
  `data_sm` NPE is the standing cautionary example of what ships when this rule isn't
  followed.
- Timing-sensitive tests (rebind backoff, `gracefulStop` draining) should use generous,
  clearly-commented tolerances, not tight sleeps, to avoid CI flakiness — budget for this
  explicitly (see Phase 2's stabilization pass) rather than discovering it later.

## 6. Explicitly out of scope (do not overclaim coverage here)

- **Real GSM 03.38 (7-bit default alphabet) decoding.** The connector deliberately falls
  back to UTF-8 for `data_coding 0x00`, since jsmpp's main library ships no GSM 03.38
  codec and packed-vs-unpacked septet behavior is vendor-dependent. §3.5's test pins the
  *documented fallback*, not correct GSM7 decoding — there is no correct GSM7 decoding to
  test. Implementing a real codec is a separate future feature with its own test plan.
- **UDH reassembly of concatenated/binary short messages.** `Sms.properties.udhi` is a
  raw passthrough signal; §3.5's optional UDHI case tests that passthrough, not
  reassembly. Multi-segment concatenation logic (jsmpp's own examples show what this
  would take — `jsmpp-examples/.../util/Concatenation.java`) is not implemented and not
  tested here.
- **TLS/SSL transport — now COVERED (Sprint 3 + its Phase-5 review), with these bounds.**
  `tls_test.bal` exercises: full deliver_sm round-trips over TLS (truststore and PEM-cert
  forms); the dev-only no-verify (`InsecureSocket`) path; an mTLS round-trip **plus a
  negative mTLS test** (no client `key` against a client-cert-requiring mock ⇒ bind fails —
  the test that proves the server actually *demands* mutual auth); **negative trust tests
  in both cert forms** (untrusted server cert fails the handshake via a wrong truststore
  AND via a wrong PEM — the mock always presents its own `CN=localhost` leaf, so the
  hostname check passes uniformly and chain-of-trust is the isolated variable); and a
  **hostname-verification pair** (a *trusted* cert with `CN=not-localhost` dialed as
  `localhost` ⇒ fails with `verifyHostName` defaulted, connects with `verifyHostName:
  false` — mutation-verified: deleting the endpoint-identification code makes exactly this
  test fail). Committed PKCS12 fixtures under `tests/resources/certs/` (regenerable via
  `gen-certs.sh`, contents keytool-verified). Still out of scope: exhaustive
  cipher/protocol negotiation matrices, real CA-signed / intermediate chains, and OCSP/CRL
  revocation — all JSSE behaviors rather than connector behaviors.
- **Outbound `submit_sm` flows — IN SCOPE since Sprint 8.** `Caller.submit` is covered
  at three levels: pure JUnit (compose/encode/error mapping, pool sizing), wire-pinning
  `bal test` (exact octets, TON/NPI, ids correlated via the mock's per-capture record),
  and fault-path tests (rebind survival, fail-fast, throttle-starvation, the
  duplicate-MT chain, concurrent correlation). Standalone transmitter binds remain out
  of scope (`smpp:Client` is backlog): what is untested is sending *outside a listener
  session*, not sending as such. (This bullet previously ended "nothing here tests
  sending", contradicting its own first sentence — a leftover from when submit was out
  of scope.)
- **Real carrier-grade SMSC interoperability quirks** (vendor-specific TLV usage, real
  network latency/partition behavior). The in-process `MockSmsc` is a faithful jsmpp-level
  test double, not a substitute for interop testing against an actual carrier or a
  hosted SMPP simulator — that remains a manual/pre-release activity if ever needed, not
  an automated one.
