// Draws a texture over the whole screen with a single triangle and no vertex buffer.
// Both stages are named `main`; they are told apart by their stage.

// Textures are bound as one array of combined image samplers (set 0, binding 0).
// Note the attribute's argument order: binding first, then set.
[[vk::binding(0, 0)]]
Sampler2D textures[];

struct VSOutput {
    float4 position : SV_Position;
    [[vk::location(0)]] float2 uv;
};

// Vertices 0, 1, 2 produce one oversized triangle, (-1,-1), (3,-1), (-1,3), that covers the
// screen. Its UVs span (0,0) to (1,1) over the visible part, with (0,0) at the top left.
// SV_VulkanVertexID is Vulkan's VertexIndex. SV_VertexID uses D3D semantics (subtract the base vertex) requiring
// the usage of Vulkan's shaderDrawParameters feature.
[shader("vertex")]
VSOutput main(uint vertex_index: SV_VulkanVertexID) {
    VSOutput output;
    output.uv = float2((vertex_index << 1) & 2, vertex_index & 2);
    output.position = float4(output.uv * 2.0 - 1.0, 0.0, 1.0);
    return output;
}

// SV_Target0 is fragment output location 0, i.e. color attachment 0.
[shader("fragment")]
float4 main(VSOutput input) : SV_Target0 {
    return textures[0].Sample(input.uv);
}