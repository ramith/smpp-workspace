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

/**
 * {@link ObservedConnection} is the connector's independent drop signal (see its class doc
 * for the jsmpp reader-death wedge it exists for). These tests pin its contract: EOF and
 * IOException fire the callback exactly once; SocketTimeoutException — jsmpp's routine
 * keepalive cadence — never fires it; close() never fires it; and an unarmed holder is
 * silently tolerated (connect-phase deaths belong to connectAndBind's error path).
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
                new StubConnection(InputStream.nullInputStream()), armed(fired));
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
        ObservedConnection conn = new ObservedConnection(new StubConnection(broken), armed(fired));
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
        ObservedConnection conn = new ObservedConnection(new StubConnection(timingOut), armed(fired));
        InputStream in = conn.getInputStream();
        // SO_TIMEOUT doubles as jsmpp's enquire_link trigger - it fires on every idle
        // interval of a perfectly healthy session and must never register as a death.
        assertThrows(SocketTimeoutException.class, in::read);
        assertThrows(SocketTimeoutException.class, () -> in.read(new byte[4], 0, 4));
        assertEquals(0, fired.get(), "SocketTimeoutException must NOT fire the death callback");
    }

    @Test
    void closeIsNeverADeathSignal() throws IOException {
        AtomicInteger fired = new AtomicInteger();
        ObservedConnection conn = new ObservedConnection(
                new StubConnection(InputStream.nullInputStream()), armed(fired));
        conn.close();
        assertEquals(0, fired.get(),
                "close() is user teardown or jsmpp's own choreography - never a drop report");
    }

    @Test
    void unarmedHolderDropsTheSignalWithoutThrowing() throws IOException {
        // Connect-phase deaths can happen before bind() arms the holder; they must be
        // swallowed (connectAndBind surfaces those failures itself), never NPE.
        ObservedConnection conn = new ObservedConnection(
                new StubConnection(InputStream.nullInputStream()), new AtomicReference<>());
        assertEquals(-1, conn.getInputStream().read());
    }

    @Test
    void sameWrappedStreamOnRepeatedFetch() {
        ObservedConnection conn = new ObservedConnection(
                new StubConnection(InputStream.nullInputStream()), new AtomicReference<>());
        assertSame(conn.getInputStream(), conn.getInputStream(),
                "repeated getInputStream() must not stack fresh wrappers (double-fire hazard)");
    }
}
