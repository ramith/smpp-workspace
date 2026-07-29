# SMPP listener (trigger) connector

A Ballerina listener/trigger that binds to an SMSC as a **receiver/transceiver ESME**,
dispatches inbound SMPP PDUs (mobile-originated SMS and delivery receipts) to your
service — and lets the service reply on the same transceiver session via an
`smpp:Caller` parameter (`caller->submit`). Speaks **SMPP v3.4** by wrapping
`org.jsmpp:jsmpp` through Ballerina Java interop.

See the package overview (`Package.md`) for the quickstart, the service contract
(`onDeliverSm`/`onDataSm`/`onError`), configuration, TLS, throughput expectations, and
protocol conformance — including the **Known limitations** section, which is worth
reading before you size or deploy anything against it.
