// Copyright (c) 2026. Bridges jsmpp receive callbacks into the Ballerina runtime.
package io.ballerinax.smpp;

import io.ballerina.runtime.api.Runtime;
import io.ballerina.runtime.api.concurrent.StrandMetadata;
import io.ballerina.runtime.api.creators.ValueCreator;
import io.ballerina.runtime.api.types.MethodType;
import io.ballerina.runtime.api.types.ObjectType;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.utils.TypeUtils;
import io.ballerina.runtime.api.values.BError;
import io.ballerina.runtime.api.values.BMap;
import io.ballerina.runtime.api.values.BObject;
import io.ballerina.runtime.api.values.BString;

import org.jsmpp.PDUStringException;
import org.jsmpp.SMPPConstant;
import org.jsmpp.bean.AbstractSmCommand;
import org.jsmpp.bean.AlertNotification;
import org.jsmpp.bean.DataSm;
import org.jsmpp.bean.DeliverSm;
import org.jsmpp.bean.OptionalParameter;
import org.jsmpp.extra.ProcessRequestException;
import org.jsmpp.session.DataSmResult;
import org.jsmpp.session.MessageReceiverListener;
import org.jsmpp.session.Session;
import org.jsmpp.util.MessageId;

import java.nio.charset.StandardCharsets;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Implements the jsmpp {@link MessageReceiverListener}. jsmpp invokes these
 * callbacks from one of its own PDU processor threads (sized by
 * {@code ConnectionConfig.maxConcurrentDispatch}); each PDU is converted to an
 * {@code smpp:Sms} record and dispatched to the attached Ballerina service via
 * {@link Runtime#callMethod}. {@code ConnectionConfig.responseMode} controls how:
 * in {@code SYNC} mode (the default) the call blocks the jsmpp thread, so the
 * {@code deliver_sm_resp}/{@code data_sm_resp} jsmpp sends back to the SMSC
 * reflects the service's real outcome and jsmpp's own bounded work queue can
 * apply backpressure; in {@code ASYNC} mode the call runs on a virtual thread
 * and the PDU is acknowledged immediately, before the service has run.
 */
public class Dispatcher implements MessageReceiverListener {

    private static final String ON_DELIVER_SM = "onDeliverSm";
    private static final String ON_DATA_SM = "onDataSm";
    private static final String ON_ERROR = "onError";

    /**
     * The {@code message_id} returned with every {@code data_sm_resp}. DATA_SM has no
     * submit queue behind it in this connector, so there is no application-assigned id to
     * report; an empty {@code MessageId} is used instead of {@code null} - jsmpp's own PDU
     * sender unconditionally calls {@code getCommandStatus()}/{@code getMessageId()} on
     * whatever {@link #onAcceptDataSm} returns, so a {@code null} result is a guaranteed NPE.
     */
    private static final MessageId EMPTY_MESSAGE_ID = emptyMessageId();

    private static MessageId emptyMessageId() {
        try {
            return new MessageId("");
        } catch (PDUStringException e) {
            // MessageId validates against StringParameter.MESSAGE_ID, a plain max-length
            // (65) check with no minimum - an empty string can never fail it. Unreachable
            // in practice; only guarded because MessageId's constructor declares a checked
            // exception.
            throw new AssertionError("unreachable: an empty MessageId must always be valid", e);
        }
    }

    /**
     * Immutable (service, remote-method-set) pair published through a single volatile
     * reference, so a PDU thread can never observe a torn attach/detach (the new
     * service paired with the old method set, or vice versa).
     */
    private record ServiceBinding(BObject service, Set<String> remoteMethods) { }

    enum AttachResult { ATTACHED, ALREADY_ATTACHED, NO_REMOTE_METHODS }

    private final Runtime runtime;
    private volatile ServiceBinding binding; // null = no service attached
    private volatile boolean async = false;
    private final AtomicInteger inFlight = new AtomicInteger(0);

    public Dispatcher(Runtime runtime) {
        this.runtime = runtime;
    }

    int inFlightCount() {
        return inFlight.get();
    }

    /**
     * Notifies the attached service's optional {@code onError} remote method, e.g. on an
     * unexpected SMPP session drop. Falls back to a stack trace on stderr if the service
     * doesn't implement {@code onError}. Runs on its own virtual thread: unlike PDU dispatch,
     * there's no {@code deliver_sm_resp}/{@code data_sm_resp} timing contract to preserve here,
     * so there's no reason to block the caller (typically one of jsmpp's own threads).
     *
     * @param message a description of what went wrong
     */
    void dispatchError(String message) {
        ServiceBinding binding = this.binding;
        BError err = ModuleUtils.createError(message);
        if (binding == null || !binding.remoteMethods().contains(ON_ERROR)) {
            err.printStackTrace();
            return;
        }
        StrandMetadata meta = new StrandMetadata(false, null);
        // Incremented before the virtual thread starts (same as the ASYNC dispatch path)
        // so a gracefulStop beginning immediately after this call already sees it and
        // its drain genuinely covers the in-flight onError notification.
        inFlight.incrementAndGet();
        Thread.startVirtualThread(() -> {
            try {
                Object result = runtime.callMethod(binding.service(), ON_ERROR, meta, err);
                if (result instanceof BError callbackErr) {
                    callbackErr.printStackTrace();
                }
            } finally {
                inFlight.decrementAndGet();
            }
        });
    }

    void setAsync(boolean async) {
        this.async = async;
    }

    BObject getService() {
        ServiceBinding b = this.binding;
        return b == null ? null : b.service();
    }

    /**
     * Validates before assigning (Sprint 1 semantics preserved): every rejection path
     * returns with NO state change, so a rejected attach can never disturb a previously
     * attached, valid service. Synchronized so two concurrent attaches can't both pass
     * the already-attached check; the hot read path (dispatch) stays a single volatile
     * read.
     */
    synchronized AttachResult attach(BObject service) {
        if (this.binding != null) {
            return AttachResult.ALREADY_ATTACHED;
        }
        Set<String> names = new HashSet<>();
        ObjectType objType = (ObjectType) TypeUtils.getReferredType(TypeUtils.getType(service));
        for (MethodType method : objType.getMethods()) {
            names.add(method.getName());
        }
        if (!names.contains(ON_DELIVER_SM) && !names.contains(ON_DATA_SM)
                && !names.contains(ON_ERROR)) {
            return AttachResult.NO_REMOTE_METHODS;
        }
        this.binding = new ServiceBinding(service, Set.copyOf(names));
        return AttachResult.ATTACHED;
    }

    /** Clears the binding only if {@code expected} is the currently attached service (identity). */
    synchronized void detachIf(BObject expected) {
        ServiceBinding b = this.binding;
        if (b != null && b.service() == expected) {
            this.binding = null;
        }
    }

    @Override
    public void onAcceptDeliverSm(DeliverSm deliverSm) throws ProcessRequestException {
        dispatch(ON_DELIVER_SM, toSms(deliverSm, deliverSm.getShortMessage(), deliverSm.isSmscDeliveryReceipt()));
    }

    @Override
    public DataSmResult onAcceptDataSm(DataSm dataSm, Session source) throws ProcessRequestException {
        // DATA_SM has no short_message field at all (unlike DELIVER_SM) - its payload is
        // always carried in the message_payload optional parameter (TLV), if present.
        dispatch(ON_DATA_SM, toSms(dataSm, new byte[0], false));
        return new DataSmResult(EMPTY_MESSAGE_ID, new OptionalParameter[0]);
    }

    @Override
    public void onAcceptAlertNotification(AlertNotification alertNotification) {
        // No corresponding service method exposed yet; ignored.
    }

    /**
     * Per the SMPP spec, {@code short_message} and {@code message_payload} are mutually
     * exclusive; when a PDU carries both, {@code message_payload} takes precedence. Used for
     * both {@code DELIVER_SM} (where {@code fallback} is {@code getShortMessage()}) and
     * {@code DATA_SM} (where {@code fallback} is empty, since DATA_SM has no short_message).
     *
     * @param pdu the PDU to check for a message_payload TLV
     * @param fallback the bytes to use if no message_payload TLV is present
     * @return the resolved payload bytes
     */
    // package-private (not private): exercised directly by DispatcherTest, a pure-logic
    // JUnit suite that needs no jsmpp session or Ballerina runtime.
    static byte[] payloadBytes(AbstractSmCommand pdu, byte[] fallback) {
        OptionalParameter.Message_payload payload =
                pdu.getOptionalParameter(OptionalParameter.Message_payload.class);
        return payload != null ? payload.getValue() : fallback;
    }

    private BMap<BString, Object> toSms(AbstractSmCommand pdu, byte[] shortMessage, boolean deliveryReceipt) {
        BMap<BString, Object> sms = ValueCreator.createRecordValue(ModuleUtils.getModule(), "Sms");
        sms.put(StringUtils.fromString("sourceAddr"), StringUtils.fromString(nullSafe(pdu.getSourceAddr())));
        sms.put(StringUtils.fromString("destAddr"), StringUtils.fromString(nullSafe(pdu.getDestAddress())));
        byte[] body = payloadBytes(pdu, shortMessage);
        sms.put(StringUtils.fromString("shortMessage"),
                StringUtils.fromString(decodeShortMessage(body, pdu.getDataCoding())));
        // clone(): createArrayValue wraps (doesn't copy) the array, and jsmpp's bean
        // getters return their internal arrays - don't let the user-visible record share
        // a buffer with jsmpp internals, even though no post-dispatch mutator exists today.
        sms.put(StringUtils.fromString("shortMessageBytes"), ValueCreator.createArrayValue(body.clone()));
        sms.put(StringUtils.fromString("deliveryReceipt"), deliveryReceipt);
        sms.put(StringUtils.fromString("properties"), toProperties(pdu));
        return sms;
    }

    /**
     * Decodes {@code short_message}/{@code message_payload} bytes according to the PDU's
     * {@code data_coding}. Only the unambiguous single-byte-per-character encodings are
     * decoded precisely; GSM 7-bit default alphabet (data_coding 0x00) and any other/unknown
     * value fall back to UTF-8, since jsmpp's main library ships no GSM 03.38 codec and
     * whether an SMSC sends packed 7-bit septets or one byte per character over SMPP varies
     * by vendor — guessing risks a different, subtler bug than the one being fixed here. The
     * raw {@code dataCoding} value is always surfaced via {@code Sms.properties} so a service
     * can decode it itself when the default doesn't match its SMSC.
     *
     * @param bytes the raw PDU payload bytes
     * @param dataCoding the PDU's {@code data_coding} value
     * @return the decoded text
     */
    // package-private (not private): exercised directly by DispatcherTest, a pure-logic
    // JUnit suite that needs no jsmpp session or Ballerina runtime.
    static String decodeShortMessage(byte[] bytes, byte dataCoding) {
        if (bytes == null || bytes.length == 0) {
            return "";
        }
        return switch (dataCoding & 0xFF) {
            case 0x01 -> new String(bytes, StandardCharsets.US_ASCII);   // IA5/ASCII
            case 0x03 -> new String(bytes, StandardCharsets.ISO_8859_1); // Latin-1
            case 0x08 -> new String(bytes, StandardCharsets.UTF_16BE);   // UCS2
            default -> new String(bytes, StandardCharsets.UTF_8);
        };
    }

    /**
     * Surfaces PDU metadata that isn't promoted to a typed {@code Sms} field: the raw
     * {@code data_coding}, source/dest TON/NPI, the raw {@code esm_class} byte, and the
     * UDHI (User Data Header Indicator) flag — signals a concatenated/binary short message,
     * which this connector does not reassemble.
     *
     * @param pdu the PDU to read metadata from
     * @return a {@code map<anydata>} suitable for {@code Sms.properties}
     */
    private BMap<BString, Object> toProperties(AbstractSmCommand pdu) {
        BMap<BString, Object> properties = ValueCreator.createMapValue();
        properties.put(StringUtils.fromString("dataCoding"), (long) (pdu.getDataCoding() & 0xFF));
        properties.put(StringUtils.fromString("sourceAddrTon"), (long) (pdu.getSourceAddrTon() & 0xFF));
        properties.put(StringUtils.fromString("sourceAddrNpi"), (long) (pdu.getSourceAddrNpi() & 0xFF));
        properties.put(StringUtils.fromString("destAddrTon"), (long) (pdu.getDestAddrTon() & 0xFF));
        properties.put(StringUtils.fromString("destAddrNpi"), (long) (pdu.getDestAddrNpi() & 0xFF));
        properties.put(StringUtils.fromString("esmClass"), (long) (pdu.getEsmClass() & 0xFF));
        properties.put(StringUtils.fromString("udhi"), pdu.isUdhi());
        return properties;
    }

    private void dispatch(String method, BMap<BString, Object> sms) throws ProcessRequestException {
        ServiceBinding binding = this.binding;
        if (binding == null || !binding.remoteMethods().contains(method)) {
            return;
        }
        BObject svc = binding.service();
        // isConcurrentSafe = false -> the runtime serializes dispatch; safe default.
        StrandMetadata meta = new StrandMetadata(false, null);
        inFlight.incrementAndGet();
        if (this.async) {
            // ASYNC: PDU is already acknowledged (ESME_ROK) by the time this callback
            // returns; a failure here can no longer become a negative command_status.
            // Still tracked as in-flight so gracefulStop can wait for it too.
            Thread.startVirtualThread(() -> {
                try {
                    Object result = runtime.callMethod(svc, method, meta, sms);
                    if (result instanceof BError err) {
                        err.printStackTrace();
                    }
                } finally {
                    inFlight.decrementAndGet();
                }
            });
            return;
        }
        try {
            Object result = runtime.callMethod(svc, method, meta, sms);
            if (result instanceof BError err) {
                throw new ProcessRequestException(err.getMessage(), SMPPConstant.STAT_ESME_RSYSERR, err);
            }
        } finally {
            inFlight.decrementAndGet();
        }
    }

    private static String nullSafe(String s) {
        return s == null ? "" : s;
    }
}
