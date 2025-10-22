#version 450

layout(location = 0) in vec4 fragColor;

// Global UBO - must match vertex shader's descriptor layout
// Even though we don't use it here, it needs to be declared for descriptor set compatibility
layout(set = 0, binding = 0) uniform GlobalUbo {
    mat4 projection;
    mat4 view;
} ubo;

layout(location = 0) out vec4 outColor;

void main() {
    // Discard particles with zero alpha (invisible/uninitialized)
    if (fragColor.a <= 0.0) {
        discard;
    }
    
    vec2 coord = gl_PointCoord - vec2(0.5);
    float dist = length(coord);
    
    // Create circular gradient, multiply by particle alpha
    float alpha = (0.5 - dist) * fragColor.a;
    if (alpha <= 0.0) {
        discard;
    }
    
    outColor = vec4(fragColor.rgb, alpha);
}