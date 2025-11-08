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
    // Transform world position to view space
    vec4 viewPos = ubo.view * vec4(inPosition, 1.0);
    
    // Scale point size based on distance from camera
    float distance = length(viewPos.xyz);
    gl_PointSize = 80.0 / distance;
    
    // Transform to clip space
    gl_Position = ubo.projection * viewPos;
    
    fragColor = inColor; // Pass full RGBA
}