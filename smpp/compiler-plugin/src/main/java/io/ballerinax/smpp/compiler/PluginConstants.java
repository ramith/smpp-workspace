// Copyright (c) 2026. Shared constants for the smpp compiler plugin.
package io.ballerinax.smpp.compiler;

/**
 * Names the plugin validates against. The service-shape contract itself lives in
 * {@link SmppServiceValidator}; it MUST mirror the runtime's attach-time validation in
 * {@code Dispatcher.validateAndPlan} — the Sprint 9 Phase-1 review derived the contract
 * table from that code, and any change there needs a matching change here (and vice
 * versa; the fixture tests pin the parity).
 */
public final class PluginConstants {

    private PluginConstants() {
    }

    public static final String PACKAGE_ORG = "ramith";
    public static final String PACKAGE_NAME = "smpp";

    public static final String ON_DELIVER_SM = "onDeliverSm";
    public static final String ON_DATA_SM = "onDataSm";
    public static final String ON_ERROR = "onError";

    public static final String SMS_TYPE = "Sms";
    public static final String CALLER_TYPE = "Caller";
    public static final String LISTENER_TYPE = "Listener";
    public static final String SERVICE_TYPE = "Service";

    public static final String NODE_LOCATION = "node.location";
    public static final String LS = System.lineSeparator();
}
