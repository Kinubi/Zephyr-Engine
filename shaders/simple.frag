#version 450

layout (location = 0) out vec4 outColor;
layout(location = 1) in vec3 color;

layout(push_constant) uniform Push {
    mat4 projectionView;
    mat4 transform;
    vec3 color;
} push;

void main() {
    outColor = vec4(color, 1.0);
}