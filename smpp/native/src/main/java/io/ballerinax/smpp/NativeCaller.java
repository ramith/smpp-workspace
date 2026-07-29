// Copyright (c) 2026. Native side of smpp:Caller — the submit_sm path.
package io.ballerinax.smpp;

import io.ballerina.runtime.api.creators.ValueCreator;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BArray;
import io.ballerina.runtime.api.values.BError;
import io.ballerina.runtime.api.values.BMap;
import io.ballerina.runtime.api.values.BObject;
import io.ballerina.runtime.api.values.BString;

import org.jsmpp.GenericNackResponseException;
import org.jsmpp.InvalidResponseException;
import org.jsmpp.PDUException;
import org.jsmpp.bean.ESMClass;
import org.jsmpp.bean.NumberingPlanIndicator;
import org.jsmpp.bean.RawDataCoding;
import org.jsmpp.bean.RegisteredDelivery;
import org.jsmpp.bean.TypeOfNumber;
import org.jsmpp.extra.NegativeResponseException;
import org.jsmpp.extra.ResponseTimeoutException;
import org.jsmpp.extra.SessionState;
import org.jsmpp.session.SMPPSession;
import org.jsmpp.session.SubmitSmResult;
import org.jsmpp.util.StringParameter;
import org.jsmpp.util.StringType;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Implements {@code smpp:Caller.submit}. Design constraints, all load-bearing:
 *
 * <ul>
 *   <li><b>Own native data, handed over once.</b> The three references this class reads
 *       ({@code SESSION_REF}, {@code STATE_REF}, {@code CONFIG}) are set on the Caller
 *       object exactly once, at {@code NativeListener.initListener} (single-threaded).
 *       The listener BObject's native-data map is a plain unsynchronized HashMap whose
 *       post-init writes are a documented data race — so this class never touches the
 *       listener object, only its own.</li>
 *   <li><b>The session is read through the {@code AtomicReference} on every submit.</b>
 *       {@code attemptRebind} swaps the referent; a cached {@code SMPPSession} would
 *       submit on a dead socket after the first rebind
 *       ({@code testSubmitSurvivesRebindOnNewSession} pins this).</li>
 *   <li><b>No {@code stateLock} on the submit path.</b> Submits take a lock-free snapshot
 *       and fail fast; holding the listener's state lock across a blocking network call
 *       would stall every stop/rebind transition behind a slow SMSC.</li>
 *   <li><b>Local validation never echoes user data.</b> jsmpp's own validator embeds the
 *       offending value in its exception message — for submit_sm that is the SMS body
 *       and the destination MSISDN, the same leak class {@code validateCredentials}
 *       exists to prevent. Pre-checks here name the field and the length, never the
 *       value; jsmpp's validator becomes a never-fires backstop. The pre-check also
 *       prevents an orphaned {@code pendingResponses} entry: a {@code PDUStringException}
 *       escapes {@code executeSendCommand}'s IOException-only catch and would leak the
 *       registered response slot on every locally-invalid submit.</li>
 *   <li><b>Limits are read from jsmpp, not transcribed.</b> {@code StringParameter}
 *       exposes {@code getMax()}/{@code getType()}; the comparisons are asymmetric
 *       (C-octet strings reject {@code length >= max} because max includes the NUL,
 *       octet strings reject {@code length > max}) — hand-copied numbers reintroduce
 *       the off-by-one this method exists to avoid.</li>
 * </ul>
 *
 * The pure static core ({@link #compose(SubmitSpec)}, {@link #mapSubmitFailure(Throwable)})
 * takes and returns plain Java values so JUnit reaches it without a Ballerina runtime
 * ({@code OutboundSmsMappingTest}, {@code SubmitErrorMappingTest}).
 */
public final class NativeCaller {

    static final String SESSION_REF = "smpp.caller.sessionRef";
    static final String STATE_REF = "smpp.caller.stateRef";
    static final String CONFIG = "smpp.caller.config";
    static final String SESSION_USABLE = "smpp.caller.sessionUsable";
    static final String SUBMITS_IN_FLIGHT = "smpp.caller.submitsInFlight";

    private NativeCaller() {}

    // ------------------------------------------------------------------
    // Pure request model (JUnit-reachable, no Ballerina values)
    // ------------------------------------------------------------------

    /** The submit request as extracted from Ballerina values — still unvalidated. */
    static final class SubmitSpec {
        String destAddr;
        String destTon = "TON_INTERNATIONAL";
        String destNpi = "NPI_ISDN";
        String sourceAddr = "";
        String sourceTon = "TON_INTERNATIONAL";
        String sourceNpi = "NPI_ISDN";
        String shortMessage;          // XOR shortMessageBytes
        String encoding = "LATIN1";   // ASCII | LATIN1 | UCS2
        byte[] shortMessageBytes;     // escape hatch; requires dataCoding
        Integer dataCoding;           // raw byte value, only with shortMessageBytes
        String registeredDelivery = "NONE";
        String serviceType = "";
        String validityPeriod;        // null = SMSC default
    }

    /** The composed jsmpp arguments — validated, encoded, ready to send. */
    static final class SubmitRequest {
        String serviceType;
        TypeOfNumber srcTon;
        NumberingPlanIndicator srcNpi;
        String srcAddr;
        TypeOfNumber dstTon;
        NumberingPlanIndicator dstNpi;
        String dstAddr;
        byte esmClass;
        byte protocolId;
        byte priorityFlag;
        String scheduleDeliveryTime;  // always null: not part of the public surface
        String validityPeriod;
        byte registeredDelivery;
        byte replaceIfPresent;
        byte dataCoding;
        byte smDefaultMsgId;
        byte[] body;
    }

    /** A locally-refused submit: nothing reached the wire. Message never echoes data. */
    static final class InvalidRequest extends Exception {
        InvalidRequest(String message) {
            super(message);
        }
    }

    /** Pure mapping result for a failed submit — wrapped into smpp:Error by the extern. */
    static final class MappedFailure {
        final String message;
        final String failureMode;
        final Integer commandStatus;

        MappedFailure(String message, String failureMode, Integer commandStatus) {
            this.message = message;
            this.failureMode = failureMode;
            this.commandStatus = commandStatus;
        }
    }

    // ------------------------------------------------------------------
    // Pure core
    // ------------------------------------------------------------------

    /**
     * Validates and encodes a spec into jsmpp arguments. Throws {@link InvalidRequest}
     * (→ {@code failureMode: INVALID_REQUEST}) without echoing user data.
     */
    static SubmitRequest compose(SubmitSpec spec) throws InvalidRequest {
        SubmitRequest req = new SubmitRequest();

        // --- body: exactly one of shortMessage / shortMessageBytes ---
        boolean hasText = spec.shortMessage != null;
        boolean hasBytes = spec.shortMessageBytes != null;
        if (hasText == hasBytes) {
            throw new InvalidRequest(hasText
                    ? "OutboundSms must set exactly one of shortMessage or shortMessageBytes, not both"
                    : "OutboundSms must set one of shortMessage or shortMessageBytes");
        }
        if (hasBytes) {
            if (spec.dataCoding == null) {
                throw new InvalidRequest("shortMessageBytes requires dataCoding (the raw data_coding "
                        + "byte for the pre-encoded payload)");
            }
            if (spec.dataCoding < 0 || spec.dataCoding > 0xFF) {
                throw new InvalidRequest("dataCoding must be 0-255, got " + spec.dataCoding);
            }
            req.body = spec.shortMessageBytes;
            req.dataCoding = (byte) (int) spec.dataCoding;
        } else {
            if (spec.dataCoding != null) {
                throw new InvalidRequest("dataCoding is only for shortMessageBytes; with shortMessage "
                        + "the encoding field decides the data_coding");
            }
            req.body = encode(spec.shortMessage, spec.encoding);
            req.dataCoding = switch (spec.encoding) {
                case "ASCII" -> 0x01;
                case "LATIN1" -> 0x03;
                case "UCS2" -> 0x08;
                default -> throw new InvalidRequest("unknown encoding: " + spec.encoding);
            };
        }
        int max = maxLength(StringParameter.SHORT_MESSAGE);
        if (req.body.length > max) {
            throw new InvalidRequest("short message is " + req.body.length
                    + " octets encoded; a single submit_sm carries at most " + max);
        }

        // --- addresses ---
        req.dstAddr = required(spec.destAddr, "destAddr");
        checkLength("destAddr", req.dstAddr, StringParameter.DESTINATION_ADDR);
        req.dstTon = ton(spec.destTon, "destAddr.ton");
        req.dstNpi = npi(spec.destNpi, "destAddr.npi");
        req.srcAddr = spec.sourceAddr == null ? "" : spec.sourceAddr;
        checkLength("sourceAddr", req.srcAddr, StringParameter.SOURCE_ADDR);
        if (req.srcAddr.isEmpty()) {
            // SMPP v3.4 section 4.4.1: a NULL source address and its TON/NPI move
            // together - "if not known, set to NULL (Unknown)". An empty address tagged
            // INTERNATIONAL/ISDN (the Address defaults) is internally inconsistent and a
            // plausible ESME_RINVSRCADR/ESME_RINVSRCTON on strict SMSCs (protocol audit).
            req.srcTon = TypeOfNumber.UNKNOWN;
            req.srcNpi = NumberingPlanIndicator.UNKNOWN;
        } else {
            req.srcTon = ton(spec.sourceTon, "sourceAddr.ton");
            req.srcNpi = npi(spec.sourceNpi, "sourceAddr.npi");
        }

        // --- the rest ---
        req.serviceType = spec.serviceType == null ? "" : spec.serviceType;
        checkLength("serviceType", req.serviceType, StringParameter.SERVICE_TYPE);
        req.validityPeriod = spec.validityPeriod;
        if (req.validityPeriod != null) {
            // VALIDITY_PERIOD is the one pre-checked parameter with isRangeMinAndMax ==
            // false: jsmpp (correctly modelling SMPP v3.4 section 7.1.1) accepts only the
            // empty string or EXACTLY 16 characters - a range check here would let a
            // 1-15 char value through to jsmpp's validator, which throws AFTER
            // pendingResponses.put (orphaning the entry) and echoes the raw value
            // (protocol-audit finding, 2026-07-29). Validate the exact shape locally,
            // naming nothing but the field.
            if (!isValidSmppTime(req.validityPeriod)) {
                throw new InvalidRequest("validityPeriod must be empty or exactly 16 "
                        + "characters in the SMPP time format YYMMDDhhmmsstnnp "
                        + "(section 7.1.1), e.g. absolute 240115143000000+ or relative "
                        + "000000020000000R");
            }
        }
        req.registeredDelivery = switch (spec.registeredDelivery) {
            case "NONE" -> 0x00;
            case "ON_SUCCESS_OR_FAILURE" -> 0x01;
            case "ON_FAILURE_ONLY" -> 0x02;
            default -> throw new InvalidRequest("unknown registeredDelivery: " + spec.registeredDelivery);
        };
        // Locked to plain point-to-point defaults. esm_class especially: a nonzero value
        // is invisible in a happy-path test yet changes SMSC routing and billing.
        req.esmClass = 0x00;
        req.protocolId = 0x00;
        req.priorityFlag = 0x00;
        req.scheduleDeliveryTime = null;
        req.replaceIfPresent = 0x00;
        req.smDefaultMsgId = 0x00;
        return req;
    }

    /**
     * Encodes text for the wire, rejecting (never silently substituting) unencodable
     * characters. {@code String.getBytes(ISO_8859_1)} replaces what it cannot encode
     * with {@code ?} — a subscriber-visible corruption — so encodability is checked
     * per UTF-16 code unit and the failure names the index, not the character.
     */
    static byte[] encode(String text, String encoding) throws InvalidRequest {
        switch (encoding) {
            case "ASCII" -> {
                for (int i = 0; i < text.length(); i++) {
                    if (text.charAt(i) > 0x7F) {
                        throw new InvalidRequest("shortMessage contains a character not representable "
                                + "in ASCII at index " + i + "; use LATIN1, UCS2, or shortMessageBytes");
                    }
                }
                return text.getBytes(StandardCharsets.US_ASCII);
            }
            case "LATIN1" -> {
                for (int i = 0; i < text.length(); i++) {
                    if (text.charAt(i) > 0xFF) {
                        throw new InvalidRequest("shortMessage contains a character not representable "
                                + "in Latin-1 at index " + i + "; use UCS2 or shortMessageBytes");
                    }
                }
                return text.getBytes(StandardCharsets.ISO_8859_1);
            }
            case "UCS2" -> {
                // UTF-16BE: two octets per UTF-16 code unit - surrogate pairs (emoji)
                // count as two units, i.e. four octets. The octet limit is what the
                // boundary test pins (127 code units = 254 octets).
                return text.getBytes(StandardCharsets.UTF_16BE);
            }
            default -> throw new InvalidRequest("unknown encoding: " + encoding);
        }
    }

    /**
     * Maps every failure the submit path can produce onto a {@code FailureMode}, in an
     * order that respects the jsmpp exception hierarchy (verified against 3.0.2):
     * {@code GenericNackResponseException extends InvalidResponseException} and carries a
     * real command_status, so it must match first; {@code PDUStringException extends
     * PDUException}. Terminates in a {@code Throwable} branch because two known escapes
     * are unchecked — the {@code (SubmitSmResp)} cast in {@code SMPPSession.java:378} can
     * {@code ClassCastException}, and {@code DefaultPDUSender} has seven unguarded derefs
     * — and {@code QueueException}/{@code QueueMaxException} are unchecked with no
     * checked branch of their own (D3).
     */
    static MappedFailure mapSubmitFailure(Throwable t) {
        String msg = t.getMessage() != null ? t.getMessage() : t.getClass().getSimpleName();
        if (t instanceof InvalidRequest) {
            return new MappedFailure(msg, "INVALID_REQUEST", null);
        }
        if (t instanceof NegativeResponseException e) {
            return new MappedFailure("SMSC rejected the submit: " + msg, "REJECTED", e.getCommandStatus());
        }
        if (t instanceof GenericNackResponseException e) {
            // Before InvalidResponseException: it is a subclass, and unlike its parent it
            // carries the SMSC's actual command_status - a generic_nack IS a rejection.
            return new MappedFailure("SMSC answered generic_nack: " + msg, "REJECTED", e.getCommandStatus());
        }
        if (t instanceof ResponseTimeoutException) {
            return new MappedFailure("no submit_sm_resp within transactionTimeout: " + msg
                    + " (the SMSC may still have accepted the message - retrying may duplicate it)",
                    "TIMEOUT_DELIVERY_UNKNOWN", null);
        }
        if (t instanceof InvalidResponseException) {
            return new MappedFailure("invalid submit_sm_resp: " + msg, "PROTOCOL_ERROR", null);
        }
        if (t instanceof PDUException) {
            // Includes PDUStringException - jsmpp's own validator, which compose()'s
            // pre-checks make a never-fires backstop.
            return new MappedFailure("jsmpp rejected the request PDU: " + msg, "INVALID_REQUEST", null);
        }
        if (t instanceof IOException) {
            return new MappedFailure("connection failed mid-submit: " + msg
                    + " (delivery unknown; the listener is rebinding if the link dropped)",
                    "LINK_DOWN", null);
        }
        return new MappedFailure("unexpected failure in the submit path: "
                + t.getClass().getSimpleName() + ": " + msg, "PROTOCOL_ERROR", null);
    }

    // ------------------------------------------------------------------
    // The extern
    // ------------------------------------------------------------------

    /**
     * {@code smpp:Caller.submit}. Lock-free pre-checks (lifecycle, bind type, session
     * liveness), then compose → send → wrap. Never panics: every failure returns a typed
     * {@code smpp:Error} with {@code ErrorDetail} populated.
     */
    public static Object submit(BObject caller, BMap<BString, Object> sms) {
        @SuppressWarnings("unchecked")
        AtomicReference<NativeListener.ListenerState> stateRef =
                (AtomicReference<NativeListener.ListenerState>) caller.getNativeData(STATE_REF);
        @SuppressWarnings("unchecked")
        AtomicReference<SMPPSession> sessionRef =
                (AtomicReference<SMPPSession>) caller.getNativeData(SESSION_REF);
        @SuppressWarnings("unchecked")
        BMap<BString, Object> config = (BMap<BString, Object>) caller.getNativeData(CONFIG);

        // Pre-check 1: lifecycle. STOPPING is deliberately ALLOWED (owner decision,
        // 2026-07-29): gracefulStop drains in-flight handlers, and rejecting submits
        // from the very handlers being drained would drop every reply-style service's
        // replies on shutdown. Submits stay legal until the session actually unbinds;
        // the drain tracks them (submitsInFlight below).
        NativeListener.ListenerState st = stateRef.get();
        if (st == NativeListener.ListenerState.INIT || st == NativeListener.ListenerState.STARTING) {
            return detailError("cannot submit: the listener has not started yet - call 'start() first",
                    "INVALID_REQUEST", null);
        }
        if (st == NativeListener.ListenerState.STOPPED) {
            return detailError("cannot submit: the listener has been stopped", "INVALID_REQUEST", null);
        }

        // Pre-check 2: bind type. Deliberately names the config field and the fix, and
        // never says BOUND_RX - jsmpp's own ensureTransmittable would throw a bare
        // IOException here, which is exactly what this guard exists to improve on.
        String bindType = config.getStringValue(StringUtils.fromString("bindType")).getValue();
        if (!"TRANSCEIVER".equals(bindType)) {
            return detailError("cannot submit on a RECEIVER bind: submitting requires "
                    + "bindType: TRANSCEIVER in the ConnectionConfig", "INVALID_REQUEST", null);
        }

        // Pre-check 3: session liveness. Two signals, both required:
        // - sessionUsable is the connector's OWN drop decision (set false in
        //   onUnexpectedDrop, true at install). It is what makes the wedge visible here:
        //   a wedged session still CLAIMS BOUND_TRX forever, so getSessionState() alone
        //   would accept submits onto a dead socket for the whole rebind window
        //   (architecture-review finding #3).
        // - getSessionState() covers the inverse sliver (a stop closed the session but
        //   the flag flip has not been observed yet).
        // Classified LINK_DOWN, not INVALID_REQUEST (owner decision, 2026-07-29): an
        // already-down link and a mid-submit link death are the same operational
        // condition and must land in one FailureMode bucket. The wording promises
        // nothing a disabled/exhausted rebind cannot deliver (D8).
        @SuppressWarnings("unchecked")
        java.util.concurrent.atomic.AtomicBoolean usable =
                (java.util.concurrent.atomic.AtomicBoolean) caller.getNativeData(SESSION_USABLE);
        @SuppressWarnings("unchecked")
        java.util.concurrent.atomic.AtomicInteger submitsInFlight =
                (java.util.concurrent.atomic.AtomicInteger) caller.getNativeData(SUBMITS_IN_FLIGHT);
        // RESERVATION ORDER (Phase 5 finding #2): increment FIRST, then check liveness.
        // The other order is a TOCTOU: a submit passing the check could still be between
        // check and increment when awaitDrain reads 0 and stop() unbinds under it. With
        // increment-first, either the drain sees us, or we see the usable=false flip that
        // stop() makes before its post-flip sweep - never neither.
        submitsInFlight.incrementAndGet();
        try {
            SMPPSession session = sessionRef.get();
            if (session == null || !usable.get()
                    || session.getSessionState() != SessionState.BOUND_TRX) {
                return detailError("cannot submit: the SMSC session is down"
                        + " (rebinding runs per rebindPolicy, if enabled)", "LINK_DOWN", null);
            }
            SubmitSpec spec = specFrom(sms, config);
            SubmitRequest req = compose(spec);
            SubmitSmResult result;
            ConnectorSession.enterSubmitContext();
            try {
                result = session.submitShortMessage(
                        req.serviceType,
                        req.srcTon, req.srcNpi, req.srcAddr,
                        req.dstTon, req.dstNpi, req.dstAddr,
                        new ESMClass(req.esmClass), req.protocolId, req.priorityFlag,
                        req.scheduleDeliveryTime, req.validityPeriod,
                        new RegisteredDelivery(req.registeredDelivery), req.replaceIfPresent,
                        new RawDataCoding(req.dataCoding), req.smDefaultMsgId,
                        req.body);
            } finally {
                ConnectorSession.exitSubmitContext();
            }
            BMap<BString, Object> out = ValueCreator.createRecordValue(
                    ModuleUtils.getModule(), "SubmitResult");
            String messageId = result == null || result.getMessageId() == null
                    ? "" : result.getMessageId();
            out.put(StringUtils.fromString("messageId"), StringUtils.fromString(messageId));
            return out;
        } catch (Exception e) {
            // Exception, not Throwable: every failure D3 named is an Exception, and a
            // VirtualMachineError must panic, not become a returned smpp:Error. specFrom
            // is inside this net too, so a malformed BMap cannot panic across interop.
            MappedFailure f = mapSubmitFailure(e);
            return detailError(f.message, f.failureMode, f.commandStatus);
        } finally {
            // The one decrement, on every path incl. throws - a leaked count would make
            // every later gracefulStop burn its full timeout (Phase 5 finding #7).
            submitsInFlight.decrementAndGet();
        }
    }

    // ------------------------------------------------------------------
    // Ballerina-value plumbing
    // ------------------------------------------------------------------

    private static BError detailError(String message, String failureMode, Integer commandStatus) {
        Map<String, Object> detail = new HashMap<>();
        detail.put("failureMode", failureMode);
        if (commandStatus != null) {
            detail.put("commandStatus", (long) (int) commandStatus);
        }
        return ModuleUtils.createError(message, detail);
    }

    /** Unpacks OutboundSms (+ the config's default sourceAddr) into a pure SubmitSpec. */
    private static SubmitSpec specFrom(BMap<BString, Object> sms, BMap<BString, Object> config)
            throws InvalidRequest {
        SubmitSpec spec = new SubmitSpec();

        Object dest = sms.get(StringUtils.fromString("destAddr"));
        applyAddress(spec, dest, true);

        Object src = sms.get(StringUtils.fromString("sourceAddr"));
        if (src == null) {
            // Per-message omission falls back to the binding-level default; an empty
            // value there means "send no source address", which is spec-legal.
            src = config.getMapValue(StringUtils.fromString("sourceAddr"));
        }
        applyAddress(spec, src, false);

        BString text = sms.getStringValue(StringUtils.fromString("shortMessage"));
        spec.shortMessage = text == null ? null : text.getValue();
        spec.encoding = str(sms, "encoding", "LATIN1");
        Object bytes = sms.get(StringUtils.fromString("shortMessageBytes"));
        spec.shortMessageBytes = bytes == null ? null : ((BArray) bytes).getBytes();
        Object dc = sms.get(StringUtils.fromString("dataCoding"));
        if (dc != null) {
            long dcLong = (Long) dc;
            // Range-check BEFORE narrowing: (int) 4294967296L is 0, which would silently
            // send data_coding 0x00 instead of erroring (concurrency-review finding #6).
            if (dcLong < 0 || dcLong > 0xFF) {
                throw new InvalidRequest("dataCoding must be 0-255, got " + dcLong);
            }
            spec.dataCoding = (int) dcLong;
        }
        spec.registeredDelivery = str(sms, "registeredDelivery", "NONE");
        spec.serviceType = str(sms, "serviceType", "");
        BString validity = sms.getStringValue(StringUtils.fromString("validityPeriod"));
        spec.validityPeriod = validity == null ? null : validity.getValue();
        return spec;
    }

    /** string|Address → the spec's addr/ton/npi triple. */
    @SuppressWarnings("unchecked")
    private static void applyAddress(SubmitSpec spec, Object value, boolean isDest)
            throws InvalidRequest {
        String addr;
        String tonName = "TON_INTERNATIONAL";
        String npiName = "NPI_ISDN";
        if (value == null) {
            if (isDest) {
                throw new InvalidRequest("destAddr is required");
            }
            addr = "";
        } else if (value instanceof BString s) {
            addr = s.getValue();
        } else {
            BMap<BString, Object> rec = (BMap<BString, Object>) value;
            addr = rec.getStringValue(StringUtils.fromString("value")).getValue();
            tonName = rec.getStringValue(StringUtils.fromString("ton")).getValue();
            npiName = rec.getStringValue(StringUtils.fromString("npi")).getValue();
        }
        if (isDest) {
            spec.destAddr = addr;
            spec.destTon = tonName;
            spec.destNpi = npiName;
        } else {
            spec.sourceAddr = addr;
            spec.sourceTon = tonName;
            spec.sourceNpi = npiName;
        }
    }

    private static String str(BMap<BString, Object> map, String key, String fallback) {
        BString v = map.getStringValue(StringUtils.fromString(key));
        return v == null ? fallback : v.getValue();
    }

    private static String required(String value, String field) throws InvalidRequest {
        if (value == null || value.isEmpty()) {
            throw new InvalidRequest(field + " is required and must not be empty");
        }
        return value;
    }

    /**
     * SMPP v3.4 section 7.1.1 time format: 15 digits then one of {@code + - R}. jsmpp's
     * StringValidator only checks the length (0 or exactly 16); the shape check here is
     * stricter so a malformed-but-16-char value fails locally (non-echoing) instead of
     * drawing ESME_RINVEXPIRY from the SMSC.
     */
    static boolean isValidSmppTime(String value) {
        if (value.isEmpty()) {
            return true;
        }
        if (value.length() != 16) {
            return false;
        }
        for (int i = 0; i < 15; i++) {
            char c = value.charAt(i);
            if (c < '0' || c > '9') {
                return false;
            }
        }
        char last = value.charAt(15);
        return last == '+' || last == '-' || last == 'R';
    }

    /**
     * jsmpp's limit for the parameter, adjusted for the C-octet asymmetry: a C-octet
     * string's max INCLUDES the terminating NUL (its validator rejects
     * {@code length >= max}), an octet string's does not (rejects {@code > max}).
     */
    static int maxLength(StringParameter p) {
        return p.getType() == StringType.C_OCTET_STRING ? p.getMax() - 1 : p.getMax();
    }

    private static void checkLength(String field, String value, StringParameter p)
            throws InvalidRequest {
        int max = maxLength(p);
        if (value.length() > max) {
            // Names the field and lengths only - the value may be an MSISDN.
            throw new InvalidRequest(field + " is " + value.length()
                    + " characters; the SMPP limit is " + max);
        }
    }

    private static TypeOfNumber ton(String name, String field) throws InvalidRequest {
        // The Ballerina Ton enum's values equal its member names (TON_INTERNATIONAL), so
        // Config.toml matches the docs and jsmpp's identifier spelling stays OUT of the
        // published contract (owner decision, 2026-07-29). Stripping the prefix here is
        // the entire jsmpp mapping.
        try {
            return TypeOfNumber.valueOf(stripPrefix(name, "TON_", field));
        } catch (IllegalArgumentException e) {
            throw new InvalidRequest(field + ": unknown type-of-number '" + name + "'");
        }
    }

    private static NumberingPlanIndicator npi(String name, String field) throws InvalidRequest {
        try {
            return NumberingPlanIndicator.valueOf(stripPrefix(name, "NPI_", field));
        } catch (IllegalArgumentException e) {
            throw new InvalidRequest(field + ": unknown numbering-plan indicator '" + name + "'");
        }
    }

    private static String stripPrefix(String name, String prefix, String field) throws InvalidRequest {
        if (!name.startsWith(prefix)) {
            throw new InvalidRequest(field + ": unknown value '" + name + "'");
        }
        return name.substring(prefix.length());
    }
}
