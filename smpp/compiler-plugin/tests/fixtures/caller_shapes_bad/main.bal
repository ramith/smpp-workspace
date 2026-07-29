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

// Alias of a union involving Caller: PluginUtils' reference-unwrap-to-union path,
// otherwise unexercised (Phase-5 finding L3a). Same SMPP_108 as the direct form.
type MaybeCaller smpp:Caller?;

// Phase-5 H1/M1: the intersection-flavored variants - `(readonly & Caller)?` and
// `readonly & Caller?` - which used to evade BOTH the plugin and the runtime.
type ReadonlyCaller readonly & smpp:Caller;

type WrappedMaybeCaller readonly & smpp:Caller?;

isolated service class IntersectionCallerShapes {
    *smpp:Service;

    remote isolated function onDeliverSm(smpp:Sms sms, ReadonlyCaller? a = ()) returns error? {
    }

    remote isolated function onDataSm(smpp:Sms sms, WrappedMaybeCaller b = ()) returns error? {
    }
}

isolated service class AliasedOptionalCaller {
    *smpp:Service;

    remote isolated function onDataSm(smpp:Sms sms, MaybeCaller c = ()) returns error? {
    }
}

isolated service class DupSms {
    *smpp:Service;

    remote isolated function onDeliverSm(smpp:Sms a, smpp:Sms b) returns error? {
    }
}
