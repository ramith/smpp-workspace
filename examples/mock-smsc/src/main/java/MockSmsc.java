// A configurable jsmpp-based mock SMSC for the ramith/smpp Ballerina examples.
//
// This is NOT a real SMSC. It accepts any bind (receiver or transceiver), pushes a
// scripted stream of inbound PDUs — mobile-originated (MO) short messages and SMSC
// delivery receipts (DLRs) — and answers `submit_sm` (the connector's 1.1.0
// `caller->submit` reply path) with a generated `message_id`. A submit asking for a
// receipt on success OR failure (registered_delivery bits 1-0 = 01) gets a
// correlated DLR pushed back ~1.5s later, carrying the `receipted_message_id` TLV;
// a failure-only request (10) gets none, because this mock always delivers. So each
// example runs end to end with `bal run`, no carrier account required.
//
// Usage:  ./gradlew run --args="<scenario> [port]"
//   steady (default) — accept the bind and forever push a rotating stream:
//                       plain MO, keyword MO "WIN", keyword MO "STOP", a DLR.
//   flaky            — accept, push a few MO, then hard-drop the link so the
//                       client's rebind/backoff logic kicks in; then re-accept.
//   tls              — same stream as steady, but over TLS (bundled self-signed
//                       keystore); defaults to port 3550.
// Every scenario answers submit_sm.
import org.jsmpp.PDUStringException;
import org.jsmpp.bean.*;
import org.jsmpp.extra.ProcessRequestException;
import org.jsmpp.session.*;
import org.jsmpp.session.connection.ServerConnection;
import org.jsmpp.session.connection.ServerConnectionFactory;
import org.jsmpp.session.connection.socket.ServerSocketConnection;
import org.jsmpp.util.MessageId;

import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLServerSocketFactory;
import java.io.IOException;
import java.io.InputStream;
import java.net.ServerSocket;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

public class MockSmsc {

    private static final long PUSH_INTERVAL_MS = 3000L;
    private static final String KEYSTORE_RESOURCE = "/keystore.p12";
    private static final char[] KEYSTORE_PASSWORD = "password".toCharArray();

    // A well-formed SMPP v3.4 Appendix-B receipt body — the exact shape jsmpp's
    // receipt parser accepts, so the connector surfaces a populated `sms.receipt`.
    private static final String RECEIPT_BODY =
            "id:0123456789 sub:001 dlvrd:001 submit date:0809011130 "
            + "done date:0809011131 stat:DELIVRD err:000 text:Hello";

    public static void main(String[] args) throws Exception {
        String scenario = args.length > 0 ? args[0].toLowerCase() : "steady";
        int port = args.length > 1
                ? Integer.parseInt(args[1])
                : (scenario.equals("tls") ? 3550 : 2775);

        SMPPServerSessionListener listener = scenario.equals("tls")
                ? new SMPPServerSessionListener(port, tlsFactory())
                : new SMPPServerSessionListener(port);

        System.out.println("[mock-smsc] scenario=" + scenario + " listening on port " + port);

        // Accept binds forever: when one client disconnects we simply loop back to
        // accept() and wait for the next bind (so restarting an example just works).
        while (true) {
            SMPPServerSession session = listener.accept();
            System.out.println("[mock-smsc] TCP connection accepted");
            session.setMessageReceiverListener(new MockListener());
            try {
                BindRequest bind = session.waitForBind(15_000);
                System.out.println("[mock-smsc] BIND accepted (systemId=" + bind.getSystemId() + ")");
                bind.accept("mock-smsc");
                serve(session, scenario);
            } catch (Exception e) {
                System.out.println("[mock-smsc] session ended: " + e.getClass().getSimpleName()
                        + (e.getMessage() != null ? " - " + e.getMessage() : ""));
            } finally {
                session.unbindAndClose();
            }
        }
    }

    private static void serve(SMPPServerSession session, String scenario) throws Exception {
        if (scenario.equals("flaky")) {
            for (int i = 0; i < 3; i++) {
                pushPlain(session, i);
                Thread.sleep(PUSH_INTERVAL_MS);
            }
            System.out.println("[mock-smsc] FLAKY: dropping the connection to trigger a rebind");
            session.close(); // hard close, no unbind — looks like a network drop to the client
            return;
        }
        // steady / tls: rotate through a representative inbound stream forever.
        int i = 0;
        while (true) {
            switch (i % 4) {
                case 0 -> pushPlain(session, i);
                case 1 -> pushKeyword(session, "WIN");
                case 2 -> pushKeyword(session, "STOP");
                default -> pushReceipt(session);
            }
            i++;
            Thread.sleep(PUSH_INTERVAL_MS);
        }
    }

