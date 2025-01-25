#version 450

const vec2 OFFSETS[6] = vec2[](
    vec2(-1.0, -1.0),
    vec2(-1.0, 1.0),
    vec2(1.0, -1.0),
    vec2(1.0, -1.0),
    vec2(-1.0, 1.0),
    vec2(1.0, 1.0));

layout(location = 4) out vec2 v_pos;

layout(set = 0, binding = 0) uniform GlobalUbo {
    mat4 projection;
    mat4 view;
    vec4 ambientColor;
    vec3 lightPosition;
    vec4 lightColor;
} ubo;

const float LIGHT_RADIUS = 0.05;

void main() {
    v_pos = OFFSETS[gl_VertexIndex];
    vec3 cameraRightWorld = {
        ubo.view[0][0], ubo.view[1][0], ubo.view[2][0]
    };
    vec3 cameraUpWorld = {
        ubo.view[0][1], ubo.view[1][1], ubo.view[2][1]
    };

    vec3 positionWorld = ubo.lightPosition.xyz
    + LIGHT_RADIUS * v_pos.x * cameraRightWorld
    + LIGHT_RADIUS * v_pos.y * cameraUpWorld;

    gl_Position = ubo.projection * ubo.view * vec4(positionWorld, 1.0);
}