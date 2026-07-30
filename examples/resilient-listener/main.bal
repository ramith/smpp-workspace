// resilient-listener — a carrier-grade, always-on receiver. SMSC links drop:
// the SMSC restarts, a firewall times out an idle NAT mapping, the network blips.
// The connector detects the drop and rebinds automatically with exponential
// backoff; this example tunes that policy and surfaces each drop via onError.
//
// Run it against the mock's `flaky` scenario, which accepts the bind, pushes a few
// messages, then hard-drops the link — so you can watch the rebind loop recover.
import ballerina/log;
import ramith/smpp;

configurable string host = "localhost";
configurable int port = 2775;
configurable string systemId = "esme";
configurable string password = "password";

listener smpp:Listener smsListener = check new ({
    host,
    port,
    systemId,
    password,
    bindType: smpp:RECEIVER,
    // How often to probe an idle link. A silently-dead SMSC (no FIN, just gone) is
    // only detected when an enquire_link goes unanswered, so a shorter interval means
    // faster detection — at the cost of more keepalive traffic. Must be >= 5s.
    enquireLinkInterval: 15,
    rebindPolicy: {
        initialRebindDelay: 1,  // wait 1s before the first reconnect attempt
        maxRebindDelay: 30,     // ...backing off 1s, 2s, 4s, 8s, ... capped at 30s
        backOffMultiplier: 2.0,
        // Retry forever (default); 0 disables rebinding. A positive cap counts
        // CONSECUTIVE failures — and a bind that drops again before ~60s of stable
        // uptime counts as one — so a flapping link exhausts it too. On give-up the
        // listener latches dead (submits fail with LINK_ABANDONED) until replaced.
        maxRebindAttempts: -1
    }
});

service on smsListener {

    remote function onDeliverSm(smpp:Sms sms) returns error? {
        log:printInfo("inbound message", 'from = sms.sourceAddr, text = sms.shortMessage);
    }

    // Called once for the initial unexpected drop, again for every failed rebind
    // attempt, and once more if a capped policy gives up — so during an extended
    // outage this fires repeatedly. It is NOT called for a deliberate
    // gracefulStop/immediateStop. Wire your alerting here.
    remote function onError(error err) returns error? {
        log:printError("SMSC session dropped — connector is rebinding with backoff", 'error = err);
    }
}
