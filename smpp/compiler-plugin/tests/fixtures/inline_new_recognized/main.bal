// The inline-new / union-typed listener form - the quickstart copy-paste shape.
// attachedToSmppListener's union branch FAILS OPEN: if it were wrong, the plugin would
// silently treat this service as not-smpp and emit NOTHING, and a merely-valid fixture
// would pass anyway (Phase-5 finding M1). So this fixture pins RECOGNITION with a
// deliberate violation: an empty service through the inline form must draw SMPP_101 -
// if the recognition path breaks, the code goes missing and the harness fails.
import ramith/smpp;

service on new smpp:Listener({host: "localhost", systemId: "x", password: "y"}) {
}
