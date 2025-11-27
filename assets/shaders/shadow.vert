#version 450

// Shadow map vertex shader - transforms vertices to light space

layout(location = 0) in vec3 position;
layout(location = 1) in vec3 color;
layout(location = 2) in vec2 uv;
layout(location = 3) in vec3 normal;

// Push constant contains: lightSpaceMatrix * modelMatrix
layout(push_constant) uniform Push {
    mat4 lightSpaceModel;  // lightProjection * lightView * model
} push;

void main() {
    gl_Position = push.lightSpaceModel * vec4(position, 1.0);
}
