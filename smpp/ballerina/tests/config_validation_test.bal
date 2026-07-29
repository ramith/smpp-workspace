// Copyright (c) 2026. Negative tests for Listener init's config validation.
import ballerina/test;

# Pure-logic coverage for `validateConfig`/`validateRebindPolicy` (listener.bal): no
# socket, no mock, no native round trip - `Listener` init validates before `externInit`.
# One case per constraint, each asserting the error is the distinct `smpp:Error` type and
# names the offending field (a wrong-way comparison in exactly this kind of code is what
# these tests exist to pin).
@test:Config {}
function testConfigValidationRejectsOutOfBoundsValues() {
    record {|ConnectionConfig config; string expect;|}[] cases = [
        {config: {host: "h", systemId: "s", password: "p", port: 0}, expect: "port"},
        {config: {host: "h", systemId: "s", password: "p", port: 65536}, expect: "port"},
        {config: {host: "h", systemId: "s", password: "p", maxConcurrentDispatch: 0}, expect: "maxConcurrentDispatch"},
        {config: {host: "h", systemId: "s", password: "p", gracefulStopTimeout: -1}, expect: "gracefulStopTimeout"},
        {config: {host: "h", systemId: "s", password: "p", rebindPolicy: {initialRebindDelay: -1}}, expect: "initialRebindDelay"},
        {config: {host: "h", systemId: "s", password: "p", rebindPolicy: {initialRebindDelay: 10, maxRebindDelay: 5}}, expect: "maxRebindDelay"},
        {config: {host: "h", systemId: "s", password: "p", rebindPolicy: {backOffMultiplier: 0.5}}, expect: "backOffMultiplier"},
        {config: {host: "h", systemId: "s", password: "p", rebindPolicy: {maxRebindAttempts: -2}}, expect: "maxRebindAttempts"},
        // Sprint 4 fields. Upper bounds double as seconds-vs-millis unit-confusion guards.
        {config: {host: "h", systemId: "s", password: "p", maxConcurrentDispatch: 5000}, expect: "maxConcurrentDispatch"},
        {config: {host: "h", systemId: "s", password: "p", enquireLinkInterval: 2}, expect: "enquireLinkInterval"},
        {config: {host: "h", systemId: "s", password: "p", enquireLinkInterval: 60000}, expect: "enquireLinkInterval"},
        {config: {host: "h", systemId: "s", password: "p", bindTimeout: 0.5}, expect: "bindTimeout"},
        {config: {host: "h", systemId: "s", password: "p", bindTimeout: 60000}, expect: "bindTimeout"},
        // Sprint 8 (item 5): same seconds-vs-millis guard family as its neighbours.
        // sourceAddr deliberately has NO validation case: an absent/empty source address
        // is spec-legal and D9 decided not to reject it locally.
        {config: {host: "h", systemId: "s", password: "p", transactionTimeout: 0.5}, expect: "transactionTimeout"},
        {config: {host: "h", systemId: "s", password: "p", transactionTimeout: 30000}, expect: "transactionTimeout"}
    ];
    foreach var {config, expect} in cases {
        Listener|error result = new (config);
        test:assertTrue(result is error, string `config with out-of-bounds ${expect} must fail init`);
        if result is error {
            test:assertTrue(result is Error,
                    string `${expect}: the init error must be the distinct smpp:Error type`);
            test:assertTrue(result.message().includes(expect),
                    string `${expect}: the error should name the field, got: ${result.message()}`);
        }
    }
}

@test:Config {}
function testConfigValidationAcceptsBoundaryValues() {
    // Exactly-at-the-boundary values must pass (init performs no network activity, so a
    // successful init needs no cleanup beyond letting the listener go unused).
    Listener|error ok = new ({
        host: "h",
        systemId: "s",
        password: "p",
        port: 65535,
        maxConcurrentDispatch: 1024,
        gracefulStopTimeout: 0,
        enquireLinkInterval: 5,
        bindTimeout: 300,
        rebindPolicy: {initialRebindDelay: 0, maxRebindDelay: 0, backOffMultiplier: 1, maxRebindAttempts: -1}
    });
    test:assertTrue(ok !is error, "boundary-valid config must init cleanly");
}
