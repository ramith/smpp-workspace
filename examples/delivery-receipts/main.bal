// delivery-receipts — the classic receive-side workload behind A2P SMS: you send
// messages (OTPs, alerts, marketing) elsewhere — e.g. with `caller->submit` on a
// transceiver session (see the two-way-sms example) — and collect the SMSC's
// delivery receipts (DLRs) here to reconcile billing, drive retries, and power
// deliverability analytics. This example parses each DLR and acts on its state.
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
    bindType: smpp:RECEIVER
});

service on smsListener {

    remote function onDeliverSm(smpp:Sms sms) returns error? {
        // This service cares only about DLRs; a real deployment might handle MO
        // traffic on a separate service (see the two-way-sms example).
        if !sms.deliveryReceipt {
            log:printInfo("ignoring mobile-originated message", 'from = sms.sourceAddr);
            return;
        }

        smpp:DeliveryReceipt? receipt = sms.receipt;
        if receipt is () {
            // `deliveryReceipt` was true but the body didn't match SMPP Appendix B, so
            // jsmpp couldn't parse it. The raw text is still available for a custom parse.
            log:printWarn("delivery receipt could not be parsed", raw = sms.shortMessage);
            return;
        }

        // Correlate back to the message_id your submit returned, to attach this
        // outcome to the original submission. `receiptedMessageId` (the
        // receipted_message_id TLV, §5.3.2.12) is the only field SMPP guarantees to
        // match it; the Appendix-B body's `id:` (receipt.id) is vendor-specific —
        // some SMSCs emit it in a different radix — so it is fallback only.
        string messageId = sms.receiptedMessageId ?: (receipt?.id ?: "(none)");
        smpp:DeliveryReceiptStatus? status = receipt?.finalStatus;

        if status == smpp:DELIVRD {
            log:printInfo("message DELIVERED",
                    id = messageId, doneDate = receipt?.doneDate);
        } else if status == smpp:UNDELIV || status == smpp:EXPIRED
                || status == smpp:REJECTD || status == smpp:DELETED {
            // Terminal failure — this is where you'd trigger a retry on another route
            // or flag the number. `errorCode` is the SMSC/network-specific reason.
            log:printError("message FAILED",
                    id = messageId, status = status, err = receipt?.errorCode);
        } else if status == smpp:ACCEPTD {
            // Also FINAL: "accepted by the SMSC on the recipient's behalf" — no
            // further delivery attempt (or receipt) is coming. Don't wait for one.
            log:printInfo("message ACCEPTED on the recipient's behalf (final)",
                    id = messageId);
        } else if status == smpp:ENROUTE {
            // The one genuinely in-flight state: another receipt is still coming.
            log:printInfo("message in transit", id = messageId);
        } else {
            // UNKNOWN — §5.2.28 calls this an INVALID state, not an in-flight one:
            // the SMSC cannot say what happened and guarantees no further receipt.
            // Investigate (or query the SMSC); don't sit waiting for an outcome.
            log:printWarn("message state is indeterminate — no further receipt promised",
                    id = messageId, status = status);
        }
    }
}
