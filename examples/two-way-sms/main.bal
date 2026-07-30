// two-way-sms — inbound keyword handling for short-code / long-number campaigns:
// votes, competitions ("text WIN to 12345"), HELP, and — most importantly — STOP
// opt-outs, which are legally mandated (TCPA in the US, GDPR/PECR in the EU).
//
// As of ramith/smpp:1.1.0 the connector is bidirectional: a service declares an
// `smpp:Caller` parameter and replies on the same SMSC session with
// `caller->submit`. Replying needs `bindType: TRANSCEIVER` (a RECEIVER bind cannot
// transmit), and `responseMode: ASYNC` is the documented recommendation for
// reply-style services — in SYNC a slow inline reply holds a dispatch slot for the
// whole submit round trip and can outlive the SMSC's own transaction timer,
// drawing a duplicate redelivery of the message you already answered.
import ballerina/log;
import ramith/smpp;

configurable string host = "localhost";
configurable int port = 2775;
configurable string systemId = "esme";
configurable string password = "password";
// The campaign's short code — the sender the subscriber sees on every reply.
configurable string shortCode = "12345";

listener smpp:Listener smsListener = check new ({
    host,
    port,
    systemId,
    password,
    bindType: smpp:TRANSCEIVER,
    responseMode: smpp:ASYNC,
    // Default source address for every submit; OutboundSms.sourceAddr overrides it
    // per message. TON_ABBREVIATED is the SMPP type-of-number for short codes.
    sourceAddr: {value: shortCode, ton: smpp:TON_ABBREVIATED, npi: smpp:NPI_UNKNOWN}
});

isolated service on smsListener {

    // Opt-out confirmations awaiting their delivery receipt: SMSC message_id ->
    // subscriber. In production this lives in a database; the shape of the
    // correlation (SubmitResult.messageId matched against Sms.receiptedMessageId)
    // is the point. Against an SMSC that omits the receipted_message_id TLV this
    // correlation never fires — production code should also handle its SMSC's
    // documented body-id radix, and put a TTL on this store. Size that TTL ABOVE
    // the message's validity period: an EXPIRED receipt only fires when validity
    // runs out, which under an SMSC's default can be days, and a shorter TTL
    // evicts the entry before its final receipt can ever land.
    private map<string> pendingOptOuts = {};

    // Final receipts that arrived BEFORE the STOP branch recorded their message_id:
    // the DLR is dispatched on its own strand, and nothing orders it after the
    // insert (a real SMSC can receipt faster than this mock's 1.5s). Parked here;
    // the STOP branch reconciles right after it records the id. Production wants a
    // TTL here too — two things park forever: a receipt for a message some other
    // system sent, and a DUPLICATE final receipt for one of ours (an SMSC
    // retransmits a deliver_sm whose deliver_sm_resp was lost, and the second copy
    // finds the pending entry already consumed).
    private map<FinalOutcome> earlyReceipts = {};

    isolated remote function onDeliverSm(smpp:Sms sms, smpp:Caller caller) returns error? {
        if sms.deliveryReceipt {
            self.correlateReceipt(sms);
            return;
        }

        string subscriber = sms.sourceAddr; // the mobile subscriber (MSISDN)
        // Campaign keywords are matched on the first word, case-insensitively.
        string keyword = firstWord(sms.shortMessage).toUpperAscii();

        match keyword {
            "STOP"|"UNSUBSCRIBE"|"CANCEL" => {
                // Handle opt-out first and unconditionally — this is a compliance
                // action: suppress the subscriber, then confirm, and ask the SMSC
                // for a receipt so the confirmation itself is provably delivered.
                log:printWarn("OPT-OUT — suppress all future messages to this subscriber",
                        subscriber = subscriber, shortCode = shortCode);
                string? messageId = submitReply(caller, subscriber,
                        "You are unsubscribed and will receive no further messages.",
                        registeredDelivery = smpp:ON_SUCCESS_OR_FAILURE);
                if messageId is string {
                    // The receipt may already have arrived (see earlyReceipts):
                    // reconcile and record under ONE lock, so exactly one side wins.
                    FinalOutcome? early;
                    lock {
                        early = self.earlyReceipts.removeIfHasKey(messageId);
                        if early is () {
                            self.pendingOptOuts[messageId] = subscriber;
                        }
                    }
                    if early is FinalOutcome {
                        logConfirmationOutcome(subscriber, messageId, early);
                    }
                }
            }
            "START"|"UNSTOP"|"YES" => {
                log:printInfo("OPT-IN — subscriber (re)subscribed", subscriber = subscriber);
                _ = submitReply(caller, subscriber,
                        "Welcome back! Reply STOP at any time to unsubscribe.");
            }
            "HELP"|"INFO" => {
                _ = submitReply(caller, subscriber,
                        "Campaign info line. Msg&data rates may apply. Reply STOP to unsubscribe.");
            }
            "WIN" => {
                log:printInfo("campaign entry accepted", subscriber = subscriber, keyword = keyword);
                _ = submitReply(caller, subscriber, "Your entry is in - good luck!");
            }
            _ => {
                // Anything unrecognized: route to a chatbot / live agent / NLP
                // pipeline rather than auto-replying.
                log:printInfo("unrecognized keyword — routing to agent",
                        subscriber = subscriber, text = sms.shortMessage);
            }
        }
    }

    // Matches an inbound delivery receipt against the opt-out confirmations this
    // service submitted. `Sms.receiptedMessageId` (the receipted_message_id TLV) is
    // the only correlation key SMPP guarantees to equal the message_id the submit
    // returned; the Appendix-B body's `id:` is vendor-specific (radix may differ).
    isolated function correlateReceipt(smpp:Sms sms) {
        string? messageId = sms.receiptedMessageId;
        if messageId is () {
            log:printInfo("delivery receipt without a receipted_message_id TLV — cannot correlate",
                    raw = sms.shortMessage);
            return;
        }
        smpp:DeliveryReceiptStatus? status = sms.receipt?.finalStatus;
        // ENROUTE and UNKNOWN are the only states that promise a later receipt, so
        // they are the only ones that keep the entry pending. Everything else is
        // FINAL — including ACCEPTD, which SMPP defines as "accepted by the SMSC on
        // the recipient's behalf": no further delivery attempt is made. So is an
        // unparseable body (`status` is `()`, because a vendor `stat:` token fails
        // jsmpp's Appendix-B parse entirely): these confirmations ask for
        // ON_SUCCESS_OR_FAILURE, which draws exactly ONE receipt and only at the
        // final state, so a body we cannot read is still the last word on it.
        boolean isFinal = status != smpp:ENROUTE && status != smpp:UNKNOWN;
        string? subscriber;
        lock {
            subscriber = isFinal ? self.pendingOptOuts.removeIfHasKey(messageId)
                    : self.pendingOptOuts[messageId];
            if subscriber is () && isFinal {
                // Either our receipt outran the STOP branch's insert, or the message
                // was never ours (e.g. the mock's scripted DLR) — indistinguishable
                // here, which is why final receipts are parked, not dropped.
                self.earlyReceipts[messageId] = {status, raw: sms.shortMessage};
            }
        }
        if subscriber is () {
            log:printInfo("receipt with no matching pending opt-out",
                    id = messageId, status = status, parked = isFinal);
        } else if !isFinal {
            log:printInfo("opt-out confirmation not yet final",
                    subscriber = subscriber, id = messageId, status = status);
        } else {
            logConfirmationOutcome(subscriber, messageId, {status, raw: sms.shortMessage});
        }
    }
}

