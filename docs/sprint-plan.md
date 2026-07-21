# Remediation sprint plan — `ramith/smpp`

Source: an adversarial architecture/code review (5 independent SME passes + a hostile
red-team adjudication), followed by 4 SMEs designing fix plans for their domain
(java-architect, ballerina-developer, qa-expert, architect-reviewer). This document
reconciles those plans into a single, dependency-ordered execution plan.

**Pacing note:** no deadline is driving this; sequencing is by risk and dependency, not
calendar weeks. "Sprint" here means a milestone with an explicit exit gate — move to the
next one only when its gate passes, however long that takes. Hour estimates are included
for relative sizing, not as a schedule commitment.

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

## Sprint 0 — Stop the bleeding

**Goal:** the two fully-independent, zero-dependency, high-severity items — a
100%-reproducible crash and a live credential-leak path. Both are safe to fix and ship in
isolation, before anything else in this plan starts.

| Item | Scope | Est. |
|---|---|---|
| Fix `Dispatcher.onAcceptDataSm` returning `null` | Return `new DataSmResult(EMPTY_MESSAGE_ID, new OptionalParameter[0])` instead of `null`; confirmed via jsmpp's own reference listeners (`MessageReceiverListenerImpl`, `SMPPServerSimulator`, `StressServer` in `jsmpp-examples`) that none of them ever return `null` here. Also: swept every other non-`void` `MessageReceiverListener` callback in `Dispatcher.java` — confirmed this is the *only* one with this shape. | 2h |
| Credential length pre-validation | Validate `systemId` (≤15), `password` (≤8), `systemType` (≤12) *before* `connectAndBind`, so jsmpp's own length-validator (which embeds the raw value in its exception message) is never reached with an oversized credential. Return a clean, credential-free error instead. | 3–4h |
| Minimal mock scaffolding + a `data_sm` end-to-end test, written test-first | Enough of the MockSmsc rewrite to send one real `data_sm` PDU through a session and assert a `data_sm_resp` comes back. Write this test *before* the fix above, confirm it reproduces the NPE/timeout, then flip it green. | ~10–15h |
| Pure-logic JUnit suite for `decodeShortMessage`/`payloadBytes` | Fully independent of the mock/session work — start in parallel. Needs a small visibility refactor (private static → package-private, or extract a `PduCodec` utility) first. | 9h |

**Exit gate:** the `data_sm` test passes against the fixed code; credential boundary tests
(7/8/9 chars password, 15/16 systemId, 12/13 systemType) pass and confirm no credential
substring appears in any error message; JUnit decode suite passes.

**Total: ~25–30h.**

---

## Sprint 1 — Make the public API fail loudly instead of silently

**Goal:** every item here is a `.bal`-layer or thin native-boundary safety net; none
touches the lifecycle state machine, so this can proceed independently of (and before)
Sprint 2's riskier rewrite.

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

## Sprint 2 — The lifecycle state machine

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

**Exit gate:** qa-strategy.md's Phase-2 lifecycle-timing tests — double-`start()`
rejection, restart-after-stop rejection, rebind backoff/exhaustion, `gracefulStop` vs
`immediateStop` timing, abrupt-severance vs peer-initiated-unbind detection — all pass.
Given java-architect's own flag that the `bound`-race fix is the hardest to test with
confidence, budget explicit soak-test time (repeated-iteration runs, not a single pass)
before calling this sprint done.

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

## Sprint 3 — Transport security (TLS)

