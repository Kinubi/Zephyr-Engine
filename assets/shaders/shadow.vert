#version 450

// Cube shadow map vertex shader - transforms vertices and passes world position to fragment

layout(location = 0) in vec3 position;
layout(location = 1) in vec3 color;
layout(location = 2) in vec2 uv;
layout(location = 3) in vec3 normal;

layout(location = 0) out vec3 fragWorldPos;

// Push constant contains model matrix and light info
layout(push_constant) uniform Push {
    mat4 modelMatrix;
    vec4 lightPos;      // xyz = light position, w = far plane
    mat4 viewProj;      // view * projection for current face
} push;

void main() {
    vec4 worldPos = push.modelMatrix * vec4(position, 1.0);
    fragWorldPos = worldPos.xyz;
    gl_Position = push.viewProj * worldPos;
}
