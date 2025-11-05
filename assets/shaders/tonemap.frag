#version 450
#extension GL_ARB_separate_shader_objects : enable

layout (location = 0) out vec4 outColor;
layout (location = 0) in vec2 vUV;

layout(set = 0, binding = 0) uniform sampler2D uHdr;

layout(push_constant) uniform TonemapPC {
    float exposure;
    uint manual_gamma; // 1 -> apply gamma 2.2 in shader, 0 -> rely on sRGB attachment
} pc;

// ACES filmic approximation (Narkowicz 2015)
vec3 aces_tonemap(vec3 x) {
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;
    return clamp((x*(a*x + b)) / (x*(c*x + d) + e), 0.0, 1.0);
}

void main() {
    vec3 hdr = texture(uHdr, vUV).rgb;
    // simple exposure
    hdr = max(hdr * max(pc.exposure, 0.0001), 0.0);
    // tonemap
    vec3 ldr = aces_tonemap(hdr);
    // manual gamma if not rendering to an sRGB attachment
    if (pc.manual_gamma != 0u) {
        ldr = pow(ldr, vec3(1.0/2.2));
    }
    outColor = vec4(ldr, 1.0);
}
