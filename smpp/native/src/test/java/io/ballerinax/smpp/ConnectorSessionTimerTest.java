// Copyright (c) 2026. Pins the split-timer routing in ConnectorSession.
package io.ballerinax.smpp;

import org.junit.jupiter.api.Test;

import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.assertEquals;

/**
 * Pins {@link ConnectorSession}'s ThreadLocal submit-context routing: the configured
 * submit bound applies ONLY between enter/exit (which {@code NativeCaller} wraps around
 * {@code submitShortMessage}); everything else — including all of jsmpp's housekeeping
 * threads, which never enter the context — sees the short field value. There is no
 * dependency on jsmpp thread names, so nothing here breaks on a jsmpp upgrade; the
 * remaining version coupling (getter-vs-field call sites) is audited via javap per the
 * Sprint 8 plan.
 */
class ConnectorSessionTimerTest {

    private static final long SUBMIT_MS = 30_000;

    private static ConnectorSession session() {
        return new ConnectorSession((host, port) -> {
            throw new java.io.IOException("never connects in this test");
        }, SUBMIT_MS);
    }

    @Test
    void outsideSubmitContextIsTheHousekeepingBound() throws Exception {
        ConnectorSession s = session();
        assertEquals(ConnectorSession.HOUSEKEEPING_TIMER_MS, s.getTransactionTimer(),
                "any thread outside the submit context (jsmpp housekeeping included) "
                        + "must see the short bound");
        // And from a differently-named thread, same answer - names are irrelevant now.
        AtomicLong seen = new AtomicLong(-1);
        Thread t = new Thread(() -> seen.set(s.getTransactionTimer()), "EnquireLinkSender-cafebabe");
        t.start();
        t.join(5_000);
        assertEquals(ConnectorSession.HOUSEKEEPING_TIMER_MS, seen.get());
    }

    @Test
    void insideSubmitContextIsTheConfiguredBound() {
        ConnectorSession s = session();
        ConnectorSession.enterSubmitContext();
        try {
            assertEquals(SUBMIT_MS, s.getTransactionTimer());
        } finally {
            ConnectorSession.exitSubmitContext();
        }
        assertEquals(ConnectorSession.HOUSEKEEPING_TIMER_MS, s.getTransactionTimer(),
                "exit must restore the short bound - a leaked context would silently "
                        + "lengthen housekeeping waits on this thread");
    }

    @Test
    void contextIsPerThread() throws Exception {
        ConnectorSession s = session();
        ConnectorSession.enterSubmitContext();
        try {
            AtomicLong seen = new AtomicLong(-1);
            Thread t = new Thread(() -> seen.set(s.getTransactionTimer()));
            t.start();
            t.join(5_000);
            assertEquals(ConnectorSession.HOUSEKEEPING_TIMER_MS, seen.get(),
                    "another thread must not inherit this thread's submit context");
        } finally {
            ConnectorSession.exitSubmitContext();
        }
    }
}
