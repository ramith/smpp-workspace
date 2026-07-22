// Copyright (c) 2026. Plaintext (non-TLS) jsmpp ConnectionFactory with a bounded TCP connect.
package io.ballerinax.smpp;

import org.jsmpp.session.connection.Connection;
import org.jsmpp.session.connection.ConnectionFactory;
import org.jsmpp.session.connection.socket.SocketConnection;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.Socket;

/**
 * A plaintext {@link ConnectionFactory} whose only reason to exist is to bound the TCP
 * connect. jsmpp's stock {@code SocketConnectionFactory} does {@code new Socket(host, port)}
 * (SocketConnectionFactory.java:40), a blocking connect with the OS-default timeout — which
 * can be minutes against a black-holed host (SYN dropped). Because the connector's rebind
 * loop is single-threaded, one such stalled attempt would block every subsequent rebind for
 * that whole OS timeout. This factory instead uses
 * {@code socket.connect(address, connectTimeoutMillis)} so a stalled connect fails fast and
 * the rebind loop keeps its cadence — mirroring what {@link SmppSslConnectionFactory} already
 * does on the TLS path. The {@code connectAndBind} bind-response wait is bounded separately
 * (its own timeout argument); this covers the connect phase that the bind timeout does not.
 *
 * <p>Immutable and therefore safe to reuse, though the connector builds a fresh instance per
 * bind attempt (like the TLS factory).
 */
public final class SmppPlainConnectionFactory implements ConnectionFactory {

    private final int connectTimeoutMillis;

    public SmppPlainConnectionFactory(int connectTimeoutMillis) {
        this.connectTimeoutMillis = connectTimeoutMillis;
    }

    @Override
    public Connection createConnection(String host, int port) throws IOException {
        Socket socket = new Socket();
        try {
            socket.connect(new InetSocketAddress(host, port), connectTimeoutMillis);
            return new SocketConnection(socket);
        } catch (IOException e) {
            // Close the half-open socket so a failed attempt leaks no file descriptor, then
            // rethrow so connectAndBind surfaces the failure to start()/the rebind loop.
            try {
                socket.close();
            } catch (IOException ignored) {
                // best-effort close; the connect failure is the meaningful error
            }
            throw e;
        }
    }
}
