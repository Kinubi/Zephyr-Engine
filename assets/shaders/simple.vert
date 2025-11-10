#version 450

layout(location = 0) in vec3 position;
layout(location = 1) in vec3 color;
layout(location = 2) in vec3 normal;
layout(location = 3) in vec2 uv;

layout(location = 1) out vec3 v_color;
layout(location = 2) out vec2 v_uv;
layout(location = 3) out vec3 v_normal;
layout(location = 4) out vec3 v_pos;

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

// Instance data SSBO for instanced rendering
struct InstanceData {
    mat4 transform;          // 16 floats
    uint materialIndex;      // 1 uint
};

layout(set = 1, binding = 2) readonly buffer InstanceDataBuffer {
    InstanceData instances[];
};

// Push constants for per-draw data
layout(push_constant) uniform PushConstants {
    mat4 transform;          // Legacy: per-object transform
    mat4 normalMatrix;       // Legacy: per-object normal matrix
    uint materialIndex;      // Legacy: per-object material
    uint instanceOffset;     // Instanced: offset into instance buffer
} push;

void main() {
    // Read instance data using gl_InstanceIndex + push constant offset
    // gl_InstanceIndex: 0-based index within this draw call
    // push.instanceOffset: starting index in the instance buffer for this batch
    InstanceData instance = instances[gl_InstanceIndex + push.instanceOffset];
    
    vec4 positionWorld = instance.transform * vec4(position, 1.0);
    gl_Position = ubo.projection * ubo.view * positionWorld;

    v_color = color;
    v_uv = uv;
    v_normal = normalize(transpose(inverse(mat3(instance.transform))) * normal);
    v_pos = positionWorld.xyz;
}
