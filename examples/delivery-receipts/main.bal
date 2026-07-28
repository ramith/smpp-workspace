// delivery-receipts — the classic receive-side workload behind A2P SMS: you send
// messages (OTPs, alerts, marketing) on a transmitter elsewhere, and collect the
// SMSC's delivery receipts (DLRs) here to reconcile billing, drive retries, and
// power deliverability analytics. This example parses each DLR and acts on its state.
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

        // `id` correlates back to the message_id your submit_sm_resp returned — look it
        // up in your outbound store to attach this outcome to the original submission.
        string messageId = receipt?.id ?: "(none)";
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
        } else {
            // ENROUTE / ACCEPTD / UNKNOWN — not a final state; an intermediate receipt.
            log:printInfo("message in transit", id = messageId, status = status);
        }
    }
}
