// Copyright (c) 2026. Test-only: a distinctly-named exception for an ESME_RX_P_APPN response.
package io.ballerinax.smpp.test;

/**
 * Thrown by the mock when a {@code deliver_sm}/{@code data_sm} comes back with
 * command_status {@code ESME_RX_P_APPN} (0x00000065, "Permanent Application Error") — the
 * connector NACKing a PDU type the attached service does not implement (D14).
 *
 * <p>A distinct type for the same reason as {@link ThrottledException} (interop surfaces
 * the class name as {@code error.message()}) — and this one is the load-bearing wire pin:
 * jsmpp's callback catch-alls rewrite any non-{@code ProcessRequestException} thrown by
 * the connector into {@code RX_T_APPN} (SMPPSession.java:551-552/:565-566), so a wrong
 * exception type connector-side silently degrades this permanent NACK into a transient
 * one — a guaranteed redelivery poison loop. Only asserting the exact decoded status at
 * the mock catches that class of regression.
 */
public final class PermanentAppErrorException extends Exception {

    private final int commandStatus;

    public PermanentAppErrorException(int commandStatus) {
        super(String.format("ESME_RX_P_APPN (command_status=0x%08x)", commandStatus));
        this.commandStatus = commandStatus;
    }

    public int getCommandStatus() {
        return commandStatus;
    }
}
