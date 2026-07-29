// Copyright (c) 2026. Pins the split-timer routing in ConnectorSession.
package io.ballerinax.smpp;

import org.junit.jupiter.api.Test;

import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.assertEquals;

/**
 * Pins {@link ConnectorSession}'s thread-name routing. The names are jsmpp 3.0.2 facts
 * (vendored source: {@code EnquireLinkSender} names itself
 * {@code "EnquireLinkSender-" + sessionId} at AbstractSession.java:517; the reader is
 * {@code "PDUReaderWorker-" + sessionId}) — if a jsmpp upgrade renames either, this test
 * still passes (it constructs the names itself), so the UPGRADE CHECKLIST in the class
 * doc is the real guard; this test guards against regressions in OUR routing logic.
 */
class ConnectorSessionTimerTest {

    private static final long SUBMIT_MS = 30_000;

    private static long timerSeenFrom(ConnectorSession session, String threadName)
            throws InterruptedException {
        AtomicLong seen = new AtomicLong(-1);
        Thread t = new Thread(() -> seen.set(session.getTransactionTimer()), threadName);
        t.start();
        t.join(5_000);
        return seen.get();
    }

    @Test
    void housekeepingThreadsGetTheShortBound() throws Exception {
        ConnectorSession session = new ConnectorSession((host, port) -> {
            throw new java.io.IOException("never connects in this test");
        }, SUBMIT_MS);
        assertEquals(ConnectorSession.HOUSEKEEPING_TIMER_MS,
                timerSeenFrom(session, "EnquireLinkSender-cafebabe"),
                "the enquire-link probe wait must use the housekeeping bound");
        assertEquals(ConnectorSession.HOUSEKEEPING_TIMER_MS,
                timerSeenFrom(session, "PDUReaderWorker-cafebabe"),
                "the reader's exit drain must use the housekeeping bound");
    }

    @Test
    void callerThreadsGetTheConfiguredSubmitBound() throws Exception {
        ConnectorSession session = new ConnectorSession((host, port) -> {
            throw new java.io.IOException("never connects in this test");
        }, SUBMIT_MS);
        assertEquals(SUBMIT_MS, timerSeenFrom(session, "main"));
        // jsmpp's PDU-processor pool threads - where SYNC handlers (and therefore their
        // submits) actually run - are pool-N-thread-M, NOT PDUReaderWorker-*: they must
        // get the submit bound, or a SYNC handler's reply would time out at 2s.
        assertEquals(SUBMIT_MS, timerSeenFrom(session, "pool-7-thread-3"));
        // Ballerina strands (virtual threads, arbitrary/empty names) likewise.
        assertEquals(SUBMIT_MS, timerSeenFrom(session, ""));
    }
}
