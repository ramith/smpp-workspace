// Copyright (c) 2026. Pure-logic tests for NativeListener's credential-length validation.
package io.ballerinax.smpp;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

/**
 * Exercises {@link NativeListener#validateCredentials} directly - a pure function with no
 * jsmpp session or Ballerina runtime dependency, so this needs neither. The exact usable
 * lengths (systemId 15, password 8, systemType 12) come from jsmpp's own
 * {@code StringParameter.SYSTEM_ID}/{@code PASSWORD}/{@code SYSTEM_TYPE} C-Octet-String
 * maxima (16/9/13), which include the wire NUL terminator.
 *
 * <p>Every assertion on a thrown message additionally confirms the raw credential value
 * never appears in it - the whole point of validating up front is to never reach jsmpp's
 * own validator, whose exception message embeds the value verbatim.
 */
class NativeListenerTest {

    private static final String VALID_SYSTEM_ID = "a".repeat(15);
    private static final String VALID_PASSWORD = "b".repeat(8);
    private static final String VALID_SYSTEM_TYPE = "c".repeat(12);

    @Test
    void validateCredentials_allAtMaxUsableLength_doesNotThrow() {
        assertDoesNotThrow(() ->
                NativeListener.validateCredentials(VALID_SYSTEM_ID, VALID_PASSWORD, VALID_SYSTEM_TYPE));
    }

    @Test
    void validateCredentials_empty_doesNotThrow() {
        assertDoesNotThrow(() -> NativeListener.validateCredentials("", "", ""));
    }

    // ---- systemId boundary: 15 ok, 16 rejected ----

    @Test
    void validateCredentials_systemIdOneOverLimit_throwsWithoutLeakingValue() {
        String tooLong = "a".repeat(16);
        IllegalArgumentException e = assertThrows(IllegalArgumentException.class, () ->
                NativeListener.validateCredentials(tooLong, VALID_PASSWORD, VALID_SYSTEM_TYPE));
        assertEquals("systemId exceeds the maximum length of 15 characters", e.getMessage());
    }

    // ---- password boundary: 8 ok, 9 rejected ----

    @Test
    void validateCredentials_passwordOneOverLimit_throwsWithoutLeakingValue() {
        String tooLong = "b".repeat(9);
        IllegalArgumentException e = assertThrows(IllegalArgumentException.class, () ->
                NativeListener.validateCredentials(VALID_SYSTEM_ID, tooLong, VALID_SYSTEM_TYPE));
        assertEquals("password exceeds the maximum length of 8 characters", e.getMessage());
        // The whole point of validating up front: the actual (invalid) password must never
        // appear in the exception message, unlike jsmpp's own StringValidator.
        assert !e.getMessage().contains(tooLong);
    }

    // ---- systemType boundary: 12 ok, 13 rejected ----

    @Test
    void validateCredentials_systemTypeOneOverLimit_throwsWithoutLeakingValue() {
        String tooLong = "c".repeat(13);
        IllegalArgumentException e = assertThrows(IllegalArgumentException.class, () ->
                NativeListener.validateCredentials(VALID_SYSTEM_ID, VALID_PASSWORD, tooLong));
        assertEquals("systemType exceeds the maximum length of 12 characters", e.getMessage());
    }

    @Test
    void validateCredentials_checksSystemIdBeforePasswordBeforeSystemType() {
        // All three invalid at once: systemId's violation should be reported first, since
        // that's the order bind() extracts and validates them in.
        String tooLong = "x".repeat(20);
        IllegalArgumentException e = assertThrows(IllegalArgumentException.class, () ->
                NativeListener.validateCredentials(tooLong, tooLong, tooLong));
        assertEquals("systemId exceeds the maximum length of 15 characters", e.getMessage());
    }
}