**Goal:** architect-reviewer's firm position, which I'm carrying into this plan as a hard
gate rather than a nice-to-have: a public, Central-bound connector that hands real
credentials over the network in cleartext, with *no* in-band encryption option and no
documented alternative, is not defensible. Documentation-only ("assume TLS is
network-terminated") is not an acceptable substitute for having the option at all — it can
still be the *recommended* production topology, but the option must exist.

| Item | Scope | Est. |
|---|---|---|
| `secureSocket` config on `ConnectionConfig` | `cert` (truststore/cert path, server verification), optional `key` (keystore, for mTLS), optional `protocol`/`ciphers`. | ~1 day (8h) |
| Custom `ConnectionFactory` wiring in `NativeListener.bind()` | jsmpp's stock `SSLSocketConnectionFactory` only reads a JVM-global truststore, which isn't idiomatic for per-listener Ballerina config — build a small factory wrapping an `SSLContext` constructed from the Ballerina-supplied material, passed to `new SMPPSession(factory)`. Map an explicit, clearly-labeled dev-only "disable verification" flag to `NoTrustSSLSocketConnectionFactory`. | ~0.5–1 day (4–8h) |
| TLS integration test | Stand up a TLS-terminating mock SMSC and assert a full bind+dispatch round-trip over it. This is the real cost driver of this sprint. | ~1.5–2 days (12–16h) |

**Exit gate:** the TLS round-trip test passes; the insecure/no-verification path is
excluded from any default and clearly labeled in both code and docs.

**Total: ~24–32h.**

---

## Sprint 4 — Stop the connector from dropping its own connection

**Goal:** the "self-inflicted drop" risk — a slow `SYNC` handler at the *default*
`maxConcurrentDispatch` (3) can starve jsmpp's shared PDU-processing pool badly enough that
`enquire_link` traffic stalls and the SMSC (or jsmpp's own keepalive sender) decides the
link is dead and closes it, triggering exactly the rebind churn the connector's resilience
feature exists to handle — self-inflicted, not external. Also bounds ASYNC mode's currently
uncapped resource growth.

| Item | Scope | Est. |
|---|---|---|
| Expose `enquireLinkTimer`/`transactionTimer`/`queueCapacity` as config | Wired to the existing `AbstractSession` setters before `connectAndBind`. Gives operators a way to tune the failure window even before the structural fix below. | 4–8h |
| Structural fix: decouple handler concurrency from keepalive capacity | Size jsmpp's `pduProcessorDegree` to `maxConcurrentDispatch + a small keepalive reserve`; gate handler entry with a connector-owned `Semaphore(maxConcurrentDispatch)` in `Dispatcher.dispatch()`, rejecting overflow immediately with `ESME_RTHROTTLED` rather than letting it consume a reserved thread. (Note, corrected during fix-planning: routing handler execution to a *separate* thread pool does **not**, by itself, fix this for SYNC mode — SYNC's whole contract is blocking the jsmpp thread until the handler returns, so the reserve-capacity approach is the actual fix, not a relocation of where the blocking happens.) | 16–24h |
| ASYNC backpressure | A `Semaphore` sized by `maxConcurrentDispatch`, acquired before spawning each ASYNC virtual thread and released in its `finally` — bounds ASYNC to the same bounded-throughput-at-cost-of-latency behavior. Explicit decision: block (`acquireUninterruptibly`), don't drop — SMPP is at-least-once, and a dropped PDU after a positive ack is permanently lost, whereas blocking only adds ack latency. | 5–6h |

**Exit gate:** a slow-handler saturation test proving `enquire_link` is still answered
while every handler slot is occupied; a bounded-concurrency test for ASYNC mode.

**Total: ~25–38h.**

**Reconciliation note:** architect-reviewer's top-down estimate for the structural fix
(2–3 engineer-days, 16–24h) and for ASYNC bounding (1–2 days, 8–16h) were both somewhat
higher than java-architect's bottom-up, code-level estimate for ASYNC bounding specifically
(5–6h). Used java-architect's number for ASYNC since it's grounded in an exact code sketch;
kept architect-reviewer's range for the SYNC-side structural fix since no other agent
scoped that one at code level.

---

## Sprint 5 — Polish / fast-follow

**Goal:** real improvements that are safe to defer — nothing here is a correctness or
security gap, just quality-of-life.

| Item | Scope | Est. |
|---|---|---|
| Route stderr fallback (`printStackTrace`) through `ballerina/log` | Small new plumbing (a Ballerina-side `log:printError` helper invoked from Java via `Runtime.callFunction`) so the doc's existing claim becomes true instead of being fixed by lowering the claim. | 2–3h |
| GSM 03.38 opt-in decoder | A default+extension-table decoder for the unpacked case, shipped **opt-in** (not changing the `data_coding 0x00` default) so it can't break anyone currently relying on the UTF-8 fallback. | 8–16h |

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
