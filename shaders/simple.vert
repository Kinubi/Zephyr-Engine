
#version 450

layout(location = 0) in vec3 position;
layout(location = 1) in vec3 color;
layout(location = 2) in vec3 normal;
layout(location = 3) in vec2 uv;

layout(location = 1) out vec3 v_color;
layout(location = 2) out vec3 v_normal;
layout(location = 3) out vec2 v_uv;

layout(set = 0, binding = 0) uniform GlobalUbo {
    mat4 projection;
    mat4 view;
    vec3 directionToLight;
} ubo;

layout(push_constant) uniform Push {
    mat4 transform;
    mat4 normalMatrix;
} push;

const vec3 DIRECTION_TO_LIGHT = normalize(vec3(1.0, -3.0, -1.0));
const float AMBIENT = 0.02;

void main() {
    gl_Position = ubo.view *  ubo.projection * push.transform* vec4(position, 1.0);
    vec3 normalWorldSpace = normalize(mat3(push.normalMatrix) * normal);
    float lightIntensity = AMBIENT + max(dot(normalWorldSpace, DIRECTION_TO_LIGHT), 0);
    v_color = lightIntensity * color;
    v_normal = normal;
    v_uv = lightIntensity * uv;
}
