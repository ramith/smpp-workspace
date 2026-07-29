// Copyright (c) 2026. Type-resolution helpers for the smpp compiler plugin.
package io.ballerinax.smpp.compiler;

import io.ballerina.compiler.api.symbols.IntersectionTypeSymbol;
import io.ballerina.compiler.api.symbols.ModuleSymbol;
import io.ballerina.compiler.api.symbols.Symbol;
import io.ballerina.compiler.api.symbols.TypeDescKind;
import io.ballerina.compiler.api.symbols.TypeReferenceTypeSymbol;
import io.ballerina.compiler.api.symbols.TypeSymbol;
import io.ballerina.compiler.api.symbols.UnionTypeSymbol;
import io.ballerina.compiler.syntax.tree.ModulePartNode;
import io.ballerina.compiler.syntax.tree.NonTerminalNode;
import io.ballerina.compiler.syntax.tree.SyntaxTree;
import io.ballerina.tools.diagnostics.Diagnostic;
import io.ballerina.tools.diagnostics.DiagnosticFactory;
import io.ballerina.tools.diagnostics.DiagnosticInfo;
import io.ballerina.tools.diagnostics.Location;
import io.ballerina.tools.text.LineRange;
import io.ballerina.tools.text.TextDocument;
import io.ballerina.tools.text.TextRange;

import java.text.MessageFormat;
import java.util.Optional;

/**
 * Type matching that mirrors the runtime's {@code Dispatcher.isModuleType}/
 * {@code involvesCallerType} EXACTLY — including the intersection handling.
 *
 * <p>Deliberately NOT the string-signature comparison ftp's plugin uses: rendering the
 * type to text and comparing substrings rejects {@code readonly & smpp:Sms}, which is
 * precisely the shape Sprint 8.5 (H5) restored support for at attach time. A plugin
 * that re-broke it at compile time would undo that fix for every IDE user. Matching is
 * symbol-based: unwrap type-reference chains, and for intersections scan the
 * CONSTITUENT type symbols for the org/module/name match — the same two-level
 * resolution the runtime performs (Dispatcher, Sprint 8.5: "getImpliedType alone was
 * NOT sufficient; the implied form no longer carries the name").
 */
public final class PluginUtils {

    private PluginUtils() {
    }

    public static Diagnostic diagnostic(SmppDiagnostic d, Location location, Object... args) {
        String message = args.length == 0 ? d.message() : MessageFormat.format(d.message(), args);
        // The code is prefixed INTO the message, not only carried in DiagnosticInfo:
        // `bal build` renders just the message text, so without the prefix the code
        // would be invisible on the command line - unusable in docs, in bug reports,
        // and in the fixture tests that pin this plugin's behaviour.
        return DiagnosticFactory.createDiagnostic(
                new DiagnosticInfo(d.code(), d.code() + ": " + message, d.severity()), location);
    }

    /** True if the module symbol is this connector's module (any version). */
    public static boolean isSmppModule(ModuleSymbol module) {
        return module != null
                && PluginConstants.PACKAGE_NAME.equals(module.id().moduleName())
                && PluginConstants.PACKAGE_ORG.equals(module.id().orgName());
    }

    /**
     * True if {@code type} IS the named smpp type: a direct reference, an alias chain,
     * an intersection with the type as a constituent ({@code readonly & smpp:Sms}), or
     * an alias of such an intersection. Unions do NOT match here (mirrors the runtime's
     * exact-type rule — {@code smpp:Sms?} is not an Sms parameter).
     */
    public static boolean isSmppType(TypeSymbol type, String name) {
        return isSmppType(type, name, 0);
    }

    private static boolean isSmppType(TypeSymbol type, String name, int depth) {
        if (depth > 8 || type == null) {
            return false; // defensive: alias cycles cannot occur, but never recurse unbounded
        }
        if (type.typeKind() == TypeDescKind.TYPE_REFERENCE) {
            TypeReferenceTypeSymbol ref = (TypeReferenceTypeSymbol) type;
            Optional<ModuleSymbol> module = ref.getModule();
            if (module.isPresent() && isSmppModule(module.get())
                    && name.equals(ref.definition().getName().orElse(null))) {
                return true;
            }
            // An alias of an intersection (type ROSms readonly & Sms) resolves through
            // the reference's descriptor.
            return isSmppType(ref.typeDescriptor(), name, depth + 1);
        }
        if (type.typeKind() == TypeDescKind.INTERSECTION) {
            for (TypeSymbol constituent : ((IntersectionTypeSymbol) type).memberTypeDescriptors()) {
                if (isSmppType(constituent, name, depth + 1)) {
                    return true;
                }
            }
        }
        return false;
    }

