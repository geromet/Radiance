package com.radiance.client.pipeline;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotSame;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.radiance.client.pipeline.config.AttributeConfig;
import com.radiance.client.pipeline.config.ImageConfig;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import org.junit.jupiter.api.Test;

class ModuleTest {

    private static ImageConfig image(String name) {
        ImageConfig c = new ImageConfig();
        c.name = name;
        return c;
    }

    @Test
    void copyAttributeConfigsHandlesNullAndSkipsNullEntries() {
        assertTrue(Module.copyAttributeConfigs(null).isEmpty());
        AttributeConfig a = new AttributeConfig();
        a.name = "x";
        a.type = "float";
        a.value = "1.0";
        List<AttributeConfig> src = new ArrayList<>(Arrays.asList(null, a));
        List<AttributeConfig> copy = Module.copyAttributeConfigs(src);
        assertEquals(1, copy.size());
        assertNotSame(a, copy.get(0));
        assertEquals("x", copy.get(0).name);
        assertEquals("float", copy.get(0).type);
        assertEquals("1.0", copy.get(0).value);
    }

    @Test
    void imageConfigLookup() {
        Module m = new Module();
        ImageConfig in = image("in");
        ImageConfig out = image("out");
        m.inputImageConfigs = List.of(in);
        m.outputImageConfigs = List.of(out);
        assertSame(in, m.getInputImageConfig("in"));
        assertSame(out, m.getOutputImageConfig("out"));
        assertThrows(RuntimeException.class, () -> m.getInputImageConfig("out"));
        assertThrows(RuntimeException.class, () -> m.getOutputImageConfig("in"));
    }
}
