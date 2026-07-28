// Copyright (c) 2026. Pure-logic tests: OutboundSms spec -> jsmpp submit arguments.
package io.ballerinax.smpp;

import org.jsmpp.bean.NumberingPlanIndicator;
import org.jsmpp.bean.TypeOfNumber;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Pins {@link NativeCaller#compose} — the OutboundSms → jsmpp argument mapping — without
 * a session or a Ballerina runtime. The esm_class assertion is the load-bearing one: a
 * wrong value there is invisible in a happy-path round trip yet changes SMSC routing and
 * billing.
 */
class OutboundSmsMappingTest {

    private static NativeCaller.SubmitSpec minimalText() {
        NativeCaller.SubmitSpec spec = new NativeCaller.SubmitSpec();
        spec.destAddr = "264811234567";
        spec.shortMessage = "hello";
        return spec;
    }

    @Test
    void happyPathDefaults() throws Exception {
        NativeCaller.SubmitRequest req = NativeCaller.compose(minimalText());
        assertEquals("264811234567", req.dstAddr);
        assertEquals(TypeOfNumber.INTERNATIONAL, req.dstTon);
        assertEquals(NumberingPlanIndicator.ISDN, req.dstNpi);
        assertEquals("", req.srcAddr, "absent source address goes on the wire empty (spec-legal)");
        assertEquals((byte) 0x03, req.dataCoding, "LATIN1 default must stamp data_coding 0x03");
        assertArrayEquals("hello".getBytes(StandardCharsets.ISO_8859_1), req.body);
        assertEquals((byte) 0x00, req.registeredDelivery, "no receipt requested MUST be 0 - "
                + "the negative is what catches an always-on bug");
        // Point-to-point defaults, asserted on the composed byte.
        assertEquals((byte) 0x00, req.esmClass, "esm_class must be 0x00: nonzero changes "
                + "SMSC routing and billing invisibly");
        assertEquals((byte) 0x00, req.protocolId);
        assertEquals((byte) 0x00, req.priorityFlag);
        assertEquals((byte) 0x00, req.replaceIfPresent);
        assertEquals((byte) 0x00, req.smDefaultMsgId);
        assertNull(req.scheduleDeliveryTime);
        assertNull(req.validityPeriod);
        assertEquals("", req.serviceType);
    }

    @Test
    void encodingsStampTheirDataCoding() throws Exception {
        NativeCaller.SubmitSpec spec = minimalText();
        spec.encoding = "ASCII";
        assertEquals((byte) 0x01, NativeCaller.compose(spec).dataCoding);
        spec.encoding = "UCS2";
        NativeCaller.SubmitRequest ucs2 = NativeCaller.compose(spec);
        assertEquals((byte) 0x08, ucs2.dataCoding);
        assertArrayEquals("hello".getBytes(StandardCharsets.UTF_16BE), ucs2.body);
    }

    @Test
    void registeredDeliveryVariants() throws Exception {
        NativeCaller.SubmitSpec spec = minimalText();
        spec.registeredDelivery = "ON_SUCCESS_OR_FAILURE";
        assertEquals((byte) 0x01, NativeCaller.compose(spec).registeredDelivery);
        spec.registeredDelivery = "ON_FAILURE_ONLY";
        assertEquals((byte) 0x02, NativeCaller.compose(spec).registeredDelivery);
    }

    @Test
    void tonNpiResolveViaJsmppNames() throws Exception {
        NativeCaller.SubmitSpec spec = minimalText();
        spec.destTon = "ALPHANUMERIC";
        spec.destNpi = "UNKNOWN";
        spec.sourceAddr = "INFO";
        spec.sourceTon = "ALPHANUMERIC";
        spec.sourceNpi = "UNKNOWN";
        NativeCaller.SubmitRequest req = NativeCaller.compose(spec);
        assertEquals(TypeOfNumber.ALPHANUMERIC, req.dstTon);
        assertEquals(NumberingPlanIndicator.UNKNOWN, req.dstNpi);
        assertEquals(TypeOfNumber.ALPHANUMERIC, req.srcTon);
        assertEquals("INFO", req.srcAddr);
    }

    @Test
    void escapeHatchBytesPassVerbatimWithRawDataCoding() throws Exception {
        NativeCaller.SubmitSpec spec = new NativeCaller.SubmitSpec();
        spec.destAddr = "264811234567";
        spec.shortMessageBytes = new byte[] {0x01, 0x02, (byte) 0xFF};
        spec.dataCoding = 0x00; // the GSM-7 escape-hatch case the Encoding enum cannot express
        NativeCaller.SubmitRequest req = NativeCaller.compose(spec);
        assertArrayEquals(new byte[] {0x01, 0x02, (byte) 0xFF}, req.body);
        assertEquals((byte) 0x00, req.dataCoding);
    }

    @Test
    void bodyXorRulesAreMutuallyExclusive() {
        // both set
        NativeCaller.SubmitSpec both = minimalText();
        both.shortMessageBytes = new byte[] {1};
        both.dataCoding = 0;
        assertThrows(NativeCaller.InvalidRequest.class, () -> NativeCaller.compose(both));
        // neither set
        NativeCaller.SubmitSpec neither = new NativeCaller.SubmitSpec();
        neither.destAddr = "264811234567";
        assertThrows(NativeCaller.InvalidRequest.class, () -> NativeCaller.compose(neither));
        // bytes without dataCoding
        NativeCaller.SubmitSpec noDc = new NativeCaller.SubmitSpec();
        noDc.destAddr = "264811234567";
        noDc.shortMessageBytes = new byte[] {1};
        assertThrows(NativeCaller.InvalidRequest.class, () -> NativeCaller.compose(noDc));
        // dataCoding without bytes
        NativeCaller.SubmitSpec dcOnly = minimalText();
        dcOnly.dataCoding = 8;
        assertThrows(NativeCaller.InvalidRequest.class, () -> NativeCaller.compose(dcOnly));
    }

    @Test
    void oversizeRejectedAtExactOctetBoundary() throws Exception {
        // 254 octets accepted / 255 rejected, in OCTETS per the encoded form - the limit
        // is read from jsmpp's StringParameter, not transcribed.
        NativeCaller.SubmitSpec at = minimalText();
        at.shortMessage = "a".repeat(254);
        assertEquals(254, NativeCaller.compose(at).body.length);
        NativeCaller.SubmitSpec over = minimalText();
        over.shortMessage = "a".repeat(255);
        NativeCaller.InvalidRequest e =
                assertThrows(NativeCaller.InvalidRequest.class, () -> NativeCaller.compose(over));
        assertTrue(e.getMessage().contains("255") && e.getMessage().contains("254"),
                "boundary error must name both lengths: " + e.getMessage());
    }

    @Test
    void ucs2BoundaryCountsUtf16CodeUnitsNotCodePoints() throws Exception {
        // 127 UTF-16 code units = 254 octets: fits. An emoji is TWO units (four octets),
        // so 63 emoji + 1 char = 127 units fits, 64 emoji = 128 units (256 octets) does not.
        NativeCaller.SubmitSpec fits = minimalText();
        fits.encoding = "UCS2";
        fits.shortMessage = "😀".repeat(63) + "x";
        assertEquals(254, NativeCaller.compose(fits).body.length);
        NativeCaller.SubmitSpec over = minimalText();
        over.encoding = "UCS2";
        over.shortMessage = "😀".repeat(64);
        assertThrows(NativeCaller.InvalidRequest.class, () -> NativeCaller.compose(over));
    }

    @Test
    void unencodableCharacterRejectedNamingIndex() {
        // € is not in ISO-8859-1 (0x80-0x9F are control chars; € lives in Latin-9/CP1252):
        // getBytes would silently substitute '?', which a subscriber would see. The index,
        // not the character, is named (messages never echo user data).
        NativeCaller.SubmitSpec latin = minimalText();
        latin.shortMessage = "ab€cd";
        NativeCaller.InvalidRequest e1 =
                assertThrows(NativeCaller.InvalidRequest.class, () -> NativeCaller.compose(latin));
        assertTrue(e1.getMessage().contains("index 2"), e1.getMessage());
        assertTrue(!e1.getMessage().contains("€"), "must not echo the character");
        NativeCaller.SubmitSpec ascii = minimalText();
        ascii.encoding = "ASCII";
        ascii.shortMessage = "nä";
        NativeCaller.InvalidRequest e2 =
                assertThrows(NativeCaller.InvalidRequest.class, () -> NativeCaller.compose(ascii));
        assertTrue(e2.getMessage().contains("index 1"), e2.getMessage());
    }

    @Test
    void addressAndFieldLimitsFromJsmpp() {
        // destAddr: C-octet max 21 including NUL -> 20 usable.
        NativeCaller.SubmitSpec longDest = minimalText();
        longDest.destAddr = "1".repeat(21);
        assertThrows(NativeCaller.InvalidRequest.class, () -> NativeCaller.compose(longDest));
        NativeCaller.SubmitSpec okDest = minimalText();
        okDest.destAddr = "1".repeat(20);
        assertEquals(20, assertDoesNotThrowCompose(okDest).dstAddr.length());
        // serviceType: C-octet max 6 -> 5 usable.
        NativeCaller.SubmitSpec longSvc = minimalText();
        longSvc.serviceType = "CMTCMT";
        assertThrows(NativeCaller.InvalidRequest.class, () -> NativeCaller.compose(longSvc));
        // empty destAddr is required
        NativeCaller.SubmitSpec noDest = new NativeCaller.SubmitSpec();
        noDest.shortMessage = "x";
        assertThrows(NativeCaller.InvalidRequest.class, () -> NativeCaller.compose(noDest));
    }

    private static NativeCaller.SubmitRequest assertDoesNotThrowCompose(NativeCaller.SubmitSpec spec) {
        try {
            return NativeCaller.compose(spec);
        } catch (NativeCaller.InvalidRequest e) {
            throw new AssertionError("compose unexpectedly rejected: " + e.getMessage(), e);
        }
    }
}
