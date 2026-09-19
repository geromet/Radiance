package com.radiance.client.option;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.HashSet;
import java.util.Set;
import net.minecraft.util.StringIdentifiable;
import net.minecraft.util.TranslatableOption;
import org.junit.jupiter.api.Test;

class OptionEnumsTest {

    private static <E extends Enum<E> & TranslatableOption & StringIdentifiable> void check(
        E[] values) {
        Set<Integer> ids = new HashSet<>();
        Set<String> names = new HashSet<>();
        for (E v : values) {
            assertTrue(ids.add(v.getId()), "duplicate id on " + v);
            assertTrue(names.add(v.asString()), "duplicate name on " + v);
            assertNotNull(v.getTranslationKey());
            assertTrue(v.getTranslationKey().startsWith("options.video."));
        }
    }

    @Test
    void dlssMode() {
        check(DLSSMode.values());
        assertEquals("dlaa", DLSSMode.DLAA.asString());
    }

    @Test
    void upscalerQuality() {
        check(UpscalerQuality.values());
        assertEquals(0, UpscalerQuality.NATIVEAA.getId());
    }

    @Test
    void denoiserAndUpscalerType() {
        check(DenoiserMode.values());
        check(UpscalerType.values());
    }
}
