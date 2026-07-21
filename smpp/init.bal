// Copyright (c) 2026. Captures the module reference for native record creation.

import ballerina/jballerina.java;

function setModule() = @java:Method {
    'class: "io.ballerinax.smpp.ModuleUtils",
    name: "setModule"
} external;

function init() {
    setModule();
}
