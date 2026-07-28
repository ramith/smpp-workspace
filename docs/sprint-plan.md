# Remediation sprint plan — `ramith/smpp`

Source: an adversarial architecture/code review (5 independent SME passes + a hostile
red-team adjudication), followed by 4 SMEs designing fix plans for their domain
(java-architect, ballerina-developer, qa-expert, architect-reviewer). This document
reconciles those plans into a single, dependency-ordered execution plan.

**Pacing note:** no deadline is driving this; sequencing is by risk and dependency, not
calendar weeks. "Sprint" here means a milestone with an explicit exit gate — move to the
next one only when its gate passes, however long that takes. Hour estimates are included
for relative sizing, not as a schedule commitment.

**Prerequisites (done, before Sprint 0 starts):** the project is now on GitHub at
[ramith/smpp-workspace](https://github.com/ramith/smpp-workspace) (public; the vendored
`jsmpp/` source checkout is excluded via `.gitignore` — it's a reference copy of the
third-party library, not part of this project). The build itself was also broken and has
been fixed first, since every sprint below depends on being able to actually build and test
the connector: `smpp/build-native.sh` hardcoded machine-specific JDK/Ballerina install paths
and the native jar plus third-party dependencies were manually vendored as committed binary
blobs. It's now a proper Gradle multi-project build (`smpp/native/` + `smpp/ballerina/` as
sibling subprojects, modeled on `ballerina-platform/module-ballerinax-activemq`) — a single
`./gradlew build` from `smpp/` builds everything, verified end-to-end including
`bal push --repository=local` and a fresh `smpp_tester` rebuild against the result. See
[docs/development-process.md](development-process.md) for how each sprint below is actually
run.

## How to read this document

Each sprint has:
- **Goal** — why this work is grouped together
- **Work items** — the fix, who scoped it, and an effort estimate
- **Exit gate** — what must be true (usually: which tests pass) before moving on
- **Reconciliation notes** — where two SME plans disagreed on scope/estimate and how it
  was resolved, so the reasoning isn't lost

Companion documents: [docs/architecture.md](architecture.md) (design/behavior reference),
[docs/qa-strategy.md](qa-strategy.md) (the living test-coverage reference this plan's test
work feeds into).

---

## Sprint 0 — Stop the bleeding ✅ DONE

**Goal:** the two fully-independent, zero-dependency, high-severity items — a
100%-reproducible crash and a live credential-leak path. Both are safe to fix and ship in
isolation, before anything else in this plan starts.

| Item | Scope | Est. | Status |
|---|---|---|---|
| Fix `Dispatcher.onAcceptDataSm` returning `null` | Returns `new DataSmResult(EMPTY_MESSAGE_ID, new OptionalParameter[0])` instead of `null`; confirmed via jsmpp's own reference listeners (`MessageReceiverListenerImpl`, `SMPPServerSimulator`, `StressServer` in `jsmpp-examples`) that none of them ever return `null` here. Also: swept every other non-`void` `MessageReceiverListener` callback in `Dispatcher.java` — confirmed this is the *only* one with this shape. | 2h | Done |
| Credential length pre-validation | Validates `systemId` (≤15), `password` (≤8), `systemType` (≤12) *before* `connectAndBind` in `NativeListener.validateCredentials`, so jsmpp's own length-validator (which embeds the raw value in its exception message) is never reached with an oversized credential. Returns a clean, credential-free `IllegalArgumentException` instead. | 3–4h | Done |
| `data_sm` end-to-end regression test, written test-first | See "How the `data_sm` test actually got built" below — took two false starts to land on a working design. | ~10–15h (est.); took longer in practice due to the false starts | Done |
| Pure-logic JUnit suite for `decodeShortMessage`/`payloadBytes` | `smpp/native/src/test/java/io/ballerinax/smpp/DispatcherTest.java` (14 cases: the full `data_coding` matrix with real per-codec byte fixtures, `message_payload` precedence on both `DeliverSm`/`DataSm`, null/empty edge cases) + `NativeListenerTest.java` (6 cases: credential boundary values, confirms no credential substring leaks into any thrown message). Both methods made package-private (not the originally-considered `PduCodec` extraction) for direct testability. Wired into `native/build.gradle` (JUnit 5, `useJUnitPlatform()`). | 9h | Done — 20/20 passing |

**Exit gate:** ✅ all met. `./gradlew clean build` runs the full suite: 20 JUnit cases plus
the `data_sm` `bal test`, all green.

**Total: ~25–30h estimated.**

### How the `data_sm` test actually got built

The original plan (per `docs/qa-strategy.md`) called for building the *full*
MockSmsc-as-Ballerina-test-bridge (accept-loop, configurable bind validation, bursts) just
to prove this one fix. Two cheaper alternatives were tried first and both failed
instructively before landing on the right scope:

1. **A bare JUnit test** driving real jsmpp sessions directly, skipping Ballerina entirely
   (passing `new Dispatcher(null)` with no attached service). This doesn't work:
   `Dispatcher.onAcceptDataSm` unconditionally calls `toSms()` before it returns anything,
   and `toSms()` calls `ValueCreator.createRecordValue(module, "Sms")`, which needs the
   `Sms` record type registered in a live Ballerina runtime's type registry — something
   that only exists inside an actual `bal test`/`bal run` process. Priming
   `ModuleUtils.smppModule` via reflection fixed one NPE but not this deeper one, and the
   test failed identically whether the fix was applied or not — meaning it didn't actually
   prove anything. Abandoned.
2. **A minimal real `bal test`**, but scoped down to just enough native bridge code to
   send one `data_sm` PDU — this is what shipped. Landed as:
   - `smpp/native/src/testBridge/java/io/ballerinax/smpp/test/MockSmscBridge.java` — a
     small, static-method-only bridge (open a listening socket, accept+bind once, send one
     `data_sm`, close). Built as a **separate Gradle source set** (`native/build.gradle`'s
     `testBridge` source set → `testBridgeJar` task), producing its own jar
     (`smpp-native-test-bridge-0.1.0.jar`) that's never part of the production build.
   - Wired into `ballerina/Ballerina.toml` as a `[[platform.java21.dependency]]` with
     `scope = "testOnly"` — a real Ballerina.toml feature that keeps a platform dependency
     on the `bal test` classpath without bundling it into the built package.
   - `smpp/ballerina/tests/mocksmsc.bal` — thin `@java:Method` wrapper functions. Two
     interop details worth recording because they cost real debugging time: Ballerina
     `byte[]` doesn't interop-map to Java `byte[]` (Ballerina's `byte` is 0-255, Java's is
     signed) — the bridge takes UTF-8 payload as a `string`/`BString` instead, converting
     to bytes in Java, since exact byte-level payload fidelity is already covered by
     `DispatcherTest`'s decode matrix. And a plain `java.lang.String` parameter doesn't
     interop-match Ballerina's `string` either — it must be typed `BString` on the Java
     side (`.getValue()` inside the method), matching this codebase's own established
     pattern in `NativeListener.str(...)`.
   - `smpp/ballerina/tests/data_sm_test.bal` — binds a real `smpp:Listener` against the
     bridge (`start`ed concurrently with the bridge's blocking `acceptAndBind`, since both
     sides of an SMPP bind block until the other is ready), attaches a test service
     recording received `Sms` values, sends one `data_sm`, and asserts it was received.
     The actual fix-discriminating assertion is the `check` on the send call itself, not
     the delivery-count assertion after it: in SYNC mode (this connector's default), the
     dispatch to the test service already completes *before* `onAcceptDataSm` returns, so
     the delivery-count assertion would pass even pre-fix — it's the send call failing
     with a timeout that the fix actually changes.

The fuller MockSmsc rewrite described in `docs/qa-strategy.md` §3 is still deferred to
Sprint 1, which needs it anyway for bind-success/rejection and SYNC/ASYNC coverage — but
per that document's updated Phase 1 note, this is a **restructuring** of
`MockSmscBridge.java`'s static/single-shot internals into something that can serve an
accept-*loop*, not just an additive extension of it.

**Verified failure mode (test-first, both directions confirmed):** with the fix reverted,
the test fails with `error("org.jsmpp.extra.ResponseTimeoutException", ...)` — the mock's
blocking `dataShortMessage` call times out after jsmpp's default 2000ms transaction timer,
because `Dispatcher.onAcceptDataSm` returning `null` causes an **uncaught** NPE inside
jsmpp's `AbstractGenericSMPPSessionBound.processDataSm` (a state-processor method whose own
`catch` only handles `PDUStringException`/`ProcessRequestException`, not a bare NPE) —
crashing a PDU-processor thread with no `data_sm_resp` ever sent. This matches the
originally documented/predicted mechanism exactly. (An earlier, abandoned JUnit attempt at
this same test briefly appeared to show a *different* failure — an explicit negative
response rather than a timeout — which would have contradicted the documented mechanism;
that turned out to be an artifact of that attempt's incomplete test environment, not a real
finding, and was not carried into this document.)

---

## Sprint 1 — Make the public API fail loudly instead of silently ✅ DONE

**Goal:** every item here is a `.bal`-layer or thin native-boundary safety net; none
touches the lifecycle state machine, so this can proceed independently of (and before)
Sprint 2's riskier rewrite.

**Outcome:** all six items shipped, plus the mock-bridge restructure and the five Phase-1
test files (see the scope adjustments below and qa-strategy.md's Phase 1 status). Exit
gate passed: 20 JUnit + 11 `bal test` cases green on a clean build. Phase 5's adversarial
review (3 reviewers) caught one real Medium bug in the sprint's own flagship guard —
`Dispatcher.setService` assigned the new service *before* validating it, so a rejected
`attach` silently clobbered a previously attached valid service (found independently by
two reviewers; fixed by validating first, with no state change on rejection) — plus
several confirmed smaller items, all fixed in-sprint: a `body.clone()` defensive copy for
`shortMessageBytes` (the BArray wraps rather than copies, and jsmpp's getters return
internal arrays), a `maxRebindAttempts < -1` validation floor (other negatives silently
meant "infinite"), bounds documentation on the `ConnectionConfig`/`RebindPolicy` field
docs that `init`'s doc pointed at, always-run mock cleanup in every test file (an erroring
`gracefulStop` would have skipped the mock close and leaked the port into the next test),
a defensive listener stop in `bind_test`'s cleanup (a wrongly-accepted bind would
otherwise start an infinite rebind loop against a dead port for the rest of the suite),
negative tests for the new config validation itself (it had shipped untested), and a
handful of architecture.md accuracy nits. Three genuinely new, out-of-scope findings were
appended to Sprint 2's table rather than fixed here: `deregisterListener` never being
called, the `service`/`remoteMethods` torn two-volatile publication, and double-`attach()`
silently replacing a valid service.

