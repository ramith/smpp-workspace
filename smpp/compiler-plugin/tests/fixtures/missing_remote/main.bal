// The shipped-breaking-change case: this exact shape WORKED on 1.0.1 (attach used
// getMethods()) and silently stops firing on 1.1.0 (getRemoteMethods()).
import ramith/smpp;

listener smpp:Listener lis = new ({host: "localhost", systemId: "x", password: "y"});

service on lis {
    isolated function onDeliverSm(smpp:Sms sms) returns error? {
        return;
    }
}
