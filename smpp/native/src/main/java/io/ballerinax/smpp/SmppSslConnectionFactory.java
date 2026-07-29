// Copyright (c) 2026. Builds a per-listener TLS ConnectionFactory for jsmpp from
// Ballerina-supplied trust/key material. Deliberately free of io.ballerina.runtime
// types so it is unit-testable without the Ballerina runtime (cf. validateCredentials).
package io.ballerinax.smpp;

import org.jsmpp.session.connection.Connection;
import org.jsmpp.session.connection.ConnectionFactory;
import org.jsmpp.session.connection.socket.SocketConnection;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.GeneralSecurityException;
import java.security.KeyStore;
import java.security.KeyStoreException;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.util.Arrays;
import java.util.Collection;

import javax.net.ssl.KeyManager;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;
import javax.net.ssl.TrustManager;
import javax.net.ssl.TrustManagerFactory;
import javax.net.ssl.X509TrustManager;

/**
 * A jsmpp {@link ConnectionFactory} that opens TLS connections using trust/key
 * material supplied per listener (NOT the JVM-global truststore that jsmpp's stock
 * {@code SSLSocketConnectionFactory} uses).
 *
 * <p>Instances are effectively immutable (an {@link SSLSocketFactory} plus config
 * primitives) and hold no per-connection state, so a single instance is safe to
 * reuse and safe under concurrent {@code createConnection} calls. The connector
 * nonetheless builds a fresh instance per bind attempt (see NativeListener), which
 * also means rotated trust material is picked up on the next rebind.
 *
 * <p>Security posture: hostname verification is enabled via JSSE endpoint
 * identification when requested — deliberately diverging from (and improving on)
 * jsmpp's own SSL factories, none of which perform hostname verification at all.
 * {@code trustAll} is a dev-only escape hatch that also forces hostname
 * verification off. No thrown message ever contains a password.
 */
public final class SmppSslConnectionFactory implements ConnectionFactory, RawConnectionFactory {

    private final SSLSocketFactory socketFactory;
    private final String[] enabledProtocols;      // null => JVM defaults
    private final String[] enabledCipherSuites;   // null => JVM defaults
    private final boolean verifyHostname;
    private final int connectTimeoutMillis;

    private SmppSslConnectionFactory(SSLSocketFactory socketFactory, String[] enabledProtocols,
            String[] enabledCipherSuites, boolean verifyHostname, int connectTimeoutMillis) {
        this.socketFactory = socketFactory;
        this.enabledProtocols = enabledProtocols;
        this.enabledCipherSuites = enabledCipherSuites;
        this.verifyHostname = verifyHostname;
        this.connectTimeoutMillis = connectTimeoutMillis;
    }

    /**
     * Builds the factory from resolved primitives (see listener.bal's ResolvedTls).
     * Exactly one of {@code trustAll}, {@code trustStorePath}, {@code trustCertPath}
     * supplies the trust decision; {@code keyStorePath}/{@code keyStorePassword} are
     * empty when mTLS is not configured; empty protocol/cipher arrays leave JVM
     * defaults in place.
     *
     * <p>The supplied password arrays are zeroed before this method returns (the
     * caller hands ownership over). Failure messages never echo a password.
     */
    public static SmppSslConnectionFactory create(
            String trustStorePath, char[] trustStorePassword,
            String trustCertPath,
            String keyStorePath, char[] keyStorePassword,
            String[] enabledProtocols, String[] enabledCipherSuites,
            boolean trustAll, boolean verifyHostname,
            int connectTimeoutMillis) throws GeneralSecurityException, IOException {
        try {
            TrustManager[] trustManagers;
            if (trustAll) {
                trustManagers = trustAllManagers();
            } else if (!trustCertPath.isEmpty()) {
                trustManagers = trustManagersForPemCert(trustCertPath);
            } else {
                trustManagers = trustManagersForStore(trustStorePath, trustStorePassword);
            }
            KeyManager[] keyManagers = keyStorePath.isEmpty()
                    ? null
                    : keyManagersFor(keyStorePath, keyStorePassword);

            SSLContext sslContext = SSLContext.getInstance("TLS");
            sslContext.init(keyManagers, trustManagers, null);

            // trustAll disables chain validation; hostname verification would be
            // both meaningless and (as a dev escape hatch) unwanted, so force it off.
            boolean effectiveVerify = verifyHostname && !trustAll;
            return new SmppSslConnectionFactory(sslContext.getSocketFactory(),
                    copyOrNull(enabledProtocols), copyOrNull(enabledCipherSuites),
                    effectiveVerify, connectTimeoutMillis);
        } finally {
            wipe(trustStorePassword);
            wipe(keyStorePassword);
        }
    }

    @Override
    public Connection createConnection(String host, int port) throws IOException {
        return createRawConnection(host, port).connection();
    }

