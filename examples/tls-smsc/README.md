# tls-smsc

Bind over **TLS**. An SMPP bind sends the `systemId`/`password` in cleartext, so any
SMSC reachable over an untrusted network should be dialed over TLS. This example
verifies the SMSC's certificate against a truststore before binding.

The connector verifies the server certificate against `secureSocket.cert`, matches its
hostname against `host` (CN/SAN = `localhost` here), and negotiates only TLS 1.2/1.3.
Add a `key` (a `crypto:KeyStore`) for mutual TLS.

## Certificates

`resources/truststore.p12` (password `password`) was generated from the mock SMSC's
self-signed certificate — see [../mock-smsc/README.md](../mock-smsc/README.md) to
regenerate the pair. For a real SMSC, point `cert` at your SMSC's CA and keep the
password out of source control (a `Config.toml` or secret).

## Run

Use the `tls` scenario (default port 3550):

```bash
# terminal 1
cd ../mock-smsc && ./gradlew run --args="tls 3550"

# terminal 2
bal run
```

Expected output:

```
message="inbound message over TLS" from="447700900001" text="Hello from the mock SMSC #0"
message="inbound message over TLS" from="447700900002" text="WIN"
```

## Against a real SMSC

```toml
host = "smsc.example.com"
port = 3550
systemId = "your-system-id"
password = "your-password"
truststorePassword = "your-truststore-password"
```

Then place your CA truststore at `resources/truststore.p12` (or change the path in
`main.bal`).
