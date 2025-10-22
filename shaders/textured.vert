#version 450

layout(location = 0) in vec3 position;
layout(location = 1) in vec3 color;
layout(location = 2) in vec3 normal;
layout(location = 3) in vec2 uv;

layout(location = 1) out vec3 v_color;
layout(location = 2) out vec2 v_uv;
layout(location = 3) out vec3 v_normal;
layout(location = 4) out vec3 v_pos;
layout(location = 5) out flat uint v_material_index;

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

layout(push_constant) uniform Push {
    mat4 transform;
    mat4 normalMatrix;
    uint materialIndex;
} push;

void main() {
    vec4 positionWorld = push.transform * vec4(position, 1.0);
    gl_Position = ubo.projection * ubo.view * positionWorld;

    v_color = color;
    v_uv = uv;
    v_normal = normalize(mat3(push.normalMatrix) * normal);
    v_pos = positionWorld.xyz;
    v_material_index = push.materialIndex;
}