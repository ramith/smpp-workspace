// Copyright (c) 2026. Test-only: a distinctly-named exception for an ESME_RTHROTTLED response.
package io.ballerinax.smpp.test;

/**
 * Thrown by the mock when a {@code deliver_sm} comes back with command_status
 * {@code ESME_RTHROTTLED} - the connector's backpressure gate rejecting an overflow PDU.
 *
 * <p>It exists as its own type because Ballerina's Java interop surfaces a thrown exception's
 * <em>class name</em> as {@code error.message()} (not its {@code getMessage()} text), so a
 * distinct class is how a {@code bal test} assertion can tell a throttle apart from any other
 * negative response. The command_status is kept available for completeness.
 */
public final class ThrottledException extends Exception {

    private final int commandStatus;

    public ThrottledException(int commandStatus) {
        super(String.format("deliver_sm ESME_RTHROTTLED (command_status=0x%08x)", commandStatus));
        this.commandStatus = commandStatus;
    }

    public int getCommandStatus() {
        return commandStatus;
    }
}
