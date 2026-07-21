// Copyright (c) 2026. Bridges jsmpp receive callbacks into the Ballerina runtime.
package io.ballerinax.smpp;

import io.ballerina.runtime.api.Runtime;
import io.ballerina.runtime.api.concurrent.StrandMetadata;
import io.ballerina.runtime.api.creators.ErrorCreator;
import io.ballerina.runtime.api.creators.ValueCreator;
import io.ballerina.runtime.api.types.MethodType;
import io.ballerina.runtime.api.types.ObjectType;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.utils.TypeUtils;
import io.ballerina.runtime.api.values.BError;
import io.ballerina.runtime.api.values.BMap;
import io.ballerina.runtime.api.values.BObject;
import io.ballerina.runtime.api.values.BString;

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

    private final Runtime runtime;
    private volatile BObject service;
    private volatile Set<String> remoteMethods = new HashSet<>();
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
        BObject svc = this.service;
        BError err = ErrorCreator.createError(StringUtils.fromString(message));
        if (svc == null || !this.remoteMethods.contains(ON_ERROR)) {
            err.printStackTrace();
            return;
        }
        StrandMetadata meta = new StrandMetadata(false, null);
        Thread.startVirtualThread(() -> {
            Object result = runtime.callMethod(svc, ON_ERROR, meta, err);
            if (result instanceof BError callbackErr) {
                callbackErr.printStackTrace();
            }
        });
    }

    void setAsync(boolean async) {
        this.async = async;
    }

    void setService(BObject service) {
        this.service = service;
        Set<String> names = new HashSet<>();
        if (service != null) {
            ObjectType objType = (ObjectType) TypeUtils.getReferredType(TypeUtils.getType(service));
            for (MethodType method : objType.getMethods()) {
                names.add(method.getName());
            }
        }
        this.remoteMethods = names;
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
        // Returning null acknowledges the DATA_SM without a message id.
        return null;
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
    private static byte[] payloadBytes(AbstractSmCommand pdu, byte[] fallback) {
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
    private static String decodeShortMessage(byte[] bytes, byte dataCoding) {
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
        BObject svc = this.service;
        if (svc == null || !this.remoteMethods.contains(method)) {
            return;
        }
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