    /**
     * True if the type IS Caller or is a union with Caller among its (unwrapped)
     * members — {@code smpp:Caller?}, {@code Caller|X}, aliases thereof. Mirrors the
     * runtime's {@code involvesCallerType}, which rejects these loudly rather than
     * letting a defaulted one be silently skipped into nil (D1 trap 1).
     */
    public static boolean involvesCaller(TypeSymbol type) {
        return involvesCaller(type, 0);
    }

    private static boolean involvesCaller(TypeSymbol type, int depth) {
        if (depth > 8 || type == null) {
            return false;
        }
        if (isSmppType(type, PluginConstants.CALLER_TYPE)) {
            return true;
        }
        TypeSymbol unwrapped = type;
        int hops = 0;
        while (unwrapped.typeKind() == TypeDescKind.TYPE_REFERENCE && hops++ < 8) {
            unwrapped = ((TypeReferenceTypeSymbol) unwrapped).typeDescriptor();
        }
        if (unwrapped.typeKind() == TypeDescKind.UNION) {
            for (TypeSymbol member : ((UnionTypeSymbol) unwrapped).memberTypeDescriptors()) {
                if (involvesCaller(member, depth + 1)) {
                    return true;
                }
            }
        }
        return false;
    }

    /**
     * True if the type resolves (through references and intersections, mirroring the
     * runtime's {@code getImpliedType} use) to an error type. A UNION does not pass:
     * {@code error?} is rejected at attach and therefore rejected here too.
     */
    public static boolean isErrorType(TypeSymbol type) {
        return isErrorType(type, 0);
    }

    private static boolean isErrorType(TypeSymbol type, int depth) {
        if (depth > 8 || type == null) {
            return false;
        }
        if (type.typeKind() == TypeDescKind.ERROR) {
            return true;
        }
        if (type.typeKind() == TypeDescKind.TYPE_REFERENCE) {
            return isErrorType(((TypeReferenceTypeSymbol) type).typeDescriptor(), depth + 1);
        }
        if (type.typeKind() == TypeDescKind.INTERSECTION) {
            for (TypeSymbol constituent : ((IntersectionTypeSymbol) type).memberTypeDescriptors()) {
                if (isErrorType(constituent, depth + 1)) {
                    return true;
                }
            }
        }
        return false;
    }

    /**
     * True if the return type is a subtype of {@code error?}: nil, never, an error
     * type, or a union whose every member is one of those. (The runtime never inspects
     * return types — S6 — which is exactly why this check is load-bearing: a
     * {@code returns string} handler runs, but its failures can never become a negative
     * acknowledgement.)
     */
    public static boolean isErrorOrNilReturn(TypeSymbol type) {
        return isErrorOrNilReturn(type, 0);
    }

    private static boolean isErrorOrNilReturn(TypeSymbol type, int depth) {
        if (depth > 8 || type == null) {
            return false;
        }
        TypeDescKind kind = type.typeKind();
        if (kind == TypeDescKind.NIL || kind == TypeDescKind.NEVER || kind == TypeDescKind.ERROR) {
            return true;
        }
        if (kind == TypeDescKind.TYPE_REFERENCE) {
            return isErrorOrNilReturn(((TypeReferenceTypeSymbol) type).typeDescriptor(), depth + 1);
        }
        if (kind == TypeDescKind.UNION) {
            for (TypeSymbol member : ((UnionTypeSymbol) type).memberTypeDescriptors()) {
                if (!isErrorOrNilReturn(member, depth + 1)) {
                    return false;
                }
            }
            return true;
        }
        return false;
    }

    /** mqtt's findNode: locate the syntax node covering a line range (code actions). */
    public static NonTerminalNode findNode(SyntaxTree syntaxTree, LineRange lineRange) {
        if (lineRange == null) {
            return null;
        }
        TextDocument textDocument = syntaxTree.textDocument();
        int start = textDocument.textPositionFrom(lineRange.startLine());
        int end = textDocument.textPositionFrom(lineRange.endLine());
        return ((ModulePartNode) syntaxTree.rootNode()).findNode(TextRange.from(start, end - start), true);
    }

    /** Null-tolerant name accessor for symbols. */
    public static String nameOf(Symbol symbol) {
        return symbol == null ? "" : symbol.getName().orElse("");
    }
}
