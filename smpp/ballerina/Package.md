# SMPP Trigger Connector (jsmpp wrapper)

A Ballerina trigger/listener that receives inbound SMPP PDUs (mobile-originated
SMS and delivery receipts) by wrapping the Java library
[`org.jsmpp:jsmpp`](https://jsmpp.org/) via Ballerina's Java interoperability.

## Usage

```ballerina
import ramith/smpp;
import ballerina/io;

configurable string systemId = ?;
configurable string password = ?;

listener smpp:Listener smsListener = check new ({
    host: "localhost",
    port: 2775,
    systemId,
    password,
    bindType: smpp:RECEIVER
});

service on smsListener {
    remote function onDeliverSm(smpp:Sms sms) returns error? {
        io:println(string `SMS from ${sms.sourceAddr}: ${sms.shortMessage}`);
    }
}
```

Supply the credentials via a `Config.toml` next to your `Ballerina.toml` (never
hardcode them in source):

```toml
systemId = "your-system-id"
password = "your-password"
```

## TLS

SMPP binds send the `systemId`/`password` in cleartext unless the transport is
encrypted. For an SMSC that terminates TLS in-band, add `secureSocket`:

```ballerina
listener smpp:Listener smsListener = check new ({
    host: "smsc.example.com",
    port: 3550,
    systemId,
    password,
    secureSocket: {
        cert: {path: "./truststore.p12", password: trustStorePass}
    }
});
```

`cert` (required) verifies the server against a PKCS12/JKS truststore or a PEM CA
certificate path; hostname verification is on by default; only TLS 1.2/1.3 are
negotiated; set `key` (a `crypto:KeyStore`) for mutual TLS. See the module docs on
`SecureSocket` for the full surface, including the loudly-labeled development-only
`InsecureSocket` escape hatch.
