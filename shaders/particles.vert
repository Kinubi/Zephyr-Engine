#version 450

layout(location = 0) in vec3 inPosition;  // 3D world position
layout(location = 1) in vec3 inVelocity;  // 3D velocity (not used in vertex shader)
layout(location = 2) in vec4 inColor;

layout(set = 0, binding = 0) uniform GlobalUbo {
    mat4 projection;
    mat4 view;
} ubo;

layout(location = 0) out vec4 fragColor;

void main() {
    gl_PointSize = 14.0;
    
    // Transform world position to clip space
    vec4 worldPos = vec4(inPosition, 1.0);
    gl_Position = ubo.projection * ubo.view * worldPos;
    
    fragColor = inColor; // Pass full RGBA
}