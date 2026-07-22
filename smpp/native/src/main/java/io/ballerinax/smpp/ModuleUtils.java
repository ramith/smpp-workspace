// Copyright (c) 2026. Holds the Ballerina module reference for record/error creation.
package io.ballerinax.smpp;

import io.ballerina.runtime.api.Environment;
import io.ballerina.runtime.api.Module;
import io.ballerina.runtime.api.creators.ErrorCreator;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BError;

/**
 * Captures the {@code ramith/smpp} module reference at module init time so the
 * native dispatcher can create {@code smpp:Sms} record values and {@code smpp:Error}
 * values.
 */
public final class ModuleUtils {

    // Must match the distinct error type name declared in types.bal
    // (`public type Error distinct error;`).
    private static final String ERROR_TYPE_NAME = "Error";

    private static Module smppModule;

    private ModuleUtils() {}

    /** Invoked from the module {@code init()} function via Java interop. */
    public static void setModule(Environment env) {
        smppModule = env.getCurrentModule();
    }

    public static Module getModule() {
        return smppModule;
    }

    /**
     * Creates a module-qualified {@code smpp:Error} carrying {@code message}, so every
     * error this connector's native layer returns is typed - callers can match it with
     * {@code err is smpp:Error} instead of getting a generic, unqualified {@code error}.
     *
     * @param message the error message
     * @return a {@code smpp:Error} value
     */
    public static BError createError(String message) {
        return ErrorCreator.createDistinctError(ERROR_TYPE_NAME, smppModule, StringUtils.fromString(message));
    }
}
