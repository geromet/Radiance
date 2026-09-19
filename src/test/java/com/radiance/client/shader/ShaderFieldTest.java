package com.radiance.client.shader;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.radiance.client.shader.ShaderField.Kind;
import org.junit.jupiter.api.Test;

class ShaderFieldTest {

    private static ShaderField field(Kind kind, int components) {
        return new ShaderField("N", "f", kind, components, 0, 16, 0);
    }

    @Test
    void glslTypes() {
        assertEquals("int", field(Kind.INT, 1).glslType());
        assertEquals("ivec3", field(Kind.INT, 3).glslType());
        assertEquals("float", field(Kind.FLOAT, 1).glslType());
        assertEquals("vec4", field(Kind.FLOAT, 4).glslType());
        assertEquals("mat3", field(Kind.MATRIX, 3).glslType());
        assertEquals("uint", field(Kind.SAMPLER, 1).glslType());
    }

    @Test
    void unsupportedSizesThrow() {
        assertThrows(IllegalStateException.class, () -> field(Kind.INT, 5).glslType());
        assertThrows(IllegalStateException.class, () -> field(Kind.FLOAT, 0).glslType());
        assertThrows(IllegalStateException.class, () -> field(Kind.MATRIX, 1).glslType());
    }

    @Test
    void onlySamplerKindIsSampler() {
        assertTrue(field(Kind.SAMPLER, 1).isSampler());
        assertFalse(field(Kind.FLOAT, 1).isSampler());
    }
}
