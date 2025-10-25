#version 450
#extension GL_ARB_shader_draw_parameters : enable

const vec2 OFFSETS[6] = vec2[](
    vec2(-1.0, -1.0),
    vec2(-1.0, 1.0),
    vec2(1.0, -1.0),
    vec2(1.0, -1.0),
    vec2(-1.0, 1.0),
    vec2(1.0, 1.0));

layout(location = 4) out vec2 v_pos;
layout(location = 5) out vec4 v_color;
layout(location = 6) out float v_radius;

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
} ubo;

// SSBO for instanced light data
struct LightVolumeData {
    vec4 position;
    vec4 color;
    float radius;
    float _padding[3];
};

layout(set = 0, binding = 1) readonly buffer LightVolumeBuffer {
    LightVolumeData lights[];
} lightVolumes;

void main() {
    // Fetch light data for this instance
    LightVolumeData light = lightVolumes.lights[gl_InstanceIndex];
    
    v_pos = OFFSETS[gl_VertexIndex];
    v_color = light.color;
    v_radius = light.radius;
    
    vec3 cameraRightWorld = {
        ubo.view[0][0], ubo.view[1][0], ubo.view[2][0]
    };
    vec3 cameraUpWorld = {
        ubo.view[0][1], ubo.view[1][1], ubo.view[2][1]
    };

    vec3 positionWorld = light.position.xyz
    + light.radius * v_pos.x * cameraRightWorld
    + light.radius * v_pos.y * cameraUpWorld;

    gl_Position = ubo.projection * ubo.view * vec4(positionWorld, 1.0);
}