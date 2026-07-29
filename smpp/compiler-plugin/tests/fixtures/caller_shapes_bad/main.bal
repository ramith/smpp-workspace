// D1 trap 1 (smpp:Caller? would be silently skipped into nil), a Caller-only handler
// missing its Sms, and a duplicate Sms.
import ramith/smpp;

listener smpp:Listener lis = new ({host: "localhost", systemId: "x", password: "y", bindType: smpp:TRANSCEIVER});

service on lis {
    remote isolated function onDeliverSm(smpp:Sms sms, smpp:Caller? caller = ()) returns error? {
    }

    remote isolated function onDataSm(smpp:Caller caller) returns error? {
    }
}

isolated service class DupSms {
    *smpp:Service;

    remote isolated function onDeliverSm(smpp:Sms a, smpp:Sms b) returns error? {
    }
}
