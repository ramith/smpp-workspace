# jsmpp upgrade checklist

**This connector depends on behaviours of jsmpp 3.0.2 that are not part of its
public contract, plus three JDK behaviours.** Do not bump the jsmpp version — or
the JDK baseline — without walking this list.

Legend: **LOUD** = a test or a startup path fails, so the upgrade cannot ship
broken. **SILENT** = behaviour degrades with no signal; only reading the source
catches it. Silent rows are the ones that matter.

The version is pinned in `smpp/gradle.properties` (`jsmppVersion`) and bundled by
path from `smpp/ballerina/lib/`. A reference copy of the 3.0.2 source is vendored
at `jsmpp/` precisely so this audit can be re-run by reading, not guessing.

---

## A. `transactionTimer`: the getter-vs-field split

`ConnectorSession` exists entirely because of this asymmetry. jsmpp has ONE
`transactionTimer` per session bounding two unrelated things (how long a *submit*
waits for `submit_sm_resp`, where patience is safety; and how long *housekeeping*
waits, where patience is pure latency). The connector splits them by putting the
short housekeeping bound in the **field** and returning the long submit bound from
the overridden **getter** only inside a connector-owned `ThreadLocal` context.

| Call site | Reads | If it flips |
|---|---|---|
| `AbstractSession.unbind()` | **FIELD** — the only field read in the library | field→getter is harmless (the getter falls through to the field outside a submit context) |
| `SMPPSession.submitShortMessage` | getter | getter→field ⇒ submits silently get the 2s housekeeping bound. **LOUD** — `testSubmitWaitsBeyondHousekeepingTimer` fails |
| `AbstractSession.sendEnquireLink()` | getter | no change today (both 2s) |
| `SMPPSession`'s `pduExecutor.awaitTermination` | getter | no change today |
| `dataShortMessage`, `submitMultiple`, `query`/`replace`/`cancel` | getter | unused today; **they go live if the submit family is extended** — re-check then |
| `SMPPSession.sendBind` | NEITHER — uses its explicit `timeout` argument | this is why `bindTimeout` works. If a future release routes bind through `getTransactionTimer()`, `bindTimeout` silently stops bounding the bind-response wait. **SILENT** |

**How to re-verify:** `javap -p -c org.jsmpp.session.AbstractSession
org.jsmpp.session.SMPPSession | grep -n "transactionTimer\|getTransactionTimer"`.
Field reads appear as `getfield`; getter reads as `invokevirtual`.

**Related, unlisted coupling:** `ConnectorSession` assigns its submit timer
*after* `super(connectionFactory)`, while `getTransactionTimer()` is public and
overridden. Safe only because nothing in jsmpp's constructor chain reads the timer
during construction. If a future constructor does (or starts a thread that does),
it observes `0`. **SILENT.**

## B. `AbstractSession.close()`: two structural holes, both load-bearing

The choreography is: close the connection → `if (Thread.currentThread() !=
enquireLinkSender)` → `interrupt()` then **unbounded `join()`** → `ctx.close()`,
the only line that fires the CLOSED listener, *inside* that same guard.

1. **`close()` invoked FROM the EnquireLinkSender** — which is exactly what
   happens on the ordinary dead-link path — never reaches `ctx.close()`. Session
   state stays `BOUND_TRX`; CLOSED never fires from the closing thread. This is
   why `ObservedConnection.close()` is a drop signal (see §D).
2. **`interrupt()` cannot break `synchronized` monitor entry.** The
   EnquireLinkSender's send path enters `synchronized (os)` in
   `SynchronizedPDUSender`. If another thread holds `os` in an untimed write, the
   `join()` blocks forever and `ctx.close()` is never reached.

Both are why the stop path has a force-close watchdog (`CLOSE_WATCHDOG_MS`) and
why the connector force-closes the raw socket rather than waiting on jsmpp. If
either changes upstream, re-derive the whole drop-detection stack.

**`close()` also never touches `pendingResponses`** — see §F.

## C. `SessionStateListener` firing: the deadlock-freedom proof

Two jsmpp locks are involved and the connector's safety rests on the second:

- `SMPPSessionContext.changeState` releases `stateProcessorLock`'s write lock
  **before** calling `fireStateChanged`.
- `AbstractSessionContext.open()/bound()/unbound()/close()` are all
  `synchronized`, so `fireStateChanged` runs **holding the context object
  monitor**.
- **`SMPPSessionContext.getSessionState()` takes only the READ lock and NEVER the
  object monitor.** This is the load-bearing fact: the connector holds
  `stateLock` and wants the read lock; a firing jsmpp thread holds the monitor and
  wants `stateLock`. No cycle.