    /** A mobile-originated short message from a subscriber MSISDN to a short code. */
    private static void pushPlain(SMPPServerSession s, int n) throws Exception {
        deliver(s, "447700900001", "12345", new ESMClass(),
                new GeneralDataCoding(Alphabet.ALPHA_DEFAULT),
                ("Hello from the mock SMSC #" + n).getBytes(StandardCharsets.US_ASCII));
        System.out.println("[mock-smsc] -> MO short message");
    }

    /** An MO carrying a single campaign/opt-out keyword (WIN, STOP, ...). */
    private static void pushKeyword(SMPPServerSession s, String keyword) throws Exception {
        deliver(s, "447700900002", "12345", new ESMClass(),
                new GeneralDataCoding(Alphabet.ALPHA_DEFAULT),
                keyword.getBytes(StandardCharsets.US_ASCII));
        System.out.println("[mock-smsc] -> MO keyword '" + keyword + "'");
    }

    /**
     * A deliver_sm flagged as an SMSC delivery receipt (the esm_class receipt bit).
     * Addressed the way real SMSCs do it: source = the MSISDN the original message
     * went to, destination = the short code it was sent from. Carries the
     * `receipted_message_id` TLV (§5.3.2.12) — the correlation key SMPP guarantees —
     * matching the Appendix-B body's `id:` field.
     */
    private static void pushReceipt(SMPPServerSession s) throws Exception {
        deliver(s, "447700900001", "12345",
                new ESMClass(DeliverSm.composeSmscDeliveryReceipt((byte) 0)),
                new RawDataCoding((byte) 0),
                RECEIPT_BODY.getBytes(StandardCharsets.US_ASCII),
                new OptionalParameter.Receipted_message_id("0123456789"));
        System.out.println("[mock-smsc] -> delivery receipt (stat:DELIVRD)");
    }

    private static void deliver(SMPPServerSession s, String src, String dst,
            ESMClass esm, DataCoding dcs, byte[] body,
            OptionalParameter... opts) throws Exception {
        s.deliverShortMessage(
                "", TypeOfNumber.INTERNATIONAL, NumberingPlanIndicator.ISDN, src,
                TypeOfNumber.INTERNATIONAL, NumberingPlanIndicator.ISDN, dst,
                esm, (byte) 0, (byte) 0,
                new RegisteredDelivery(0), dcs, body, opts);
    }

    /** Builds a TLS server-socket connection factory from the bundled self-signed keystore. */
    private static ServerConnectionFactory tlsFactory() throws Exception {
        KeyStore ks = KeyStore.getInstance("PKCS12");
        try (InputStream in = MockSmsc.class.getResourceAsStream(KEYSTORE_RESOURCE)) {
            if (in == null) {
                throw new IllegalStateException("keystore resource not found on classpath: " + KEYSTORE_RESOURCE);
            }
            ks.load(in, KEYSTORE_PASSWORD);
        }
        KeyManagerFactory kmf = KeyManagerFactory.getInstance("SunX509");
        kmf.init(ks, KEYSTORE_PASSWORD);
        SSLContext ctx = SSLContext.getInstance("TLS");
        ctx.init(kmf.getKeyManagers(), null, null);
        final SSLServerSocketFactory ssf = ctx.getServerSocketFactory();
        return new ServerConnectionFactory() {
            public ServerConnection listen(int port) throws IOException {
                return new ServerSocketConnection(ssf.createServerSocket(port));
            }
            public ServerConnection listen(int port, int timeout) throws IOException {
                ServerSocket ss = ssf.createServerSocket(port);
                ss.setSoTimeout(timeout);
                return new ServerSocketConnection(ss);
            }
            public ServerConnection listen(int port, int timeout, int backlog) throws IOException {
                ServerSocket ss = ssf.createServerSocket(port, backlog);
                ss.setSoTimeout(timeout);
                return new ServerSocketConnection(ss);
            }
        };
    }

