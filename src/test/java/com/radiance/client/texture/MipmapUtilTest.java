package com.radiance.client.texture;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

class MipmapUtilTest {

    private static final int OPAQUE_RED = 0xFFFF0000;
    private static final int OPAQUE_WHITE = 0xFFFFFFFF;

    @Test
    void colorFractionIsGammaDecodedAndMasksToOneByte() {
        assertEquals(0.0F, MipmapUtil.getColorFraction(0));
        assertEquals(1.0F, MipmapUtil.getColorFraction(255), 1e-6F);
        assertEquals(MipmapUtil.getColorFraction(0x7F), MipmapUtil.getColorFraction(0xABCD7F));
        assertTrue(MipmapUtil.getColorFraction(128) < 0.5F, "gamma 2.2 darkens midtones");
    }

    @Test
    void blendOfIdenticalOpaquePixelsIsIdentity() {
        assertEquals(OPAQUE_RED,
            MipmapUtil.blend(OPAQUE_RED, OPAQUE_RED, OPAQUE_RED, OPAQUE_RED, false));
        assertEquals(OPAQUE_WHITE,
            MipmapUtil.blend(OPAQUE_WHITE, OPAQUE_WHITE, OPAQUE_WHITE, OPAQUE_WHITE, false));
    }

    @Test
    void blendOfFullyTransparentPixelsIsZero() {
        assertEquals(0, MipmapUtil.blend(0, 0, 0, 0, false));
        assertEquals(0, MipmapUtil.blend(0, 0, 0, 0, true));
    }

    @Test
    void transparentPixelsDoNotBleedColorIntoOpaqueOnes() {
        int transparentGreen = 0x0000FF00;
        int result = MipmapUtil.blend(OPAQUE_RED, transparentGreen, transparentGreen,
            transparentGreen, false);
        assertEquals(0x00, (result >> 8) & 0xFF, "green must be weighted out by zero alpha");
        assertEquals(0xFF, (result >> 16) & 0xFF);
    }

    @Test
    void cutoutAlphaCoverageThreshold() {
        int clear = 0x00000000;
        // 2/4 opaque -> coverage exactly 0.5 -> opaque
        int half = MipmapUtil.blend(OPAQUE_WHITE, OPAQUE_WHITE, clear, clear, true);
        assertEquals(255, (half >>> 24));
        // 1/4 opaque -> below threshold -> fully transparent
        int quarter = MipmapUtil.blend(OPAQUE_WHITE, clear, clear, clear, true);
        assertEquals(0, (quarter >>> 24));
    }

    @Test
    void blendIsDeterministicAndOrderIndependent() {
        int a = 0xFF102030, b = 0xFF405060, c = 0xFF708090, d = 0xFFA0B0C0;
        int expected = MipmapUtil.blend(a, b, c, d, false);
        assertEquals(expected, MipmapUtil.blend(a, b, c, d, false));
        assertEquals(expected, MipmapUtil.blend(d, c, b, a, false));
    }

    @Test
    void colorComponentAveragesChannel() {
        assertEquals(255, MipmapUtil.getColorComponent(0xFF, 0xFF, 0xFF, 0xFF, 0));
        assertEquals(0, MipmapUtil.getColorComponent(0, 0, 0, 0, 8));
    }
}