**If a future jsmpp made `getSessionState()` synchronized** — a plausible fix for
the unsynchronized `stateProcessor` read in `changeState` — the connector's
post-install check becomes a hard deadlock between a Ballerina strand and a jsmpp
reader thread. **SILENT until it hangs.**

Also: `AbstractSessionContext` swallows any `Exception` a listener throws into
slf4j. A throw from the connector's lambda vanishes.

## D. `PDUReaderWorker` and the streams `ObservedConnection` wraps

- `SocketTimeoutException` → `notifyNoActivity()`: SO_TIMEOUT doubles as the
  enquire_link trigger, so it fires on every idle interval of a **healthy**
  session. `ObservedConnection` excludes it explicitly. If jsmpp ever wrapped that
  exception, every keepalive tick would fire a false transport death. **LOUD**
  (tests would storm).
- Stream stack: socket → `StrictBufferedInputStream` → **our `FilterInputStream`**
  → `DataInputStream`. `StrictBufferedInputStream` overrides only the 3-arg
  `read` and rethrows `IOException` untranslated; `FilterInputStream` routes
  `read(byte[])` through the overridden 3-arg form, so `readFully`/`readInt` are
  both covered.
- The reader can itself enter `synchronized (os)` when it NACKs
  (`sendNegativeResponse` on a full queue, `sendGenericNack` on a bad length). A
  reader parked on that monitor never reaches `read()`, which is why the
  connector cannot rely on the stream signal alone.

## E. `SynchronizedPDUSender` locking and stream identity

- The monitor is the `OutputStream` **object**, one per connection
  (`SocketConnection.out` is `final` and returned unwrapped; `ObservedConnection`
  also returns it unwrapped; the session caches it once). So the serialization is
  per **connection**, not per listener — a rebind mints a fresh monitor.
- **Never return a fresh wrapper from `getOutputStream()`.** `synchronized (os)`
  locks on whatever object the connector hands back; a per-call wrapper would
  silently destroy jsmpp's write serialization and interleave PDU bytes on the
  wire. If output-side observation is ever added, it must return a stable
  identity.
- `sendSubmitSmResp` and one `sendDataSmResp` overload reach the inner sender
  **without** holding the monitor. Server-side paths only — this connector, as an
  ESME, never invokes them — but it is a real jsmpp defect that would corrupt the
  wire for any future server-style listener.

## F. `pendingResponses` lifecycle

- An unbounded `ConcurrentHashMap`; the entry is `put` **before**
  `task.executeTask`.
- A `PDUStringException` from `executeTask` is not an `IOException`, escapes the
  catch, and **orphans the entry permanently**. This is the entire reason
  `NativeCaller.compose()` pre-validates every string parameter locally.
- **`close()` never touches `pendingResponses`, and `PendingResponse.waitDone()`
  is a plain condition await** woken only by `done()`/`doneWithInvalidResponse()`
  or by timeout. **Link death does not wake a blocked submitter**, and neither
  does closing the socket. There is no connector-side way to wake one (the map is
  private, the sequence number is not exposed, and `waitDone` swallows
  interrupts), which is why an in-flight submit is remapped on timeout rather than
  woken. If a future jsmpp adds fail-pending-on-close, the remap can be retired.

## G. `pduProcessorDegree` is applied by a jsmpp-PRIVATE listener

`setPduProcessorDegree` only stores the value. The pool is built `(1, 1)` and
resized **only** by jsmpp's own private `BoundSessionStateListener` on the bound
transition. There is no public accessor for the real pool size.

**If that resize is ever dropped or reordered, the pool stays single-threaded and
every SYNC submit deadlocks until `transactionTimeout`** — a SYNC handler occupies
the one thread while its own `submit_sm_resp` needs another. **SILENT AND
CATASTROPHIC** in principle, but two integration tests fail loudly if it happens:
`testConcurrentSubmitsCorrelateAndKeepaliveAnswered` and
`testSubmitStarvesInboundDispatchWithThrottle`. Neither name suggests it — do not
delete or weaken them without replacing the coverage.

## H. Inbound queue overflow stalls the reader

The work queue is fixed at 100 and never overridden. On overflow the rejection
handler runs **on the reader thread**; for a *response* PDU it offers with a
**60 000 ms** timeout, during which no PDU is read at all. Since submits exist,
`submit_sm_resp` is a response PDU — so a saturated `pduExecutor` can stall all
reading for 60s while the submit awaiting that response times out at 30s.

## I. Exception hierarchy (pins `mapSubmitFailure`'s branch order)

`GenericNackResponseException extends InvalidResponseException` (and carries a
real `command_status`, so it must be matched FIRST); `PDUStringException extends
PDUException`. `SMPPSession`'s unchecked `(SubmitSmResp)` cast can
`ClassCastException`, which is why the mapper terminates in a `Throwable` branch.

