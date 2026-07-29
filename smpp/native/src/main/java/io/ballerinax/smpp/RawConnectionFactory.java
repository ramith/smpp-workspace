// Copyright (c) 2026. Factory contract that also exposes the pre-TLS raw socket.
package io.ballerinax.smpp;

import org.jsmpp.session.connection.Connection;
import org.jsmpp.session.connection.ConnectionFactory;

import java.io.IOException;
import java.net.Socket;

/**
 * Extends jsmpp's {@link ConnectionFactory} with a variant that returns the pre-TLS raw
 * {@link Socket} alongside the {@link Connection}. The raw socket is the ONLY safe
 * force-close target for the bounded-close watchdog (D11):
 *
 * <ul>
 *   <li>On the TLS path, {@code SocketConnection.close()} closes the {@code SSLSocket},
 *       whose {@code close()} attempts a close_notify WRITE on the very transport the
 *       watchdog assumes is dead — it can block on the SSLSocket's internal write lock
 *       behind the stalled writer it exists to break (design review, FINDING-2/G1:
 *       {@code SmppSslConnectionFactory} discards the raw socket at the TLS wrap, and
 *       jsmpp's {@code SocketConnection} offers no accessor).</li>
 *   <li>A raw {@code Socket.close()} takes no jsmpp or JSSE lock and asynchronously
 *       unblocks threads parked in read/write on that socket (JDK {@code NioSocketImpl}
 *       preClose). That behaviour is a <b>JDK coupling</b> the whole D11 design rests
 *       on; {@code ObservedConnectionTest.forceCloseUnblocksAParkedWrite} pins it.</li>
 * </ul>
 */
interface RawConnectionFactory extends ConnectionFactory {

    /** A jsmpp {@link Connection} paired with the pre-TLS raw socket beneath it. */
    record RawConnection(Connection connection, Socket rawSocket) { }

    RawConnection createRawConnection(String host, int port) throws IOException;
}
