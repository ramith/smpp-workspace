// Copyright (c) 2026. Test-only: TLS-terminating jsmpp ServerConnectionFactory built from
// an explicit per-mock keystore (not the JVM-global -Djavax.net.ssl.* properties that
// jsmpp's stock SSLServerSocketConnectionFactory relies on).
package io.ballerinax.smpp.test;

import org.jsmpp.session.connection.ServerConnection;
import org.jsmpp.session.connection.ServerConnectionFactory;
import org.jsmpp.session.connection.socket.ServerSocketConnection;

import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLServerSocket;
import javax.net.ssl.SSLServerSocketFactory;
import javax.net.ssl.TrustManagerFactory;

import java.io.IOException;
import java.io.InputStream;
import java.net.ServerSocket;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.GeneralSecurityException;
import java.security.KeyStore;

/**
 * Blueprint: jsmpp-examples KeyStoreSSLServerSocketConnectionFactory. Differences: the
 * keystore path/password are arguments (not JVM-global properties), and when a client
 * truststore is supplied the created socket requires client auth (mTLS) - jsmpp's own
 * server factories never call setNeedClientAuth, so that half is net-new.
 */
final class TlsServerConnectionFactory implements ServerConnectionFactory {

    private final SSLServerSocketFactory sslServerSocketFactory;
    private final boolean requireClientAuth;

    /** @param clientTruststorePath null = server-auth only (no mTLS). */
    TlsServerConnectionFactory(String serverKeystorePath, char[] serverKeystorePassword,
                               String clientTruststorePath, char[] clientTruststorePassword) {
        try {
            KeyStore keyStore = KeyStore.getInstance("PKCS12");
            try (InputStream in = Files.newInputStream(Path.of(serverKeystorePath))) {
                keyStore.load(in, serverKeystorePassword);
            }
            KeyManagerFactory kmf =
                    KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
            kmf.init(keyStore, serverKeystorePassword);

            TrustManagerFactory tmf = null;
            if (clientTruststorePath != null) {
                KeyStore trustStore = KeyStore.getInstance("PKCS12");
                try (InputStream in = Files.newInputStream(Path.of(clientTruststorePath))) {
                    trustStore.load(in, clientTruststorePassword);
                }
                tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
                tmf.init(trustStore);
            }
            SSLContext ctx = SSLContext.getInstance("TLS");
            ctx.init(kmf.getKeyManagers(), tmf == null ? null : tmf.getTrustManagers(), null);
            this.sslServerSocketFactory = ctx.getServerSocketFactory();
            this.requireClientAuth = clientTruststorePath != null;
        } catch (GeneralSecurityException | IOException e) {
            throw new RuntimeException("failed to build TLS server socket factory: " + e.getMessage(), e);
        }
    }

    private ServerConnection wrap(ServerSocket socket) {
        if (requireClientAuth && socket instanceof SSLServerSocket ssl) {
            ssl.setNeedClientAuth(true);   // mTLS: reject clients presenting no/untrusted cert
        }
        return new ServerSocketConnection(socket);
    }

    // SMPPServerSessionListener(port, factory) calls exactly listen(port).
    @Override public ServerConnection listen(int port) throws IOException {
        return wrap(sslServerSocketFactory.createServerSocket(port));
    }

    @Override public ServerConnection listen(int port, int timeout) throws IOException {
        ServerSocket s = sslServerSocketFactory.createServerSocket(port);
        s.setSoTimeout(timeout);
        return wrap(s);
    }

    @Override public ServerConnection listen(int port, int timeout, int backlog) throws IOException {
        ServerSocket s = sslServerSocketFactory.createServerSocket(port, backlog);
        s.setSoTimeout(timeout);
        return wrap(s);
    }
}
