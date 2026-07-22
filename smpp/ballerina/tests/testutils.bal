// Copyright (c) 2026. Shared recording store + service for the bal test suite.

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
