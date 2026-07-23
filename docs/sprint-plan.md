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

## Explicit backlog (scoped, not scheduled)

| Item | Why it's backlog | Rough size |
|---|---|---|
| Ballerina compiler plugin (compile-time service-shape validation) | New tooling category (separate compiler-API jar, `CompilerPlugin.toml`, diagnostic-assertion test loop) — real value, but Sprint 1's runtime check captures most of it for a fraction of the cost. Typical for `ballerinax/*` connectors to add this well after v1. | 3–5 days (24–40h) |
| UDH multipart reassembly | Genuinely larger stateful design (per-source/ref keying, reassembly timeouts, out-of-order handling, memory bounds/eviction). Many mature SMPP libraries deliberately leave this to the application; `shortMessageBytes` (Sprint 1) plus the existing `udhi` flag already let a caller do it themselves. | 3–5 days (24–40h) |
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
```

Only Sprint 2 is a genuine hard gate (it owns the highest-risk code and several other
findings are explicitly "resolved by" its lock). Sprints 0, 1, 3, and 5 have no functional
dependency on each other and can be reordered or parallelized if more than one person is
ever working on this.

## Grand total

~175–218 hours across all six sprints (roughly 22–27 nominal 8-hour days), not counting the
explicit backlog. Given the "no deadline, correctness over speed" framing, treat these as
sequential gated milestones rather than a calendar commitment — each sprint's exit gate
(tests passing) is the actual definition of done, not the hour estimate.
