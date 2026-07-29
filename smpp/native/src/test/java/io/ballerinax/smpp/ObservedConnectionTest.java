// Copyright (c) 2026. Pure-logic tests for the transport-death observer.
package io.ballerinax.smpp;

import org.jsmpp.session.connection.Connection;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.SocketException;
import java.net.SocketTimeoutException;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * {@link ObservedConnection} is the connector's independent drop signal (see its class doc
 * for the jsmpp reader-death wedge it exists for). These tests pin its contract: EOF,
 * IOException, and close() each fire the one-shot callback exactly once (close() is the
 * FOURTH signal since Sprint 8.5 — classification lives in the shared guards, not here);
 * SocketTimeoutException — jsmpp's routine keepalive cadence — never fires it; forceClose()
 * closes the raw socket without firing and asynchronously unblocks a parked write (the
 * D11 JDK coupling); and an unarmed holder is silently tolerated (connect-phase deaths
 * belong to connectAndBind's error path).
 */
class ObservedConnectionTest {

    /** A Connection stub whose InputStream behaviour is scripted per test. */
    private static final class StubConnection implements Connection {
        private final InputStream in;

        StubConnection(InputStream in) {
            this.in = in;
        }

        public boolean isOpen() {
            return true;
        }

        public InetAddress getInetAddress() {
            return null;
        }

        public InetAddress getLocalAddress() {
            return null;
        }

        public int getPort() {
            return 0;
        }

        public int getLocalPort() {
            return 0;
        }

        public InputStream getInputStream() {
            return in;
        }

        public OutputStream getOutputStream() {
            return OutputStream.nullOutputStream();
        }

        public void setSoTimeout(int timeout) {
        }

        public void close() {
        }
    }

    private static AtomicReference<Runnable> armed(AtomicInteger counter) {
        AtomicReference<Runnable> holder = new AtomicReference<>();
        holder.set(counter::incrementAndGet);
        return holder;
    }

    @Test
    void eofFiresExactlyOnceAcrossReadsAndVariants() throws IOException {
        AtomicInteger fired = new AtomicInteger();
        ObservedConnection conn = new ObservedConnection(
                new StubConnection(InputStream.nullInputStream()), null, armed(fired));
        InputStream in = conn.getInputStream();
        assertEquals(-1, in.read());
        assertEquals(-1, in.read(new byte[4], 0, 4));
        assertEquals(-1, in.read());
        assertEquals(1, fired.get(), "EOF must fire the death callback exactly once");
    }

    @Test
    void ioExceptionFiresOnceAndPropagates() {
        AtomicInteger fired = new AtomicInteger();
        InputStream broken = new InputStream() {
            @Override
            public int read() throws IOException {
                throw new SocketException("Connection reset");
            }
        };
        ObservedConnection conn = new ObservedConnection(new StubConnection(broken), null, armed(fired));
        InputStream in = conn.getInputStream();
        assertThrows(SocketException.class, in::read);
        assertThrows(SocketException.class, () -> in.read(new byte[4], 0, 4));
        assertEquals(1, fired.get(), "IOException must fire the death callback exactly once");
    }

    @Test
    void socketTimeoutIsRoutineCadenceNotDeath() {
        AtomicInteger fired = new AtomicInteger();
        InputStream timingOut = new InputStream() {
            @Override
            public int read() throws IOException {
                throw new SocketTimeoutException("Read timed out");
            }
        };
        ObservedConnection conn = new ObservedConnection(new StubConnection(timingOut), null, armed(fired));
        InputStream in = conn.getInputStream();
        // SO_TIMEOUT doubles as jsmpp's enquire_link trigger - it fires on every idle
        // interval of a perfectly healthy session and must never register as a death.
        assertThrows(SocketTimeoutException.class, in::read);
        assertThrows(SocketTimeoutException.class, () -> in.read(new byte[4], 0, 4));
        assertEquals(0, fired.get(), "SocketTimeoutException must NOT fire the death callback");
    }

    @Test
    void closeFiresTheOneShotSignalSharingTheSameCas() throws IOException {
        // Sprint 8.5, FD2: close() IS the fourth drop signal - the EnquireLinkSender's
        // self-close structurally skips ctx.close() (AbstractSession.java:264), and under
        // inbound overflow the reader may never reach read() to observe the closed
        // socket, so this first-hand call is sometimes the ONLY signal. The
        // stop-vs-drop classification lives in scheduleTransportDeathCheck's guards,
        // deliberately NOT here (design review FINDING-1).
        AtomicInteger fired = new AtomicInteger();
        ObservedConnection conn = new ObservedConnection(
                new StubConnection(InputStream.nullInputStream()), null, armed(fired));
        conn.close();
        assertEquals(1, fired.get(), "close() must fire the one-shot signal");
        conn.close();
        assertEquals(1, fired.get(), "idempotent: a second close must not double-fire");
        assertEquals(-1, conn.getInputStream().read());
        assertEquals(1, fired.get(), "the stream signal shares the same CAS - still once");
    }

    @Test
    void forceCloseDoesNotFireTheSignalItself() throws IOException {
        // The watchdog primitive closes the RAW socket only; the death report comes from
        // the unblocked reader's own IOException, classified by the shared guards (T2.4).
        AtomicInteger fired = new AtomicInteger();
        java.net.Socket raw = new java.net.Socket();
        ObservedConnection conn = new ObservedConnection(
                new StubConnection(InputStream.nullInputStream()), raw, armed(fired));
        conn.forceClose();
        conn.forceClose(); // idempotent, never throws
        assertEquals(0, fired.get(), "forceClose must not fire the death signal directly");
        assertTrue(raw.isClosed(), "the raw socket must actually be closed");
    }

    @Test
    void forceCloseUnblocksAParkedWrite() throws Exception {
        // THE load-bearing JDK coupling of the whole D11 design (new-category coupling
        // row): Socket.close() must asynchronously unblock a thread parked in a blocking
        // write (NioSocketImpl preClose). If a future JDK changed this, the close
        // watchdog would silently become a no-op and the stop-path hang would return -
        // this test is the loud tripwire. A real socket pair; the peer never reads, so
        // writes park once both buffers fill.
        try (java.net.ServerSocket server = new java.net.ServerSocket(0)) {
            java.net.Socket client = new java.net.Socket();
            client.connect(server.getLocalSocketAddress(), 5000);
            try (java.net.Socket accepted = server.accept()) {
                client.setSendBufferSize(8 * 1024);
                accepted.setReceiveBufferSize(8 * 1024);
                ObservedConnection conn = new ObservedConnection(
                        new StubConnection(InputStream.nullInputStream()), client,
                        new AtomicReference<>());
                java.util.concurrent.CountDownLatch unblocked =
                        new java.util.concurrent.CountDownLatch(1);
                AtomicReference<Throwable> outcome = new AtomicReference<>();
                Thread writer = new Thread(() -> {
                    try {
                        java.io.OutputStream out = client.getOutputStream();
                        byte[] chunk = new byte[64 * 1024];
                        while (true) {
                            out.write(chunk); // parks once send+receive buffers fill
                        }
                    } catch (Throwable t) {
                        outcome.set(t);
                        unblocked.countDown();
                    }
                }, "test-blocked-writer");
                writer.setDaemon(true);
                writer.start();
                // Give the writer time to fill both buffers and park in write().
                Thread.sleep(500);
                conn.forceClose();
                assertTrue(unblocked.await(5, java.util.concurrent.TimeUnit.SECONDS),
                        "Socket.close() must unblock the parked write within 5s - the "
                                + "D11 watchdog is a no-op if this JDK behaviour changed");
                assertTrue(outcome.get() instanceof java.net.SocketException,
                        "the unblocked write must surface a SocketException, got: " + outcome.get());
            } finally {
                if (!client.isClosed()) {
                    client.close();
                }
            }
        }
    }

    @Test
    void unarmedHolderDropsTheSignalWithoutThrowing() throws IOException {
        // Connect-phase deaths can happen before bind() arms the holder; they must be
        // swallowed (connectAndBind surfaces those failures itself), never NPE.
        ObservedConnection conn = new ObservedConnection(
                new StubConnection(InputStream.nullInputStream()), null, new AtomicReference<>());
        assertEquals(-1, conn.getInputStream().read());
    }

    @Test
    void sameWrappedStreamOnRepeatedFetch() {
        ObservedConnection conn = new ObservedConnection(
                new StubConnection(InputStream.nullInputStream()), null, new AtomicReference<>());
        assertSame(conn.getInputStream(), conn.getInputStream(),
                "repeated getInputStream() must not stack fresh wrappers (double-fire hazard)");
    }
}
