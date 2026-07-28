// Copyright (c) 2026. Shared recording store + service for the bal test suite.
import ballerina/lang.runtime;

// All test files compile into this one module, so this store and service are shared;
// tests run sequentially (Ballerina's default), and every test that uses the store calls
// `clearRecorded()` in its setup, so cross-test contamination can't occur.
isolated Sms[] recordedSms = [];

isolated function recordSms(Sms sms) {
    lock {
        recordedSms.push(sms.clone());
    }
}

isolated function recordedCount() returns int {
    lock {
        return recordedSms.length();
    }
}

isolated function recordedAt(int i) returns Sms {
    lock {
        return recordedSms[i].clone();
    }
}

isolated function clearRecorded() {
    lock {
        recordedSms.removeAll();
    }
}

# Records every deliver_sm and data_sm it receives; never fails.
service class RecordingService {
    *Service;

    remote function onDeliverSm(Sms sms) returns error? {
        recordSms(sms);
    }

    remote function onDataSm(Sms sms) returns error? {
        recordSms(sms);
    }
}

// ---- onError recording (lifecycle tests) ----
isolated string[] recordedErrors = [];

isolated function recordError(error err) {
    lock {
        recordedErrors.push(err.message());
    }
}

isolated function recordedErrorCount() returns int {
    lock {
        return recordedErrors.length();
    }
}

# Count of recorded onError messages containing `substring`. Lifecycle tests assert
# per-cause counts, not ordering — onError notifications run on separate virtual threads
# (Dispatcher.dispatchError), so arrival order is not guaranteed.
#
# + substring - the message fragment to count
# + return - how many recorded onError messages contain it
isolated function recordedErrorsContaining(string substring) returns int {
    lock {
        int n = 0;
        foreach string msg in recordedErrors {
            if msg.includes(substring) {
                n += 1;
            }
        }
        return n;
    }
}

# Counts recorded drop notifications regardless of which detection path reported them.
# A drop reaches `onError` through one of two exactly-once-guarded signals: jsmpp's
# CLOSED state listener ("SMPP session closed unexpectedly ...") — the normal path — or
# the connector's own transport-death observer ("SMPP transport died and jsmpp's CLOSED
# notification did not arrive ..."), which recovers the rare jsmpp reader-death wedge
# where CLOSED never fires (see ObservedConnection.java). Tests asserting drop COUNTS
# must accept either wording, or a correctly-healed wedge cycle fails the count; tests
# pinning the normal path's wording specifically should keep `recordedErrorsContaining`.
#
# + return - how many recorded onError messages are drop notifications, by either wording
isolated function recordedDropCount() returns int {
    return recordedErrorsContaining("closed unexpectedly")
        + recordedErrorsContaining("transport died");
}

isolated function clearRecordedErrors() {
    lock {
        recordedErrors.removeAll();
    }
}

# Records every delivery and every onError notification; never fails.
service class LifecycleRecordingService {
    *Service;

    remote function onDeliverSm(Sms sms) returns error? {
        recordSms(sms);
    }

    remote function onError(error err) returns error? {
        recordError(err);
    }
}

// ---- slow SYNC handler + markers (stop-timing tests) ----
isolated boolean slowHandlerStarted = false;
isolated boolean slowHandlerCompleted = false;

isolated function markSlowHandlerStarted() {
    lock {
        slowHandlerStarted = true;
    }
}

isolated function isSlowHandlerStarted() returns boolean {
    lock {
        return slowHandlerStarted;
    }
}

isolated function markSlowHandlerCompleted() {
    lock {
        slowHandlerCompleted = true;
    }
}

isolated function isSlowHandlerCompleted() returns boolean {
    lock {
        return slowHandlerCompleted;
    }
}

isolated function resetSlowHandlerMarkers() {
    // Two lock blocks: Ballerina forbids touching two isolated module-level variables
    // in a single lock statement.
    lock {
        slowHandlerStarted = false;
    }
    lock {
        slowHandlerCompleted = false;
    }
}

