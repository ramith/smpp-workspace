// tls-smsc — bind over TLS. An SMPP bind sends the systemId/password in cleartext,
// so any SMSC reachable over an untrusted network should be dialed over TLS. This
// example verifies the SMSC's certificate against a truststore before binding.
//
// Run it against the mock's `tls` scenario (default port 3550). The truststore in
// ./resources was generated from the mock's self-signed cert; in production point
// `cert` at your SMSC's CA and keep the password out of source control.
import ballerina/log;
import ramith/smpp;

configurable string host = "localhost";
configurable int port = 3550;
configurable string systemId = "esme";
configurable string password = "password";
configurable string truststorePassword = "password";

listener smpp:Listener smsListener = check new ({
    host,
    port,
    systemId,
    password,
    bindType: smpp:RECEIVER,
    secureSocket: {
        // A PKCS12/JKS truststore (or a PEM CA path). The server cert is verified
        // against this, and its hostname is matched against `host` (CN/SAN=localhost
        // here). Only TLS 1.2/1.3 are negotiated. Add `key` for mutual TLS.
        cert: {
            path: "./resources/truststore.p12",
            password: truststorePassword
        }
    }
});

service on smsListener {

    remote function onDeliverSm(smpp:Sms sms) returns error? {
        log:printInfo("inbound message over TLS", 'from = sms.sourceAddr, text = sms.shortMessage);
    }
}
