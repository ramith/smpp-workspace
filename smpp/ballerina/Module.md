# SMPP listener (trigger) connector

A Ballerina listener/trigger that binds to an SMSC as a **receiver/transceiver ESME**
and dispatches inbound SMPP PDUs (mobile-originated SMS and delivery receipts) to your
service. Speaks **SMPP v3.4** by wrapping `org.jsmpp:jsmpp` through Ballerina Java
interop.

See the package overview (`Package.md`) for the quickstart, the service contract
(`onDeliverSm`/`onDataSm`/`onError`), configuration, TLS, and protocol conformance.
