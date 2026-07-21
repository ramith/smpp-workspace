// Copyright (c) 2026. Holds the Ballerina module reference for record creation.
package io.ballerinax.smpp;

import io.ballerina.runtime.api.Environment;
import io.ballerina.runtime.api.Module;

/**
 * Captures the {@code ramith/smpp} module reference at module init time so the
 * native dispatcher can create {@code smpp:Sms} record values.
 */
public final class ModuleUtils {

    private static Module smppModule;

    private ModuleUtils() {}

    /** Invoked from the module {@code init()} function via Java interop. */
    public static void setModule(Environment env) {
        smppModule = env.getCurrentModule();
    }

    public static Module getModule() {
        return smppModule;
    }
}