// A receipt's final outcome as this service records it. `status` is `()` when the
// SMSC's Appendix-B body failed jsmpp's parse — final all the same (see the
// `isFinal` note), which is why the raw text travels with it: that is all the
// evidence there is about how the message actually ended up.
//
// `readonly` so a parked outcome can be read inside the `lock` and used outside it:
// an isolated object may only transfer immutable values across that boundary.
type FinalOutcome readonly & record {|
    smpp:DeliveryReceiptStatus? status;
    string raw;
|};

// Logs the final outcome of a receipted opt-out confirmation.
isolated function logConfirmationOutcome(string subscriber, string messageId,
        FinalOutcome outcome) {
    smpp:DeliveryReceiptStatus? status = outcome.status;
    if status == smpp:DELIVRD {
        log:printInfo("opt-out confirmation DELIVERED",
                subscriber = subscriber, id = messageId);
    } else if status == smpp:ACCEPTD {
        // Final, but not a handset delivery: the SMSC took responsibility for the
        // message on the recipient's behalf. The content WAS handled — do not wire
        // an automatic resend here, or the subscriber receives it twice.
        log:printInfo("opt-out confirmation ACCEPTED on the recipient's behalf",
                subscriber = subscriber, id = messageId);
    } else if status is () {
        log:printWarn("opt-out confirmation: final receipt body could not be parsed",
                subscriber = subscriber, id = messageId, raw = outcome.raw);
    } else {
        // UNDELIV / EXPIRED / REJECTD / DELETED — the subscriber never got it.
        // THIS is where a resend on another route, or an escalation, belongs.
        log:printWarn("opt-out confirmation was not delivered",
                subscriber = subscriber, id = messageId, status = status);
    }
}

// Submits one reply and returns the SMSC's message_id, or `()` when the submit
// failed (already logged). Errors carry the retry-safety bit `possiblySubmitted`:
// `false` means a retry cannot duplicate the message; `true` means the SMSC may
// already have accepted it, so retrying may deliver a duplicate.
isolated function submitReply(smpp:Caller caller, string destAddr, string text,
        smpp:DeliveryReceiptRequest registeredDelivery = smpp:NONE) returns string? {
    smpp:SubmitResult|smpp:Error result = caller->submit({
        destAddr,
        shortMessage: text,
        registeredDelivery
    });
    if result is smpp:Error {
        log:printError("reply failed", 'error = result,
                failureMode = result.detail().failureMode,
                possiblySubmitted = result.detail().possiblySubmitted);
        return ();
    }
    log:printInfo("reply submitted", to = destAddr, messageId = result.messageId);
    return result.messageId;
}

// Returns the first whitespace-delimited token of a message (trimmed), or the whole
// trimmed string when there is no space.
isolated function firstWord(string message) returns string {
    string trimmed = message.trim();
    int? space = trimmed.indexOf(" ");
    return space is int ? trimmed.substring(0, space) : trimmed;
}
