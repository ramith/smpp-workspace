// Copyright (c) 2026. The service-shape validation task: the smpp contract, at compile time.
package io.ballerinax.smpp.compiler;

import io.ballerina.compiler.api.SemanticModel;
import io.ballerina.compiler.api.symbols.ClassSymbol;
import io.ballerina.compiler.api.symbols.FunctionTypeSymbol;
import io.ballerina.compiler.api.symbols.MethodSymbol;
import io.ballerina.compiler.api.symbols.ModuleSymbol;
import io.ballerina.compiler.api.symbols.ParameterKind;
import io.ballerina.compiler.api.symbols.ParameterSymbol;
import io.ballerina.compiler.api.symbols.Qualifier;
import io.ballerina.compiler.api.symbols.ServiceDeclarationSymbol;
import io.ballerina.compiler.api.symbols.Symbol;
import io.ballerina.compiler.api.symbols.TypeDescKind;
import io.ballerina.compiler.api.symbols.TypeSymbol;
import io.ballerina.compiler.api.symbols.UnionTypeSymbol;
import io.ballerina.compiler.syntax.tree.ClassDefinitionNode;
import io.ballerina.compiler.syntax.tree.FunctionDefinitionNode;
import io.ballerina.compiler.syntax.tree.Node;
import io.ballerina.compiler.syntax.tree.ServiceDeclarationNode;
import io.ballerina.compiler.syntax.tree.SyntaxKind;
import io.ballerina.projects.plugins.AnalysisTask;
import io.ballerina.projects.plugins.SyntaxNodeAnalysisContext;
import io.ballerina.tools.diagnostics.Diagnostic;
import io.ballerina.tools.diagnostics.DiagnosticSeverity;
import io.ballerina.tools.diagnostics.Location;

import java.util.List;
import java.util.Optional;

import static io.ballerinax.smpp.compiler.PluginConstants.CALLER_TYPE;
import static io.ballerinax.smpp.compiler.PluginConstants.ON_DATA_SM;
import static io.ballerinax.smpp.compiler.PluginConstants.ON_DELIVER_SM;
import static io.ballerinax.smpp.compiler.PluginConstants.ON_ERROR;
import static io.ballerinax.smpp.compiler.PluginConstants.SMS_TYPE;
import static io.ballerinax.smpp.compiler.PluginUtils.diagnostic;
import static io.ballerinax.smpp.compiler.PluginUtils.involvesCaller;
import static io.ballerinax.smpp.compiler.PluginUtils.isErrorOrNilReturn;
import static io.ballerinax.smpp.compiler.PluginUtils.isErrorType;
import static io.ballerinax.smpp.compiler.PluginUtils.isSmppModule;
import static io.ballerinax.smpp.compiler.PluginUtils.isSmppType;

/**
 * Validates smpp service shapes at compile time, mirroring the runtime contract in
 * {@code Dispatcher.validateAndPlan} (derived by the Sprint 9 Phase-1 review; the
 * fixture tests pin the parity). Two syntactic forms are analyzed — a gap in the
 * plan's ftp/mqtt models, which register only {@code SERVICE_DECLARATION}:
 *
 * <ul>
 *   <li>{@code service on smppListener { ... }} — what every shipped example uses;</li>
 *   <li>{@code service class X { *smpp:Service; ... }} — what a reusable handler (and
 *       this repo's whole test suite) uses with an explicit {@code attach}.</li>
 * </ul>
 *
 * <p>Severity discipline: everything the runtime rejects at attach is an ERROR here
 * too (same outcome, earlier). The two silent-at-runtime cases — a typo'd method name
 * and a missing {@code remote} qualifier — are also ERRORs: since Sprint 8 moved attach
 * to {@code getRemoteMethods()}, a non-remote handler is not merely un-validated, it is
 * a program that WORKED on 1.0.1 and silently stops receiving traffic on 1.1.0, and a
 * compile-time error at the exact line (with a one-word fix) is the honest way to
 * surface an already-shipped breaking change. Isolation is a WARNING: legal, but it
 * silently serializes all dispatch process-wide.
 */
public class SmppServiceValidator implements AnalysisTask<SyntaxNodeAnalysisContext> {

    @Override
    public void perform(SyntaxNodeAnalysisContext context) {
        // Bail out on existing compile errors (mqtt's guard): symbols may be broken.
        for (Diagnostic diagnostic : context.semanticModel().diagnostics()) {
            if (diagnostic.diagnosticInfo().severity() == DiagnosticSeverity.ERROR) {
                return;
            }
        }
        if (context.node().kind() == SyntaxKind.SERVICE_DECLARATION) {
            validateServiceDeclaration(context);
        } else if (context.node().kind() == SyntaxKind.CLASS_DEFINITION) {
            validateServiceClass(context);
        }
    }

