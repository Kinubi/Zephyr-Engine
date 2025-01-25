#version 450

layout (location = 0) out vec4 outColor;
layout(location = 4) in vec2 positionWorld;

layout(set = 0, binding = 0) uniform GlobalUbo {
    mat4 projection;
    mat4 view;
    vec4 ambientLightColor; // w is intensity
    vec3 lightPosition;
    vec4 lightColor;
} ubo;

void main() {
    float dis = sqrt(dot(positionWorld, positionWorld));
    if (dis >= 1.0) {
        discard;
    }
    outColor = vec4(ubo.lightColor.xyz, 1.0);
}