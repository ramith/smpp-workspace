// Copyright (c) 2026. Diagnostic catalogue for the smpp compiler plugin.
package io.ballerinax.smpp.compiler;

import io.ballerina.tools.diagnostics.DiagnosticSeverity;

/**
 * Every diagnostic this plugin can report. The split that justifies the plugin's
 * existence (Sprint 9 Phase-1 review):
 *
 * <ul>
 *   <li><b>Load-bearing</b> — cases where NOTHING fails at runtime: the connector's
 *       attach-time validation cannot see them, so without the plugin the program looks
 *       healthy while messages silently go nowhere. {@code SMPP_102} (typo'd handler
 *       name), {@code SMPP_103} (missing {@code remote} — which also became a shipped,
 *       previously-undocumented breaking change when Sprint 8 moved attach to
 *       {@code getRemoteMethods()}), {@code SMPP_104} (resource method), {@code SMPP_105}
 *       (return type never inspected at runtime), and {@code SMPP_112} (isolation:
 *       legal, but silently serializes every dispatch on the runtime's process-wide
 *       lock).</li>
 *   <li><b>Convenience mirrors</b> — shapes the runtime already rejects loudly at
 *       {@code listener.attach}; the plugin only moves the same message from startup to
 *       the editor. Kept because an IDE squiggle at the exact parameter beats a startup
 *       failure, but they are not the sprint's justification.</li>
 * </ul>
 */
public enum SmppDiagnostic {

    // -- code-action anchor + attach mirror -------------------------------------------
    SMPP_101("SMPP_101", "service must implement at least one of the smpp remote methods "
            + "(onDeliverSm, onDataSm, onError)", DiagnosticSeverity.ERROR),

    // -- load-bearing: silent at runtime ----------------------------------------------
    SMPP_102("SMPP_102", "unrecognized remote method ''{0}'': the smpp listener dispatches only "
            + "onDeliverSm, onDataSm, and onError - this method will never be invoked",
            DiagnosticSeverity.ERROR),
    SMPP_103("SMPP_103", "method ''{0}'' must be declared ''remote'': without the qualifier the "
            + "smpp listener cannot see it and it will silently never be invoked",
            DiagnosticSeverity.ERROR),
    SMPP_104("SMPP_104", "resource methods are not supported by the smpp listener; declare "
            + "''remote function {0}'' instead", DiagnosticSeverity.ERROR),
    SMPP_105("SMPP_105", "method ''{0}'' must return ''error?'': any other return type is ignored "
            + "at runtime, so a handler failure could never reach the SMSC as a negative "
            + "acknowledgement", DiagnosticSeverity.ERROR),

    // -- convenience mirrors of the attach-time BAD_SIGNATURE rules -------------------
    SMPP_106("SMPP_106", "method ''{0}'' must not declare a rest parameter",
            DiagnosticSeverity.ERROR),
    SMPP_107("SMPP_107", "parameter ''{0}'' has an unsupported type; expected smpp:Sms or "
            + "smpp:Caller (trailing parameters with defaults are permitted)",
            DiagnosticSeverity.ERROR),
    SMPP_108("SMPP_108", "parameter ''{0}'': smpp:Caller must be a plain, non-defaultable "
            + "parameter (smpp:Caller? or a union involving Caller is not accepted)",
            DiagnosticSeverity.ERROR),
    SMPP_109("SMPP_109", "method ''{0}'' declares more than one ''{1}'' parameter",
            DiagnosticSeverity.ERROR),
    SMPP_110("SMPP_110", "method ''{0}'' must declare an smpp:Sms parameter",
            DiagnosticSeverity.ERROR),
    SMPP_111("SMPP_111", "onError must take exactly one required parameter, of an error type "
            + "(and no smpp:Caller in any form): {0}", DiagnosticSeverity.ERROR),

    // -- load-bearing hint: legal but operationally surprising ------------------------
    SMPP_112("SMPP_112", "''{0}'' is not isolated: dispatch will hold the runtime''s "
            + "process-wide lock for the whole handler (including any caller->submit round "
            + "trip), so maxConcurrentDispatch stops being a parallelism knob. Declare the "
            + "service and its remote methods ''isolated''", DiagnosticSeverity.WARNING);

    private final String code;
    private final String message;
    private final DiagnosticSeverity severity;

    SmppDiagnostic(String code, String message, DiagnosticSeverity severity) {
        this.code = code;
        this.message = message;
        this.severity = severity;
    }

    public String code() {
        return code;
    }

    public String message() {
        return message;
    }

    public DiagnosticSeverity severity() {
        return severity;
    }
}
