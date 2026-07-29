import ramith/smpp;

listener smpp:Listener lis = new ({host: "localhost", systemId: "x", password: "y"});

service on lis {
    remote isolated function onDeliverSm(smpp:Sms sms, string... extras) returns error? {
    }

    remote isolated function onDataSm(smpp:Sms sms, int count) returns error? {
    }
}
