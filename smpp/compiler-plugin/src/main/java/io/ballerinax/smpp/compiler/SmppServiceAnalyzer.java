// Copyright (c) 2026. Registers the service-shape analysis task.
package io.ballerinax.smpp.compiler;

import io.ballerina.compiler.syntax.tree.SyntaxKind;
import io.ballerina.projects.plugins.CodeAnalysisContext;
import io.ballerina.projects.plugins.CodeAnalyzer;

import java.util.List;

/**
 * Registers {@link SmppServiceValidator} for BOTH syntactic forms an smpp service can
 * take. ftp and mqtt register only {@code SERVICE_DECLARATION}; copying that would
 * leave the {@code service class X { *smpp:Service; }} + explicit-{@code attach} idiom
 * — the reusable-handler form this repo's own test suite uses throughout — completely
 * unvalidated (Sprint 9 Phase-1 finding 2c).
 */
public class SmppServiceAnalyzer extends CodeAnalyzer {

    @Override
    public void init(CodeAnalysisContext codeAnalysisContext) {
        codeAnalysisContext.addSyntaxNodeAnalysisTask(new SmppServiceValidator(),
                List.of(SyntaxKind.SERVICE_DECLARATION, SyntaxKind.CLASS_DEFINITION));
    }
}
