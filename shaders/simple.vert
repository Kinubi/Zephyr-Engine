#version 450

layout (location  = 0) out vec2 fragOffset;

vec2 positions[3] = vec2[](
    vec2(-1.0, -1.0),
    vec2(3.0, -1.0),
    vec2(-1.0, 3.0)
);

void main() {
    fragOffset = positions[gl_VertexIndex];
    gl_Position = vec4(positions[gl_VertexIndex].xy, 0.0, 1.0);
}