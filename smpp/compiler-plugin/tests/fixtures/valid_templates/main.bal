// BYTE-FOR-BYTE the five code-action templates (HandlerTemplateCodeAction.template()),
// as inserted into services: pins that the generated text compiles clean and
// warning-free in a fresh consumer project (Phase-5 finding M2). If you change the
// template strings, change this fixture to match - a drift fails loudly either way
// (template that no longer compiles -> this fixture never notices, BUT template text
// lives in one method and this file is named in its javadoc; a fixture that no longer
// compiles -> harness FAIL).
import ramith/smpp;

listener smpp:Listener lis = new ({host: "localhost", systemId: "x", password: "y", bindType: smpp:TRANSCEIVER});

service on lis {
	remote function onDeliverSm(smpp:Sms sms) returns error? {

	}

	remote function onDataSm(smpp:Sms sms, smpp:Caller caller) returns error? {
		smpp:SubmitResult _ = check caller->submit({
			destAddr: sms.sourceAddr,
			shortMessage: "TODO: reply"
		});
	}

	remote function onError(smpp:Error smppError) returns error? {

	}
}
