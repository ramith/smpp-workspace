// Copyright (c) 2026. Entry point: registered via ballerina/CompilerPlugin.toml.
package io.ballerinax.smpp.compiler;

import io.ballerina.projects.plugins.CompilerPlugin;
import io.ballerina.projects.plugins.CompilerPluginContext;

import static io.ballerinax.smpp.compiler.PluginConstants.ON_DATA_SM;
import static io.ballerinax.smpp.compiler.PluginConstants.ON_DELIVER_SM;
import static io.ballerinax.smpp.compiler.PluginConstants.ON_ERROR;

/**
 * The smpp compiler plugin: compile-time service-shape validation plus handler code
 * actions. Runs in every consumer project that imports {@code ramith/smpp} (the jar
 * ships inside the bala); it never runs while building this package itself.
 *
 * <p>Five templates, not mqtt's two: mqtt has one dispatchable handler, smpp has three
 * recognized methods, so the action set is onDeliverSm ± caller, onDataSm ± caller, and
 * onError (Sprint 9 Phase-1 finding 2a). All anchor on {@code SMPP_101} — the "service
 * implements no smpp handler" diagnostic an empty {@code service on smppListener {}}
 * lands on, which is exactly the moment a user discovers the opt-in Caller parameter
 * through their editor rather than the docs.
 */
public class SmppCompilerPlugin extends CompilerPlugin {

    @Override
    public void init(CompilerPluginContext context) {
        context.addCodeAnalyzer(new SmppServiceAnalyzer());
        context.addCodeAction(new HandlerTemplateCodeAction(ON_DELIVER_SM, false));
        context.addCodeAction(new HandlerTemplateCodeAction(ON_DELIVER_SM, true));
        context.addCodeAction(new HandlerTemplateCodeAction(ON_DATA_SM, false));
        context.addCodeAction(new HandlerTemplateCodeAction(ON_DATA_SM, true));
        context.addCodeAction(new HandlerTemplateCodeAction(ON_ERROR, false));
    }
}
