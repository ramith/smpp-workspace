// A minimal jsmpp-based mock SMSC for testing the ramith/smpp trigger.
// Accepts one bind, then pushes a DELIVER_SM (inbound SMS) to the bound client.
import org.jsmpp.bean.*;
import org.jsmpp.extra.ProcessRequestException;
import org.jsmpp.session.*;

import java.nio.charset.StandardCharsets;

public class MockSmsc {

    public static void main(String[] args) throws Exception {
        int port = args.length > 0 ? Integer.parseInt(args[0]) : 2775;
        SMPPServerSessionListener ssl = new SMPPServerSessionListener(port);
        System.out.println("[mock-smsc] listening on port " + port);

        SMPPServerSession session = ssl.accept();
        System.out.println("[mock-smsc] TCP connection accepted");
        session.setMessageReceiverListener(new NoOpListener());

        BindRequest bind = session.waitForBind(15000);
        System.out.println("[mock-smsc] BIND received (systemId=" + bind.getSystemId() + "); accepting");
        bind.accept("mock-smsc");

        Thread.sleep(1000);
        System.out.println("[mock-smsc] pushing DELIVER_SM to client...");
        session.deliverShortMessage(
                "",
                TypeOfNumber.INTERNATIONAL, NumberingPlanIndicator.ISDN, "12345",
                TypeOfNumber.INTERNATIONAL, NumberingPlanIndicator.ISDN, "99999",
                new ESMClass(), (byte) 0, (byte) 0,
                new RegisteredDelivery(0),
                new GeneralDataCoding(Alphabet.ALPHA_DEFAULT),
                "Hello from mock SMSC!".getBytes(StandardCharsets.US_ASCII));
        System.out.println("[mock-smsc] DELIVER_SM sent");

        Thread.sleep(3000);
        System.out.println("[mock-smsc] shutting down");
        session.unbindAndClose();
        ssl.close();
        System.exit(0);
    }

    /** No-op server listener; the client only receives, so nothing here is exercised. */
    static class NoOpListener implements ServerMessageReceiverListener {
        public SubmitSmResult onAcceptSubmitSm(SubmitSm s, SMPPServerSession src) throws ProcessRequestException { return null; }
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
