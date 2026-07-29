// The canonical bare-declaration form every shipped example uses: a valid reply-style
// service. Must produce ZERO SMPP_ diagnostics.
import ramith/smpp;

listener smpp:Listener lis = new ({
    host: "localhost",
    systemId: "x",
    password: "y",
    bindType: smpp:TRANSCEIVER
});

service on lis {
    remote isolated function onDeliverSm(smpp:Sms sms, smpp:Caller caller) returns error? {
        smpp:SubmitResult _ = check caller->submit({destAddr: "26481", shortMessage: "ok"});
    }

    remote isolated function onError(smpp:Error smppError) returns error? {
    }

    // A non-remote helper with an unrecognized name is an ordinary private method -
    // it must NOT be flagged.
    isolated function helper() {
    }
}
