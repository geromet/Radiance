package com.radiance.client.shader;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.radiance.client.shader.ShaderField.Kind;
import java.util.List;
import net.minecraft.client.render.VertexFormat;
import net.minecraft.client.render.VertexFormatElement;
import org.junit.jupiter.api.Test;

class ShaderTranslatorTest {

    private static final VertexFormat FORMAT = VertexFormat.builder()
        .add("Position", VertexFormatElement.POSITION)
        .add("Color", VertexFormatElement.COLOR)
        .build();

    private static final List<ShaderField> FIELDS = List.of(
        new ShaderField("ColorModulator", "colorModulator", Kind.FLOAT, 4, 0, 16, 0),
        new ShaderField("Sampler0", "sampler0", Kind.SAMPLER, 1, 16, 4, 0));

    private static final String VERT = """
        #version 150
        uniform vec4 ColorModulator;
        in vec3 Position;
        in vec4 Color;
        out vec4 vertexColor;
        void main() { vertexColor = Color * ColorModulator; }
        """;
    private static final String FRAG = """
        #version 150
        uniform sampler2D Sampler0;
        in vec4 vertexColor;
        out vec4 fragColor;
        void main() { fragColor = vertexColor; }
        """;

    @Test
    void translatesToVulkanGlsl() {
        ShaderTranslator.Result r = ShaderTranslator.translate(FORMAT, VERT, FRAG, FIELDS);

        assertTrue(r.vertexSource().startsWith("#version 460\n"));
        assertFalse(r.vertexSource().contains("#version 150"));
        assertFalse(r.vertexSource().contains("uniform vec4 ColorModulator;"));
        assertTrue(r.vertexSource().contains("layout(location = 0) in vec3 Position;"));
        assertTrue(r.vertexSource().contains("layout(location = 1) in vec4 Color;"));
        assertTrue(r.vertexSource().contains("layout(location = 0) out vec4 vertexColor;"));
        assertTrue(r.fragmentSource().contains("layout(location = 0) in vec4 vertexColor;"));
        assertTrue(r.fragmentSource().contains("layout(location = 0) out vec4 fragColor;"));
        assertTrue(r.vertexSource().contains("#define ColorModulator (uniforms.colorModulator)"));
        assertTrue(r.fragmentSource()
            .contains("#define Sampler0 textures[nonuniformEXT(int(uniforms.sampler0))]"));
    }

    @Test
    void uniformBufferSizeIsRoundedUpTo16() {
        assertEquals(32, ShaderTranslator.translate(FORMAT, VERT, FRAG, FIELDS).uniformBufferSize());
        assertEquals(0, ShaderTranslator.translate(FORMAT, VERT, FRAG, List.of()).uniformBufferSize());
    }

    @Test
    void translationIsDeterministic() {
        assertEquals(ShaderTranslator.translate(FORMAT, VERT, FRAG, FIELDS),
            ShaderTranslator.translate(FORMAT, VERT, FRAG, FIELDS));
    }
}
