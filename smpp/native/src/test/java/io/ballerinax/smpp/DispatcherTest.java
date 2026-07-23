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
        // \u00E9=0xE9, \u00F1=0xF1, \u00EF=0xEF, \u00BF=0xBF under true ISO-8859-1 - none representable as
        // standalone valid UTF-8, so this could only pass if the Latin-1 branch actually ran.
        String text = "Caf\u00E9, ma\u00F1ana, na\u00EFve, \u00BFqu\u00E9?";
        byte[] bytes = text.getBytes(StandardCharsets.ISO_8859_1);
        assertEquals(text, Dispatcher.decodeShortMessage(bytes, (byte) 0x03));
    }

    // ---- decodeShortMessage: 0x08 UCS2/UTF-16BE - non-Latin script content ----

    @Test
    void decodeShortMessage_ucs2_decodesNonLatinBmpContent() {
        // Non-Latin BMP content, so a naive "every other byte is 0x00" padding bug (which
        // Latin-script UCS2 content could hide behind) would be caught.
        String text = "\u3053\u3093\u306B\u3061\u306F"; // Japanese "konnichiwa"
        byte[] bytes = text.getBytes(StandardCharsets.UTF_16BE);
        assertEquals(text, Dispatcher.decodeShortMessage(bytes, (byte) 0x08));
    }

    @Test
    void decodeShortMessage_ucs2_surrogatePairDecodesCorrectly() {
        // Technically outside strict UCS-2's BMP-only contract, but real SMSCs do sometimes
        // send UTF-16 mislabeled as UCS2 - Java's UTF_16BE decoder reassembles a valid
        // surrogate pair correctly since UTF-16BE is a superset in this specific case.
        String text = "\u1F600"; // U+1F600 GRINNING FACE
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

    // ---- decodeShortMessage: opt-in GSM 03.38 (data_coding 0x00), unpacked ----

    @Test
    void gsm7_off_isTheDefault_and_0x00_stillFallsBackToUtf8() {
        // The 2-arg overload and the 3-arg with decodeGsm7=false must both leave 0x00 as the
        // UTF-8 fallback: bytes 0x01,0x02 are control chars in UTF-8, NOT the GSM "\u00A3$".
        byte[] bytes = {0x01, 0x02};
        assertEquals("\u0001\u0002", Dispatcher.decodeShortMessage(bytes, (byte) 0x00));
        assertEquals("\u0001\u0002", Dispatcher.decodeShortMessage(bytes, (byte) 0x00, false));
    }

    @Test
    void gsm7_on_decodesDefaultAlphabetSpecials() {
        // 0x00->@, 0x01->\u00A3, 0x02->$, 0x03->\u00A5, 0x24->\u00A4, 0x40->\u00A1, 0x5F->\u00A7, 0x60->\u00BF
        byte[] bytes = {0x00, 0x01, 0x02, 0x03, 0x24, 0x40, 0x5F, 0x60};
        assertEquals("@\u00A3$\u00A5\u00A4\u00A1\u00A7\u00BF",
                Dispatcher.decodeShortMessage(bytes, (byte) 0x00, true));
    }

    @Test
    void gsm7_on_row1AlignmentAroundEscapePlaceholder() {
        // Regression guard for the ESC-placeholder slot at 0x1B: the chars around it must land
        // on the right indices - 0x1A->\u039E, (0x1B is ESC, no char), 0x1C->\u00C6, 0x1D->\u00E6, 0x1E->\u00DF, 0x1F->\u00C9.
        byte[] bytes = {0x1A, 0x1C, 0x1D, 0x1E, 0x1F};
        assertEquals("\u039E\u00C6\u00E6\u00DF\u00C9",
                Dispatcher.decodeShortMessage(bytes, (byte) 0x00, true));
    }

    @Test
    void gsm7_on_asciiLettersDigitsAndControlMappings() {
        // A-Z/a-z/0-9 map to themselves; 0x0A->LF and 0x0D->CR are real line breaks in GSM-7.
        byte[] bytes = "Ab9".getBytes(StandardCharsets.US_ASCII); // 0x41,0x62,0x39
        assertEquals("Ab9", Dispatcher.decodeShortMessage(bytes, (byte) 0x00, true));
        assertEquals("\n\r", Dispatcher.decodeShortMessage(new byte[] {0x0A, 0x0D}, (byte) 0x00, true));
    }

    @Test
    void gsm7_on_pound100_realisticString() {
        byte[] bytes = {0x01, 0x31, 0x30, 0x30}; // \u00A3 1 0 0
        assertEquals("\u00A3100", Dispatcher.decodeShortMessage(bytes, (byte) 0x00, true));
    }

    @Test
    void gsm7_on_extensionTable_allEntries() {
        // ESC (0x1B) + each defined extension byte -> its character.
        assertEquals("\f", Dispatcher.decodeShortMessage(new byte[] {0x1B, 0x0A}, (byte) 0x00, true));
        assertEquals("^", Dispatcher.decodeShortMessage(new byte[] {0x1B, 0x14}, (byte) 0x00, true));
        assertEquals("{", Dispatcher.decodeShortMessage(new byte[] {0x1B, 0x28}, (byte) 0x00, true));
        assertEquals("}", Dispatcher.decodeShortMessage(new byte[] {0x1B, 0x29}, (byte) 0x00, true));
        assertEquals("\\", Dispatcher.decodeShortMessage(new byte[] {0x1B, 0x2F}, (byte) 0x00, true));
        assertEquals("[", Dispatcher.decodeShortMessage(new byte[] {0x1B, 0x3C}, (byte) 0x00, true));
        assertEquals("~", Dispatcher.decodeShortMessage(new byte[] {0x1B, 0x3D}, (byte) 0x00, true));
        assertEquals("]", Dispatcher.decodeShortMessage(new byte[] {0x1B, 0x3E}, (byte) 0x00, true));
        assertEquals("|", Dispatcher.decodeShortMessage(new byte[] {0x1B, 0x40}, (byte) 0x00, true));
        assertEquals("\u20AC", Dispatcher.decodeShortMessage(new byte[] {0x1B, 0x65}, (byte) 0x00, true));
    }

    @Test
    void gsm7_on_escapeHandling_loneAndUndefined() {
        // A lone trailing ESC -> a space.
        assertEquals(" ", Dispatcher.decodeShortMessage(new byte[] {0x1B}, (byte) 0x00, true));
        // ESC followed by a non-extension byte -> ESC shown as space, next byte decoded normally
        // (0x01 -> \u00A3), so {ESC, 0x01} yields " \u00A3", NOT a consumed pair.
        assertEquals(" \u00A3", Dispatcher.decodeShortMessage(new byte[] {0x1B, 0x01}, (byte) 0x00, true));
    }

    @Test
    void gsm7_flag_doesNotAffectOtherDataCodings() {
        // The flag only touches 0x00. IA5/Latin-1/UCS-2 decode identically regardless.
        byte[] bytes = {0x41, 0x42};
        assertEquals("AB", Dispatcher.decodeShortMessage(bytes, (byte) 0x01, true));  // still ASCII
        assertEquals("AB", Dispatcher.decodeShortMessage(bytes, (byte) 0x03, true));  // still Latin-1
    }

    @Test
    void gsm7_on_emptyAndHighBitPadding() {
        assertEquals("", Dispatcher.decodeShortMessage(new byte[0], (byte) 0x00, true));
        // A stray high bit is treated as 7-bit padding: 0x80|0x01 still decodes as \u00A3.
        assertEquals("\u00A3", Dispatcher.decodeShortMessage(new byte[] {(byte) 0x81}, (byte) 0x00, true));
    }
}
