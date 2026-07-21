import ballerina/log;
import ramith/smpp;

// Override via `bal run -- -Chost=... -Cport=...` or a Config.toml.
configurable string host = "localhost";
configurable int port = 2775;
configurable string systemId = "test";
configurable string password = "test";
configurable string systemType = "";

listener smpp:Listener smsListener = check new ({
    host,
    port,
    systemId,
    password,
    systemType,
    bindType: smpp:TRANSCEIVER
});

service on smsListener {

    remote function onDeliverSm(smpp:Sms sms) returns error? {
        if sms.deliveryReceipt {
            log:printInfo("delivery receipt received",
                    'source = sms.sourceAddr, payload = sms.shortMessage);
        } else {
            log:printInfo("inbound SMS received",
                    'from = sms.sourceAddr, to = sms.destAddr, text = sms.shortMessage);
        }
    }

    remote function onDataSm(smpp:Sms sms) returns error? {
        log:printInfo("inbound DATA_SM received", 'from = sms.sourceAddr, to = sms.destAddr);
    }
}