    private void validateServiceDeclaration(SyntaxNodeAnalysisContext context) {
        ServiceDeclarationNode node = (ServiceDeclarationNode) context.node();
        Optional<Symbol> symbol = context.semanticModel().symbol(node);
        if (symbol.isEmpty() || !(symbol.get() instanceof ServiceDeclarationSymbol serviceSymbol)) {
            return;
        }
        if (!attachedToSmppListener(serviceSymbol)) {
            return;
        }
        validateMembers(context, node.members(), node.location(), context.semanticModel());
    }

    private void validateServiceClass(SyntaxNodeAnalysisContext context) {
        ClassDefinitionNode node = (ClassDefinitionNode) context.node();
        Optional<Symbol> symbol = context.semanticModel().symbol(node);
        if (symbol.isEmpty() || !(symbol.get() instanceof ClassSymbol classSymbol)) {
            return;
        }
        // Only classes that opt in via `*smpp:Service` — anything else is not ours to
        // judge, however smpp-ish its method names look.
        boolean includesSmppService = false;
        for (TypeSymbol inclusion : classSymbol.typeInclusions()) {
            if (isSmppType(inclusion, PluginConstants.SERVICE_TYPE)) {
                includesSmppService = true;
                break;
            }
        }
        if (!includesSmppService) {
            return;
        }
        validateMembers(context, node.members(), node.location(), context.semanticModel());
    }

    private boolean attachedToSmppListener(ServiceDeclarationSymbol serviceSymbol) {
        for (TypeSymbol listener : serviceSymbol.listenerTypes()) {
            if (listener.typeKind() == TypeDescKind.UNION) {
                for (TypeSymbol member : ((UnionTypeSymbol) listener).memberTypeDescriptors()) {
                    Optional<ModuleSymbol> module = member.getModule();
                    if (module.isPresent() && isSmppModule(module.get())) {
                        return true;
                    }
                }
            } else {
                Optional<ModuleSymbol> module = listener.getModule();
                if (module.isPresent() && isSmppModule(module.get())) {
                    return true;
                }
            }
        }
        return false;
    }

    private void validateMembers(SyntaxNodeAnalysisContext context, Iterable<? extends Node> members,
                                 Location serviceLocation, SemanticModel semanticModel) {
        boolean anyRecognizedRemote = false;
        for (Node member : members) {
            if (!(member instanceof FunctionDefinitionNode function)) {
                continue;
            }
            Optional<Symbol> symbol = semanticModel.symbol(function);
            if (symbol.isEmpty() || !(symbol.get() instanceof MethodSymbol method)) {
                continue;
            }
            String name = PluginUtils.nameOf(method);
            boolean recognizedName = ON_DELIVER_SM.equals(name) || ON_DATA_SM.equals(name)
                    || ON_ERROR.equals(name);

            if (function.kind() == SyntaxKind.RESOURCE_ACCESSOR_DEFINITION) {
                // Load-bearing: resource methods are structurally invisible to attach.
                context.reportDiagnostic(diagnostic(SmppDiagnostic.SMPP_104,
                        function.location(), name));
                continue;
            }
            boolean isRemote = method.qualifiers().contains(Qualifier.REMOTE);
            if (!isRemote) {
                if (recognizedName) {
                    // Load-bearing, and a shipped breaking change (Sprint 8 moved attach
                    // from getMethods() to getRemoteMethods()): this exact shape worked
                    // on 1.0.1 and silently stops firing on 1.1.0.
                    context.reportDiagnostic(diagnostic(SmppDiagnostic.SMPP_103,
                            function.location(), name));
                }
                // A non-remote, non-recognized method is an ordinary private helper.
                continue;
            }
            if (!recognizedName) {
                // Load-bearing: the runtime silently ignores it (S3) - the typo case.
                context.reportDiagnostic(diagnostic(SmppDiagnostic.SMPP_102,
                        function.location(), name));
                continue;
            }
            anyRecognizedRemote = true;
            validateSignature(context, function, method, name);
        }
        if (!anyRecognizedRemote) {
            // Mirrors attach's NO_REMOTE_METHODS; also the code-action anchor for the
            // handler templates (an empty `service on smppListener {}` lands here).
            context.reportDiagnostic(diagnostic(SmppDiagnostic.SMPP_101, serviceLocation));
        }
    }

