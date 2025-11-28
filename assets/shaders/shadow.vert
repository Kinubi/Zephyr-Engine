#version 450

// Shadow map vertex shader
// gl_InstanceIndex = which light (0 to MAX_LIGHTS-1)
// Geometry shader handles face selection via invocations

layout(location = 0) in vec3 position;
layout(location = 1) in vec3 color;
layout(location = 2) in vec2 uv;
layout(location = 3) in vec3 normal;

layout(location = 0) out vec3 outWorldPos;
layout(location = 1) flat out uint outLightIndex;

// Push constant contains model matrix
layout(push_constant) uniform Push {
    mat4 modelMatrix;
    uint numActiveLights;
    uint _padding[3];
} push;

void main() {
    vec4 worldPos = push.modelMatrix * vec4(position, 1.0);
    outWorldPos = worldPos.xyz;
    outLightIndex = uint(gl_InstanceIndex);
    
    // Geometry shader will set gl_Position with proper view-proj
    gl_Position = worldPos;
}
