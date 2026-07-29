// Resource methods are invisible to attach; return types are never inspected at
// runtime - both silently inert without the plugin.
import ramith/smpp;

listener smpp:Listener lis = new ({host: "localhost", systemId: "x", password: "y"});

service on lis {
    resource isolated function get health() returns string {
        return "ok";
    }

    remote isolated function onDeliverSm(smpp:Sms sms) returns string {
        return "x";
    }
}
