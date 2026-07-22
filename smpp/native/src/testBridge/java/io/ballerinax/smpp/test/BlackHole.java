// Copyright (c) 2026. Test-only TCP "black hole": accepts connections, never responds.
package io.ballerinax.smpp.test;

import java.io.IOException;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * A plain TCP server that accepts connections and then does absolutely nothing with them -
 * it never reads the bind PDU and never sends a bind response. Used to prove the connector's
 * configurable bind timeout bounds the bind-response wait: a connector pointed here completes
 * the TCP connect (so this is distinct from connection-refused) but must give up on the bind
 * after roughly {@code bindTimeout}, not after jsmpp's hardcoded 60s default. Accepted sockets
 * are held open (not closed) so the connector sees a live-but-silent peer, the realistic
 * half-open SMSC.
 */
final class BlackHole {

    private final ServerSocket serverSocket;
    private final ExecutorService acceptLoop = Executors.newSingleThreadExecutor();
    private final List<Socket> held = new CopyOnWriteArrayList<>();
    private volatile boolean running = true;

    BlackHole(int port) throws IOException {
        this.serverSocket = new ServerSocket(port);
    }

    void start() {
        acceptLoop.execute(() -> {
            while (running) {
                try {
                    // Hold the socket open and otherwise ignore it: no read, no bind response.
                    held.add(serverSocket.accept());
                } catch (IOException e) {
                    break; // server socket closed
                }
            }
        });
    }

    void close() {
        running = false;
        try {
            serverSocket.close();
        } catch (IOException ignored) {
            // best-effort
        }
        for (Socket s : held) {
            try {
                s.close();
            } catch (IOException ignored) {
                // best-effort
            }
        }
        held.clear();
        acceptLoop.shutdownNow();
    }
}
