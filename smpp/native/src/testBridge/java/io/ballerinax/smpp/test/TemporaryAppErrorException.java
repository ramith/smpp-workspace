// Copyright (c) 2026. Test-only: a distinctly-named exception for an ESME_RX_T_APPN response.
package io.ballerinax.smpp.test;

/**
 * Thrown by the mock when a {@code deliver_sm}/{@code data_sm} comes back with
 * command_status {@code ESME_RX_T_APPN} (0x00000064, "Temporary Application Error") —
 * either a SYNC handler returning an error, or (since D14) a PDU arriving while no
 * service is attached at all (the transient startup/teardown window, where retention
 * and redelivery is exactly right).
 *
 * <p>A distinct type for the same reason as {@link ThrottledException}: interop surfaces
 * the class name as {@code error.message()}.
 */
public final class TemporaryAppErrorException extends Exception {

    private final int commandStatus;

    public TemporaryAppErrorException(int commandStatus) {
        super(String.format("ESME_RX_T_APPN (command_status=0x%08x)", commandStatus));
        this.commandStatus = commandStatus;
    }

    public int getCommandStatus() {
        return commandStatus;
    }
}