    private void validateSignature(SyntaxNodeAnalysisContext context, FunctionDefinitionNode function,
                                   MethodSymbol method, String name) {
        FunctionTypeSymbol fnType = method.typeDescriptor();

        // Return type (S6): never inspected at runtime, so this is load-bearing.
        Optional<TypeSymbol> returnType = fnType.returnTypeDescriptor();
        if (returnType.isPresent() && !isErrorOrNilReturn(returnType.get())) {
            context.reportDiagnostic(diagnostic(SmppDiagnostic.SMPP_105, function.location(), name));
        }

        // Rest parameter (R1/E1): rejected for all three methods.
        if (fnType.restParam().isPresent()) {
            context.reportDiagnostic(diagnostic(SmppDiagnostic.SMPP_106, function.location(), name));
        }

        List<ParameterSymbol> params = fnType.params().orElse(List.of());
        if (ON_ERROR.equals(name)) {
            validateOnError(context, function, params);
            return;
        }

        // onDeliverSm / onDataSm: identical rules (the Phase-1 contract table).
        boolean sawSms = false;
        boolean sawCaller = false;
        for (ParameterSymbol param : params) {
            String paramName = param.getName().orElse("?");
            TypeSymbol type = param.typeDescriptor();
            boolean defaulted = param.paramKind() == ParameterKind.DEFAULTABLE;
            if (isSmppType(type, CALLER_TYPE)) {
                if (defaulted) {
                    // R2: a defaultable Caller would let dispatch silently skip the
                    // user's reply path.
                    context.reportDiagnostic(diagnostic(SmppDiagnostic.SMPP_108,
                            function.location(), paramName));
                } else if (sawCaller) {
                    context.reportDiagnostic(diagnostic(SmppDiagnostic.SMPP_109,
                            function.location(), name, "smpp:Caller"));
                } else {
                    sawCaller = true;
                }
            } else if (isSmppType(type, SMS_TYPE)) {
                // A defaultable Sms is accepted (A8) - type match precedes the skip.
                if (sawSms) {
                    context.reportDiagnostic(diagnostic(SmppDiagnostic.SMPP_109,
                            function.location(), name, "smpp:Sms"));
                } else {
                    sawSms = true;
                }
            } else if (involvesCaller(type)) {
                // R5, checked BEFORE the defaultable skip: `smpp:Caller? c = ()` must
                // be rejected loudly, never silently skipped into nil (D1 trap 1).
                context.reportDiagnostic(diagnostic(SmppDiagnostic.SMPP_108,
                        function.location(), paramName));
            } else if (defaulted) {
                // A7 (D5 compat): trailing defaulted params of any other type are
                // SKIPPED, not rejected - `(Sms, string extra = "x")` is a legal,
                // working 1.0.1 program. A "too many parameters" rule here would be a
                // breaking regression (pinned by fixture valid_defaulted_extra).
                continue;
            } else {
                context.reportDiagnostic(diagnostic(SmppDiagnostic.SMPP_107,
                        function.location(), paramName));
            }
        }
        if (!sawSms) {
            context.reportDiagnostic(diagnostic(SmppDiagnostic.SMPP_110, function.location(), name));
        }

        // Isolation (S7): legal either way, but a non-isolated handler serializes ALL
        // dispatch on the runtime's process-wide lock - only the compiler can see this.
        if (!method.qualifiers().contains(Qualifier.ISOLATED)) {
            context.reportDiagnostic(diagnostic(SmppDiagnostic.SMPP_112, function.location(), name));
        }
    }

    private void validateOnError(SyntaxNodeAnalysisContext context, FunctionDefinitionNode function,
                                 List<ParameterSymbol> params) {
        int required = 0;
        boolean bad = false;
        String detail = "";
        for (ParameterSymbol param : params) {
            TypeSymbol type = param.typeDescriptor();
            // E2 + the N2 fix, mirrored: anything involving Caller - plain, optional,
            // union, or defaulted - is rejected. onError is 1-arity by design.
            if (involvesCaller(type)) {
                bad = true;
                detail = "it must not declare an smpp:Caller parameter (in any form)";
                break;
            }
            if (param.paramKind() != ParameterKind.DEFAULTABLE) {
                required++;
                if (!isErrorType(type)) {
                    bad = true;
                    detail = "parameter '" + param.getName().orElse("?")
                            + "' must be an error type (note: 'error?' is a union and is not accepted)";
                    break;
                }
            }
        }
        if (!bad && required != 1) {
            bad = true;
            detail = "found " + required + " required parameter(s)";
        }
        if (bad) {
            context.reportDiagnostic(diagnostic(SmppDiagnostic.SMPP_111, function.location(), detail));
        }
    }
}