# SYNC-mode slow handler: marks started, sleeps, records, marks completed. Also records
# onError so stop-timing tests can assert a user-initiated stop never fires onError.
service class SlowRecordingService {
    *Service;
    final decimal sleepSeconds;

    function init(decimal sleepSeconds) {
        self.sleepSeconds = sleepSeconds;
    }

    remote function onDeliverSm(Sms sms) returns error? {
        markSlowHandlerStarted();
        runtime:sleep(self.sleepSeconds);
        recordSms(sms);
        markSlowHandlerCompleted();
    }

    remote function onError(error err) returns error? {
        recordError(err);
    }
}

# Polls `cond` every 100 ms until true or `timeoutSeconds` elapses; returns the final value.
#
# + cond - the condition to poll
# + timeoutSeconds - how long to keep polling
# + return - the condition's final value
function pollUntil(function () returns boolean cond, decimal timeoutSeconds) returns boolean {
    int attempts = <int>(timeoutSeconds * 10);
    int i = 0;
    while i < attempts {
        if cond() {
            return true;
        }
        runtime:sleep(0.1);
        i += 1;
    }
    return cond();
}

// ---- handler gate (Sprint 4 backpressure tests) ----
// A single isolated record is the protected resource (Ballerina forbids touching two
// separate isolated module-level variables in one lock statement). `started` counts entries,
// `concurrent`/`maxConcurrent` track live handler executions, `released` opens the gate.
// `armed` controls blocking: until a test arms the gate, handlers pass through immediately
// (a warm-up phase - e.g. to make the mock's reader adopt a short enquire_link timeout before
// the handlers are saturated); once armed, handlers block until released.
type GateState record {|
    int started;
    int concurrent;
    int maxConcurrent;
    boolean released;
    boolean armed;
|};

isolated GateState gate = {started: 0, concurrent: 0, maxConcurrent: 0, released: false, armed: false};

isolated function resetGate() {
    lock {
        gate = {started: 0, concurrent: 0, maxConcurrent: 0, released: false, armed: false};
    }
}

# Arms the gate: subsequent handler entries block until released. Entries before arming
# pass straight through (warm-up round-trips).
isolated function armGate() {
    lock {
        gate.armed = true;
    }
}

# A gated handler body: records entry and tracks peak concurrency; if the gate is armed, it
# then blocks until released. This is how a test holds every dispatch slot occupied while it
# probes the connector's behaviour under saturation.
isolated function gateEnter() {
    boolean block;
    lock {
        gate.started += 1;
        gate.concurrent += 1;
        if gate.concurrent > gate.maxConcurrent {
            gate.maxConcurrent = gate.concurrent;
        }
        block = gate.armed;
    }
    if block {
        while !gateReleased() {
            runtime:sleep(0.02);
        }
    }
    lock {
        gate.concurrent -= 1;
    }
}

isolated function gateReleased() returns boolean {
    lock {
        return gate.released;
    }
}

isolated function releaseGate() {
    lock {
        gate.released = true;
    }
}

isolated function gateStartedCount() returns int {
    lock {
        return gate.started;
    }
}

# Live count of handlers currently inside the gate (entered but not yet exited). Unlike
# `gateStartedCount` (cumulative), this reflects handlers blocked *right now*, so a poll for
# "N slots occupied" is stable and unaffected by earlier warm-up entries that already exited.
isolated function gateConcurrentNow() returns int {
    lock {
        return gate.concurrent;
    }
}

isolated function gateMaxConcurrent() returns int {
    lock {
        return gate.maxConcurrent;
    }
}

# Gated dispatch service for backpressure tests: every deliver_sm blocks in the gate (holding
# its dispatch slot) until released, and records on the way out. `onError` is recorded so a
# test can assert whether the session was dropped (e.g. self-inflicted by starved keepalive).
service class GatedService {
    *Service;

    remote function onDeliverSm(Sms sms) returns error? {
        gateEnter();
        recordSms(sms);
    }

    remote function onError(error err) returns error? {
        recordError(err);
    }
}
