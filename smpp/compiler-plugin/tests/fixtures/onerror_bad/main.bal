// error? is a union, not an error type - the runtime rejects it at attach; unchecked it
// would panic per drop and LOSE the notification.
import ramith/smpp;

isolated service class BadOnError {
    *smpp:Service;

    remote isolated function onDeliverSm(smpp:Sms sms) returns error? {
    }

    remote isolated function onError(error? e) returns error? {
    }
}

public function main() returns error? {
    smpp:Listener lis = check new ({host: "localhost", systemId: "x", password: "y"});
    check lis.attach(new BadOnError());
}
