// receive-sms — the smallest possible ramith/smpp program: bind to an SMSC as a
// receiver and log every inbound message. This is the starting point for any
// receive-side integration (2-way SMS, delivery tracking, campaign ingestion, ...).
import ballerina/log;
import ramith/smpp;

// Connection settings. The defaults match the bundled mock SMSC, so this example
// runs as-is against `examples/mock-smsc$ ./gradlew run --args="steady 2775"`.
// Override with a Config.toml or `bal run -- -Chost=... -Cport=...`.
configurable string host = "localhost";
configurable int port = 2775;
configurable string systemId = "esme";
configurable string password = "password";

listener smpp:Listener smsListener = check new ({
    host,
    port,
    systemId,
    password,
    bindType: smpp:RECEIVER
});

service on smsListener {

    // Invoked for every inbound deliver_sm. A RECEIVER bind never sends, so this is
    // the only callback you need. `sms.deliveryReceipt` tells an MO message apart
    // from a delivery receipt (DLR) for something you previously submitted.
    remote function onDeliverSm(smpp:Sms sms) returns error? {
        if sms.deliveryReceipt {
            // `receiptedMessageId` is the guaranteed correlation key back to a
            // submit's message_id (the body's `receipt?.id` is vendor-specific).
            log:printInfo("delivery receipt received",
                    'from = sms.sourceAddr,
                    status = sms.receipt?.finalStatus,
                    id = sms.receiptedMessageId ?: sms.receipt?.id);
        } else {
            log:printInfo("inbound SMS received",
                    'from = sms.sourceAddr,
                    to = sms.destAddr,
                    text = sms.shortMessage);
        }
    }
}
