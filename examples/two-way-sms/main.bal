// two-way-sms — inbound keyword handling for short-code / long-number campaigns:
// votes, competitions ("text WIN to 12345"), HELP, and — most importantly — STOP
// opt-outs, which are legally mandated (TCPA in the US, GDPR/PECR in the EU).
//
// This example pins smpp:1.0.0 (receive-only); 1.1.0 adds Caller.submit. The realistic
// pattern is: classify the inbound message here, then hand the action to whatever
// sends (an HTTP call to your messaging API, a transmitter session, a queue). This
// example logs the routing decision that outbound path would act on.
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
        // Delivery receipts are a separate concern (see the delivery-receipts example).
        if sms.deliveryReceipt {
            return;
        }

        string subscriber = sms.sourceAddr; // the mobile subscriber (MSISDN)
        string shortCode = sms.destAddr;     // the short code / long number they texted
        // Campaign keywords are matched on the first word, case-insensitively.
        string keyword = firstWord(sms.shortMessage).toUpperAscii();

        match keyword {
            "STOP"|"UNSUBSCRIBE"|"CANCEL" => {
                // Handle opt-out first and unconditionally — this is a compliance action.
                log:printWarn("OPT-OUT — suppress all future messages to this subscriber",
                        subscriber = subscriber, shortCode = shortCode);
            }
            "START"|"UNSTOP"|"YES" => {
                log:printInfo("OPT-IN — subscriber (re)subscribed", subscriber = subscriber);
            }
            "HELP"|"INFO" => {
                log:printInfo("HELP requested — would reply with program info + opt-out terms",
                        subscriber = subscriber);
            }
            "WIN" => {
                log:printInfo("campaign entry accepted", subscriber = subscriber, keyword = keyword);
            }
            _ => {
                // Anything unrecognized: route to a chatbot / live agent / NLP pipeline.
                log:printInfo("unrecognized keyword — routing to agent",
                        subscriber = subscriber, text = sms.shortMessage);
            }
        }
    }
}

// Returns the first whitespace-delimited token of a message (trimmed), or the whole
// trimmed string when there is no space.
isolated function firstWord(string message) returns string {
    string trimmed = message.trim();
    int? space = trimmed.indexOf(" ");
    return space is int ? trimmed.substring(0, space) : trimmed;
}
