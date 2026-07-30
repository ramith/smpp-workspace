# Mock SMSC (test harness)

A tiny [jsmpp](https://jsmpp.org/)-based **mock SMSC** used to run the `ramith/smpp`
examples end to end without a real carrier account. It is **not** a production SMSC:
it accepts any bind (receiver or transceiver), pushes a scripted stream of inbound
PDUs at the bound client, and answers `submit_sm` (the connector's `caller->submit`
reply path) with a generated decimal `message_id`. A submit whose
`registered_delivery` requests a receipt on success or failure (bits 1-0 = `01`,
§5.2.17) gets a correlated `stat:DELIVRD` receipt pushed back ~1.5s later, carrying
the `receipted_message_id` TLV — so submit → receipt correlation works end to end.
A failure-only request (`10`) gets no receipt: the mock always "delivers", and a
success receipt for it would be wire-illegal.

It is a standalone Gradle application — it does not depend on the connector build.

## Run

```bash
./gradlew run --args="<scenario> [port]"
```

| Scenario | Default port | What it does |
|----------|--------------|--------------|
| `steady` (default) | 2775 | Accepts the bind, then every 3s pushes a rotating stream: a plain MO short message, an MO keyword `WIN`, an MO keyword `STOP`, and a well-formed SMSC **delivery receipt** (`stat:DELIVRD`, `receipted_message_id` TLV included). |
| `flaky` | 2775 | Accepts the bind, pushes a few MO messages, then **hard-drops** the link — so a client can exercise its rebind/backoff logic. Then re-accepts and repeats. |
| `tls` | 3550 | Same stream as `steady`, but over **TLS**, using the bundled self-signed keystore. |

Examples:

```bash
./gradlew run --args="steady 2775"   # for receive-sms, delivery-receipts, two-way-sms
./gradlew run --args="flaky 2775"    # for resilient-listener
./gradlew run --args="tls 3550"      # for tls-smsc
```

Stop it with `Ctrl-C`.

## TLS certificates

`src/main/resources/keystore.p12` is a self-signed cert for `CN=localhost` (with a
SAN for `localhost`/`127.0.0.1`), password `password`. The matching truststore the
`tls-smsc` example verifies against lives in `../tls-smsc/resources/truststore.p12`.

To regenerate both:

```bash
keytool -genkeypair -alias mocksmsc -keyalg RSA -keysize 2048 -validity 3650 \
  -dname "CN=localhost, OU=examples, O=ramith-smpp" \
  -ext "SAN=dns:localhost,ip:127.0.0.1" \
  -keystore src/main/resources/keystore.p12 -storetype PKCS12 \
  -storepass password -keypass password

keytool -exportcert -alias mocksmsc -keystore src/main/resources/keystore.p12 \
  -storepass password -rfc -file /tmp/mocksmsc.crt
keytool -importcert -alias mocksmsc -file /tmp/mocksmsc.crt \
  -keystore ../tls-smsc/resources/truststore.p12 -storetype PKCS12 \
  -storepass password -noprompt
```

These credentials are for local testing only — never point the connector at a
production SMSC with a self-signed/unverified certificate.