| Item | Scope | Est. |
|---|---|---|
| Config validation in `Listener.init()` | `port` 1–65535, `maxConcurrentDispatch` ≥ 1, `gracefulStopTimeout` ≥ 0, `initialRebindDelay` ≥ 0, `maxRebindDelay` ≥ `initialRebindDelay`, `backOffMultiplier` ≥ 1. Lives in `.bal` before `externInit`, so it's testable without any native round-trip. | 2–3h |
| `attach()` rejects a service matching none of the 3 known methods | `Dispatcher.setService` returns `boolean` (matched anything?); `NativeListener.attach` returns a clear `error` if not. | 2–2.5h |
| Wire `smpp:Error` through native error creators | Mirror the existing `Sms`-record pattern (`ValueCreator.createRecordValue(ModuleUtils.getModule(), ...)`) for errors, at the 3 call sites that currently create a plain generic `error`. | 2–3h |
| `detach(service)` identity check | Add a `Dispatcher.getService()` getter; only clear if the passed service is the one currently attached. | 1–1.5h |
| `Sms.shortMessageBytes` escape hatch | New `byte[]` field on the `Sms` record, populated from the same bytes `decodeShortMessage` already has before discarding them — makes the documented "decode GSM-7 yourself" workaround actually possible. | 1.5–2h |
| Doc corrections | `onError` fires on *every* failed rebind attempt, not just once on give-up (fix docs/architecture.md + the `RebindPolicy` doc comment); ASYNC failures reach raw stderr, not `ballerina/log` as currently claimed; GSM-7/multipart doc section updated to reference `shortMessageBytes` instead of a workaround that doesn't exist; Package.md's example stops hardcoding `password: "test"` in source, uses `configurable` instead. | ~2–2.5h combined |

**Exit gate:** qa-strategy.md's Phase-1 test set (bind success/rejection, SYNC/ASYNC
dispatch smoke tests, per-`data_coding` decode tests, `message_payload` precedence) passes
against this sprint's code. None of these tests touch rebind/stop timing, so they're
unaffected by Sprint 2 happening after this.

**Total: ~11–13h of fixes + ~26h of Phase-1 test-writing ≈ 37–39h.**

**Phase 1 (team review) scope adjustments — recorded before implementation, per
docs/development-process.md:**

- **Burst-sending deferred to Sprint 4.** qa-strategy.md's Phase 1 narrative bundled the
  burst sender into this sprint's mock work, but Sprint 1's exit gate never consumes it —
  `maxConcurrentDispatch` saturation is Sprint 4's exit gate. Building it now would ship an
  untested capability, against this project's own bar. Sprint 4 builds it alongside the
  test that exercises it.
- **Per-test `after:` instead of `@test:AfterEach`.** Verified against the Ballerina
  distribution's own examples: `@test:BeforeEach`/`@test:AfterEach` are *suite-global*
  (they fire around every test function in the whole module, not just their own file).
  With six test files that would mean six suite-wide cleanup hooks firing after every
  single test. All new test files use `@test:Config { after: <fn> }` (per-test scope),
  and `data_sm_test.bal`'s Sprint 0 `@test:AfterEach` is retrofitted in the same pass.
- **The bridge restructure changes `openListener`'s signature** (returns a handle — the
  mock is no longer a singleton), so Sprint 0's `data_sm_test.bal` must be migrated onto
  the new handle-based API (~1h, previously uncosted). The Gradle/Ballerina.toml wiring
  survives as-is, as qa-strategy.md predicted; the "openListener/close survive as-is"
  claim did not.
