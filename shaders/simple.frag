#version 450

layout (location = 0) out vec4 outColor;

layout(location = 1) in vec3 color;
layout(location = 2) in vec3 normal;
layout(location = 3) in vec2 uv;

layout(push_constant) uniform Push {
    mat4 projectionView;
    mat4 normalMatrix;
} push;

void main() {
    outColor = vec4(color, 1.0);
}