#version 450

layout (location = 0) out vec4 outColor;
layout(location = 4) in vec2 positionWorld;
layout(location = 5) in vec4 v_color;
layout(location = 6) in float v_radius;

struct PointLight {
    vec4 position;
    vec4 color;
};

layout(set = 0, binding = 0) uniform GlobalUbo {
    mat4 projection;
    mat4 view;
    vec4 ambientColor;
    PointLight pointLights[16];
    int numPointLights;
    float dt;
} ubo;

void main() {
    float dis = sqrt(dot(positionWorld, positionWorld));
    if (dis >= 1.0) {
        discard;
    }
    // Soft falloff from center to edge for more pleasant appearance
    float falloff = 1.0 - dis;
    float alpha = falloff * 0.6; // Semi-transparent with falloff
    outColor = vec4(v_color.xyz, alpha);
}