- **Error-type coherence:** the new `.bal`-level config-validation errors construct the
  same distinct `smpp:Error` type that the native layer is being wired to produce this
  sprint (via Ballerina's `error Error(...)` constructor), so `err is smpp:Error` matches
  uniformly across the whole public API. Verified `ErrorCreator.createDistinctError(
  typeName, module, message)` exists on ballerina-rt 2201.13.4 and produces a matchable
  distinct error, and `ValueCreator.createArrayValue(byte[])` round-trips unsigned bytes
  correctly for `shortMessageBytes`.
- Net effort materially unchanged: burst deferral (−3–4h) offsets the handle-registry
  design + `data_sm_test.bal` migration (+3h).

**Reconciliation note:** architect-reviewer's top-down estimate for "service-shape
validation" was 1–1.5 engineer-days (8–12h); ballerina-developer's bottom-up estimate,
grounded in the exact code diff, was 2–2.5h. Used the bottom-up number — it's backed by a
concrete sketch of the change, not a category-level guess. Also: architect-reviewer
initially scored `detach()`'s argument-ignoring bug as Phase-3 backlog ("non-issue in the
single-service model"), while ballerina-developer scoped a concrete 1–1.5h fix. Pulled it
forward into Sprint 1 — it's cheap and rides along with other changes already touching the
same native files this sprint, so deferring it to a separate future session costs more than
just doing it now.

---

## Sprint 2 — The lifecycle state machine ✅ DONE

**Phase 5 outcome:** two adversarial reviews (java-architect on concurrency correctness,
code-reviewer on the cross-cutting/test pass). The state machine came through
concurrency-clean — no deadlock (lock ordering proven a DAG, hinging on jsmpp releasing
its state lock before firing listeners — now recorded as a load-bearing invariant comment
in `bind()`), exactly-once drop reporting with the never-zero bound race genuinely closed,
clean start/stop races, exactly-once idempotent stop/deregister. Fixes applied in-sprint:
(1) **[Medium]** `testRestartAfterStopRejected` didn't store its started listener, so a
failure between start and the manual stop would leak an infinite-rebinding listener onto
the file's shared port — the guarding comment ("cleanup must not re-stop") was
demonstrably wrong since re-stop is an idempotent no-op; now stores it and relies on
cleanup. (2) **[Low]** the post-init native-data writes (`NATIVE_SESSION`,
`NATIVE_REBIND_EXECUTOR`) raced the runtime's unsynchronized `HashMap` against jsmpp-thread
reads (masked only by the map never resizing) — converted both to write-once
`AtomicReference` holders installed at init, matching the existing `STATE` pattern, so all
native-data writes are now single-threaded at init. (3) **[Low]** rebind backoff-timing
assertions floored at 0.2s couldn't catch a shrunk-but-nonzero backoff their message
claimed to catch — tightened to 0.4s. No new findings deferred; the "same-JVM churn leak"
Phase-5 question resolved to "only leaked (never-stopped) listeners leak", i.e. finding (1),
now fixed.



**Goal:** the highest-risk, most foundational native-layer change, and the root cause of
several other findings (double-`start()` creating duplicate sessions, `stopping` never
resetting so a restart silently and permanently kills auto-rebind, `gracefulStop` not
actually cancelling an in-flight rebind, a `bound`-flag race that can permanently wedge the
listener with zero notification). Given "correctness over speed," this gets its own
isolated sprint — no other lifecycle-touching work happens concurrently with it.

| Item | Scope | Est. |
|---|---|---|
| Replace `bound`/`stopping` `AtomicBoolean`s with an explicit state machine | `enum ListenerState { INIT, STARTING, STARTED, STOPPING, STOPPED }` behind an `AtomicReference` + a monitor lock guarding transitions. Double-`start()` rejected with a clear error. **Explicit decision: restart-after-stop is rejected, not supported** — a `STOPPED` listener stays stopped forever; `start()` on it returns a clear error telling the caller to create a new `Listener`. (Rationale: matches existing Ballerina listener idioms elsewhere; a "reset to INIT" path would need to correctly re-solve re-entrancy for the rebind executor, `inFlight` counter, and stale session refs, for low value; keeps the state machine a strict DAG, easier to review.) Lock is held only around the state-check/session-install step, *not* across the blocking `connectAndBind()` call itself — otherwise `gracefulStop`/`immediateStop` would block for the network bind timeout. | 16h |
| `bound`-flag race window fix, riding the same lock | After `connectAndBind()` returns, re-acquire the lock, confirm state is still `STARTING`/`STARTED` before installing the session; if a drop is detected in the sliver before the lock is reacquired, `bind()` itself explicitly checks `session.getSessionState()` and manually invokes the drop-handling path rather than relying solely on the listener callback having fired (guarded by a per-attempt `dropReported` flag so the lambda and this manual check can't double-report). Flagged as the hardest-to-test item in this sprint — needs a socket-harness test (a fake SMSC that closes the connection immediately post-accept, looped, asserting `onError` fires exactly once, never zero), not just code inspection. | 4–5h |
| `scheduleRebind`/`attemptRebind` TOCTOU fix | Naturally closed by doing the state check and the `.schedule()` call inside the same lock the stop path uses. Add a belt-and-suspenders `try/catch(Throwable)` around the scheduled task body regardless, so any exception (including one from a future refactor mistake) surfaces via the existing `onError` channel instead of vanishing into a discarded `ScheduledFuture`. | 2h |
| `onError` virtual thread tracked by `inFlight` | Mirror the existing ASYNC-dispatch pattern in `dispatchError()` — increment/decrement the same `inFlight` counter around the virtual thread, so `gracefulStop`'s drain genuinely covers it. | 2–3h |
| **(Added by Sprint 1's Phase 5 review)** `deregisterListener` never called | `initListener` registers the listener with the runtime; neither `gracefulStop` nor `immediateStop` ever deregisters. Empirically the `bal test` JVM still exits promptly, but for a `bal run` program a stopped-but-registered dynamic listener may pin the scheduler alive. Investigate and pair register/deregister as part of the stop paths (the ActiveMQ module this build is modeled on deregisters in stop). | 1–2h |
| **(Added by Sprint 1's Phase 5 review)** `service`/`remoteMethods` torn publication | `Dispatcher.setService` writes two separate volatiles; a PDU thread can observe the new service with the old method set (attach/detach while bound and receiving — nothing does this today, but attach is public API on a running listener). Fold into this sprint's atomicity work: a single volatile immutable holder for (service, methods). | 1h |
| **(Added by Sprint 1's Phase 5 review)** double-`attach()` silently replaces | A second *valid* service attached to the same listener overwrites the first with no diagnostic (last-writer-wins). Sprint 1 fixed the *rejected*-service clobber (validate-before-assign); the silent replacement of a valid service by another valid one remains. Decide and enforce: either reject a second attach with a clear error (matching this sprint's one-way-lifecycle philosophy) or document single-service-per-listener loudly. | 1–2h |

**Phase 1 (team review) amendments — recorded before implementation:**

- **The ActiveMQ deregister claim from Sprint 1's review was wrong** — that module never
  calls `registerListener`/`deregisterListener` at all. The deregister fix stands on the
  runtime's own verified contract instead (`RuntimeRegistry` is a plain deque under a
  lock; deregistering mid-invocation is a non-event). Deregister fires exactly once, on
  the transition to `STOPPED`.
- **Failed initial `start()` reverts `STARTING → INIT` (retryable)** — a refinement of
  the "strict DAG": a failed bind installs nothing, so every invariant the DAG protected
  still holds, and the user isn't told "listener stopped" for a listener they never
  stopped. Restart-after-*stop* remains rejected.
- **Stops are idempotent (`STOPPING`/`STOPPED` → immediate success) — mandatory, not
  stylistic**: the runtime's shutdown path re-stops every still-registered listener, so
  an already-stopped listener must no-op. This also means zero changes to existing test
  cleanups (per qa-expert's audit, the only green-path conflict was `bind_test`'s
  defensive stop of a never-started listener — idempotency absorbs it).
- **Double-`attach()` is rejected with a clear error** (three-outcome `attach` API
  replaces Sprint 1's boolean `setService`; validate-before-assign semantics preserved).
  Intentional swap stays expressible via `detach(old)` then `attach(new)`.
- **Peer-initiated unbind keeps today's treatment** (drop + rebind, same as abrupt
  severance) — the state-machine lambda doesn't distinguish them; qa's Variant-B
  (terminal peer-unbind) test stays as a commented-out option if this is ever revisited.
  Post-exhaustion state stays `STARTED` (stop works normally; `start()` rejected as
  already-started).
- **Phase-2 test scope grew: ~26h → ~35h, 6 files not 3** (the exit gate items added
  since qa-strategy's Phase 2 was written), plus new mock capabilities (`sever`,
  `peerUnbind`, `stopAccepting`, `closeAfterAccept`, per-connection transaction timer)
  and a `scripts/soak-lifecycle.sh` repeat-runner for the budgeted soak.

**Exit gate:** qa-strategy.md's Phase-2 lifecycle-timing tests — double-`start()`
rejection, restart-after-stop rejection, rebind backoff/exhaustion, `gracefulStop` vs
`immediateStop` timing, abrupt-severance vs peer-initiated-unbind detection — all pass.
Given java-architect's own flag that the `bound`-race fix is the hardest to test with
confidence, budget explicit soak-test time (repeated-iteration runs, not a single pass)
before calling this sprint done.

**Implementation outcome (Phase 3/4):** state machine, Dispatcher `ServiceBinding` holder,
double-attach rejection, `onError` inFlight-tracking, and `deregisterListener` pairing all
landed; the full automated suite is green (20 JUnit + 21 `bal test`), and the deterministic
drop/rebind soak (`testRepeatedSeverRebindCycles`, 15 real sever→rebind cycles) is stable
across repeated isolated runs. Two dispositions worth recording:

- **Bound-race soak is split.** The deterministic cycle test covers the drop/rebind engine
  exactly-once and fast, and stays in the gate. The accept-then-*vanish* hammer
  (`testAcceptThenDropCyclesRecoverWithoutWedge`) is disabled in the automated suite
  (`enable: false`, manual-runnable) — see the finding below for why it's slow/nondeterministic.
- **New finding → Sprint 4:** jsmpp's `connectAndBind` uses a **60s default bind timeout**,
  and the rebind executor is single-threaded, so a half-open SMSC (accepts the TCP socket
  then never completes the bind handshake) stalls the *entire* rebind loop for up to 60s
  before the attempt fails and the next is scheduled. It recovers on its own — not a
  permanent wedge — but it's an unbounded, unconfigurable stall on the resilience path.
  Fold into Sprint 4's timer-exposure work (alongside `enquireLinkTimer`/`transactionTimer`/
  `queueCapacity`): expose/bound the bind timeout so operators can cap it. Also open for
  Phase 5: does sustained same-JVM rebind churn leave any connector-side resources
  unreleased across many stopped listeners (rebind executors, `onError` virtual threads)?

**Total: ~24–26h of fixes + ~26h of lifecycle tests + soak-test buffer (~4–8h) ≈ 54–60h.**

**Reconciliation note:** this sprint also resolves a genuine three-way disagreement
between the earlier bug-hunting agents about a `RejectedExecutionException` race —
java-architect had called it a "confirmed non-issue," code-reviewer called it a real race;
my own adjudication (in the review report) found both were partially right, and that the
most dangerous form of it (inside `attemptRebind`'s own retry-scheduling call) fails
*silently* because exceptions thrown inside a task submitted via `.schedule()` are
swallowed by the JDK's `Future` machinery rather than surfacing anywhere. The state-machine
lock closes the race itself; the added `try/catch` is insurance against the possibility
that it doesn't, fully.

---

## Sprint 3 — Transport security (TLS) ✅ DONE

**Goal:** architect-reviewer's firm position, which I'm carrying into this plan as a hard
gate rather than a nice-to-have: a public, Central-bound connector that hands real
credentials over the network in cleartext, with *no* in-band encryption option and no
documented alternative, is not defensible. Documentation-only ("assume TLS is
network-terminated") is not an acceptable substitute for having the option at all — it can
still be the *recommended* production topology, but the option must exist.

| Item | Scope | Est. |
|---|---|---|
| `secureSocket` config on `ConnectionConfig` | `cert` (truststore/cert path, server verification), optional `key` (keystore, for mTLS), optional `protocol`/`ciphers`. | ~1 day (8h) |

**Phase 1 (team review) refinements — recorded before implementation:**

- **Config shape** (verified against the distribution's own `crypto` 2.12.0 and `tcp` module
  source): a `SecureSocket` record — `crypto:TrustStore|string cert` (required; PEM CA path
  or truststore), `crypto:KeyStore key?` (mTLS), `string[] protocolVersions` defaulting to
  `["TLSv1.3","TLSv1.2"]` with a **TLS 1.2 floor enforced in `validateConfig`**,
  `string[] ciphers`, `boolean verifyHostName = true`. Deliberate deviations from
  `tcp:ClientSecureSocket`: no redundant `enable` boolean (presence of the field means TLS),
  no nested protocol-family record (SMPP never negotiates SSL/DTLS families).
- **The dev-only trust-all path is a separate `InsecureSocket` record**
  (`true disableSslVerification` — a required field whose type admits only `true`), with
  `secureSocket` typed `SecureSocket|InsecureSocket?`. Chosen over a peer boolean so
  verification-off is mutually exclusive with `cert` by construction and unreachable via a
  defaulted/copied field. An `InsecureSocket` in use logs a loud warning at init.
- **v1 scope narrowing (free to re-widen pre-release):** `key` is `crypto:KeyStore` only —
  the PEM `CertKey` client-key form (fiddly PKCS8 parsing, no jsmpp precedent) is deferred;
  PEM stays supported for the trust side (`cert` as a CA-cert path). No `connectTimeout`
  field in v1 — the native layer uses a 60s constant aligned with jsmpp's bind timeout, and
  Sprint 4's timer-exposure item owns making timeouts configurable holistically.
- **Boundary:** the `.bal` layer normalizes the union into a flat internal `ResolvedTls`
  record (paths + passwords + versions + flags, no union tags) passed to `externInit`;
  the native side builds the `SSLContext` → a custom `SmppSslConnectionFactory` fresh per
  bind attempt (no shared TLS state across rebinds; rotated trust material picked up on the
  next rebind for free).
- **Hostname verification is ON by default and set explicitly**
  (`SSLParameters.setEndpointIdentificationAlgorithm("HTTPS")`) — deliberately diverging
  from jsmpp's own SSL factories, **none of which perform hostname verification at all**
  (qa-expert's Finding A, confirmed at source). The handshake is forced eagerly
  (`startHandshake()`) so a bad cert fails at `'start()`/rebind, not later on a PDU thread.
- **Recorded open question (qa-expert's Finding B), deferred with a disabled test stub:**
  a *permanent* TLS trust failure discovered at rebind time currently retries forever under
  `rebindPolicy` like any transient fault. Whether cert-trust failures should be terminal
  (one final `onError`, no retry) is a design decision for a later sprint.
- **Test harness:** committed PKCS12 fixtures under `tests/resources/certs/` +
  `gen-certs.sh` (server cert CN=localhost + SAN; the trust-negative "wrong" cert is also
  CN=localhost — the mock always presents its own CN=localhost leaf, so the hostname check
  passes uniformly and chain-of-trust is the isolated variable; a separate
  `CN=not-localhost` keypair drives the hostname tests); TLS-terminating mock via a
  per-mock `TlsServerConnectionFactory` (explicit keystore, not jsmpp's JVM-global-property
  server factory); nine tests on ports 27788–27795: happy-path round-trips (truststore +
  PEM forms), no-verify dev path, **trust negatives in both cert forms**, mTLS round-trip
  **plus the no-client-cert mTLS negative** (proves the server *demands* the cert), and a
  **hostname-verification pair** (trusted-but-wrong-host cert: fails with `verifyHostName`
  defaulted, connects with it `false`; mutation-verified against deletion of the
  endpoint-identification code). All fixture stores keytool-verified against `gen-certs.sh`.
| Custom `ConnectionFactory` wiring in `NativeListener.bind()` | jsmpp's stock `SSLSocketConnectionFactory` only reads a JVM-global truststore, which isn't idiomatic for per-listener Ballerina config — build a small factory wrapping an `SSLContext` constructed from the Ballerina-supplied material, passed to `new SMPPSession(factory)`. Map an explicit, clearly-labeled dev-only "disable verification" flag to `NoTrustSSLSocketConnectionFactory`. | ~0.5–1 day (4–8h) |
| TLS integration test | Stand up a TLS-terminating mock SMSC and assert a full bind+dispatch round-trip over it. This is the real cost driver of this sprint. | ~1.5–2 days (12–16h) |

**Exit gate:** the TLS round-trip test passes; the insecure/no-verification path is
excluded from any default and clearly labeled in both code and docs.

**Phase 5 (adversarial review) disposition — the gate that actually closed the sprint:**

Three independent reviewers (two java/security passes + one cross-cutting pass), all
verifying against the JSSE contract and the local jsmpp source. Verdict on the *code*:
**fail-closed and correct — no exploitable path found.** Every producible `ResolvedTls`
was traced (trust-all reachable only from `InsecureSocket`; no null/empty trust-manager
path, so JSSE's silent `cacerts` fallback is unreachable); hostname verification ordering,
socket ownership (no fd leak on any failure path), password hygiene, and per-rebind
freshness all confirmed. The confirmed findings were **test-coverage gaps on the sprint's
own security claims** — the round-trip suite would have stayed green if hostname
verification or mTLS enforcement were silently deleted. Dispositioned per process 5.3(a),
all fixed in-sprint:

1. **(High) Hostname verification untested** → hostname-mismatch test pair added
   (trusted `CN=not-localhost` cert dialed as `localhost`: must fail with `verifyHostName`
   defaulted, must connect with it `false`). Mutation-verified: disabling the
   endpoint-identification code makes exactly the new test fail, nothing else.
2. **(Med-High) mTLS enforcement untested** → no-client-cert negative added (mock demands
   a client cert, connector has no `key` ⇒ bind must fail).
3. **(Med) PEM-path rejection untested** → wrong-PEM negative added (`wrong.crt` fixture).
4. **(Med) Fail-open-on-refactor surface in the native boundary** → the lenient
   `bool()`/`str()` readers (missing key ⇒ `false`/`""`) were replaced for TLS with
   *strict* readers that throw on a missing `ResolvedTls` key — a one-sided field rename
   can no longer silently flip `verifyHostName` off.
5. **(Low) Empty `cert` path** reached the native layer and failed with a blank message →
   rejected at init in `validateSecureSocket`.
6. **(Low) Non-discriminating negative assertions** → trust negatives now also assert the
   failure is NOT a local keystore-load error; two tests sharing port 27788 → PEM test
   moved to its own port; doc drift (test count, `CN=localhost` rationale wording)
   corrected; committed fixture stores keytool-verified against `gen-certs.sh`.

Recorded residuals (accepted, not bugs): passwords transit as unwipeable `BString`s and
live in the listener-lifetime `ResolvedTls` map by design (rebinds re-read trust material);
`TLS_CONNECT_TIMEOUT_MILLIS` hardcoded 60s → Sprint 4's timer item; Finding B (terminal vs
retried trust failures at rebind) stays deferred with its disabled test stub.

**Total: ~24–32h.**

---

## Sprint 4 — Stop the connector from dropping its own connection ✅ DONE

**Goal:** the "self-inflicted drop" risk — a slow `SYNC` handler at the *default*
`maxConcurrentDispatch` (3) can starve jsmpp's shared PDU-processing pool badly enough that
`enquire_link` traffic stalls and the SMSC (or jsmpp's own keepalive sender) decides the
link is dead and closes it, triggering exactly the rebind churn the connector's resilience
feature exists to handle — self-inflicted, not external. Also bounds ASYNC mode's currently
uncapped resource growth.

| Item | Scope | Est. |
|---|---|---|
| Expose keepalive/bind config | Two public fields on `ConnectionConfig` (decimal seconds): `enquireLinkInterval` (connector's idle-probe interval + socket read timeout) and `bindTimeout` (below). **Scope corrected during Phase 1:** the plan originally listed `enquireLinkTimer`/`transactionTimer`/`queueCapacity`; on the config-surface review, `transactionTimer` and `queueCapacity` were kept **internal** (safe fixed defaults, additive later) to keep a Central-bound public API minimal, and `enquireLinkTimer` was exposed as the clearer-named `enquireLinkInterval`. | 4–8h |
| **(Added by Sprint 2's Phase 4)** Expose/bound the connect + bind timeout | jsmpp defaults the bind-response wait to **60s** AND its stock plaintext connect is unbounded (`new Socket(host,port)`); the rebind executor is single-threaded, so a half-open/black-holed SMSC stalls the whole rebind loop. `bindTimeout` now feeds all three sinks — the 10-arg `connectAndBind` (bind-response wait), a new connect-bounded plaintext `SmppPlainConnectionFactory`, and the (previously hardcoded) TLS connect timeout — on both the initial `start()` and every rebind. | 2–4h |
| Structural fix: decouple handler concurrency from keepalive capacity | Size jsmpp's `pduProcessorDegree` mode-aware (`SYNC` = `maxConcurrentDispatch + 1` reserve; `ASYNC` = a small fixed pool since handlers run on virtual threads); gate handler entry with a per-listener `Semaphore(maxConcurrentDispatch)` in `Dispatcher.dispatch()` using a non-blocking `tryAcquire`, rejecting overflow immediately with `ESME_RTHROTTLED`. (Corrected during fix-planning: routing handler execution to a *separate* thread pool does **not** fix SYNC — SYNC's contract is blocking the jsmpp thread until the handler returns, so the reserve-capacity approach is the actual fix.) | 16–24h |
| ASYNC backpressure | `maxConcurrentDispatch` now bounds ASYNC too (breaking change vs the shipped "ASYNC ignores it" contract — approved). **Mechanism reversed from the original plan during Phase 1:** the plan proposed *block* (`acquireUninterruptibly`) before spawning; both the Java and adversarial reviewers refuted that — blocking on the pool thread delays the ack (the ROK is sent *after* the callback returns, `SMPPSessionBound.java:52`) and reintroduces keepalive starvation through the ASYNC door. Built instead as the **same non-blocking `tryAcquire` + `ESME_RTHROTTLED` gate as SYNC**; the only per-mode difference is the success path. RTHROTTLED is a NACK, so the SMSC retains/retries — the at-least-once concern the plan raised is satisfied without blocking. | 5–6h |

**Exit gate:** a slow-handler saturation test proving `enquire_link` is still answered
while every handler slot is occupied; a bounded-concurrency test for ASYNC mode. **Met:**
`testSyncKeepaliveSurvivesSaturatedHandlers` and `testAsyncBoundedConcurrency` (plus
`testSyncOverflowThrottled`, `testBindTimeoutBoundsHalfOpenConnect`); the keepalive and
overflow tests are **mutation-verified** (reverting the reserve makes both fail).

**Total: ~25–38h.**

**Phase 5 (adversarial review) disposition:** two independent reviews (Java-concurrency +
test/doc). The permit lifecycle in `Dispatcher.dispatch()` was re-derived by hand across all
eight control-flow paths — **exactly-once release, no double-release, no wrong-thread
release, no `inFlight`/permit desync** that could break the `gracefulStop` drain — and the
keepalive reserve was proven sufficient (including the TRX handler-reentrant-`submit_sm`
case, which is moreover unreachable here since the connector is receive-only). A
**pre-existing** `inFlight` leak (an `startVirtualThread` OOM would hang `gracefulStop` to
its timeout) was found and fixed in passing (`spawned`-guard in both `dispatch` and
`dispatchError`). No code-correctness defect survived. All confirmed findings were
documentation drift, fixed in-sprint: `architecture.md`'s dispatch section (stale
"ASYNC unbounded"/pool-sizing prose, missing reserve mechanism, missing new config fields,
and a dangling `types.bal` cross-reference into it), this plan's reversed ASYNC decision and
overstated config-exposure item (corrected above), and two `types.bal` phrasing nits. A
test-hygiene gap (no `after` on the bind-timeout test) was closed. Control-byte scan clean.

**Reconciliation note:** architect-reviewer's top-down estimate for the structural fix
(2–3 engineer-days, 16–24h) and for ASYNC bounding (1–2 days, 8–16h) were both somewhat
higher than java-architect's bottom-up, code-level estimate for ASYNC bounding specifically
(5–6h). Used java-architect's number for ASYNC since it's grounded in an exact code sketch;
kept architect-reviewer's range for the SYNC-side structural fix since no other agent
scoped that one at code level.

---

## Sprint 5 — Polish / fast-follow ✅ DONE

**Goal:** real improvements that are safe to defer — nothing here is a correctness or
security gap, just quality-of-life.

| Item | Scope | Est. |
|---|---|---|
| Route stderr fallback (`printStackTrace`) through `ballerina/log` | The three `Dispatcher` `printStackTrace` sites now call a `logDispatchError(string, error)` module function (listener.bal → `log:printError`) via `Runtime.callFunction`. Fixed a latent hazard uncovered by this: `dispatchError`'s no-`onError` fallback ran synchronously on the jsmpp state-listener thread — inert as a `printStackTrace`, but a real runtime call there derailed the subsequent `scheduleRebind`; `dispatchError` now always runs on a virtual thread (both paths). | 2–3h |
| GSM 03.38 opt-in decoder | `boolean decodeGsm7 = false` on `ConnectionConfig`; when enabled, `data_coding 0x00` decodes as **unpacked** GSM 03.38 (default alphabet + extension table) instead of the UTF-8 fallback. Opt-in and off by default, so the `data_coding 0x00` default is unchanged. Packed 7-bit is out of scope. | 8–16h |

**Exit gate:** the log routing works without regressing rebind/drop-reporting; the GSM-7
decoder is correct and opt-in. **Met:** 38 bal + 30 JUnit green.

**Phase 5 (adversarial review) disposition.** The two review subagents (decoder-correctness +
threading lenses) both terminated on **infrastructure errors** (connection-closed / stall
watchdog) without returning findings, across three attempts — an environment issue, not a
signal about the code. The two load-bearing checks were therefore completed in the main agent
against ground truth:

1. **GSM table vs 3GPP TS 23.038 — verified.** The `\uXXXX` table was extracted from source,
   every entry decoded and compared to the canonical GSM 7-bit default alphabet: all 127
   non-ESC entries match, the ESC slot (0x1B) is a `￿` placeholder (never read — ESC is
   handled before indexing), and all 10 extension-table entries match exactly. A JUnit
   regression guard pins the ESC-placeholder alignment (Æ at 0x1C … É at 0x1F).
2. **Log-routing threading — verified by trace + test.** `dispatchError`→always-vthread does
   not derail `scheduleRebind` (returns immediately) and introduces no new ordering issue
   (the `onError` path was already async; the no-`onError` path is a log with no ordering
   contract); the exactly-once drop-reporting CAS is untouched; `inFlight` stays exactly-once
   via the `spawned`-guard and is covered by the `gracefulStop` drain; `logError`/`callFunction`
   runs only from vthread contexts (never synchronously on a raw jsmpp thread); and in
   `dispatch()`'s ASYNC branch `logError` sits inside the `try` whose `finally` releases the
   permit, so it cannot skip release (Sprint 4 invariant intact). The drop-with-no-`onError`
   rebind test is effectively a mutation check: it failed before the vthread fix, passes after.

Control-byte scan clean (two authoring hazards were caught and fixed pre-commit: a raw 0x1B
ESC byte in a char literal, and raw 0x01/0x02 bytes in a test string — both now `\uXXXX`).

**Total: ~10–19h.**

---

## Sprint 6 — Protocol-conformance audit + documentation ✅ DONE

**Goal:** audit the listener against the actual SMPP specification jsmpp implements, fix any
non-conformance, and bring the user-facing documentation (the listener README + code docs)
up to release quality.

**Spec:** the connector binds `interface_version 0x34`, so the governing spec is **SMPP
v3.4 (Issue 1.2)** — downloaded from smpp.org and audited page-by-page against the code
(command_status table §5.1.3, data_coding §5.2.19, esm_class §5.2.12, deliver_sm_resp
§4.6.2, data_sm/data_sm_resp §4.7, sequence_number §5.1.4, interface_version §5.2.4).

**Conformance verdict: conforms.** Verified against the spec: PDU header + sequence_number
(jsmpp-managed, echoed on responses); `deliver_sm_resp.message_id` = NULL; `data_sm` carries
no `short_message` (payload via `message_payload` TLV) and its resp `message_id` is the empty
neutral value for an SMSC-originated data_sm; all command_status values used
(`ESME_ROK`=0x0, `ESME_RTHROTTLED`=0x58, `ESME_RINVSYSID`=0xF, `ESME_RINVPASWD`=0xE); the
`data_coding` decode table (0x01 IA5/ASCII, 0x03 Latin-1, 0x08 UCS2, 0x00 SMSC-default
GSM/UTF-8); and `esm_class` → `deliveryReceipt` (message-type bits 5-2 = 0001) + `udhi`
(bit 6). enquire_link (Sprint 4) and unbind (Sprint 2) conformance were already established.

**One conformance improvement made:** a SYNC handler `error` returned the generic
`ESME_RSYSERR` (0x08, "System Error"). SMPP v3.4 defines receiver-specific application error
codes (Table 5-2): `ESME_RX_T_APPN` (0x64, temporary), `ESME_RX_P_APPN` (0x65, permanent),
`ESME_RX_R_APPN` (0x66, reject). Changed the SYNC handler-error response to **`ESME_RX_T_APPN`**
— the code purpose-built for "receiver application failed to process a delivered message,"
and its "temporary" semantics signal the SMSC to redeliver, matching the connector's
at-least-once intent (whereas RX_P/R_APPN would tell the SMSC to drop the message). This is
an observable wire-value change (0x08 → 0x64); `testSyncNegativeAck` updated to assert it.

**Documentation:** rewrote `Package.md` into a full listener README (what it is, quickstart,
the `onDeliverSm`/`onDataSm`/`onError` service contract, `Sms` record, bind modes,
resilience, character encoding, TLS, and a **protocol-conformance + limitations** section);
`Module.md` refreshed as the concise module landing; `types.bal`/`architecture.md` updated
for the RX_T_APPN change; the `Error` type doc expanded. Public API doc comments were audited
for spec-accuracy (data_coding/esm_class/deliveryReceipt all match) and left intact where
already correct (no churn).

**Known limitations (documented, deferred to backlog):** concatenated/multipart messages are
not reassembled (the `udhi` flag + `shortMessageBytes` are surfaced instead); delivery-receipt
bodies are delivered as-is, not parsed into typed fields; packed GSM 7-bit is not decoded.

**Exit gate:** listener conforms to SMPP v3.4; README/docs accurate. **Met:** 38 bal + 30
JUnit green.

---

## Sprint 7 — Delivery-receipt parsing ✅ DONE

**Governing principle (project owner):** the connector must not do anything jsmpp doesn't /
can't do — jsmpp is mature, widely used, and authoritative. The connector stays a faithful
thin wrapper: it surfaces what jsmpp parses and adds no protocol logic jsmpp lacks.

After the Sprint-6 conformance audit, an expert panel reviewed the open findings (F1 UDH
multipart, F2 delivery-receipt parsing, F3 packed GSM-7, F4 compiler plugin, F5 observability,
F6 TLS-trust-failure). Filtered by two owner rules — **do it only if it is in the SMPP spec
AND supported by jsmpp** — the list collapses to one item:

- **F2 delivery-receipt parsing — DONE (this sprint).** In the spec (Appendix B) and fully
  parsed by jsmpp (`DeliverSm.getShortMessageAsDeliveryReceipt()` → `DeliveryReceipt` bean).
  Added a typed optional `DeliveryReceipt?` on `Sms` (+ a `DeliveryReceiptStatus` enum),
  mapped 1:1 from jsmpp's bean — `id`, `finalStatus`, `submitted`/`delivered`,
  `submitDate`/`doneDate` (raw `yyMMddHHmm` strings — the wire has no timezone), `errorCode`,
  `text`, all optional. **Lenient / never-throw:** jsmpp's parser throws
  `InvalidDeliveryReceiptException` on a non-conforming body, and a bare `NullPointerException`
  (null short_message) *before* that wrapping — both caught
  (`InvalidDeliveryReceiptException | RuntimeException`), yielding `receipt = ()` with the raw
  body preserved on `shortMessage`. A throw escaping into the jsmpp PDU thread would NACK the
  receipt → endless SMSC redelivery, so the catch is load-bearing. The parse runs inside
  `toSms` **after** the permit gate (no work on the throttle/reject path) and only for
  `deliver_sm` (data_sm has no receipt body, and jsmpp has no data_sm equivalent). No delivery
  TLVs are read or merged — jsmpp's DLR parse doesn't, so neither does the connector.
  40 bal + 36 JUnit green.

### Dropped, per the owner's two rules (not in spec, or not jsmpp-supported)

- **F1 UDH parsing/reassembly — OUT.** The UDH is a GSM 03.40 structure, not SMPP; jsmpp does
  not parse it (it only exposes the `udhi` esm_class flag + raw bytes). Both filters fail. The
  connector keeps surfacing `udhi` + `shortMessageBytes`; the application handles concatenation.
- **F3 packed GSM-7 — OUT.** Not in jsmpp core (no packed/septet codec; the only packed codec
  in the tree is an examples-only external dependency). Unpacked GSM-7 (`decodeGsm7`, Sprint 5)
  stays; packed bytes remain available via `shortMessageBytes`.
- **F4 compiler plugin, F5 observability — OUT.** Neither is SMPP-spec conformance, and the
  owner declined observability. Sprint 1's runtime service-shape check already stands.
- **F6 TLS-trust-failure-at-rebind — OUT (not a spec item).** Left as-is: retry under
  `rebindPolicy` (bounded by `maxRebindAttempts`), with `onError` on every failed attempt.

**Net:** the connector conforms to SMPP v3.4 (Sprint 6) and now surfaces delivery receipts via
jsmpp's own parser. Nothing further is both spec-required and jsmpp-supported; the remaining
findings are deliberately left to jsmpp / the application.

---

## Sprint 8 — Outbound `submit_sm` via `smpp:Caller`

**Goal:** make the connector bidirectional. Today it is a receive-only trigger, which blocks the
dominant short-code use case — receive an MO message and reply to it. With a returned `message_id`
the Sprint-7 delivery-receipt support finally has something to correlate against, so the full
MO → REST → MT → DLR circuit becomes expressible.

**Release gating (owner decision, 2026-07-29):** this sprint does **not** publish 1.1.0. The
compiler plugin (Sprint 9) is a release blocker — the owner overruled the red team's "1.1.0 may
publish without it" on the grounds that every Ballerina listener module passing a `Caller` ships
one, and shipping an opt-in parameter with no compile-time validation is not the standard this
package holds itself to. **1.1.0 publishes at the end of Sprint 9.** Two practical consequences:
the signature contract must be frozen by this sprint's Phase-5 review so Sprint 9 can encode it;
and the `examples/` rewrite (which resolves `ramith/smpp` from Central) is blocked for two sprints
rather than one, so add the local-repo override to `examples/build.sh` + `smoke-test.sh` rather
than waiting — see item N8 in the reconciliation notes.

**Input:** [docs/submit-sm-implementation-report.md](submit-sm-implementation-report.md) (a design
report written against `main` at 2026-07-28), then a five-SME panel — `architect-reviewer`,
`java-architect`, `ballerina-developer`, `qa-expert`, plus a dedicated **SMPP v3.4 conformance
audit** — followed by a hostile `the-fool` red-team pass that **refuted claims from four of the
five SMEs**. The report's plumbing analysis survived; a substantial part of its protocol and API
design did not. See the reconciliation notes for what changed and why.

**Governing rules applied throughout** (unchanged from Sprint 7): a feature ships only if it is in
the SMPP v3.4 spec **and** supported by jsmpp; correctness over speed; 1.0.1 is published so
nothing may break existing users; and the public surface must match how Ballerina's own service
implementations do request-response.

### Work items

| # | Item | Scope | Scoped by | Est. |
|---|---|---|---|---|
| 1 | Public types | `OutboundSms` (closed, every field documented — a build WARNING on an undocumented public field is a regression); `Encoding` = `ASCII`/`LATIN1`/`UCS2`, default `LATIN1`; `Address record {\| string value; Ton ton; Npi npi; \|}` used behind a `string\|Address` union on both `destAddr` and `sourceAddr` (mirrors this package's own `crypto:TrustStore\|string cert`, `types.bal:155`, and keeps `destAddr: sms.sourceAddr` a one-liner); `Ton`/`Npi` **string enums** mirroring jsmpp's enum member names; `DeliveryReceiptRequest` = `NONE`/`ON_SUCCESS_OR_FAILURE`/`ON_FAILURE_ONLY`; `SubmitResult record {\| string messageId?; \|}`; `ConnectionConfig.sourceAddr` **defaulted, and NOT validated in `validateConfig`**. | ballerina-developer + conformance audit | 8–10h |
| 2 | `Caller` on the Ballerina side | `smpp/ballerina/caller.bal`: `public isolated client class Caller` — **not `distinct`** (0 of 7 stdlib Callers are) — with a **module-private `isolated function init`**, or users can write `new smpp:Caller()`. One `remote isolated function submit(OutboundSms) returns SubmitResult\|Error`. Signature is the one a future `Client` will carry verbatim. | ballerina-developer | 4h |
| 3 | Trailing-optional caller parameter + attach-time validation | `onDeliverSm(smpp:Sms sms, smpp:Caller caller)` — **Caller LAST**, matching the two verifiable stdlib precedents for an *optional* Caller (ftp `FTP_109`: "(WatchEvent) or (WatchEvent & Caller)"; mqtt's own code template and position-enforcing validator). Resolve **by parameter TYPE**, never by arity or position. Add a `BAD_SIGNATURE` variant to the existing typed `AttachResult` (`Dispatcher.java:87`) and store the resolved plan **inside `ServiceBinding`** (`:85`) so the documented torn-attach guarantee holds. `onError` stays 1-arity. | red-team (amending the report) | 8–10h |
| 4 | `NativeCaller.java` | Its **own** native data — the `AtomicReference<SMPPSession>`, the `AtomicReference<ListenerState>`, the config map — handed over **once, at `initListener`**, single-threaded. `NativeListener`'s native-data map is a plain unsynchronised `HashMap` and `:93-97` already documents that post-init writes are a data race, so the Caller must never touch the listener `BObject`. Read the session **through the `AtomicReference` on every submit**. Three-way pre-check (below). No `stateLock` on the submit path. | java-architect | 12–14h |
| 5 | `transactionTimeout` on `ConnectionConfig` | jsmpp's `transactionTimer` defaults to **2000 ms** (`AbstractSession.java:67`) and the connector never sets it, so every submit would give up after 2 s — on a call whose timeout means *"possibly delivered, retrying may duplicate"*. Apply via `setTransactionTimer` in `bind()` beside `setEnquireLinkTimer` (`NativeListener.java:205`) so it is re-applied on every rebind. **Not named `submitTimeout`:** the same jsmpp field also bounds `unbind()` (`:436`), `sendEnquireLink()` (`:403`) and `pduExecutor.awaitTermination` (`SMPPSession.java:678`). Document all three couplings. **Includes updating three existing tests** whose assertions encode the 2 s default. | 4 SMEs independently; couplings by red-team | 6–8h |
| 6 | Native pre-validation, non-echoing | Pre-check `short_message` ≤254 octets, addresses ≤20 chars, `service_type` ≤5, time strings — using **jsmpp's own declared limits** (`util/StringParameter.java:46-63`), so jsmpp's validator becomes a never-fires backstop. Two independent reasons: (a) `StringValidator` embeds the offending value verbatim, which for `submit_sm` is **the SMS body and the destination MSISDN** — the same leak class `validateCredentials` (`NativeListener.java:272-279`) already exists to prevent; (b) `PDUStringException` is not an `IOException`, so it escapes `executeSendCommand`'s only catch (`AbstractSession.java:332`) and **permanently orphans a `pendingResponses` entry** — an unbounded leak on a long-lived listener, assertable via `getUnacknowledgedRequests()`. | java-architect + conformance audit | 6h |
| 7 | Error mapping | `public type Error distinct error<ErrorDetail>` with **all-optional** detail fields (verified source-compatible: existing `error Error("msg")` sites in `listener.bal:100-184` keep compiling). Detail carries `commandStatus` (int), `sequenceNumber`, and a **`FailureMode` enum** over the five jsmpp exception classes — `REJECTED` / `TIMEOUT_DELIVERY_UNKNOWN` / `LINK_DOWN` / `INVALID_REQUEST` / `PROTOCOL_ERROR`. **No `retriable`**, **no `commandStatusName`**. Message is `e.getMessage()`, which jsmpp already formats as hex status + description. Branch order matters: `GenericNackResponseException` **before** `InvalidResponseException` (it is a subclass and carries a real `command_status`); `PDUStringException` before `PDUException`; `IOException` last. Pure static `mapSubmitFailure(Exception) → BError` for JUnit reach. | red-team, over 3 conflicting SME positions | 8h |
| 8 | Encoding + raw-byte escape hatch | Encode only the three schemes the connector already **decodes precisely** (`Dispatcher.java:464-466`). **No GSM-7 option of any kind** — see reconciliation. The escape hatch (`byte[]` + explicit `dataCoding` int) is **mandatory in this sprint**, because it is what makes `data_coding 0x00` expressible at all; and it must be **mutually exclusive** with `shortMessage`+`encoding`, rejecting both-supplied — otherwise it recreates the very both-fields ambiguity SMPP forbids. Encoder must **reject** unencodable characters naming the offending index (`getBytes(ISO_8859_1)` silently substitutes `?`). | red-team + conformance audit | 6h |
| 9 | `receiptedMessageId` (TLV 0x001E) | `submit_sm_resp.message_id` is **opaque and SMSC-defined** (§5.2.23) while Appendix B calls the receipt format "SMSC vendor specific" and types `id` as 10 octets decimal — so the hex-vs-decimal radix mismatch is a *consequence of the spec*, not a vendor bug, and jsmpp ships both a hex and a decimal id generator rather than resolving it. The spec's only **guaranteed** correlation key is the `receipted_message_id` TLV (§5.3.2.12), reachable via the same `pdu.getOptionalParameter(Class)` call already made at `Dispatcher.java:272-273`. Add as a new optional field on **`Sms`** — not inside `DeliveryReceipt` (which `types.bal:250-252` promises is a faithful 1:1 surface of jsmpp's bean, and jsmpp's bean has no such field) and not in `properties` (a correlation key is load-bearing, not advisory). **Correct `types.bal:263`**, which currently states the correlation as fact. Normalise nothing. | conformance audit; placement by red-team | 5h |
| 10 | Mock SMSC submit support — **pulled forward, blocks everything else** | Today `MockSmsc` sets **no** `ServerMessageReceiverListener` at all, so every submit test would fail with `ESME_RX_R_APPN` regardless of connector correctness. Needs: a capturing listener set **once in the private ctor** (`SMPPServerSessionListener.accept()` copies it into each session, which removes the accept→set race structurally); `connectionId` minted **before** `request.accept(...)` (currently `:116-117` mints it after, so a submit arriving on the heels of `bind_resp` is unattributable); a **per-connection** FIFO capture queue + field accessors; monotonic generated `message_id`; `setSubmitFailure`; `setSubmitDelay`; a per-mock `pduProcessorDegree` knob. Use `new SubmitSmResult(new MessageId(id), …)` — the `String` ctors are package-private. | qa-expert | 14–16h |
| 11 | Docs | `Package.md:9-10` ("receive-only by design: there is no `submit_sm`/transmit API"), `:62-71`, `:109-112`, `:152-162`; `Module.md:1-9`; `types.bal:4-6` and `listener.bal:7-15` (both ship in generated API docs); `architecture.md:8`, `:161-176`, `:270-293`; `examples/README.md`; `examples/two-way-sms/README.md`. Plus **the M2 re-derivation in all three places it is stated**: `NativeListener.java:46-54`, `architecture.md:236-238`, and `types.bal:88-97` — the last being the guarantee in the connector's own shipped voice. Also fix the **pre-existing** contradiction at `Package.md:161-162` ("receipt text is not parsed into typed fields") against `:96-107` and `types.bal:260-288`. Add `qa-strategy.md` §6, which currently lists outbound `submit_sm` as out of scope. | ballerina-developer + red-team | 8h |
| 12 | The duplicate-MT caveat | The single biggest risk in the feature, and it is documentation plus one test, not code. See reconciliation. | red-team | 3h |

### Exit gate

All of the following pass under `./gradlew build` from `smpp/`, with zero new
`@test:Config {enable: false}`. New `bal test` files take ports **27805+** (27776–27804 are taken).

**Level 2.1 — JUnit (pure, no session):** `OutboundSmsMappingTest` (`OutboundSms` → jsmpp
arguments, including `esm_class == 0x00` asserted on the composed byte — a wrong value is invisible
in a happy-path test yet changes SMSC routing and billing); `SubmitErrorMappingTest` (every
`FailureMode` branch, including `PDUException`/`InvalidResponseException` which the mock cannot
reach); encoder rejection cases.

**Level 2.2 — `bal test`:**

- `testSubmitHappyPathPinsWirePdu` — asserts at the mock: `destAddr`, TON/NPI, `data_coding`,
  `registered_delivery` (**and that it is 0 when not requested** — the negative is what catches an
  always-on bug), `sourceAddr` defaulting and per-message override; and that the returned id
  **equals the mock's generated id**, not merely that it is non-empty.
- `testSubmitOnReceiverBindIsRejected` — message names `bindType` and the fix, and **does not
  contain `"BOUND_RX"`**. That negative is the only thing distinguishing guard-present from
  guard-absent, since jsmpp's `ensureTransmittable` throws a bare `IOException`.
- `testSubmitSurvivesRebindOnNewSession` — the stale-session regression, designed so it **cannot**
  pass with a cached session: a submit **before** the sever captured on conn1 (without it a
  lazy resolve-on-first-use cache is never wrong); the post-rebind submit captured on **conn2**;
  `submitCount(conn1)` unchanged; returned ids differ; **two full cycles** (kills a refresh-once
  cache).
- `testSubmitDuringRebindFailsFast` — the connector's own wording, no `"CLOSED"` leak.
- `testSubmitBeforeStartIsRejected` / `testSubmitAfterGracefulStopIsRejected` — a clear
  `smpp:Error` naming the lifecycle state, not an `IOException` or a panic.
- `testSubmitFromOnErrorDoesNotDerailRebind` — the submit errors **and** `awaitNextBind` still
  yields conn2. Sprint 5 recorded that runtime work on that path already once derailed the rebind.
- `testCallerParamShapes` — four services: `onDeliverSm(Sms)` (the 1.0.1 compat guarantee),
  `onDeliverSm(Sms, Caller)`, `onDataSm(Sms, Caller)` (a separate dispatch site), and a **mixed**
  service with one of each — the case a two-case test misses entirely.
- `testSubmitErrorMappingPerCommandStatus` — every status in the table → `commandStatus` +
  `FailureMode` in the detail.
- `testConcurrentSubmitsCorrelateAndKeepaliveAnswered` — N concurrent submits against a slow mock;
  distinct, **correctly correlated** ids (each handler gets the id for *its own* text);
  `recordedErrorCount() == 0`; peak handler concurrency `== N` as a **positive** assertion.
  **Mutation-verified:** setting `KEEPALIVE_RESERVE_THREADS = 0` must make it fail.
- `testSubmitStarvesInboundDispatchWithThrottle` — with all permits held, the next inbound
  `deliver_sm` comes back `ESME_RTHROTTLED`. Pins the documented consequence as intended.
- `testDuplicateMtUnderSyncTransactionTimeout` — **the item-12 test.** Forces the SMSC-side
  transaction timer to expire while a SYNC handler is submitting, and pins the documented outcome.
- `testDlrCorrelatesWithReturnedMessageId` and `testReceiptedMessageIdTlvSurfaced`.
- `testOversizeRejectedAtExactBoundary` — per-encoding, in **octets**; includes a 160-character
  string containing one `€` (the escape costs two septets) and the UCS-2 boundary in **UTF-16 code
  units**, not code points, so emoji are counted correctly.
- `testRejectedSubmitsDoNotLeakPendingResponses` — `getUnacknowledgedRequests()` stays 0 across N
  rejected submits (item 6b).
- `config_validation_test.bal` extended for `sourceAddr` and `transactionTimeout`.
- The three existing tests whose premises item 5 changes — `immediate_stop_test.bal:57`
  (`stopElapsed <= 2.0d`), `graceful_stop_test.bal:45-47`, `backpressure_test.bal:69` — updated
  and still green.

**Explicitly NOT in this gate:** the compiler plugin (Sprint 9); the `examples/two-way-sms` rewrite
and its `smoke-test.sh` MT assertion (blocked on 1.1.0 being on Central — see item N8 below);
`smpp:Client` (Sprint 10); any GSM-7 encoding; splitting/`message_payload`; rate limiting.

### Reconciliation notes

**Where `submit` lives — `Caller`, with the report's signature corrected.** The report proposed
`onDeliverSm(smpp:Caller caller, smpp:Sms sms)`. Mid-review the `ballerina-developer` SME reversed
itself and proposed instead a vended `smpp:Sender` obtained via `listener.createSender()` (precedent
`jms:Session.createProducer()`), on the principle that *a stdlib `Caller` exists only when the
framework holds addressing identity the user cannot otherwise obtain* — and SMPP has one session on
a listener the user already named, with the reply address already in `sms.sourceAddr`.

The red team **refuted that discriminator** with `ftp:Caller`: it is per-**listener** (built in
`FtpListenerHelper.register`, never per `WatchEvent`), lifetime-constant, wraps a *separate*
`ftp:Client`, and exposes 28 methods that every one take an explicit `path` and have nothing to do
with the inbound event. A capability-only, per-listener Caller that originates unrelated outbound
traffic has direct stdlib precedent, so the discriminator was a description of http/websocket/tcp/
udp/grpc rather than a principle. It also refuted three supporting claims: reversibility is
**symmetric** (either shape can be added later additively, so that axis decides nothing), and
`Sender` does **not** serve MT-only apps in 1.1.0 — verified empirically three ways, because
`main()` runs *before* the listener starts, `NativeListener.initListener:100` calls
`registerListener` unconditionally so the process never exits, and pre-starting the listener by hand
then crashes with the connector's own "already started". **MT-only is a lifecycle problem, not an
API-shape problem, and belongs to Sprint 10.**

But the same evidence **corrected the report**: mqtt's blessed code template is
`onMessage(mqtt:Message, mqtt:Caller)` and its validator *enforces* that order, and ftp's plugin
says "(WatchEvent) or (WatchEvent & Caller)". Caller-**first** is the pattern only where the Caller
is mandatory. So the caller goes **last** — which is also strictly safer: the 1-arity form is then a
strict prefix of the 2-arity form, `Sms` stays at index 0 in both, and a mis-slotted first argument
becomes impossible. *(A "rabbitmq accepts 1/2/3 params" claim could not be verified — the module is
absent locally — and is not relied on.)*

**GSM-7 does not ship, and the reasoning changed twice.** The report proposed `Encoding.GSM7` as
"packed", which is precisely what Sprint 7 ruled out as F3 (`:592-594`). The conformance audit then
argued the opposite — that packing is an *air-interface* job the SMSC performs, so unpacked septet
values with `data_coding 0x00` would be correct and only a character mapper (not a bit-packer) was
needed. The red team refuted that using jsmpp's own words: `Concatenation.java:71-80` documents the
charset as *"normally ISO Latin 1 unpacked as default SMSC alphabet"* and the implementation emits
`getBytes(charset)` **Latin-1 bytes** while using `GSMCharset` only to *count* septets. jsmpp counts
in septets and writes in Latin-1. So for 0x00 a conforming SMSC expects **its own provisioned
single-byte charset**, not septet values — and a septet-value mapper would emit bytes jsmpp itself
calls wrong. The architect's arithmetic off our own table (`Dispatcher.java:483-485`) shows the
cost concretely: `$` is septet `0x02` while septet `0x24` is `¤`, so `N$47.50` becomes `N¤47.50`
under the septet reading.

Both the audit and the architect were partly right and neither conclusion stood as stated:
**no bit-packer** (audit was right) and **no GSM-7 option at all, packed or unpacked** (architect's
outcome). The `decodeGsm7` flag remains what it is — an opt-in *tolerance*, default off, for SMSCs
that do send septet values. Receive tolerates; send conforms. The 0x00 case still ships, via the
escape hatch, and the documented recipe is exactly what jsmpp does: Latin-1 bytes with
`dataCoding: 0`. `LATIN1` stays the default: the audit's §5.2.19-note-b objection does not
discriminate, since `0x01` is equally an SMPP-specific reuse, and the only coding note b spares is
UCS-2 — indefensible as a default at 70 characters and doubled octets.

**`retriable` is rejected, and the amendments proposed to rescue it are what killed it.** Three SMEs
took three positions (reject / keep / keep-with-a-discriminator). It is not in the spec, not in
jsmpp, carrier-specific in practice, and — decisively — `commandStatus` is structurally **absent for
four of the five exception types**. A field that must be `true` for `ESME_RTHROTTLED` and must not be
`true` for a timeout is not one boolean, and two booleans encoding a five-valued taxonomy is worse
than shipping the taxonomy. Hence `FailureMode`, which is derived from the exception class and so is
defensible forever, and which states *"unknown, retrying may duplicate"* explicitly rather than
smuggling it into a flag. `commandStatusName` is dropped too: jsmpp's description table is private
with no accessor, `getMessage()` already carries hex plus description, and the proposed alternative
would have put **Java reflection into shipped native code** — permanently foreclosing any future
attempt to flip `graalvmCompatible` (`Ballerina.toml:17`, whose `false` currently has no recorded
rationale anywhere; record it while in there).

**The transaction-timer change is this sprint's only genuine backward-compatibility hazard**, and
five reviewers found the default while nobody traced the consequences. Raising it grows `unbind()`'s
wait 2 s → 10 s, so `immediateStop()`/`gracefulStop()` gain up to **+8 s** against an unresponsive
SMSC — against `listener.bal:77-84`'s published "immediately unbinds and closes" — and grows the
reader thread's post-close drain (`SMPPSession.java:678`, cited by no SME). Dead-link detection
degrades far *less* than feared: the probe fires from `readPDU`'s socket timeout, so the budget is
`enquireLinkInterval + transactionTimer` ≈ 62 s → 70 s, **13% not 5×** — which removes the strongest
objection and is worth recording. Three existing tests encode the 2 s default and are in this
sprint's diff whether the plan says so or not. The field is a non-volatile `long` read by the
enquire-link thread, so it is set once per bind and **never mutated per submit**.

**Findings the red team added that no SME had.** (N2) `immediateStop()` can now block for an
unbounded time and it is *user-attributable* for the first time: `AbstractSession.close()` does an
unbounded `enquireLinkSender.join()`, `interrupt()` does not break monitor entry, and a submitting
handler holds that same monitor across compose+write+flush with no write timeout — payload size and
submit rate become user-controlled. Worse under TLS, and it compounds the JDK-21 behaviour where a
virtual thread blocking on `synchronized` pins its carrier (JEP 491 lands in 24). Document; do not
patch jsmpp. (N3) Conversely the "interrupt → false `ResponseTimeoutException`" hazard that
`java-architect` raised is **not reachable** through any connector stop path — `close()` interrupts
only the enquire-link thread and `PDUReaderWorker` calls `shutdown()`, not `shutdownNow()` — so no
test is owed and **the docs must not claim it**. (N4) The PDU reader thread can now stall up to 60 s:
the pool's rejection handler runs *on the reader thread* and, for a response PDU, offers with a 60 s
timeout — during which no PDU is read at all. New because today the only response the connector ever
receives is `enquire_link_resp`. (N7) `_ = caller->submit(...)` is legal and discards the error,
leaving no log, no NACK and no trace — the one place this feature can lose an MT invisibly. Document
it and have the example `check` it; do **not** add connector-side logging, which would double-log for
users who handle it. (N8) The examples resolve `ramith/smpp` from **Central**, so the `two-way-sms`
rewrite cannot compile in CI until 1.1.0 publishes — sequence it after the publish or add a
local-repo override.

**Conflicts resolved against an SME by evidence:** a null `onAcceptSubmitSm` return does **not** NPE
— jsmpp 3.0.2 guards it (`SMPPServerSession:394-413`) and answers `ESME_RX_R_APPN`, so it is
unlike the Sprint-0 `data_sm` bug and there are **two** example mocks to fix, not one. jsmpp's write
path **is** synchronised — `SMPPSession(ConnectionFactory)` (`:124-128`), the only form the connector
uses, wraps the sender in `SynchronizedPDUSender`, and the monitor is provably one object per session
because `SocketConnection` caches the stream in a `private final` field and both our factories return
it unwrapped. So concurrent submits are **safe by construction** and the report's "verify under load"
is settled by inspection; the concurrency test becomes a regression test whose assertions had to be
rewritten, since "assert no interleaving corruption" is unfalsifiable. TON/NPI became typed enums and
the return type became a record — both reversals the `architect-reviewer` accepted against its own
earlier rulings, the second because **`getMessageId()` can be null on an `ESME_ROK` response**, which
`returns string|Error` cannot honestly represent.

**Carried into the risk register rather than fixed:** `SynchronizedPDUSender.sendSubmitSmResp` is the
only method in that class **not** wrapped in `synchronized (os)`. It cannot affect the connector
(which never sends `submit_sm_resp`) but it can corrupt **our mock's** output stream and would
present as a connector concurrency failure — hence the per-mock `pduProcessorDegree` knob in item 10,
pinned to 1 in the concurrency test, with the reason in a comment so nobody "fixes" it back.

**Phase 1 spec verification — DONE (2026-07-29), all claims CONFIRMED verbatim.** The red team
flagged three rulings as resting on the conformance audit's authority because no local spec copy was
available. The PDF was fetched from smpp.org and all three hold, so **no design change is needed**:

- **§5.2.21 `sm_length`:** "0 — no user data in short message field / **1-254 allowed** / **255 not
  allowed**", and §5.2.22: "A maximum of **254 octets** can be sent." §3.2.3 repeats it. So the
  report's 140 was the GSM air-interface budget, as diagnosed; the connector's reject threshold is
  254, with the lower coding-dependent guard layered above it.
- **§5.2.17 `registered_delivery`:** `xxxxxx00` none (default) / `xxxxxx01` success-or-failure /
  `xxxxxx10` failure-only / **`xxxxxx11` reserved**, and "The default setting of the
  registered_delivery parameter is 0x00." So the enum ships **three** members. jsmpp's fourth
  (`SUCCESS` = 0x03) is javadoc'd "Introduced in SMPP 5.0" — confirmed in the pinned jar.
- **§5.2.12 `esm_class`:** "The default setting of the esm_class parameter is 0x00", and the
  ESME→SMSC table gives `xxxxxx00` = Default SMSC Mode (Store and Forward), `xx0000xx` = default
  message type, `00xxxxxx` = no GSM features. So 0x00 is exactly a plain MT, and UDHI is
  `01xxxxxx` = 0x40. *(The NPE-on-null half of that finding is a jsmpp fact, already verified at
  `DefaultPDUSender.java:240`, not a spec claim.)*

Three further claims pinned in the same pass, all CONFIRMED verbatim: §5.2.12's notes make UDHI
**mandatory** — "it must set the UDHI flag in the esm_class field" — which is what forces
reject-oversize rather than merely recommending it; §5.2.16 defines `validity_period` in "absolute
time format or relative time format" per §7.1.1, so it is definitively not a number of seconds; and
the item-9 honesty argument is the spec's own wording — §5.2.23: `message_id` "is an **opaque value**
and is set according to SMSC implementation", versus §5.3.2.12 `receipted_message_id`: "the opaque
SMSC message identifier **that was returned in the message_id parameter of the SMPP response PDU**
that acknowledged the submission of the original message." The TLV is the guaranteed key; `id:` is
not.

**Bonus finding, and it strengthens an exclusion.** §5.2.17's own footnote reads: "Support for
Intermediate Notification Functionality is specific to the SMSC implementation and is **beyond the
scope of the SMPP Protocol Specification**." So intermediate notification (bit 4) fails the owner's
*first* filter outright — not in the spec — independently of jsmpp's bug where
`IntermediateNotification.NOT_REQUESTED` and `REQUESTED` are **both declared `0x00`** (verified in
the checkout), making that setter a no-op. Two independent reasons to leave it out; record both so
it is not revisited. Also confirmed: the spec's "Intermediate Notification (bit 5)" heading sits
over the pattern `xxx1xxxx`, which is bit **4** — an internal spec inconsistency, and jsmpp follows
the bit pattern (`MASK_BYTE = 0x10`), which is the correct reading.

**`Runtime.callMethod` and defaulted parameters — RESOLVED (2026-07-29). The red team's concern was
real, and the answer gives item 3 a sharper rule than "validate narrowly".**

Traced through the pinned runtime (`ballerina-rt-2201.13.4.jar`): `BalRuntime.callMethod` calls
`validateArgs(BObject, String)` — which takes only the object and the method *name*, so it does not
check arity — then `Scheduler.callMethod`, whose private overload calls
**`getArgsWithDefaultValues(ObjectType, MethodType, Strand, Object...)`** before
`ObjectValue.call`. That method reads `FunctionType.getParameters()`, `System.arraycopy`s the
supplied arguments into a wider array, and then consults **`Parameter.isDefault`** and
**`Parameter.defaultFunctionName`** to compute and store the missing ones.

So **the runtime pads defaulted trailing parameters automatically**, and
`onDeliverSm(smpp:Sms sms, string extra = "x")` is a **legal, working program at 1.0.1 today** —
`attach` matches on name alone and the runtime fills `extra` in. Validation that rejected any
2-parameter `onDeliverSm` whose second parameter is not a `Caller` would therefore break a shipped
program at startup: exactly the minor-release runtime break the red team warned about.

**The rule for item 3, precisely:** bind by parameter **type**; **skip trailing parameters where
`Parameter.isDefault` is true** — the runtime already handles those and they are none of our
business; and reject only when a **required** parameter exists that the dispatcher cannot supply.
That is narrower than "reject unknown 2-param shapes", it preserves every 1.0.1-legal program by
construction rather than by enumeration, and it uses a public field the runtime hands us instead of
a heuristic. `Parameter` exposes `name`, `isDefault`, `defaultFunctionName` and `type` as public
members, so all of this is a plain read. *(The runtime does raise an error inside that method for the
genuinely-unsatisfiable case; the connector should still reject at attach so the failure names the
method and the two legal signatures rather than surfacing per-PDU.)*

**The biggest remaining risk is not placement, encoding, or concurrency — it is that the shipped
defaults make duplicate MTs the likely outcome rather than the exotic one.** Every link is verified
and every one is a default: `responseMode = SYNC` withholds the `deliver_sm_resp` until the handler
returns; the handler blocks inside `submitShortMessage` holding both a dispatch permit and a jsmpp
pool thread; exceeding the **SMSC's** transaction timer makes the SMSC redeliver the `deliver_sm`,
and SMPP has no dedup key, so **the reply is sent twice**; independently, if our own timer fires the
PDU has provably already been flushed, so the SMSC likely has it while jsmpp silently drops the late
response and the caller never learns the id; and `maxConcurrentDispatch = 3` caps sustained replies
at roughly 10/s against a 300 ms SMSC, with the excess `ESME_RTHROTTLED` and redelivered **by
design** into handlers that may have already submitted. None of the mitigations are code: recommend
`ASYNC` for reply-style services in both `Caller.submit`'s and `ResponseMode.SYNC`'s docs, invert the
`maxConcurrentDispatch` tuning advice to *"if your handler submits, size for submit latency, not
handler CPU"*, and tell users to carry their own idempotency key. That is item 12, and it earns the
one test in the gate that pins a documented hazard rather than a behaviour.

**Total: ~90–105h estimated.**

---

## Sprint 9 — Ballerina compiler plugin → **gates the 1.1.0 release**

**Goal:** compile-time service-shape validation. Promoted out of the backlog because every stdlib
listener module that passes a `Caller` ships a plugin — http, websocket, grpc, mqtt, tcp, udp, ftp,
and (per report) rabbitmq — and this package has none, so `smpp:Service` being an empty
`distinct service object` (`listener.bal:90-91`) means the language validates **nothing**. Today a
typo'd `onDeliverSM`, or a method missing `remote`, compiles clean and silently never fires as long
as one other recognised method is present. Sprint 8's opt-in second parameter makes that gap
untenable rather than merely unfortunate.

**The red team ruled 1.1.0 may publish without it; the owner overruled that on 2026-07-29 and this
sprint now gates the release.** The red team's reasoning was sound as far as it went — with
type-based resolution plus attach-time rejection a mis-shaped signature fails at `listener.attach`,
so the program does not start: loud, immediate, deterministic, and the plugin only moves that from
startup to compile time. The owner's counter is about the standard rather than the severity: every
Ballerina listener module that passes a `Caller` ships a plugin, users discover an *opt-in*
parameter through code actions rather than docs, and a connector that publishes an unvalidated
service contract to Central is not what this project has been building. Sequencing it after
Sprint 8 is still right either way — the signature contract must be frozen before the plugin
encodes it, so writing them together would mean writing the plugin twice.

Scope: a third gradle subproject, `CompilerPlugin.toml`, ~8 `SMPP_1xx` diagnostics modelled on
`MqttFunctionValidator`, and two code-action templates (with and without the caller) — mqtt ships
exactly that pair. Note `qa-strategy.md` has no level for diagnostic assertions, so that test
infrastructure gets pulled forward per `development-process.md` Phase 4.

**Est. 3–5 days (24–40h).**

---

## Sprint 10 — session-lifecycle extraction, then `smpp:Client`

**Goal:** serve MT-only applications (bulk send, no inbound), which Sprint 8 deliberately does not.

Two phases in one sprint, the first gated on its own adversarial review before the second is
written, because it touches the repo's highest-risk code: the stateLock/`stateProcessorLock`
deadlock-freedom proof at `NativeListener.java:232-239` (explicitly labelled a load-bearing
cross-library invariant), the `dropReported` exactly-once handshake at `:213-227`, and the bound-race
critical section at `:240-263`. `development-process.md:96-99` already says that code runs in
isolation.

Phase 1 must also answer what MT-only actually requires, which the red team established is **not** an
API-shape question: `main()` runs before the listener starts, and `initListener:100` calls
`registerListener` unconditionally so a submit-and-exit program never terminates. And Phase 1 must
answer the design fork the original report never posed: does `Client` bind `TRANSMITTER` only, or may
it bind `TRANSCEIVER` — and if the latter, where do its inbound PDUs go, at which point it has
reinvented `Listener`?

One SMPP-economics constraint no stdlib precedent surfaces: SMSC operators meter and contractually
cap concurrent binds, unlike MQTT or Kafka connections, so a naive two-connection copy of the
`mqtt:Client`/`mqtt:Listener` split imposes a cost those ecosystems do not have. `TRANSCEIVER` exists
in the spec precisely so one session serves both directions.

**Est. 5–7 days.** Also worth folding in: `submitMultiple`, `queryShortMessage`,
`cancelShortMessage`, `replaceShortMessage` — all present on `SMPPSession`, all deferred from
Sprint 8.

---

## Explicit backlog (scoped, not scheduled)

| Item | Why it's backlog | Rough size |
|---|---|---|
| UDH multipart reassembly **and** concatenated send | Genuinely larger stateful design (per-source/ref keying, reassembly timeouts, out-of-order handling, memory bounds/eviction). Many mature SMPP libraries deliberately leave this to the application; `shortMessageBytes` (Sprint 1) plus the existing `udhi` flag already let a caller do it themselves. Sprint 8's send-side symmetry (reject oversize, don't split) is the matching decision: jsmpp's only helper, `LongSMS.splitMessage8Bit`, has a **JVM-global** static reference counter, prepends a UDH even for a 1-of-1 segment, silently chops beyond 255 segments, and does not set the `esm_class` UDHI bit the spec requires — so building on it is not the cheap option it appears to be. Splitting also means N message ids, N round trips, and **no atomicity** on partial failure. | 3–5 days (24–40h) |
| `message_payload` TLV for long messages | An explicit opt-in field, never a silent fallback — SMSC support is inconsistent and it changes segmentation and billing semantics invisibly. Note jsmpp documents the "never both fields" rule but does **not** enforce it, so enforcement would be the connector's. Still yields exactly one message id, so it does not disturb Sprint 8's return type. | 1–2 days |
| Outbound rate limiting | Policy, not protocol: nothing in SMPP v3.4 or jsmpp implements ESME-side TPS shaping, and the connector has no window/credit model to hang it on. Sprint 8's obligation is only that `ESME_RTHROTTLED` be *distinguishable*, which `FailureMode` satisfies. Note `maxConcurrentDispatch` already acts as an implicit outbound limit for reply-style traffic — documenting that honestly is the better answer. | Unestimated |
| Observability/metrics surface | Not raised as a defect by any reviewer, flagged by architect-reviewer as a natural future addition. | Unestimated |

---

## Full dependency graph (informal)

```
Sprint 0 (data_sm fix, credential leak, JUnit)  ──┐
                                                    ├─→ independent, can start immediately, no ordering between them
Sprint 1 (API safety nets, non-lifecycle tests) ──┘

Sprint 1 ─────────────────────────────────────────→ Sprint 2 (lifecycle state machine)
    (soft: shares native files; not a hard functional dependency)

Sprint 2 ─────────────────────────────────────────→ Sprint 4's structural fix
    (soft: cleaner to land the self-inflicted-drop fix against stable lifecycle code,
     not a hard functional dependency)

Sprint 3 (TLS) ────────────────────────────────────  fully independent of 0/1/2/4 — can run
                                                      in parallel with any of them if capacity allows

Sprint 5 ──────────────────────────────────────────  fully independent, do whenever convenient

Sprints 0-7 (all DONE) ───────────────────────────→ Sprint 8 (submit_sm → 1.1.0)
    (hard: Sprint 2's lifecycle state machine and Sprint 7's receipt parsing are both
     load-bearing for submit — the state machine is what `submit`'s pre-check consults,
     and the receipt surface is what a returned message_id correlates against)

Sprint 8 ─────────────────────────────────────────→ Sprint 9 (compiler plugin) ──→ PUBLISH 1.1.0
    (hard: the plugin encodes the remote-method signature contract, so that contract must
     be frozen by Sprint 8's Phase-5 review before the plugin is written. And per the owner's
     2026-07-29 decision the plugin is a RELEASE blocker — 1.1.0 ships at the end of 9, not 8)

Sprint 8 ─────────────────────────────────────────→ Sprint 10 (lifecycle extraction + Client)
    (hard: `Client` reuses `submit`'s public shape verbatim, and the extraction must not
     run concurrently with anything else touching the native lifecycle lock)

Sprint 9 ∥ Sprint 10 ─────────────────────────────  independent of each other; either order
```

Only Sprint 2 is a genuine hard gate (it owns the highest-risk code and several other
findings are explicitly "resolved by" its lock). Sprints 0, 1, 3, and 5 have no functional
dependency on each other and can be reordered or parallelized if more than one person is
ever working on this.

## Grand total

~175–218 hours across Sprints 0–7 (roughly 22–27 nominal 8-hour days), **all now done** — that
work shipped as 1.0.0/1.0.1 on Central. Sprint 8 adds ~90–105h; **Sprint 9 (~24–40h) gates the
1.1.0 release**, so 1.1.0 publishes at the end of Sprint 9 rather than Sprint 8; Sprint 10 adds a
further ~40–56h. Neither figure counts the explicit backlog.

Given the "no deadline, correctness over speed" framing, treat these as sequential gated
milestones rather than a calendar commitment — each sprint's exit gate (tests passing) is the
actual definition of done, not the hour estimate. Sprint 8's estimate is deliberately larger than
the report's implied scope: roughly a third of it is test infrastructure that has to land before
any submit code can be verified at all (the mock SMSC accepts no `submit_sm` today), and another
slice is correcting things the panel found in *existing* shipped behaviour — the 2-second
transaction timer, the keepalive rationale that three documents state in now-incomplete terms, and
a self-contradicting paragraph in `Package.md`.
