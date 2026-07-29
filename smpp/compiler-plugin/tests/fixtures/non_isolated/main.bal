// Legal, and it works - but dispatch holds the runtime's process-wide lock for the
// whole handler, so maxConcurrentDispatch silently stops being a parallelism knob.
// WARNING only: the build must still succeed.
//
// Note the handler must genuinely defeat isolated INFERENCE (the unlocked module-level
// mutable state below): an empty non-`isolated` handler is inferred isolated by the
// compiler, the runtime sees the same inference, and there is nothing to warn about -
// the first version of this fixture got that wrong and the plugin rightly stayed quiet.
import ramith/smpp;

listener smpp:Listener lis = new ({host: "localhost", systemId: "x", password: "y"});

int counter = 0;

service on lis {
    remote function onDeliverSm(smpp:Sms sms) returns error? {
        counter += 1;
    }
}
