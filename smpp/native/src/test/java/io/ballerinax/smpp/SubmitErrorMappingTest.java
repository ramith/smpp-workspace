// Copyright (c) 2026. Pure-logic tests: submit-path failure -> FailureMode mapping.
package io.ballerinax.smpp;

import org.jsmpp.GenericNackResponseException;
import org.jsmpp.InvalidResponseException;
import org.jsmpp.PDUException;
import org.jsmpp.PDUStringException;
import org.jsmpp.extra.NegativeResponseException;
import org.jsmpp.extra.ResponseTimeoutException;
import org.junit.jupiter.api.Test;

import java.io.IOException;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Pins {@link NativeCaller#mapSubmitFailure} — every {@code FailureMode} branch,
 * including the classes the mock SMSC cannot produce over the wire
 * ({@code PDUException}, {@code InvalidResponseException}) and the unchecked escapes
 * that D3 proved must terminate in a {@code Throwable} branch.
 */
class SubmitErrorMappingTest {

    @Test
    void negativeResponseIsRejectedWithCommandStatus() {
        // 0x00000058 = ESME_RTHROTTLED
        NativeCaller.MappedFailure f =
                NativeCaller.mapSubmitFailure(new NegativeResponseException(0x58));
        assertEquals("REJECTED", f.failureMode);
        assertEquals(0x58, f.commandStatus);
    }

    @Test
    void genericNackIsRejectedNotProtocolError() {
        // GenericNackResponseException extends InvalidResponseException but carries the
        // SMSC's real command_status - branch order matters, a generic_nack IS a rejection.
        NativeCaller.MappedFailure f = NativeCaller.mapSubmitFailure(
                new GenericNackResponseException("nack", 0x03));
        assertEquals("REJECTED", f.failureMode);
        assertEquals(0x03, f.commandStatus);
    }

    @Test
    void responseTimeoutIsDeliveryUnknownAndSaysSo() {
        NativeCaller.MappedFailure f =
                NativeCaller.mapSubmitFailure(new ResponseTimeoutException("no resp in 30000ms"));
        assertEquals("TIMEOUT_DELIVERY_UNKNOWN", f.failureMode);
        assertNull(f.commandStatus);
        assertTrue(f.message.contains("may still have accepted"),
                "the duplicate-MT caveat (item 12) must be in the message: " + f.message);
    }

    @Test
    void invalidResponseIsProtocolError() {
        NativeCaller.MappedFailure f =
                NativeCaller.mapSubmitFailure(new InvalidResponseException("seq mismatch"));
        assertEquals("PROTOCOL_ERROR", f.failureMode);
    }

    @Test
    void pduExceptionsAreInvalidRequest() {
        assertEquals("INVALID_REQUEST",
                NativeCaller.mapSubmitFailure(new PDUException("bad pdu")).failureMode);
        // PDUStringException extends PDUException - jsmpp's own validator, made a
        // never-fires backstop by compose()'s pre-checks, but mapped correctly anyway.
        assertEquals("INVALID_REQUEST",
                NativeCaller.mapSubmitFailure(
                        new PDUStringException("too long", org.jsmpp.util.StringParameter.SHORT_MESSAGE))
                        .failureMode);
    }

    @Test
    void ioExceptionIsLinkDown() {
        NativeCaller.MappedFailure f =
                NativeCaller.mapSubmitFailure(new IOException("Broken pipe"));
        assertEquals("LINK_DOWN", f.failureMode);
        assertTrue(f.message.contains("delivery unknown"), f.message);
    }

    @Test
    void localValidationIsInvalidRequestVerbatim() {
        NativeCaller.MappedFailure f = NativeCaller.mapSubmitFailure(
                new NativeCaller.InvalidRequest("destAddr is required"));
        assertEquals("INVALID_REQUEST", f.failureMode);
        assertEquals("destAddr is required", f.message,
                "local validation messages pass through verbatim - they are already safe");
    }

    @Test
    void possiblySubmittedPartitionsByDuplicateRisk() {
        // The semantics are "can a retry duplicate?", NOT "did it reach the wire"
        // (design-review FINDING-6). REJECTED is the subtle row: the PDU WAS written,
        // but the SMSC received and definitively refused it - a retry cannot duplicate.
        assertFalse(NativeCaller.mapSubmitFailure(
                new NativeCaller.InvalidRequest("x")).possiblySubmitted, "local refusal");
        assertFalse(NativeCaller.mapSubmitFailure(
                new NegativeResponseException(0x58)).possiblySubmitted, "REJECTED: refused");
        assertFalse(NativeCaller.mapSubmitFailure(
                new GenericNackResponseException("nack", 0x03)).possiblySubmitted, "nack: refused");
        assertFalse(NativeCaller.mapSubmitFailure(
                new PDUException("bad pdu")).possiblySubmitted, "composer throws pre-write");
        assertTrue(NativeCaller.mapSubmitFailure(
                new ResponseTimeoutException("t")).possiblySubmitted, "response lost");
        assertTrue(NativeCaller.mapSubmitFailure(
                new InvalidResponseException("seq")).possiblySubmitted, "response unusable");
        assertTrue(NativeCaller.mapSubmitFailure(
                new IOException("pipe")).possiblySubmitted, "mid-flight death");
        assertTrue(NativeCaller.mapSubmitFailure(
                new NullPointerException()).possiblySubmitted, "unknown: assume the worst");
    }

    @Test
    void uncheckedEscapesTerminateInThrowableBranch() {
        // D3: the (SubmitSmResp) cast in SMPPSession can ClassCastException, and
        // DefaultPDUSender has seven unguarded derefs - both unchecked, neither may panic.
        assertEquals("PROTOCOL_ERROR",
                NativeCaller.mapSubmitFailure(new ClassCastException(
                        "GenericNack cannot be cast to SubmitSmResp")).failureMode);
        assertEquals("PROTOCOL_ERROR",
                NativeCaller.mapSubmitFailure(new NullPointerException()).failureMode);
        // Null message must not NPE the mapper itself; class name stands in.
        NativeCaller.MappedFailure f = NativeCaller.mapSubmitFailure(new NullPointerException());
        assertTrue(f.message.contains("NullPointerException"), f.message);
    }
}
