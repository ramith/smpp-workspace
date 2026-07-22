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
