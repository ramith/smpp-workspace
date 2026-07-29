// The service-class + explicit-attach idiom (what this repo's own tests use), covering
// the shapes Sprint 8.5 restored (intersections, aliases of intersections,
// caller-first) plus the acceptance edges nothing else pins: a DEFAULTED Sms (A8: the
// type match runs before the defaultable skip), D5's trailing-defaulted-extra compat,
// and onError with a trailing defaulted extra (E5: legal, padded at dispatch). ZERO
// SMPP_ diagnostics. Each service gets its own listener - one service per listener is
// a runtime rule, and a "valid shapes" fixture should model a runtime-valid program
// (Phase-5 finding L6).
import ramith/smpp;

public type ROSms readonly & smpp:Sms;

isolated service class CallerFirst {
    *smpp:Service;

    remote isolated function onDeliverSm(smpp:Caller caller, readonly & smpp:Sms sms) returns error? {
    }
}

isolated service class AliasDefaultsAndOnError {
    *smpp:Service;

    remote isolated function onDataSm(ROSms sms, string extra = "x") returns error? {
    }

    remote isolated function onDeliverSm(smpp:Sms sms = {sourceAddr: "", destAddr: "", shortMessage: ""}) returns error? {
    }

    remote isolated function onError(error err, string tag = "x") returns error? {
    }
}

public function main() returns error? {
    smpp:Listener lisA = check new ({host: "localhost", systemId: "x", password: "y"});
    check lisA.attach(new CallerFirst());
    smpp:Listener lisB = check new ({host: "localhost", port: 2776, systemId: "x", password: "y"});
    check lisB.attach(new AliasDefaultsAndOnError());
}
