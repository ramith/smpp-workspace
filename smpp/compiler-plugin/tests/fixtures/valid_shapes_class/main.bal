// The service-class + explicit-attach idiom (what this repo's own tests use), covering
// the shapes Sprint 8.5 restored: intersections, aliases of intersections, caller-first
// ordering, and D5's trailing-defaulted-extra compatibility. ZERO SMPP_ diagnostics.
import ramith/smpp;

public type ROSms readonly & smpp:Sms;

isolated service class CallerFirst {
    *smpp:Service;

    remote isolated function onDeliverSm(smpp:Caller caller, readonly & smpp:Sms sms) returns error? {
    }
}

isolated service class AliasAndDefaults {
    *smpp:Service;

    remote isolated function onDataSm(ROSms sms, string extra = "x") returns error? {
    }
}

public function main() returns error? {
    smpp:Listener lis = check new ({host: "localhost", systemId: "x", password: "y"});
    check lis.attach(new CallerFirst());
    check lis.attach(new AliasAndDefaults());
}
