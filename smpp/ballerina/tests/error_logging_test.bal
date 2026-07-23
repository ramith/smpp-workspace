// Copyright (c) 2026. Sprint 5: native errors route through ballerina/log, not stderr.
import ballerina/test;

const int LOG_ROUTING_PORT = 27800;

// (A) The drop-with-no-onError fallback in Dispatcher.dispatchError calls the Ballerina
//     logDispatchError function via Runtime.callFunction, on a jsmpp thread. This exercises
//     that interop path end to end: a service with NO onError method suffers a session drop,
//     the connector logs it (rather than printing a stderr stack trace) and keeps going -
//     if the callFunction wiring were wrong (bad name/args), the drop handler would throw on
//     the jsmpp thread and the rebind below would never complete.
@test:Config {groups: ["logging"]}
function testDropWithoutOnErrorLogsAndRebinds() returns error? {
    int mockId = check mockSmscOpen(LOG_ROUTING_PORT);
    Listener smsListener = check new ({
        host: "localhost",
        port: LOG_ROUTING_PORT,
        systemId: "test",
        password: "test",
        bindType: TRANSCEIVER,
        rebindPolicy: {initialRebindDelay: 0.5, maxRebindDelay: 2}
    });
    // RecordingService implements onDeliverSm/onDataSm but NOT onError - so a drop takes the
    // logDispatchError fallback path.
    check smsListener.attach(new RecordingService());
    check smsListener.'start();
    int connId = check mockSmscAwaitNextBind(mockId, 5000);

    // Abruptly sever: the connector sees an unexpected drop, logs it (no onError handler),
    // and rebinds per policy.
    check mockSmscSever(mockId, connId);
    int reboundConn = check mockSmscAwaitNextBind(mockId, 10000);
    test:assertTrue(reboundConn != connId,
            "the connector must log the no-onError drop and rebind (a new connection), not crash the drop handler");

    check smsListener.gracefulStop();
    mockSmscClose(mockId);
}

// (A2) The Ballerina log helper itself must run without panicking when invoked directly
//      (it's the module function Java calls via callFunction).
@test:Config {groups: ["logging"]}
function testLogDispatchErrorHelperDoesNotPanic() {
    logDispatchError("unit check: dispatch error routed to log", error("simulated cause"));
    test:assertTrue(true, "logDispatchError returned normally");
}