    /**
     * Server listener for the ESME's own requests. `submit_sm` (the connector's
     * `caller->submit` reply path) is answered with a generated decimal `message_id`;
     * a submit that asked for a receipt on success or failure additionally gets a
     * correlated DLR pushed back ~1.5s later (see the bit test in onAcceptSubmitSm —
     * a failure-only request gets none). Everything else stays a no-op — the
     * connector sends only `submit_sm` of the submit family.
     */
    static class MockListener implements ServerMessageReceiverListener {
        private static final AtomicLong NEXT_MESSAGE_ID = new AtomicLong(1);
        private static final ScheduledExecutorService DLR_PUSHER =
                Executors.newSingleThreadScheduledExecutor(r -> {
                    Thread t = new Thread(r, "mock-smsc-dlr");
                    t.setDaemon(true);
                    return t;
                });

        public SubmitSmResult onAcceptSubmitSm(SubmitSm s, SMPPServerSession src) throws ProcessRequestException {
            String id = String.format("%010d", NEXT_MESSAGE_ID.getAndIncrement());
            String text = new String(s.getShortMessage(), StandardCharsets.ISO_8859_1);
            System.out.println("[mock-smsc] <- submit_sm from=" + s.getSourceAddr()
                    + " to=" + s.getDestAddress() + " id=" + id + " text=\"" + text + "\"");
            // registered_delivery bits 1-0 (§5.2.17): 01 = receipt on success or
            // failure, 10 = receipt only on failure. This mock always "delivers"
            // successfully, so only 01 gets a receipt — a failure-only request must
            // produce none (pushing DELIVRD for it would be wire-illegal).
            if ((s.getRegisteredDelivery() & 0x03) == 0x01) {
                scheduleReceipt(src, s.getSourceAddr(), s.getDestAddress(), id);
            }
            try {
                return new SubmitSmResult(new MessageId(id), new OptionalParameter[0]);
            } catch (PDUStringException e) {
                throw new IllegalStateException("unreachable: a zero-padded decimal is a valid message_id", e);
            }
        }

        /** Pushes a DELIVRD receipt for an accepted submit: from the recipient MSISDN back to the submitter's address. */
        private static void scheduleReceipt(SMPPServerSession session, String submitSource, String submitDest, String id) {
            DLR_PUSHER.schedule(() -> {
                try {
                    String body = "id:" + id + " sub:001 dlvrd:001 submit date:0809011130 "
                            + "done date:0809011131 stat:DELIVRD err:000 text:";
                    deliver(session, submitDest, submitSource,
                            new ESMClass(DeliverSm.composeSmscDeliveryReceipt((byte) 0)),
                            new RawDataCoding((byte) 0),
                            body.getBytes(StandardCharsets.US_ASCII),
                            new OptionalParameter.Receipted_message_id(id));
                    System.out.println("[mock-smsc] -> delivery receipt for submitted id=" + id);
                } catch (Exception e) {
                    System.out.println("[mock-smsc] DLR push failed: " + e.getClass().getSimpleName()
                            + (e.getMessage() != null ? " - " + e.getMessage() : ""));
                }
            }, 1500, TimeUnit.MILLISECONDS);
        }

        public SubmitMultiResult onAcceptSubmitMulti(SubmitMulti s, SMPPServerSession src) throws ProcessRequestException { return null; }
        public QuerySmResult onAcceptQuerySm(QuerySm s, SMPPServerSession src) throws ProcessRequestException { return null; }
        public void onAcceptReplaceSm(ReplaceSm s, SMPPServerSession src) throws ProcessRequestException { }
        public void onAcceptCancelSm(CancelSm s, SMPPServerSession src) throws ProcessRequestException { }
        public BroadcastSmResult onAcceptBroadcastSm(BroadcastSm s, SMPPServerSession src) throws ProcessRequestException { return null; }
        public void onAcceptCancelBroadcastSm(CancelBroadcastSm s, SMPPServerSession src) throws ProcessRequestException { }
        public QueryBroadcastSmResult onAcceptQueryBroadcastSm(QueryBroadcastSm s, SMPPServerSession src) throws ProcessRequestException { return null; }
        public DataSmResult onAcceptDataSm(DataSm d, Session src) throws ProcessRequestException { return null; }
    }
}
