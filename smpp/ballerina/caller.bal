// Copyright (c) 2026. SMPP trigger connector — the reply-side Caller.
import ballerina/jballerina.java;

# Submits messages (`submit_sm`) on the same SMSC session the listener receives on.
#
# Obtained by declaring it as a parameter of a remote method — never constructed:
#
# ```ballerina
# remote function onDeliverSm(smpp:Sms sms, smpp:Caller caller) returns error? {
#     smpp:SubmitResult r = check caller->submit({
#         destAddr: sms.sourceAddr,
#         shortMessage: "reply text"
#     });
# }
# ```
#
# Declaring the parameter is opt-in: existing one-parameter services keep working
# unchanged. The parameter is matched by TYPE, not position — `(Sms, Caller)` and
# `(Caller, Sms)` are both accepted (unlike `mqtt`, which enforces caller-last; like
# `ftp`, which binds by type — and stricter than both: an optional-typed
# `smpp:Caller?` parameter or a rest parameter is rejected at attach, not silently
# left `()`).
#
# One `Caller` exists per listener and stays valid across rebinds: every submit
# resolves the listener's *current* session, so a `Caller` captured before a drop
# submits on the fresh session after the rebind (`testSubmitSurvivesRebindOnNewSession`
# pins this). Requires `bindType: TRANSCEIVER` — a `RECEIVER` bind cannot transmit,
# and `submit` on one fails fast with a clear error naming the fix.
#
# Not `distinct`, matching the 7 stdlib Callers (none are), so a future `smpp:Client`
# can satisfy the same shape.
public isolated client class Caller {

    // Module-private on purpose: user code cannot `new smpp:Caller()`. The runtime
    // constructs the one instance per listener at native init and hands it to remote
    // methods that declare the parameter.
    isolated function init() {
    }

    # Submits a message to the SMSC and waits (bounded by
    # `ConnectionConfig.transactionTimeout`) for the `submit_sm_resp`.
    #
    # In `SYNC` response mode this blocks one of the `maxConcurrentDispatch` dispatch
    # slots for the round trip — budget slots accordingly when handlers reply inline,
    # or the SMSC sees `ESME_RTHROTTLED` on concurrent inbound traffic (documented
    # consequence, pinned by `testSubmitStarvesInboundDispatchWithThrottle`).
    #
    # A slow inline reply in `SYNC` also delays the `deliver_sm_resp` past the SMSC's
    # own transaction timer, making it REDELIVER an MO you already answered - a duplicate
    # MT (pinned by `testSyncSubmitOutlivesSmscTransactionTimer`). **Prefer
    # `responseMode: ASYNC` for reply-style services**, and carry your own idempotency
    # key (e.g. dedupe on the inbound source+text+timestamp) where duplicates are costly.
    #
    # Two limits worth knowing before sizing anything against this: the connector applies
    # no rate limiting of its own (carrier throttling policy is yours to respect), and a
    # submit already awaiting its response is **not** woken if the link dies or the
    # listener stops — the underlying library has no fail-pending-on-close, so it
    # completes only at `transactionTimeout`, holding its dispatch slot in `SYNC` mode
    # for that whole time.
    #
    # + sms - the message to send: a `TextSms` (the connector encodes it) or a
    #   `BinarySms` (pre-encoded octets, with `udhi` for UDH-bearing payloads)
    # + return - the SMSC's `message_id` for the accepted message (correlate delivery
    #   receipts against it — see `Sms.receiptedMessageId`), or an `Error` whose detail
    #   carries `failureMode`, `commandStatus`, and `possiblySubmitted` — the last being
    #   the field to branch retry logic on, since `false` means a retry cannot duplicate
    #   the message (see `FailureMode` for the rest of the retry guidance)
    remote isolated function submit(OutboundSms sms) returns SubmitResult|Error {
        return self.externSubmit(sms);
    }

    isolated function externSubmit(OutboundSms sms) returns SubmitResult|Error = @java:Method {
        'class: "io.ballerinax.smpp.NativeCaller",
        name: "submit"
    } external;
}
