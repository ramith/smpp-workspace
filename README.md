# smpp-workspace

Workspace for the **[`ramith/smpp`](https://central.ballerina.io/ramith/smpp)** Ballerina
connector — an **SMPP v3.4 listener/trigger with reply support** that binds to an SMSC as an ESME
(receiver/transceiver) and dispatches inbound PDUs (mobile-originated SMS and delivery
receipts) to a Ballerina service. It wraps the Java library
[`org.jsmpp:jsmpp`](https://jsmpp.org/) through Ballerina's Java interop.

**Published:** `ramith/smpp:1.0.1` is live on Ballerina Central.

## Repository layout

```
smpp-workspace/
├── smpp/            The connector — the package published to Central
├── examples/        Runnable examples + a mock SMSC to run them against
├── docs/            Design, process, and QA documentation
├── smpp_tester/     Dev harness: a small Ballerina app that consumes the connector
├── mock-smsc/       Original minimal dev mock SMSC (superseded by examples/mock-smsc)
├── scripts/         Dev/ops scripts (e.g. the lifecycle soak runner)
├── jsmpp/           Vendored jsmpp source, reference-only (git-ignored)
└── .github/         CI workflows
```

## What each directory contains

### [smpp/](smpp/) — the connector
The published package and its build. A Gradle multi-project using the official
`io.ballerina.plugin` harness:
- [smpp/ballerina/](smpp/ballerina/) — the Ballerina package (`ramith/smpp`). Public API in
  [listener.bal](smpp/ballerina/listener.bal) (the `Listener` + service contract) and
  [types.bal](smpp/ballerina/types.bal) (`ConnectionConfig`, `Sms`, `DeliveryReceipt`, TLS
  types); [Package.md](smpp/ballerina/Package.md) is the Central page; `tests/` holds the
  test suite.
- [smpp/native/](smpp/native/) — the hand-written Java glue bridging jsmpp callbacks into the
  Ballerina runtime (`src/main`), its unit tests (`src/test`), and a test-only mock-SMSC
  bridge (`src/testBridge`).
- [smpp/build-config/](smpp/build-config/) — the `Ballerina.toml` template whose version
  placeholders are stamped at build time from `gradle.properties`.

### [examples/](examples/) — runnable examples
Five focused, receive-side examples plus the tooling to run them end to end with no carrier
account. See [examples/README.md](examples/README.md) for the full index.
- `receive-sms`, `delivery-receipts`, `two-way-sms`, `resilient-listener`, `tls-smsc` — each a
  self-contained Ballerina package consuming the connector from Central.
- [examples/mock-smsc/](examples/mock-smsc/) — a shared, scenario-driven mock SMSC (steady /
  flaky / tls) that pushes inbound traffic at the examples.
- [build.sh](examples/build.sh) compiles every example; [smoke-test.sh](examples/smoke-test.sh)
  runs each against the mock and asserts its output (both run in CI).

### [docs/](docs/) — documentation
- [architecture.md](docs/architecture.md) — design rationale, concurrency model, and lifecycle
  state machine.
- [development-process.md](docs/development-process.md), [qa-strategy.md](docs/qa-strategy.md),
  [sprint-plan.md](docs/sprint-plan.md) — how the connector was built and validated.

### Development support
- [smpp_tester/](smpp_tester/) — a minimal Ballerina app that binds a transceiver and logs
  inbound messages; used during development to exercise the connector (consumes it from the
  local repository).
- [mock-smsc/](mock-smsc/) — the original single-shot mock SMSC ([MockSmsc.java](mock-smsc/MockSmsc.java))
  from early development. The maintained, richer harness is [examples/mock-smsc/](examples/mock-smsc/).
- [scripts/](scripts/) — helper scripts such as [soak-lifecycle.sh](scripts/soak-lifecycle.sh)
  (repeats the drop/rebind soak test).
- `jsmpp/` — a reference checkout of the jsmpp library source, kept locally for consulting the
  authoritative Java API. It is git-ignored and not part of the project's code.

### [.github/](.github/) — CI
- [build.yml](.github/workflows/build.yml) — builds and tests the connector on every push/PR.
- [examples.yml](.github/workflows/examples.yml) — builds and smoke-tests the examples.
- [release.yml](.github/workflows/release.yml) — on a `v*` tag, publishes the connector to
  Ballerina Central (immutable).

## Building

- **Connector:** requires Docker + a GitHub `read:packages` PAT (see
  [architecture.md](docs/architecture.md) / the release docs). From `smpp/`: `./gradlew build`.
- **Examples:** require only Ballerina (and Java to run the mock). See
  [examples/README.md](examples/README.md).
