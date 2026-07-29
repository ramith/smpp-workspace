// The load-bearing typo case: onDeliverSM compiles clean today and the runtime silently
// ignores it - the service never receives a single SMS.
import ramith/smpp;

isolated service class Typo {
    *smpp:Service;

    remote isolated function onDeliverSM(smpp:Sms sms) returns error? {
    }
}

public function main() returns error? {
    smpp:Listener lis = check new ({host: "localhost", systemId: "x", password: "y"});
    check lis.attach(new Typo());
}
