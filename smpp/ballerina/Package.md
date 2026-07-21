# SMPP Trigger Connector (jsmpp wrapper)

A Ballerina trigger/listener that receives inbound SMPP PDUs (mobile-originated
SMS and delivery receipts) by wrapping the Java library
[`org.jsmpp:jsmpp`](https://jsmpp.org/) via Ballerina's Java interoperability.

## Usage

```ballerina
import ramith/smpp;
import ballerina/io;

listener smpp:Listener smsListener = check new ({
    host: "localhost",
    port: 2775,
    systemId: "test",
    password: "test",
    bindType: smpp:RECEIVER
});

service on smsListener {
    remote function onDeliverSm(smpp:Sms sms) returns error? {
        io:println(string `SMS from ${sms.sourceAddr}: ${sms.shortMessage}`);
    }
}
```
