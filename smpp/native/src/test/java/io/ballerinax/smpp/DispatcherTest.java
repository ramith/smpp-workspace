// Copyright (c) 2026. Pure-logic tests for Dispatcher's PDU decode helpers.
package io.ballerinax.smpp;

import org.jsmpp.bean.DataSm;
import org.jsmpp.bean.DeliverSm;
import org.jsmpp.bean.OptionalParameter;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;

/**
 * Exercises {@link Dispatcher#decodeShortMessage} and {@link Dispatcher#payloadBytes}
 * directly - both are pure functions (no jsmpp session, no Ballerina runtime), so this
 * suite needs neither. Byte fixtures are deliberately real per-codec content, not plain
 * ASCII: ASCII decodes identically under almost any charset, so it would pass "by
 * accident" for 3 of these 4 branches and prove nothing about the actual decoder chosen.
 */
class DispatcherTest {

    // ---- decodeShortMessage: null/empty edge cases ----

    @Test
    void decodeShortMessage_nullBytes_returnsEmptyString() {
        assertEquals("", Dispatcher.decodeShortMessage(null, (byte) 0x01));
    }

    @Test
    void decodeShortMessage_emptyBytes_returnsEmptyString() {
        assertEquals("", Dispatcher.decodeShortMessage(new byte[0], (byte) 0x01));
    }

    // ---- decodeShortMessage: 0x00 GSM-7 default alphabet - documented UTF-8 fallback ----

    @Test
    void decodeShortMessage_gsm7Default_fallsBackToUtf8NotGsm03_38() {
        // Real GSM 03.38 would decode byte 0x00 as '@' (COMMERCIAL AT). This connector
        // deliberately does not implement that codec and falls back to UTF-8 instead - this
        // test pins that documented fallback so a future GSM7 codec change can't silently
        // regress it back to a UTF-8 misinterpretation without a loud, explicit failure.
        byte[] bytes = {0x00};
        String decoded = Dispatcher.decodeShortMessage(bytes, (byte) 0x00);
        assertEquals(new String(bytes, StandardCharsets.UTF_8), decoded);
        assertEquals("\u0000", decoded); // NUL (U+0000) under UTF-8, not '@' as real GSM-7 would give
    }

    @Test
    void decodeShortMessage_gsm7Default_escapeByteDoesNotChokeTheFallback() {
        // 0x1B is the GSM 03.38 extension-table escape prefix; confirm the UTF-8 fallback
        // handles it like any other byte rather than choking on it.
        byte[] bytes = {0x1B, 'A'};
        String decoded = Dispatcher.decodeShortMessage(bytes, (byte) 0x00);
        assertEquals(new String(bytes, StandardCharsets.UTF_8), decoded);
    }

    // ---- decodeShortMessage: 0x01 IA5/ASCII - the one branch where ASCII is meaningful ----

    @Test
    void decodeShortMessage_ia5_decodesFullPrintableRange() {
        String text = "Hello, World! @ #1 - 100%";
        byte[] bytes = text.getBytes(StandardCharsets.US_ASCII);
        assertEquals(text, Dispatcher.decodeShortMessage(bytes, (byte) 0x01));
    }

    @Test
    void decodeShortMessage_ia5_delByteAtBoundaryDoesNotCrash() {
        byte[] bytes = {0x7F};
        assertEquals("\u007F", Dispatcher.decodeShortMessage(bytes, (byte) 0x01));
    }

    // ---- decodeShortMessage: 0x03 Latin-1/ISO-8859-1 - real 0x80-0xFF content ----

    @Test
    void decodeShortMessage_latin1_decodesExtendedCharacters() {
        // é=0xE9, ñ=0xF1, ï=0xEF, ¿=0xBF under true ISO-8859-1 - none representable as
        // standalone valid UTF-8, so this could only pass if the Latin-1 branch actually ran.
        String text = "Café, mañana, naïve, ¿qué?";
        byte[] bytes = text.getBytes(StandardCharsets.ISO_8859_1);
        assertEquals(text, Dispatcher.decodeShortMessage(bytes, (byte) 0x03));
    }

    // ---- decodeShortMessage: 0x08 UCS2/UTF-16BE - non-Latin script content ----

    @Test
    void decodeShortMessage_ucs2_decodesNonLatinBmpContent() {
        // Non-Latin BMP content, so a naive "every other byte is 0x00" padding bug (which
        // Latin-script UCS2 content could hide behind) would be caught.
        String text = "こんにちは"; // Japanese "konnichiwa"
        byte[] bytes = text.getBytes(StandardCharsets.UTF_16BE);
        assertEquals(text, Dispatcher.decodeShortMessage(bytes, (byte) 0x08));
    }

    @Test
    void decodeShortMessage_ucs2_surrogatePairDecodesCorrectly() {
        // Technically outside strict UCS-2's BMP-only contract, but real SMSCs do sometimes
        // send UTF-16 mislabeled as UCS2 - Java's UTF_16BE decoder reassembles a valid
        // surrogate pair correctly since UTF-16BE is a superset in this specific case.
        String text = "😀"; // U+1F600 GRINNING FACE
        byte[] bytes = text.getBytes(StandardCharsets.UTF_16BE);
        assertEquals(text, Dispatcher.decodeShortMessage(bytes, (byte) 0x08));
    }

    // ---- decodeShortMessage: reserved/unknown data_coding values also fall back to UTF-8 ----

    @Test
    void decodeShortMessage_unknownDataCoding_fallsBackToUtf8() {
        byte[] bytes = "reserved value".getBytes(StandardCharsets.UTF_8);
        assertEquals("reserved value", Dispatcher.decodeShortMessage(bytes, (byte) 0x02));
        assertEquals("reserved value", Dispatcher.decodeShortMessage(bytes, (byte) 0x0F));
    }

    // ---- payloadBytes: message_payload vs short_message precedence ----

    @Test
    void payloadBytes_deliverSm_withoutMessagePayload_fallsBackToShortMessage() {
        DeliverSm pdu = new DeliverSm();
        byte[] fallback = "fallback short_message".getBytes(StandardCharsets.UTF_8);
        assertArrayEquals(fallback, Dispatcher.payloadBytes(pdu, fallback));
    }

    @Test
    void payloadBytes_deliverSm_withMessagePayload_takesPrecedenceOverShortMessage() {
        DeliverSm pdu = new DeliverSm();
        byte[] payload = "message_payload wins".getBytes(StandardCharsets.UTF_8);
        pdu.setOptionalParameters(new OptionalParameter.Message_payload(payload));
        byte[] fallback = "should be ignored".getBytes(StandardCharsets.UTF_8);
        assertArrayEquals(payload, Dispatcher.payloadBytes(pdu, fallback));
    }

    @Test
    void payloadBytes_dataSm_withoutMessagePayload_fallsBackToEmpty() {
        // DATA_SM has no short_message field at all - the connector always passes an empty
        // fallback for it (see Dispatcher.onAcceptDataSm).
        DataSm pdu = new DataSm();
        assertArrayEquals(new byte[0], Dispatcher.payloadBytes(pdu, new byte[0]));
    }

    @Test
    void payloadBytes_dataSm_withMessagePayload_isUsed() {
        DataSm pdu = new DataSm();
        byte[] payload = "data_sm payload".getBytes(StandardCharsets.UTF_8);
        pdu.setOptionalParameters(new OptionalParameter.Message_payload(payload));
        assertArrayEquals(payload, Dispatcher.payloadBytes(pdu, new byte[0]));
    }
}
