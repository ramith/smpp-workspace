// Copyright (c) 2026. Pins the pool-sizing invariant the submit path's liveness rests on.
package io.ballerinax.smpp;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * SYNC degree must STRICTLY exceed maxConcurrentDispatch: submit_sm_resp PDUs ride the
 * same pool as dispatches, so a blocked submitting handler needs a spare thread for its
 * own response. This is the automatable half of the gate's mutation check; the end-to-end
 * half is the documented manual procedure on pduProcessorDegree().
 */
class PduProcessorDegreeTest {

    @Test
    void syncDegreeStrictlyExceedsDispatchBound() {
        for (int n = 1; n <= 1024; n++) {
            assertTrue(NativeListener.pduProcessorDegree(false, n) > n,
                    "SYNC pool must reserve a thread beyond " + n
                            + " - responses and keepalives share the pool with blocked handlers");
        }
    }

    @Test
    void asyncDegreeIsPositive() {
        assertTrue(NativeListener.pduProcessorDegree(true, 1024) >= 1);
    }
}