Also: **`ProcessRequestException` thrown from `onAcceptDeliverSm`/`onAcceptDataSm`
propagates with the connector's `command_status`, but ANY other exception type is
rewritten to `ESME_RX_T_APPN`.** The connector's permanent-error NACK (`RX_P_APPN`
for an unimplemented handler) would silently become a *transient* one — a
guaranteed redelivery poison loop. **SILENT**, and the reason
`testUnhandledPduTypeIsNackedPermanently` asserts the exact status byte decoded at
the mock rather than merely "it failed".

## J. `StringParameter` semantics — and the unit trap

`StringParameter` is a public enum exposing `getMax()`/`getType()`/`isRangeMinAndMax()`,
so the connector reads limits rather than transcribing them (hand-copied numbers
reintroduce the C-octet off-by-one: a C-octet max INCLUDES the NUL, an octet
string's does not).

**But jsmpp validates in UTF-16 code units and writes in platform-default bytes.**
`StringValidator` counts `value.length()`; `PDUByteBuffer.append(String)` calls
`stringValue.getBytes()` with no explicit charset. Both validators therefore agree
with each other and disagree with the wire. The connector closes this by rejecting
any character above `0x7F` in the seven affected fields (`destAddr`, `sourceAddr`,
`serviceType`, `validityPeriod`, `systemId`, `password`, `systemType`), which makes
code-unit count == octet count true by construction. If jsmpp ever specifies a
charset, this restriction can be revisited — but note it also removes a
`-Dfile.encoding` dependency, which is worth keeping regardless.

`VALIDITY_PERIOD` is the one parameter with `isRangeMinAndMax == false` (empty or
EXACTLY 16), which is why it gets a shape check rather than a range check.

## K. Thread lifecycles and publication

`PDUReaderWorker.start()` → `sendBind` → `enquireLinkSender.start()`. Both
`Thread.start()` calls happen after the connection/streams are written, supplying
the happens-before edge. The connector's `AtomicReference` read-through exists for
**staleness across rebind**, not for publication.

Both worker classes are **non-static inner classes**, so a live orphaned thread
keeps the whole session graph strongly reachable — session, context, the
registered state-listener lambda (which captures the listener object), the thread
pool, its queue, and every queued task with its PDU bytes. A wedge is therefore a
heap leak, not just a thread leak.

## L. `finalize()`

`SMPPSession.finalize()` calls `close()`. Because of §K a wedged session is never
unreachable, so its finalizer never runs; and since the connector now force-closes
and closes abandoned sessions on its own thread, `finalize()` is a no-op by the
time it could run. If the connector ever reverts to abandoning sessions outright,
this becomes a live hazard: `close()` on the JVM finalizer thread can block
forever on §B's unbounded join, stalling finalization process-wide.

## M. Bind-state double transition

`sessionContext.bound(...)` is called twice; the second is a no-op via a guard. A
future release that removed the guard would throw `IllegalStateException`.

## N. State-listener ordering

jsmpp's own `BoundSessionStateListener` is registered at index 0 of a
`CopyOnWriteArrayList`; the connector's lambda is appended. So jsmpp's pool resize
(§G) runs **before** the connector's callback on every transition. Irrelevant
today (the lambda ignores non-CLOSED), load-bearing if that ever changes.

## O. `connectAndBind`'s one non-closing failure branch

The `PDUException` catch rethrows as `IOException` while leaving the socket open
and the started `PDUReaderWorker` running — a per-attempt FD + thread leak. It is
unreachable today because `validateCredentials` covers `systemId`/`password`/
`systemType` and the connector passes `addressRange = null`. **Passing a non-null
`addressRange` would reopen it.**

---

## P. JDK / platform couplings

These are not jsmpp, but the same discipline applies — the bounded-close design
rests on them.

| Fact | Depends on | If it changes |
|---|---|---|
| `Socket.close()` asynchronously unblocks threads parked in `read`/`write` (`NioSocketImpl` preClose) | JDK 13+ | **The close watchdog silently becomes a no-op and the stop-path hang returns.** Pinned by `ObservedConnectionTest.forceCloseUnblocksAParkedWrite` — the tripwire for this row |
| `SSLSocket.close()` may attempt a `close_notify` write | JSSE | the watchdog would block on the dead transport. Mitigated structurally: the connector closes the **pre-TLS raw socket**, never the `SSLSocket`, and never joins the watchdog thread |
| `String.getBytes()` uses the platform default charset | JDK | wire bytes would change with `-Dfile.encoding`. Neutralised by the ASCII restriction in §J |
| A virtual thread blocking on `synchronized` pins its carrier | JDK 21 (fixed by JEP 491 in 24) | ASYNC + submit can pin carriers from a pool shared with the Ballerina runtime. Documented as a known limitation; on a JDK with JEP 491 the limitation lapses |