    @Override
    public RawConnection createRawConnection(String host, int port) throws IOException {
        // `raw` is the pre-TLS socket and stays valid for the connection's whole life -
        // it is the force-close target for the bounded-close watchdog (D11), because
        // SSLSocket.close() attempts a close_notify write and can block on the dead
        // transport the watchdog assumes. `socket` is reassigned to the SSLSocket after
        // the TLS layer takes ownership (autoClose), so the single catch below closes
        // the right thing exactly once - no leaked file descriptor on a failed attempt.
        Socket raw = new Socket();
        Socket socket = raw;
        try {
            socket.connect(new InetSocketAddress(host, port), connectTimeoutMillis);
            SSLSocket sslSocket = (SSLSocket) socketFactory.createSocket(socket, host, port, true);
            socket = sslSocket;

            if (enabledProtocols != null) {
                sslSocket.setEnabledProtocols(enabledProtocols);
            }
            if (enabledCipherSuites != null) {
                sslSocket.setEnabledCipherSuites(enabledCipherSuites);
            }
            if (verifyHostname) {
                SSLParameters params = sslSocket.getSSLParameters();
                params.setEndpointIdentificationAlgorithm("HTTPS");
                sslSocket.setSSLParameters(params);
            }
            // Fail fast: force the handshake here so an untrusted/mismatched cert throws
            // from connectAndBind (start()/rebind), not later on the PDU reader thread.
            // jsmpp overwrites SO_TIMEOUT with the enquire-link timer right after this
            // returns (SMPPSession.java:268), so this value only bounds the handshake read.
            sslSocket.setSoTimeout(connectTimeoutMillis);
            sslSocket.startHandshake();

            return new RawConnection(new SocketConnection(sslSocket), raw);
        } catch (IOException | RuntimeException e) {
            closeQuietly(socket);
            throw e;
        }
    }

    private static TrustManager[] trustManagersForStore(String path, char[] password)
            throws GeneralSecurityException, IOException {
        KeyStore trustStore = loadKeyStore(path, password);
        TrustManagerFactory tmf =
                TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        tmf.init(trustStore);
        return tmf.getTrustManagers();
    }

    /** PEM CA-cert path form of `cert`: load the certificate(s) into a synthetic in-memory
     *  keystore and trust exactly those. */
    private static TrustManager[] trustManagersForPemCert(String pemPath)
            throws GeneralSecurityException, IOException {
        byte[] pem = Files.readAllBytes(Path.of(pemPath));
        CertificateFactory certFactory = CertificateFactory.getInstance("X.509");
        Collection<? extends Certificate> certs =
                certFactory.generateCertificates(new ByteArrayInputStream(pem));
        if (certs.isEmpty()) {
            throw new KeyStoreException("no X.509 certificates found in " + pemPath);
        }
        KeyStore trustStore = KeyStore.getInstance(KeyStore.getDefaultType());
        trustStore.load(null, null); // fresh, empty, in-memory
        int i = 0;
        for (Certificate cert : certs) {
            trustStore.setCertificateEntry("smpp-trust-" + i++, cert);
        }
        TrustManagerFactory tmf =
                TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        tmf.init(trustStore);
        return tmf.getTrustManagers();
    }

    private static KeyManager[] keyManagersFor(String path, char[] password)
            throws GeneralSecurityException, IOException {
        KeyStore keyStore = loadKeyStore(path, password);
        KeyManagerFactory kmf =
                KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        kmf.init(keyStore, password);   // store password reused as key password (PKCS12 norm)
        return kmf.getKeyManagers();
    }

    /**
     * Loads a store by content, not by file extension: try PKCS12 (the modern default
     * and Ballerina's canonical format) then JKS (legacy), so a mislabeled file still
     * loads. A bad password fails both and yields the generic message below - the
     * password value is never part of any exception.
     */
    private static KeyStore loadKeyStore(String path, char[] password)
            throws GeneralSecurityException, IOException {
        byte[] material = Files.readAllBytes(Path.of(path));   // NoSuchFileException -> clear, no secret
        Exception lastFailure = null;
        for (String type : new String[] {"PKCS12", "JKS"}) {
            try {
                KeyStore keyStore = KeyStore.getInstance(type);
                keyStore.load(new ByteArrayInputStream(material), password);
                return keyStore;
            } catch (IOException | GeneralSecurityException e) {
                lastFailure = e;
            }
        }
        throw new KeyStoreException(
                "unable to load the key store (unsupported format or incorrect password)",
                lastFailure);
    }

    private static TrustManager[] trustAllManagers() {
        return new TrustManager[] {
            new X509TrustManager() {
                @Override public void checkClientTrusted(X509Certificate[] chain, String authType) { }
                @Override public void checkServerTrusted(X509Certificate[] chain, String authType) { }
                @Override public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
            }
        };
    }

    private static void closeQuietly(Socket socket) {
        try {
            socket.close();
        } catch (IOException ignored) {
            // best-effort cleanup of a half-open socket on a failed connection attempt
        }
    }

    private static String[] copyOrNull(String[] values) {
        return (values == null || values.length == 0) ? null : values.clone();
    }

    private static void wipe(char[] secret) {
        if (secret != null) {
            Arrays.fill(secret, '\0');
        }
    }
}
